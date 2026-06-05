#!/bin/bash
#
# download_videos.sh - Download videos from Procare video list
#
# Description:
#   Downloads video files from URLs in the JSON output of list_videos.sh.
#   Supports throttling, jitter, and resumable downloads (skips existing files).
#
# Prerequisites:
#   - raw_video_list_response.json (or custom input via -f)
#   - jq: Required for JSON parsing
#   - curl: Required for downloads
#
# Output:
#   - videos/YYYY-MM-DD HHMM <id>.<ext>: Downloaded video files
#
# Options:
#   -n <limit>    Number of videos to download (0 = all, default: 0)
#   -t <seconds>  Base sleep time between downloads (default: 2)
#   -j <seconds>  Max random jitter added to sleep (default: 2)
#   -f <file>     Input JSON file (default: raw_video_list_response.json)
#
# Usage:
#   ./download_videos.sh              # Download all videos
#   ./download_videos.sh -n 10        # Download first 10 videos
#   ./download_videos.sh -t 5 -j 3    # Custom throttling
#
set -euo pipefail

# Default values
LIMIT=0
THROTTLE=0
JITTER=0
INPUT_FILE="raw_video_list_response.json"

# Usage function
usage() {
    echo "Usage: $0 [-n limit] [-t throttle_sec] [-j jitter_sec] [-f input_file]"
    echo "  -n: Number of videos to download (default: 0 = all)"
    echo "  -t: Base sleep time between downloads (default: 2)"
    echo "  -j: Max random jitter time added to sleep (default: 2)"
    echo "  -f: Input JSON file (default: raw_video_list_response.json)"
    exit 1
}

# Parse arguments
while getopts "n:t:j:f:" opt; do
    case $opt in
        n) LIMIT=$OPTARG ;;
        t) THROTTLE=$OPTARG ;;
        j) JITTER=$OPTARG ;;
        f) INPUT_FILE=$OPTARG ;;
        *) usage ;;
    esac
done

# Validate numeric arguments
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

# Check input file exists
if [ ! -f "$INPUT_FILE" ]; then
    echo "Error: Input file '$INPUT_FILE' not found"
    exit 1
fi

# Create videos directory
mkdir -p videos

# Use mktemp for safer temp file creation
TEMP_FILE=$(mktemp)
TEMP_DIR=$(mktemp -d)
trap 'rm -f "$TEMP_FILE"; rm -rf "$TEMP_DIR"' EXIT

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

# Extract ID, created_at, and URL
if ! jq -r '.videos[] | [(.id | tostring), (.created_at // ""), (.video_file_url // "")] | @tsv' "$INPUT_FILE" > "$TEMP_FILE"; then
    echo "Error: Failed to parse JSON from '$INPUT_FILE'"
    exit 1
fi

# Counter for limit (counts successful downloads only)
COUNT=0

while IFS=$'\t' read -r id created_at url; do
    # Check limit if set
    if [ "$LIMIT" -gt 0 ] && [ "$COUNT" -ge "$LIMIT" ]; then
        echo "Limit of $LIMIT downloads reached."
        break
    fi

    if [ -z "$url" ]; then
        echo "[SKIP] $id has no download URL."
        continue
    fi

    SAFE_ID=$(sanitize_component "$id")
    TIMESTAMP_FIELDS=""
    FILENAME_DATE="unknown-date 0000"
    TOUCH_STAMP=""
    SETFILE_DATE=""

    if TIMESTAMP_FIELDS=$(format_created_at "$created_at"); then
        IFS='|' read -r FILENAME_DATE TOUCH_STAMP SETFILE_DATE <<< "$TIMESTAMP_FIELDS"
    else
        echo "[WARN] $id has unparseable created_at: $created_at"
    fi

    EXT=$(extension_from_url "$url" "mp4")
    FILENAME="videos/${FILENAME_DATE} ${SAFE_ID}.${EXT}"

    if [ -f "$FILENAME" ]; then
        echo "[SKIP] $FILENAME already exists."
        set_file_times "$FILENAME" "$TOUCH_STAMP" "$SETFILE_DATE"
    else
        TEMP_DOWNLOAD="${TEMP_DIR}/${SAFE_ID}.download"

        # Throttling with jitter
        if [ "$JITTER" -gt 0 ]; then
            RAND_JITTER=$(( RANDOM % (JITTER + 1) ))
        else
            RAND_JITTER=0
        fi
        SLEEP_TIME=$(( THROTTLE + RAND_JITTER ))

        if [ "$SLEEP_TIME" -gt 0 ]; then
            echo "Sleeping for ${SLEEP_TIME}s..."
            sleep "$SLEEP_TIME"
        fi

        echo "[DOWNLOADING] $FILENAME..."
        if curl -# -L -o "$TEMP_DOWNLOAD" "$url"; then
            mv "$TEMP_DOWNLOAD" "$FILENAME"
            set_file_times "$FILENAME" "$TOUCH_STAMP" "$SETFILE_DATE"
            echo "[SUCCESS] Saved to $FILENAME"
            COUNT=$((COUNT + 1))
        else
            echo "[ERROR] Failed to download $url"
            rm -f "$TEMP_DOWNLOAD"
        fi
    fi

done < "$TEMP_FILE"

echo "Downloaded $COUNT video(s)."
