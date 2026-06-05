#!/bin/bash
#
# download_photos.sh - Download photos from Procare photo list
#
# Description:
#   Downloads photo files from URLs in the JSON output of list_photos.sh.
#   Supports throttling, jitter, and resumable downloads (skips existing files).
#
# Prerequisites:
#   - raw_photo_list_response.json (or custom input via -f)
#   - jq: Required for JSON parsing
#   - curl: Required for downloads
#
# Output:
#   - photos/YYYY-MM-DD HHMM <id>.<ext>: Downloaded photo files
#
# Options:
#   -n <limit>    Number of photos to download (0 = all, default: 0)
#   -t <seconds>  Base sleep time between downloads (default: 2)
#   -j <seconds>  Max random jitter added to sleep (default: 2)
#   -f <file>     Input JSON file (default: raw_photo_list_response.json)
#
# Usage:
#   ./download_photos.sh              # Download all photos
#   ./download_photos.sh -n 10        # Download first 10 photos
#   ./download_photos.sh -t 5 -j 3    # Custom throttling
#
set -euo pipefail

# Default values
LIMIT=0
THROTTLE=0
JITTER=0
INPUT_FILE="raw_photo_list_response.json"

# Usage function
usage() {
    echo "Usage: $0 [-n limit] [-t throttle_sec] [-j jitter_sec] [-f input_file]"
    echo "  -n: Number of photos to download (default: 0 = all)"
    echo "  -t: Base sleep time between downloads (default: 2)"
    echo "  -j: Max random jitter time added to sleep (default: 2)"
    echo "  -f: Input JSON file (default: raw_photo_list_response.json)"
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

# Create photos directory
mkdir -p photos

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

# Extract ID, created_at, and URL
if ! jq -r '.photos[] | [(.id | tostring), (.created_at // ""), (.main_url // "")] | @tsv' "$INPUT_FILE" > "$TEMP_FILE"; then
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

    BASE_NAME="${FILENAME_DATE} ${SAFE_ID}"

    if EXISTING_FILE=$(find_existing_file "photos" "$BASE_NAME"); then
        echo "[SKIP] $EXISTING_FILE already exists."
        set_file_times "$EXISTING_FILE" "$TOUCH_STAMP" "$SETFILE_DATE"
    else
        EXT_GUESS=$(extension_from_url "$url" "jpg")
        TEMP_DOWNLOAD="${TEMP_DIR}/${SAFE_ID}.download"
        HEADER_FILE="${TEMP_DIR}/${SAFE_ID}.headers"

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

        echo "[DOWNLOADING] ${BASE_NAME}..."
        if curl -# -L -D "$HEADER_FILE" -o "$TEMP_DOWNLOAD" "$url"; then
            if EXT=$(extension_from_headers "$HEADER_FILE"); then
                :
            else
                EXT=$EXT_GUESS
            fi

            FILENAME="photos/${BASE_NAME}.${EXT}"
            mv "$TEMP_DOWNLOAD" "$FILENAME"
            set_file_times "$FILENAME" "$TOUCH_STAMP" "$SETFILE_DATE"
            echo "[SUCCESS] Saved to $FILENAME"
            COUNT=$((COUNT + 1))
        else
            echo "[ERROR] Failed to download $id"
            rm -f "$TEMP_DOWNLOAD"
        fi
    fi

done < "$TEMP_FILE"

echo "Downloaded $COUNT photo(s)."
