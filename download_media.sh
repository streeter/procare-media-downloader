#!/bin/bash
#
# download_media.sh - Download photos and videos from Procare media lists
#
# Description:
#   Downloads photo and video files from the JSON outputs of list_media.sh.
#   Supports throttling, jitter, resumable downloads, and safe
#   interrupted downloads.
#
# Prerequisites:
#   - raw_photo_list_response.json and raw_video_list_response.json
#   - jq: Required for JSON parsing
#   - curl: Required for downloads
#   - exiftool: Optional; writes embedded media creation and GPS metadata when present
#
# Output:
#   - photos/YYYY-MM-DD HHMM <photo-id>.<ext>: Downloaded photo files
#   - videos/YYYY-MM-DD HHMM <video-id>.<ext>: Downloaded video files
#
# Options:
#   -n, --limit <limit>          Number of each media type to download (0 = all, default: 0)
#   -t, --throttle <seconds>     Base sleep time between downloads (default: 0)
#   -j, --jitter <seconds>       Max random jitter added to sleep (default: 0)
#   -p, --photo-input <file>     Photo input JSON file (default: raw_photo_list_response.json)
#   -v, --video-input <file>     Video input JSON file (default: raw_video_list_response.json)
#   -m, --media <media>          Media to download: all, photo, or video (default: all)
#   -P, --parallel <count>       Parallel downloads per media type (default: 16)
#   -g, --geotag-file <file>     Optional local GPS JSON file (default: geotag.json)
#   -F, --failed-downloads-file <file>
#                                JSONL file for HTTP 403 failures
#
# Usage:
#   ./download_media.sh
#   ./download_media.sh -n 10
#   ./download_media.sh --limit 10
#   ./download_media.sh -t 5 -j 3
#   ./download_media.sh -m photo -p custom_photos.json
#   ./download_media.sh -P 8
#
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=media_common.sh
. "$SCRIPT_DIR/media_common.sh"

LIMIT=$DEFAULT_DOWNLOAD_LIMIT
THROTTLE=$DEFAULT_DOWNLOAD_THROTTLE
JITTER=$DEFAULT_DOWNLOAD_JITTER
PHOTO_INPUT_FILE=$DEFAULT_PHOTO_LIST_FILE
VIDEO_INPUT_FILE=$DEFAULT_VIDEO_LIST_FILE
GEOTAG_FILE=$DEFAULT_GEOTAG_FILE
FAILED_DOWNLOADS_FILE=$DEFAULT_FAILED_DOWNLOADS_FILE
MEDIA_SELECTION=$DEFAULT_MEDIA_SELECTION
PARALLEL_DOWNLOADS=$DEFAULT_PARALLEL_DOWNLOADS
RUN_ID="download-media-$$"
MEDIA_TIMEZONE=$DEFAULT_MEDIA_TIMEZONE
EXIFTOOL_BIN=""
GEOTAG_ENABLED=0
GEOTAG_LATITUDE=""
GEOTAG_LONGITUDE=""
GEOTAG_LATITUDE_ABS=""
GEOTAG_LONGITUDE_ABS=""
GEOTAG_LATITUDE_REF=""
GEOTAG_LONGITUDE_REF=""
GEOTAG_ISO6709=""
GPS_COORDINATE_TOLERANCE="0.000001"
ACTIVE_PIDS=()
ACTIVE_RESULTS=()
BATCH_DOWNLOADED=0
FAILED_DOWNLOADS=0

usage() {
    echo "Usage: $0 [-n|--limit limit] [-t|--throttle throttle_sec] [-j|--jitter jitter_sec] [-p|--photo-input photo_input] [-v|--video-input video_input] [-g|--geotag-file geotag_json] [-F|--failed-downloads-file file] [-m|--media all|photo|video] [-P|--parallel parallel]"
    echo "  -n, --limit: Number of each media type to download (default: $DEFAULT_DOWNLOAD_LIMIT = all)"
    echo "  -t, --throttle: Base sleep time between downloads (default: $DEFAULT_DOWNLOAD_THROTTLE)"
    echo "  -j, --jitter: Max random jitter time added to sleep (default: $DEFAULT_DOWNLOAD_JITTER)"
    echo "  -p, --photo-input: Photo input JSON file (default: $DEFAULT_PHOTO_LIST_FILE)"
    echo "  -v, --video-input: Video input JSON file (default: $DEFAULT_VIDEO_LIST_FILE)"
    echo "  -g, --geotag-file: Optional local GPS JSON file (default: $DEFAULT_GEOTAG_FILE)"
    echo "  -F, --failed-downloads-file: JSONL file for HTTP 403 failures (default: $DEFAULT_FAILED_DOWNLOADS_FILE)"
    echo "  -m, --media: Media to download: all, photo, or video (default: $DEFAULT_MEDIA_SELECTION)"
    echo "  -P, --parallel: Parallel downloads per media type (default: $DEFAULT_PARALLEL_DOWNLOADS)"
    echo "  -h, --help: Show this help message"
    exit "${1:-1}"
}

ARGS=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --limit)
            shift
            if [ "$#" -eq 0 ]; then
                echo "Error: --limit requires a value"
                exit 1
            fi
            ARGS+=("-n" "$1")
            ;;
        --limit=*)
            ARGS+=("-n" "${1#*=}")
            ;;
        --throttle)
            shift
            if [ "$#" -eq 0 ]; then
                echo "Error: --throttle requires a value"
                exit 1
            fi
            ARGS+=("-t" "$1")
            ;;
        --throttle=*)
            ARGS+=("-t" "${1#*=}")
            ;;
        --jitter)
            shift
            if [ "$#" -eq 0 ]; then
                echo "Error: --jitter requires a value"
                exit 1
            fi
            ARGS+=("-j" "$1")
            ;;
        --jitter=*)
            ARGS+=("-j" "${1#*=}")
            ;;
        --photo-input)
            shift
            if [ "$#" -eq 0 ]; then
                echo "Error: --photo-input requires a value"
                exit 1
            fi
            ARGS+=("-p" "$1")
            ;;
        --photo-input=*)
            ARGS+=("-p" "${1#*=}")
            ;;
        --video-input)
            shift
            if [ "$#" -eq 0 ]; then
                echo "Error: --video-input requires a value"
                exit 1
            fi
            ARGS+=("-v" "$1")
            ;;
        --video-input=*)
            ARGS+=("-v" "${1#*=}")
            ;;
        --geotag-file)
            shift
            if [ "$#" -eq 0 ]; then
                echo "Error: --geotag-file requires a value"
                exit 1
            fi
            ARGS+=("-g" "$1")
            ;;
        --geotag-file=*)
            ARGS+=("-g" "${1#*=}")
            ;;
        --failed-downloads-file)
            shift
            if [ "$#" -eq 0 ]; then
                echo "Error: --failed-downloads-file requires a value"
                exit 1
            fi
            ARGS+=("-F" "$1")
            ;;
        --failed-downloads-file=*)
            ARGS+=("-F" "${1#*=}")
            ;;
        --media)
            shift
            if [ "$#" -eq 0 ]; then
                echo "Error: --media requires a value"
                exit 1
            fi
            ARGS+=("-m" "$1")
            ;;
        --media=*)
            ARGS+=("-m" "${1#*=}")
            ;;
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
        --*)
            echo "Error: unknown option: $1"
            usage
            ;;
        *)
            ARGS+=("$1")
            ;;
    esac
    shift
done
if [ "${#ARGS[@]}" -gt 0 ]; then
    set -- "${ARGS[@]}"
else
    set --
fi

while getopts "n:t:j:p:v:g:F:m:P:h" opt; do
    case $opt in
        n) LIMIT=$OPTARG ;;
        t) THROTTLE=$OPTARG ;;
        j) JITTER=$OPTARG ;;
        p) PHOTO_INPUT_FILE=$OPTARG ;;
        v) VIDEO_INPUT_FILE=$OPTARG ;;
        g) GEOTAG_FILE=$OPTARG ;;
        F) FAILED_DOWNLOADS_FILE=$OPTARG ;;
        m) MEDIA_SELECTION=$OPTARG ;;
        P) PARALLEL_DOWNLOADS=$OPTARG ;;
        h) usage 0 ;;
        *) usage ;;
    esac
done

shift $((OPTIND - 1))

if [ "$#" -gt 0 ]; then
    echo "Error: unexpected argument: $1"
    usage
fi

validate_non_negative_integer "-n/--limit" "$LIMIT" || exit 1
validate_non_negative_integer "-t/--throttle" "$THROTTLE" || exit 1
validate_non_negative_integer "-j/--jitter" "$JITTER" || exit 1
validate_positive_integer "-P/--parallel" "$PARALLEL_DOWNLOADS" || exit 1
validate_media_selection "$MEDIA_SELECTION" "-m/--media" || exit 1

TEMP_DIR=$(mktemp -d)
LOG_LOCK_DIR="${TEMP_DIR}/log.lock"
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

print_parallel_download_error() {
    local file=$1
    local id=$2

    while ! mkdir "$LOG_LOCK_DIR" 2>/dev/null; do
        sleep 0.05
    done

    if [ -s "$file" ]; then
        cat "$file"
    fi
    echo "[ERROR] Failed to download $id"
    rmdir "$LOG_LOCK_DIR"
}

print_parallel_log_line() {
    local message=$1

    while ! mkdir "$LOG_LOCK_DIR" 2>/dev/null; do
        sleep 0.05
    done

    printf '%s\n' "$message"
    rmdir "$LOG_LOCK_DIR"
}

http_status_from_headers() {
    local headers_file=$1

    awk '/^HTTP\// { status = $2 } END { print status }' "$headers_file"
}

record_failed_download() {
    local media=$1
    local id=$2
    local created_at=$3
    local url_field=$4
    local http_status=$5
    local url=$6
    local recorded_at lock_dir

    if [ "$http_status" != 403 ]; then
        return 0
    fi

    recorded_at=$(date -u "+%Y-%m-%dT%H:%M:%SZ")
    lock_dir="${FAILED_DOWNLOADS_FILE}.lock"

    while ! mkdir "$lock_dir" 2>/dev/null; do
        sleep 0.05
    done

    jq -nc \
        --arg recorded_at "$recorded_at" \
        --arg media "$media" \
        --arg id "$id" \
        --arg created_at "$created_at" \
        --arg url_field "$url_field" \
        --argjson http_status "$http_status" \
        --arg url "$url" \
        '{recorded_at: $recorded_at, media: $media, id: $id, created_at: $created_at, url_field: $url_field, http_status: $http_status, url: $url}' \
        >> "$FAILED_DOWNLOADS_FILE"

    rmdir "$lock_dir"
}

format_created_at() {
    local created_at=$1
    local normalized

    normalized=$(printf '%s' "$created_at" \
        | sed -E 's/T/ /; s/\.[0-9]+//; s/Z$//; s/[[:space:]]+UTC$//; s/[+-][0-9]{2}:?[0-9]{2}$//')

    if [[ "$normalized" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        normalized="${normalized} 00:00:00"
    fi

    TZ="$MEDIA_TIMEZONE" date -j -f "%Y-%m-%d %H:%M:%S" "$normalized" "+%Y-%m-%d %H%M|%Y%m%d%H%M.%S|%m/%d/%Y %H:%M:%S|%Y:%m:%d %H:%M:%S|%Y-%m-%dT%H:%M:%S|%z" 2>/dev/null
}

colonize_timezone_offset() {
    local offset=$1

    if [[ "$offset" =~ ^[+-][0-9]{4}$ ]]; then
        printf '%s:%s' "${offset:0:3}" "${offset:3:2}"
        return 0
    fi

    return 1
}

is_decimal_number() {
    [[ "$1" =~ ^[+-]?([0-9]+([.][0-9]*)?|[.][0-9]+)$ ]]
}

validate_coordinate_range() {
    local label=$1
    local value=$2
    local min=$3
    local max=$4

    if ! is_decimal_number "$value"; then
        echo "Error: $label must be a decimal number"
        return 1
    fi

    if ! awk -v value="$value" -v min="$min" -v max="$max" 'BEGIN { exit !(value >= min && value <= max) }'; then
        echo "Error: $label must be between $min and $max"
        return 1
    fi
}

decimal_abs() {
    awk -v value="$1" 'BEGIN { if (value < 0) value = -value; printf "%.8f", value }'
}

coordinate_ref() {
    local value=$1
    local positive_ref=$2
    local negative_ref=$3

    if awk -v value="$value" 'BEGIN { exit !(value < 0) }'; then
        printf '%s' "$negative_ref"
    else
        printf '%s' "$positive_ref"
    fi
}

format_iso6709_coordinates() {
    local latitude=$1
    local longitude=$2

    awk -v latitude="$latitude" -v longitude="$longitude" 'BEGIN { printf "%+010.6f%+011.6f/", latitude, longitude }'
}

load_geotag_config() {
    local latitude
    local longitude

    if [ ! -f "$GEOTAG_FILE" ]; then
        return 0
    fi

    if ! jq -e . "$GEOTAG_FILE" >/dev/null 2>&1; then
        echo "Error: $GEOTAG_FILE is not valid JSON"
        exit 1
    fi

    if ! latitude=$(jq -er '(.latitude // .lat // .flat) | select(type == "number" or type == "string")' "$GEOTAG_FILE"); then
        echo "Error: $GEOTAG_FILE must contain latitude (or lat)"
        exit 1
    fi

    if ! longitude=$(jq -er '(.longitude // .long // .lng) | select(type == "number" or type == "string")' "$GEOTAG_FILE"); then
        echo "Error: $GEOTAG_FILE must contain longitude (or long/lng)"
        exit 1
    fi

    latitude=$(trim_whitespace "$latitude")
    longitude=$(trim_whitespace "$longitude")

    validate_coordinate_range "geotag latitude" "$latitude" -90 90 || exit 1
    validate_coordinate_range "geotag longitude" "$longitude" -180 180 || exit 1

    GEOTAG_ENABLED=1
    GEOTAG_LATITUDE=$latitude
    GEOTAG_LONGITUDE=$longitude
    GEOTAG_LATITUDE_ABS=$(decimal_abs "$GEOTAG_LATITUDE")
    GEOTAG_LONGITUDE_ABS=$(decimal_abs "$GEOTAG_LONGITUDE")
    GEOTAG_LATITUDE_REF=$(coordinate_ref "$GEOTAG_LATITUDE" N S)
    GEOTAG_LONGITUDE_REF=$(coordinate_ref "$GEOTAG_LONGITUDE" E W)
    GEOTAG_ISO6709=$(format_iso6709_coordinates "$GEOTAG_LATITUDE" "$GEOTAG_LONGITUDE")

    echo "Using GPS geotag from $GEOTAG_FILE (${GEOTAG_LATITUDE}, ${GEOTAG_LONGITUDE})."

    if [ -z "$EXIFTOOL_BIN" ]; then
        echo "[WARN] $GEOTAG_FILE exists, but exiftool is not available; GPS metadata will not be written."
    fi
}

set_file_times() {
    local file=$1
    local touch_stamp=$2
    local setfile_date=$3

    if [ -z "$touch_stamp" ]; then
        return 0
    fi

    if ! TZ="$MEDIA_TIMEZONE" touch -t "$touch_stamp" "$file" 2>/dev/null; then
        echo "[WARN] Unable to set modified time for $file"
    fi

    if command -v SetFile >/dev/null 2>&1; then
        if ! TZ="$MEDIA_TIMEZONE" SetFile -d "$setfile_date" "$file" 2>/dev/null; then
            echo "[WARN] Unable to set creation time for $file"
        fi
    fi
}

set_embedded_media_metadata() {
    local media=$1
    local file=$2
    local metadata_stamp=$3
    local iso_stamp=$4
    local timezone_offset=$5
    local timestamp_with_offset iso_timestamp_with_offset
    local -a api_args=()
    local -a tag_args=()

    if [ -z "$EXIFTOOL_BIN" ]; then
        return 0
    fi

    case "$media" in
        photo)
            if [ -n "$metadata_stamp" ] && [ -n "$timezone_offset" ]; then
                iso_timestamp_with_offset="${iso_stamp}${timezone_offset}"
                tag_args+=(
                    "-AllDates=$metadata_stamp"
                    "-OffsetTime=$timezone_offset"
                    "-OffsetTimeOriginal=$timezone_offset"
                    "-OffsetTimeDigitized=$timezone_offset"
                    "-XMP:CreateDate=$iso_timestamp_with_offset"
                    "-XMP:ModifyDate=$iso_timestamp_with_offset"
                    "-XMP:DateCreated=$iso_timestamp_with_offset"
                )
            fi

            if [ "$GEOTAG_ENABLED" -eq 1 ]; then
                tag_args+=(
                    "-GPSVersionID=2 3 0 0"
                    "-GPSLatitude=$GEOTAG_LATITUDE_ABS"
                    "-GPSLatitudeRef=$GEOTAG_LATITUDE_REF"
                    "-GPSLongitude=$GEOTAG_LONGITUDE_ABS"
                    "-GPSLongitudeRef=$GEOTAG_LONGITUDE_REF"
                )
            fi
            ;;
        video)
            api_args+=(-api QuickTimeUTC=1)

            if [ -n "$metadata_stamp" ] && [ -n "$timezone_offset" ]; then
                timestamp_with_offset="${metadata_stamp}${timezone_offset}"
                iso_timestamp_with_offset="${iso_stamp}${timezone_offset}"
                tag_args+=(
                    "-QuickTime:CreateDate=$timestamp_with_offset"
                    "-QuickTime:ModifyDate=$timestamp_with_offset"
                    "-QuickTime:TrackCreateDate=$timestamp_with_offset"
                    "-QuickTime:TrackModifyDate=$timestamp_with_offset"
                    "-QuickTime:MediaCreateDate=$timestamp_with_offset"
                    "-QuickTime:MediaModifyDate=$timestamp_with_offset"
                    "-Keys:CreationDate=$iso_timestamp_with_offset"
                    "-XMP:CreateDate=$iso_timestamp_with_offset"
                    "-XMP:ModifyDate=$iso_timestamp_with_offset"
                )
            fi

            if [ "$GEOTAG_ENABLED" -eq 1 ]; then
                tag_args+=(
                    "-ItemList:GPSCoordinates=$GEOTAG_ISO6709"
                    "-Keys:GPSCoordinates=$GEOTAG_ISO6709"
                    "-UserData:GPSCoordinates=$GEOTAG_ISO6709"
                )
            fi
            ;;
    esac

    if [ "${#tag_args[@]}" -eq 0 ]; then
        return 0
    fi

    if [ "${#api_args[@]}" -gt 0 ]; then
        if ! "$EXIFTOOL_BIN" -overwrite_original -P -q "${api_args[@]}" "${tag_args[@]}" "$file" >/dev/null 2>&1; then
            echo "[WARN] Unable to set embedded metadata for $file"
        fi
    else
        if ! "$EXIFTOOL_BIN" -overwrite_original -P -q "${tag_args[@]}" "$file" >/dev/null 2>&1; then
            echo "[WARN] Unable to set embedded metadata for $file"
        fi
    fi
}

has_expected_embedded_media_metadata() {
    local metadata_stamp=$1
    local timezone_offset=$2

    if [ -n "$metadata_stamp" ] && [ -n "$timezone_offset" ]; then
        return 0
    fi

    if [ "$GEOTAG_ENABLED" -eq 1 ]; then
        return 0
    fi

    return 1
}

exif_values_match() {
    local file=$1
    local expected=$2
    local actual
    shift 2

    if ! actual=$("$EXIFTOOL_BIN" -s3 -f "$@" "$file" 2>/dev/null); then
        return 1
    fi

    [ "$actual" = "$expected" ]
}

numeric_values_close() {
    local actual=$1
    local expected=$2
    local tolerance=$3

    awk -v actual="$actual" -v expected="$expected" -v tolerance="$tolerance" '
        BEGIN {
            if (actual !~ /^[-+]?([0-9]+([.][0-9]*)?|[.][0-9]+)$/ || expected !~ /^[-+]?([0-9]+([.][0-9]*)?|[.][0-9]+)$/) {
                exit 1
            }

            diff = actual - expected
            if (diff < 0) {
                diff = -diff
            }

            exit !(diff <= tolerance)
        }
    '
}

photo_gps_metadata_matches() {
    local file=$1
    local values actual_version actual_latitude actual_latitude_ref
    local actual_longitude actual_longitude_ref

    if ! values=$("$EXIFTOOL_BIN" -s3 -f -n \
        -GPSVersionID \
        -GPS:GPSLatitude \
        -GPS:GPSLatitudeRef \
        -GPS:GPSLongitude \
        -GPS:GPSLongitudeRef \
        "$file" 2>/dev/null); then
        return 1
    fi

    actual_version=$(printf '%s\n' "$values" | sed -n '1p')
    actual_latitude=$(printf '%s\n' "$values" | sed -n '2p')
    actual_latitude_ref=$(printf '%s\n' "$values" | sed -n '3p')
    actual_longitude=$(printf '%s\n' "$values" | sed -n '4p')
    actual_longitude_ref=$(printf '%s\n' "$values" | sed -n '5p')

    [ "$actual_version" = "2 3 0 0" ] || return 1
    [ "$actual_latitude_ref" = "$GEOTAG_LATITUDE_REF" ] || return 1
    [ "$actual_longitude_ref" = "$GEOTAG_LONGITUDE_REF" ] || return 1

    numeric_values_close "$actual_latitude" "$GEOTAG_LATITUDE_ABS" "$GPS_COORDINATE_TOLERANCE" || return 1
    numeric_values_close "$actual_longitude" "$GEOTAG_LONGITUDE_ABS" "$GPS_COORDINATE_TOLERANCE" || return 1
}

video_gps_line_matches() {
    local actual=$1
    local actual_latitude actual_longitude remainder

    [ "$actual" != "-" ] || return 1

    actual_latitude=${actual%% *}
    remainder=${actual#* }
    [ "$remainder" != "$actual" ] || return 1
    actual_longitude=${remainder%% *}

    numeric_values_close "$actual_latitude" "$GEOTAG_LATITUDE" "$GPS_COORDINATE_TOLERANCE" || return 1
    numeric_values_close "$actual_longitude" "$GEOTAG_LONGITUDE" "$GPS_COORDINATE_TOLERANCE" || return 1
}

video_gps_metadata_matches() {
    local file=$1
    local values item_list_coordinates keys_coordinates user_data_coordinates

    if ! values=$("$EXIFTOOL_BIN" -s3 -f -n \
        -ItemList:GPSCoordinates \
        -Keys:GPSCoordinates \
        -UserData:GPSCoordinates \
        "$file" 2>/dev/null); then
        return 1
    fi

    item_list_coordinates=$(printf '%s\n' "$values" | sed -n '1p')
    keys_coordinates=$(printf '%s\n' "$values" | sed -n '2p')
    user_data_coordinates=$(printf '%s\n' "$values" | sed -n '3p')

    video_gps_line_matches "$item_list_coordinates" || return 1
    video_gps_line_matches "$keys_coordinates" || return 1
    video_gps_line_matches "$user_data_coordinates" || return 1
}

photo_embedded_media_metadata_matches() {
    local file=$1
    local metadata_stamp=$2
    local timezone_offset=$3
    local timestamp_with_offset expected

    if [ -n "$metadata_stamp" ] && [ -n "$timezone_offset" ]; then
        timestamp_with_offset="${metadata_stamp}${timezone_offset}"
        expected=$(printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s' \
            "$metadata_stamp" \
            "$metadata_stamp" \
            "$metadata_stamp" \
            "$timezone_offset" \
            "$timezone_offset" \
            "$timezone_offset" \
            "$timestamp_with_offset" \
            "$timestamp_with_offset" \
            "$timestamp_with_offset")

        if ! exif_values_match "$file" "$expected" \
            -ExifIFD:DateTimeOriginal \
            -ExifIFD:CreateDate \
            -IFD0:ModifyDate \
            -ExifIFD:OffsetTime \
            -ExifIFD:OffsetTimeOriginal \
            -ExifIFD:OffsetTimeDigitized \
            -XMP:CreateDate \
            -XMP:ModifyDate \
            -XMP:DateCreated; then
            return 1
        fi
    fi

    if [ "$GEOTAG_ENABLED" -eq 1 ]; then
        if ! photo_gps_metadata_matches "$file"; then
            return 1
        fi
    fi

    return 0
}

video_embedded_media_metadata_matches() {
    local file=$1
    local metadata_stamp=$2
    local timezone_offset=$3
    local timestamp_with_offset expected

    if [ -n "$metadata_stamp" ] && [ -n "$timezone_offset" ]; then
        timestamp_with_offset="${metadata_stamp}${timezone_offset}"
        expected=$(printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s' \
            "$timestamp_with_offset" \
            "$timestamp_with_offset" \
            "$timestamp_with_offset" \
            "$timestamp_with_offset" \
            "$timestamp_with_offset" \
            "$timestamp_with_offset" \
            "$timestamp_with_offset" \
            "$timestamp_with_offset" \
            "$timestamp_with_offset")

        if ! exif_values_match "$file" "$expected" -api QuickTimeUTC=1 \
            -QuickTime:CreateDate \
            -QuickTime:ModifyDate \
            -QuickTime:TrackCreateDate \
            -QuickTime:TrackModifyDate \
            -QuickTime:MediaCreateDate \
            -QuickTime:MediaModifyDate \
            -Keys:CreationDate \
            -XMP:CreateDate \
            -XMP:ModifyDate; then
            return 1
        fi
    fi

    if [ "$GEOTAG_ENABLED" -eq 1 ]; then
        if ! video_gps_metadata_matches "$file"; then
            return 1
        fi
    fi

    return 0
}

embedded_media_metadata_matches() {
    local media=$1
    local file=$2
    local metadata_stamp=$3
    local timezone_offset=$4

    case "$media" in
        photo)
            photo_embedded_media_metadata_matches "$file" "$metadata_stamp" "$timezone_offset"
            ;;
        video)
            video_embedded_media_metadata_matches "$file" "$metadata_stamp" "$timezone_offset"
            ;;
        *)
            return 1
            ;;
    esac
}

verify_or_repair_existing_media_metadata() {
    local media=$1
    local file=$2
    local metadata_stamp=$3
    local iso_stamp=$4
    local timezone_offset=$5
    local touch_stamp=$6
    local setfile_date=$7

    normalize_media_extension "$file"
    file=$NORMALIZED_MEDIA_FILE

    if [ -z "$EXIFTOOL_BIN" ] || ! has_expected_embedded_media_metadata "$metadata_stamp" "$timezone_offset"; then
        echo "[SKIP] $file already exists."
        return 0
    fi

    if embedded_media_metadata_matches "$media" "$file" "$metadata_stamp" "$timezone_offset"; then
        echo "[SKIP] $file already exists with expected embedded metadata."
        return 0
    fi

    echo "[REPAIR] $file already exists; updating embedded metadata."
    set_embedded_media_metadata "$media" "$file" "$metadata_stamp" "$iso_stamp" "$timezone_offset"
    set_file_times "$file" "$touch_stamp" "$setfile_date"

    if ! embedded_media_metadata_matches "$media" "$file" "$metadata_stamp" "$timezone_offset"; then
        echo "[WARN] Embedded metadata for $file still differs after update."
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

extension_from_content_type() {
    local content_type=$1

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
    if extension_from_content_type "$content_type"; then
        return 0
    fi

    return 1
}

extension_from_file() {
    local file=$1
    local content_type ext

    if command -v file >/dev/null 2>&1; then
        content_type=$(file -b --mime-type "$file" 2>/dev/null || true)
        if extension_from_content_type "$content_type"; then
            return 0
        fi
    fi

    if [ -n "$EXIFTOOL_BIN" ]; then
        ext=$("$EXIFTOOL_BIN" -s3 -FileTypeExtension "$file" 2>/dev/null || true)
        if clean_extension "$ext"; then
            return 0
        fi
    fi

    return 1
}

normalize_media_extension() {
    local file=$1
    local actual_ext current_ext target

    NORMALIZED_MEDIA_FILE=$file

    if ! actual_ext=$(extension_from_file "$file"); then
        return 0
    fi

    current_ext=${file##*.}
    current_ext=$(clean_extension "$current_ext" || true)

    if [ "$actual_ext" = "$current_ext" ]; then
        return 0
    fi

    target="${file%.*}.${actual_ext}"
    if [ -e "$target" ]; then
        print_parallel_log_line "[WARN] $file is detected as .$actual_ext, but $target already exists; leaving name unchanged."
        return 0
    fi

    if mv "$file" "$target"; then
        print_parallel_log_line "[REPAIR] Renamed $file to $target to match detected media type."
        NORMALIZED_MEDIA_FILE=$target
    else
        print_parallel_log_line "[WARN] Unable to rename $file to .$actual_ext; leaving name unchanged."
    fi
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

    media_is_selected "$media" "$MEDIA_SELECTION"
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
    shift 6
    local -a candidate_fields=()
    local -a candidate_urls=()
    local safe_id timestamp_fields filename_date touch_stamp setfile_date
    local metadata_stamp iso_stamp timezone_offset_raw timezone_offset
    local base_name existing_file ext_guess temp_download header_file curl_error_file
    local ext filename http_status url_field url
    local attempt candidate_count success_status

    safe_id=$(sanitize_component "$id")
    timestamp_fields=""
    filename_date="unknown-date 0000"
    touch_stamp=""
    setfile_date=""
    metadata_stamp=""
    iso_stamp=""
    timezone_offset_raw=""
    timezone_offset=""
    temp_download=""
    curl_error_file=""
    ext_guess=$default_extension
    success_status=1

    while [ "$#" -gt 0 ]; do
        if [ "$#" -lt 2 ]; then
            echo "[ERROR] Internal error: URL candidate for $id is missing a value"
            printf '1\n' > "$result_file"
            return 0
        fi

        candidate_fields+=("$1")
        candidate_urls+=("$2")
        shift 2
    done
    candidate_count=${#candidate_urls[@]}

    if timestamp_fields=$(format_created_at "$created_at"); then
        IFS='|' read -r filename_date touch_stamp setfile_date metadata_stamp iso_stamp timezone_offset_raw <<< "$timestamp_fields"
        timezone_offset=$(colonize_timezone_offset "$timezone_offset_raw" || true)
    else
        echo "[WARN] $id has unparseable created_at: $created_at"
    fi

    base_name="${filename_date} ${safe_id}"

    if existing_file=$(find_existing_file "$output_dir" "$base_name"); then
        verify_or_repair_existing_media_metadata "$media" "$existing_file" "$metadata_stamp" "$iso_stamp" "$timezone_offset" "$touch_stamp" "$setfile_date"
        printf '2\n' > "$result_file"
        return 0
    fi

    if [ "$candidate_count" -eq 0 ]; then
        echo "[SKIP] $id has no download URL."
        printf '2\n' > "$result_file"
        return 0
    fi

    temp_download=$(mktemp "${output_dir}/.${safe_id}.${RUN_ID}.download.XXXXXX")
    CURRENT_DOWNLOAD=$temp_download
    header_file=$(mktemp "${TEMP_DIR}/${media}-${safe_id}.headers.XXXXXX")
    curl_error_file=$(mktemp "${TEMP_DIR}/${media}-${safe_id}.curl-error.XXXXXX")

    sleep_with_jitter "$THROTTLE" "$JITTER" "Sleeping for " "s before ${base_name}..."

    for ((attempt = 0; attempt < candidate_count; attempt++)); do
        url_field=${candidate_fields[$attempt]}
        url=${candidate_urls[$attempt]}
        ext_guess=$(extension_from_url "$url" "$default_extension")

        : > "$header_file"
        : > "$curl_error_file"
        rm -f "$temp_download"

        if [ "$attempt" -eq 0 ]; then
            echo "[DOWNLOADING] ${base_name}..."
        else
            echo "[DOWNLOADING] ${base_name} (${url_field})..."
        fi

        if curl --fail --silent --show-error -L -D "$header_file" -o "$temp_download" "$url" 2>"$curl_error_file"; then
            success_status=0
            break
        fi

        http_status=$(http_status_from_headers "$header_file")
        record_failed_download "$media" "$id" "$created_at" "$url_field" "$http_status" "$url"

        if [ "$http_status" = 403 ] && [ $((attempt + 1)) -lt "$candidate_count" ]; then
            print_parallel_log_line "[WARN] $id $url_field returned HTTP 403; trying ${candidate_fields[$((attempt + 1))]}."
            continue
        fi

        break
    done

    if [ "$success_status" -ne 0 ]; then
        print_parallel_download_error "$curl_error_file" "$id"
        rm -f "$temp_download"
        CURRENT_DOWNLOAD=""
        printf '1\n' > "$result_file"
        return 0
    fi

    if ext=$(extension_from_file "$temp_download"); then
        :
    elif ext=$(extension_from_headers "$header_file"); then
        :
    else
        ext=$ext_guess
    fi

    filename="${output_dir}/${base_name}.${ext}"
    mv "$temp_download" "$filename"
    CURRENT_DOWNLOAD=""
    set_embedded_media_metadata "$media" "$filename" "$metadata_stamp" "$iso_stamp" "$timezone_offset"
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
    local media_collection
    local output_dir
    local input_file default_extension
    local temp_file count limit_reached active_count should_wait
    local id created_at main_url medium_url thumb_url video_file_url safe_id result_file
    local candidate_field candidate_url seen_urls
    local -a candidate_args=()
    local -a candidate_fields=()

    media_collection=$(media_plural "$media")
    output_dir=$media_collection

    case "$media" in
        photo)
            input_file=$PHOTO_INPUT_FILE
            default_extension=jpg
            candidate_fields=(main_url medium_url thumb_url)
            ;;
        video)
            input_file=$VIDEO_INPUT_FILE
            default_extension=mp4
            candidate_fields=(video_file_url)
            ;;
        *)
            echo "Error: unsupported media '$media'"
            exit 1
            ;;
    esac

    mkdir -p "$output_dir"
    temp_file="${TEMP_DIR}/${media}.tsv"

    if ! jq -r --arg collection "$media_collection" '.[$collection][] | [(.id | tostring), (.created_at // ""), (.main_url // ""), (.medium_url // ""), (.thumb_url // ""), (.video_file_url // "")] | @tsv' "$input_file" > "$temp_file"; then
        echo "Error: Failed to parse JSON from '$input_file'"
        exit 1
    fi

    count=0
    limit_reached=0
    FAILED_DOWNLOADS=0
    ACTIVE_PIDS=()
    ACTIVE_RESULTS=()

    echo "Downloading ${media_collection} from $input_file with ${PARALLEL_DOWNLOADS} parallel download(s)..."

    while IFS=$'\t' read -r id created_at main_url medium_url thumb_url video_file_url; do
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

        candidate_args=()
        seen_urls=$'\n'

        for candidate_field in "${candidate_fields[@]}"; do
            case "$candidate_field" in
                main_url) candidate_url=$main_url ;;
                medium_url) candidate_url=$medium_url ;;
                thumb_url) candidate_url=$thumb_url ;;
                video_file_url) candidate_url=$video_file_url ;;
                *) candidate_url="" ;;
            esac

            if [ -z "$candidate_url" ]; then
                continue
            fi

            if [[ "$seen_urls" == *$'\n'"$candidate_url"$'\n'* ]]; then
                continue
            fi

            candidate_args+=("$candidate_field" "$candidate_url")
            seen_urls="${seen_urls}${candidate_url}"$'\n'
        done

        if [ "${#candidate_args[@]}" -eq 0 ]; then
            echo "[SKIP] $id has no download URL."
            continue
        fi

        safe_id=$(sanitize_component "$id")
        result_file=$(mktemp "${TEMP_DIR}/${media}-${safe_id}.status.XXXXXX")
        launch_download_job "$result_file" "$media" "$output_dir" "$default_extension" "$id" "$created_at" "${candidate_args[@]}"
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

EXIFTOOL_BIN=$(command -v exiftool 2>/dev/null || true)
if [ -z "$EXIFTOOL_BIN" ]; then
    echo "[WARN] exiftool not found; embedded photo/video creation and GPS metadata will not be written."
fi

load_geotag_config

if should_download_media photo; then
    download_one_media_type photo
fi

if should_download_media video; then
    download_one_media_type video
fi
