#!/bin/bash
#
# download_media.sh - Download photos and videos from Procare media lists
#
# Description:
#   Downloads photo and video files from the JSON outputs of list_photos.sh and
#   list_videos.sh. Supports throttling, jitter, resumable downloads, and safe
#   interrupted downloads.
#
# Prerequisites:
#   - raw_photo_list_response.json and raw_video_list_response.json
#   - jq: Required for JSON parsing
#   - curl: Required for downloads
#
# Output:
#   - photos/YYYY-MM-DD HHMM <photo-id>.<ext>: Downloaded photo files
#   - videos/YYYY-MM-DD HHMM <video-id>.<ext>: Downloaded video files
#
# Options:
#   -n <limit>    Number of each media type to download (0 = all, default: 0)
#   -t <seconds>  Base sleep time between downloads (default: 0)
#   -j <seconds>  Max random jitter added to sleep (default: 0)
#   -p <file>     Photo input JSON file (default: raw_photo_list_response.json)
#   -v <file>     Video input JSON file (default: raw_video_list_response.json)
#   -m <media>    Media to download: all, photo, or video (default: all)
#   -P <count>    Parallel downloads per media type (default: 4)
#
# Usage:
#   ./download_media.sh
#   ./download_media.sh -n 10
#   ./download_media.sh -t 5 -j 3
#   ./download_media.sh -m photo -p custom_photos.json
#   ./download_media.sh -P 8
#
set -euo pipefail

# Default values
LIMIT=0
THROTTLE=0
JITTER=0
PHOTO_INPUT_FILE="raw_photo_list_response.json"
VIDEO_INPUT_FILE="raw_video_list_response.json"
MEDIA_SELECTION=all
PARALLEL_DOWNLOADS=4
RUN_ID="download-media-$$"
ACTIVE_PIDS=()
ACTIVE_RESULTS=()
BATCH_DOWNLOADED=0
FAILED_DOWNLOADS=0

usage() {
    echo "Usage: $0 [-n limit] [-t throttle_sec] [-j jitter_sec] [-p photo_input] [-v video_input] [-m all|photo|video] [-P parallel]"
    echo "  -n: Number of each media type to download (default: 0 = all)"
    echo "  -t: Base sleep time between downloads (default: 0)"
    echo "  -j: Max random jitter time added to sleep (default: 0)"
    echo "  -p: Photo input JSON file (default: raw_photo_list_response.json)"
    echo "  -v: Video input JSON file (default: raw_video_list_response.json)"
    echo "  -m: Media to download: all, photo, or video (default: all)"
    echo "  -P, --parallel: Parallel downloads per media type (default: 4)"
    echo "  -h, --help: Show this help message"
    exit "${1:-1}"
}

ARGS=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --parallel)
            shift
            if [ "$#" -eq 0 ]; then
                echo "Error: --parallel requires a value"
                exit 1
            fi
            ARGS+=("-P" "$1")
            ;;
        --parallel=*)
            ARGS+=("-P" "${1#*=}")
            ;;
        --help)
            usage 0
            ;;
        --)
            shift
            while [ "$#" -gt 0 ]; do
                ARGS+=("$1")
                shift
            done
            break
            ;;
        *)
            ARGS+=("$1")
            ;;
    esac
    shift
done
set -- ${ARGS[@]+"${ARGS[@]}"}

while getopts "n:t:j:p:v:m:P:h" opt; do
    case $opt in
        n) LIMIT=$OPTARG ;;
        t) THROTTLE=$OPTARG ;;
        j) JITTER=$OPTARG ;;
        p) PHOTO_INPUT_FILE=$OPTARG ;;
        v) VIDEO_INPUT_FILE=$OPTARG ;;
        m) MEDIA_SELECTION=$OPTARG ;;
        P) PARALLEL_DOWNLOADS=$OPTARG ;;
        h) usage 0 ;;
        *) usage ;;
    esac
done

if ! [[ "$LIMIT" =~ ^[0-9]+$ ]]; then
    echo "Error: -n must be a non-negative integer"
    exit 1
fi
if ! [[ "$THROTTLE" =~ ^[0-9]+$ ]]; then
    echo "Error: -t must be a non-negative integer"
    exit 1
fi
if ! [[ "$JITTER" =~ ^[0-9]+$ ]]; then
    echo "Error: -j must be a non-negative integer"
    exit 1
fi
if ! [[ "$PARALLEL_DOWNLOADS" =~ ^[0-9]+$ ]] || [ "$PARALLEL_DOWNLOADS" -lt 1 ]; then
    echo "Error: -P/--parallel must be a positive integer"
    exit 1
fi
case "$MEDIA_SELECTION" in
    all|photo|video) ;;
    *)
        echo "Error: -m must be one of: all, photo, video"
        exit 1
        ;;
esac

TEMP_DIR=$(mktemp -d)
CURRENT_DOWNLOAD=""

cleanup() {
    local partial

    if [ "${#ACTIVE_PIDS[@]}" -gt 0 ]; then
        kill "${ACTIVE_PIDS[@]}" 2>/dev/null || true
        wait "${ACTIVE_PIDS[@]}" 2>/dev/null || true
    fi

    for partial in photos/.*."$RUN_ID".download.* videos/.*."$RUN_ID".download.*; do
        if [ -e "$partial" ]; then
            rm -f "$partial"
        fi
    done

    rm -rf "$TEMP_DIR"
    if [ -n "$CURRENT_DOWNLOAD" ]; then
        rm -f "$CURRENT_DOWNLOAD"
    fi
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

sanitize_component() {
    printf '%s' "$1" | tr -c '[:alnum:]_.-' '_'
}

format_created_at() {
    local created_at=$1
    local normalized

    normalized=$(printf '%s' "$created_at" \
        | sed -E 's/T/ /; s/\.[0-9]+//; s/Z$//; s/[[:space:]]+UTC$//; s/[+-][0-9]{2}:?[0-9]{2}$//')

    if [[ "$normalized" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        normalized="${normalized} 00:00:00"
    fi

    date -j -f "%Y-%m-%d %H:%M:%S" "$normalized" "+%Y-%m-%d %H%M|%Y%m%d%H%M.%S|%m/%d/%Y %H:%M:%S" 2>/dev/null
}

set_file_times() {
    local file=$1
    local touch_stamp=$2
    local setfile_date=$3

    if [ -z "$touch_stamp" ]; then
        return 0
    fi

    if ! touch -t "$touch_stamp" "$file" 2>/dev/null; then
        echo "[WARN] Unable to set modified time for $file"
    fi

    if command -v SetFile >/dev/null 2>&1; then
        if ! SetFile -d "$setfile_date" "$file" 2>/dev/null; then
            echo "[WARN] Unable to set creation time for $file"
        fi
    fi
}

clean_extension() {
    local ext
    ext=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]')

    if [ -n "$ext" ] && [ "${#ext}" -le 5 ]; then
        printf '%s' "$ext"
        return 0
    fi

    return 1
}

extension_from_url() {
    local url=$1
    local fallback=$2
    local path basename ext

    path=${url%%\?*}
    path=${path%%#*}
    basename=${path##*/}

    if [[ "$basename" == *.* ]]; then
        ext=${basename##*.}
        if clean_extension "$ext"; then
            return 0
        fi
    fi

    printf '%s' "$fallback"
}

extension_from_headers() {
    local headers_file=$1
    local filename content_type ext

    filename=$(awk 'BEGIN{IGNORECASE=1} /^Content-Disposition:/ {line=$0} END{sub(/\r$/, "", line); print line}' "$headers_file" \
        | sed -nE 's/.*filename="?([^";]+)"?.*/\1/p')
    if [[ "$filename" == *.* ]]; then
        ext=${filename##*.}
        if clean_extension "$ext"; then
            return 0
        fi
    fi

    content_type=$(awk 'BEGIN{IGNORECASE=1} /^Content-Type:/ {line=$0} END{sub(/\r$/, "", line); sub(/^[^:]+:[[:space:]]*/, "", line); sub(/;.*/, "", line); print tolower(line)}' "$headers_file")
    case "$content_type" in
        image/jpeg|image/jpg) printf 'jpg'; return 0 ;;
        image/png) printf 'png'; return 0 ;;
        image/gif) printf 'gif'; return 0 ;;
        image/heic) printf 'heic'; return 0 ;;
        image/heif) printf 'heif'; return 0 ;;
        image/webp) printf 'webp'; return 0 ;;
        video/mp4) printf 'mp4'; return 0 ;;
        video/quicktime) printf 'mov'; return 0 ;;
        video/webm) printf 'webm'; return 0 ;;
        video/x-m4v) printf 'm4v'; return 0 ;;
        video/x-msvideo) printf 'avi'; return 0 ;;
    esac

    return 1
}

find_existing_file() {
    local dir=$1
    local base_name=$2
    local existing

    for existing in "$dir/${base_name}".*; do
        if [ -e "$existing" ]; then
            printf '%s' "$existing"
            return 0
        fi
    done

    return 1
}

should_download_media() {
    local media=$1

    [ "$MEDIA_SELECTION" = all ] || [ "$MEDIA_SELECTION" = "$media" ]
}

input_file_for_media() {
    local media=$1

    case "$media" in
        photo) printf '%s' "$PHOTO_INPUT_FILE" ;;
        video) printf '%s' "$VIDEO_INPUT_FILE" ;;
    esac
}

validate_selected_inputs() {
    local media input_file

    for media in photo video; do
        if should_download_media "$media"; then
            input_file=$(input_file_for_media "$media")
            if [ ! -f "$input_file" ]; then
                echo "Error: Input file '$input_file' not found"
                exit 1
            fi
        fi
    done
}

download_media_item() {
    local result_file=$1
    local media=$2
    local output_dir=$3
    local default_extension=$4
    local id=$5
    local created_at=$6
    local url=$7
    local safe_id timestamp_fields filename_date touch_stamp setfile_date
    local base_name existing_file ext_guess temp_download header_file
    local sleep_time rand_jitter ext filename

    safe_id=$(sanitize_component "$id")
    timestamp_fields=""
    filename_date="unknown-date 0000"
    touch_stamp=""
    setfile_date=""
    temp_download=""

    if timestamp_fields=$(format_created_at "$created_at"); then
        IFS='|' read -r filename_date touch_stamp setfile_date <<< "$timestamp_fields"
    else
        echo "[WARN] $id has unparseable created_at: $created_at"
    fi

    base_name="${filename_date} ${safe_id}"

    if existing_file=$(find_existing_file "$output_dir" "$base_name"); then
        echo "[SKIP] $existing_file already exists."
        set_file_times "$existing_file" "$touch_stamp" "$setfile_date"
        printf '2\n' > "$result_file"
        return 0
    fi

    ext_guess=$(extension_from_url "$url" "$default_extension")
    temp_download=$(mktemp "${output_dir}/.${safe_id}.${RUN_ID}.download.XXXXXX")
    CURRENT_DOWNLOAD=$temp_download
    header_file=$(mktemp "${TEMP_DIR}/${media}-${safe_id}.headers.XXXXXX")

    if [ "$JITTER" -gt 0 ]; then
        rand_jitter=$(( RANDOM % (JITTER + 1) ))
    else
        rand_jitter=0
    fi
    sleep_time=$(( THROTTLE + rand_jitter ))

    if [ "$sleep_time" -gt 0 ]; then
        echo "Sleeping for ${sleep_time}s before ${base_name}..."
        sleep "$sleep_time"
    fi

    echo "[DOWNLOADING] ${base_name}..."
    if [ "$PARALLEL_DOWNLOADS" -gt 1 ]; then
        if curl --fail --silent --show-error -L -D "$header_file" -o "$temp_download" "$url"; then
            :
        else
            echo "[ERROR] Failed to download $id"
            rm -f "$temp_download"
            CURRENT_DOWNLOAD=""
            printf '1\n' > "$result_file"
            return 0
        fi
    else
        if curl --fail -# -L -D "$header_file" -o "$temp_download" "$url"; then
            :
        else
            echo "[ERROR] Failed to download $id"
            rm -f "$temp_download"
            CURRENT_DOWNLOAD=""
            printf '1\n' > "$result_file"
            return 0
        fi
    fi

    if ext=$(extension_from_headers "$header_file"); then
        :
    else
        ext=$ext_guess
    fi

    filename="${output_dir}/${base_name}.${ext}"
    mv "$temp_download" "$filename"
    CURRENT_DOWNLOAD=""
    set_file_times "$filename" "$touch_stamp" "$setfile_date"
    echo "[SUCCESS] Saved to $filename"
    printf '0\n' > "$result_file"
    return 0
}

launch_download_job() {
    local result_file=$1
    shift

    (
        download_media_item "$result_file" "$@"
    ) &

    ACTIVE_PIDS+=("$!")
    ACTIVE_RESULTS+=("$result_file")
}

wait_for_active_jobs() {
    local i pid result_file wait_status status

    BATCH_DOWNLOADED=0

    for ((i = 0; i < ${#ACTIVE_PIDS[@]}; i++)); do
        pid=${ACTIVE_PIDS[$i]}
        result_file=${ACTIVE_RESULTS[$i]}

        if wait "$pid"; then
            wait_status=0
        else
            wait_status=$?
        fi

        if [ -f "$result_file" ]; then
            status=$(sed -n '1p' "$result_file")
        else
            status=$wait_status
        fi

        case "$status" in
            0)
                BATCH_DOWNLOADED=$((BATCH_DOWNLOADED + 1))
                ;;
            2)
                ;;
            *)
                FAILED_DOWNLOADS=$((FAILED_DOWNLOADS + 1))
                ;;
        esac
    done

    ACTIVE_PIDS=()
    ACTIVE_RESULTS=()
}

download_one_media_type() {
    local media=$1
    local media_plural="${media}s"
    local output_dir=$media_plural
    local input_file default_extension url_field
    local temp_file count limit_reached active_count should_wait
    local id created_at url safe_id result_file

    case "$media" in
        photo)
            input_file=$PHOTO_INPUT_FILE
            default_extension=jpg
            url_field=main_url
            ;;
        video)
            input_file=$VIDEO_INPUT_FILE
            default_extension=mp4
            url_field=video_file_url
            ;;
        *)
            echo "Error: unsupported media '$media'"
            exit 1
            ;;
    esac

    mkdir -p "$output_dir"
    temp_file="${TEMP_DIR}/${media}.tsv"

    if ! jq -r --arg collection "$media_plural" --arg url_field "$url_field" '.[$collection][] | [(.id | tostring), (.created_at // ""), (.[$url_field] // "")] | @tsv' "$input_file" > "$temp_file"; then
        echo "Error: Failed to parse JSON from '$input_file'"
        exit 1
    fi

    count=0
    limit_reached=0
    FAILED_DOWNLOADS=0
    ACTIVE_PIDS=()
    ACTIVE_RESULTS=()

    echo "Downloading ${media_plural} from $input_file with ${PARALLEL_DOWNLOADS} parallel download(s)..."

    while IFS=$'\t' read -r id created_at url; do
        while :; do
            active_count=${#ACTIVE_PIDS[@]}
            should_wait=0

            if [ "$active_count" -ge "$PARALLEL_DOWNLOADS" ]; then
                should_wait=1
            fi
            if [ "$LIMIT" -gt 0 ] && [ $((count + active_count)) -ge "$LIMIT" ]; then
                should_wait=1
            fi
            if [ "$should_wait" -eq 0 ]; then
                break
            fi

            wait_for_active_jobs
            count=$((count + BATCH_DOWNLOADED))

            if [ "$LIMIT" -gt 0 ] && [ "$count" -ge "$LIMIT" ]; then
                echo "Limit of $LIMIT ${media} downloads reached."
                limit_reached=1
                break
            fi
        done

        if [ "$limit_reached" -eq 1 ]; then
            break
        fi

        if [ -z "$url" ]; then
            echo "[SKIP] $id has no download URL."
            continue
        fi

        safe_id=$(sanitize_component "$id")
        result_file=$(mktemp "${TEMP_DIR}/${media}-${safe_id}.status.XXXXXX")
        launch_download_job "$result_file" "$media" "$output_dir" "$default_extension" "$id" "$created_at" "$url"
    done < "$temp_file"

    if [ "${#ACTIVE_PIDS[@]}" -gt 0 ]; then
        wait_for_active_jobs
        count=$((count + BATCH_DOWNLOADED))
    fi

    echo "Downloaded $count ${media}(s)."
    if [ "$FAILED_DOWNLOADS" -gt 0 ]; then
        echo "[WARN] $FAILED_DOWNLOADS ${media} download(s) failed."
    fi
}

validate_selected_inputs

if should_download_media photo; then
    download_one_media_type photo
fi

if should_download_media video; then
    download_one_media_type video
fi
