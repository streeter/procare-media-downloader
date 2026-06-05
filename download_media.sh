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
#
# Usage:
#   ./download_media.sh
#   ./download_media.sh -n 10
#   ./download_media.sh -t 5 -j 3
#   ./download_media.sh -m photo -p custom_photos.json
#
set -euo pipefail

# Default values
LIMIT=0
THROTTLE=0
JITTER=0
PHOTO_INPUT_FILE="raw_photo_list_response.json"
VIDEO_INPUT_FILE="raw_video_list_response.json"
MEDIA_SELECTION=all

usage() {
    echo "Usage: $0 [-n limit] [-t throttle_sec] [-j jitter_sec] [-p photo_input] [-v video_input] [-m all|photo|video]"
    echo "  -n: Number of each media type to download (default: 0 = all)"
    echo "  -t: Base sleep time between downloads (default: 0)"
    echo "  -j: Max random jitter time added to sleep (default: 0)"
    echo "  -p: Photo input JSON file (default: raw_photo_list_response.json)"
    echo "  -v: Video input JSON file (default: raw_video_list_response.json)"
    echo "  -m: Media to download: all, photo, or video (default: all)"
    echo "  -h, --help: Show this help message"
    exit "${1:-1}"
}

for arg in "$@"; do
    case "$arg" in
        -h|--help) usage 0 ;;
    esac
done

while getopts "n:t:j:p:v:m:h" opt; do
    case $opt in
        n) LIMIT=$OPTARG ;;
        t) THROTTLE=$OPTARG ;;
        j) JITTER=$OPTARG ;;
        p) PHOTO_INPUT_FILE=$OPTARG ;;
        v) VIDEO_INPUT_FILE=$OPTARG ;;
        m) MEDIA_SELECTION=$OPTARG ;;
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

download_one_media_type() {
    local media=$1
    local media_plural="${media}s"
    local output_dir=$media_plural
    local input_file default_extension url_field
    local temp_file count
    local id created_at url safe_id timestamp_fields filename_date touch_stamp setfile_date
    local base_name existing_file ext_guess temp_download header_file sleep_time rand_jitter ext filename

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
    echo "Downloading ${media_plural} from $input_file..."

    while IFS=$'\t' read -r id created_at url; do
        if [ "$LIMIT" -gt 0 ] && [ "$count" -ge "$LIMIT" ]; then
            echo "Limit of $LIMIT ${media} downloads reached."
            break
        fi

        if [ -z "$url" ]; then
            echo "[SKIP] $id has no download URL."
            continue
        fi

        safe_id=$(sanitize_component "$id")
        timestamp_fields=""
        filename_date="unknown-date 0000"
        touch_stamp=""
        setfile_date=""

        if timestamp_fields=$(format_created_at "$created_at"); then
            IFS='|' read -r filename_date touch_stamp setfile_date <<< "$timestamp_fields"
        else
            echo "[WARN] $id has unparseable created_at: $created_at"
        fi

        base_name="${filename_date} ${safe_id}"

        if existing_file=$(find_existing_file "$output_dir" "$base_name"); then
            echo "[SKIP] $existing_file already exists."
            set_file_times "$existing_file" "$touch_stamp" "$setfile_date"
        else
            ext_guess=$(extension_from_url "$url" "$default_extension")
            temp_download=$(mktemp "${output_dir}/.${safe_id}.download.XXXXXX")
            CURRENT_DOWNLOAD=$temp_download
            header_file="${TEMP_DIR}/${media}-${safe_id}.headers"

            if [ "$JITTER" -gt 0 ]; then
                rand_jitter=$(( RANDOM % (JITTER + 1) ))
            else
                rand_jitter=0
            fi
            sleep_time=$(( THROTTLE + rand_jitter ))

            if [ "$sleep_time" -gt 0 ]; then
                echo "Sleeping for ${sleep_time}s..."
                sleep "$sleep_time"
            fi

            echo "[DOWNLOADING] ${base_name}..."
            if curl --fail -# -L -D "$header_file" -o "$temp_download" "$url"; then
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
                count=$((count + 1))
            else
                echo "[ERROR] Failed to download $id"
                rm -f "$temp_download"
                CURRENT_DOWNLOAD=""
            fi
        fi
    done < "$temp_file"

    echo "Downloaded $count ${media}(s)."
}

validate_selected_inputs

if should_download_media photo; then
    download_one_media_type photo
fi

if should_download_media video; then
    download_one_media_type video
fi
