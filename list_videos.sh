#!/bin/bash
#
# list_videos.sh - Fetch paginated video list from Procare API
#
# Description:
#   Retrieves all videos from the Procare parent portal API by iterating
#   through 1-month date ranges and paginating within each month.
#   Results are merged into a single JSON file.
#
# Prerequisites:
#   - credentials.txt: File containing the Bearer auth token (no newline)
#   - jq: Required for JSON parsing
#   - curl: Required for API requests
#
# Output:
#   - raw_video_list_response.json: Combined JSON with all videos
#     Format: { "videos": [...], "total": <count> }
#
# Usage:
#   ./list_videos.sh
#
set -euo pipefail

# Configuration
BASE_URL="https://api-school.procareconnect.com/api/web/parent/videos/"
OUTPUT_FILE="raw_video_list_response.json"

# Throttling settings
THROTTLE=1
JITTER=2

# Date range
START_YEAR=2023
START_MONTH=1
END_YEAR=2026
END_MONTH=8

# Initialize counters
EXPECTED_VIDEO_COUNT=0
ACTUAL_VIDEO_COUNT=0
TOTAL_API_CALLS=0
FILE_INDEX=0

# Load credentials
if [ ! -f "credentials.txt" ]; then
    echo "Error: credentials.txt not found."
    exit 1
fi
AUTH_TOKEN=$(cat credentials.txt | tr -d '\n')


# Create a unique temp directory for this run so concurrent list scripts do not
# delete or merge each other's page files.
TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/list_videos.XXXXXX")
cleanup() {
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

# Function to get last day of month (macOS compatible)
get_last_day() {
    local year=$1
    local month=$2
    if [ "$month" -eq 12 ]; then
        echo 31
    else
        local next_month=$((month + 1))
        local next_month_padded=$(printf "%02d" $next_month)
        date -j -v-1d -f "%Y-%m-%d" "${year}-${next_month_padded}-01" +%d 2>/dev/null
    fi
}

# Function to make API call with throttling
fetch_page() {
    local url=$1
    local output_file=$2

    # Throttling with jitter
    if [ "$JITTER" -gt 0 ]; then
        RAND_JITTER=$(( RANDOM % (JITTER + 1) ))
    else
        RAND_JITTER=0
    fi
    SLEEP_TIME=$(( THROTTLE + RAND_JITTER ))

    if [ "$SLEEP_TIME" -gt 0 ]; then
        echo "  Sleeping for ${SLEEP_TIME}s..."
        sleep "$SLEEP_TIME"
    fi

    curl -s "$url" \
      -H 'Accept: application/json' \
      -H "Authorization: Bearer $AUTH_TOKEN" \
      -o "$output_file"
}

echo "Starting video list retrieval (month by month)..."
echo "Date range: ${START_YEAR}-$(printf "%02d" $START_MONTH) to ${END_YEAR}-$(printf "%02d" $END_MONTH)"
echo "Throttle: ${THROTTLE}s base + ${JITTER}s max jitter"
echo ""

CURRENT_YEAR=$START_YEAR
CURRENT_MONTH=$START_MONTH

while true; do
    # Check if we've passed the end date
    if [ "$CURRENT_YEAR" -gt "$END_YEAR" ]; then
        echo "Reached end year $END_YEAR."
        break
    fi
    if [ "$CURRENT_YEAR" -eq "$END_YEAR" ] && [ "$CURRENT_MONTH" -gt "$END_MONTH" ]; then
        echo "Reached end month ${END_YEAR}-$(printf "%02d" $END_MONTH)."
        break
    fi

    # Format month with leading zero
    MONTH_PADDED=$(printf "%02d" $CURRENT_MONTH)
    LAST_DAY=$(get_last_day $CURRENT_YEAR $CURRENT_MONTH)

    # URL-encoded date range for this month
    DATE_FROM="${CURRENT_YEAR}-${MONTH_PADDED}-01%2000%3A00"
    DATE_TO="${CURRENT_YEAR}-${MONTH_PADDED}-${LAST_DAY}%2023%3A59"

    echo "=== Fetching ${CURRENT_YEAR}-${MONTH_PADDED} ==="

    PAGE=1
    MONTH_VIDEO_COUNT=0
    MONTH_EXPECTED_COUNT=0

    while true; do
        echo "  Fetching page $PAGE..."

        URL="${BASE_URL}?page=${PAGE}&filters%5Bvideo%5D%5Bdatetime_from%5D=${DATE_FROM}&filters%5Bvideo%5D%5Bdatetime_to%5D=${DATE_TO}"

        FILE_INDEX=$((FILE_INDEX + 1))
        CURRENT_PAGE_FILE="${TEMP_DIR}/page_$(printf "%05d" $FILE_INDEX).json"

        # Check curl exit code
        if ! fetch_page "$URL" "$CURRENT_PAGE_FILE"; then
            echo "  Error: Curl command failed for page $PAGE."
            rm -f "$CURRENT_PAGE_FILE"
            break
        fi
        TOTAL_API_CALLS=$((TOTAL_API_CALLS + 1))

        # Validate JSON response
        if ! jq -e . "$CURRENT_PAGE_FILE" >/dev/null 2>&1; then
            echo "  Error: Invalid JSON response on page $PAGE."
            cat "$CURRENT_PAGE_FILE"
            rm -f "$CURRENT_PAGE_FILE"
            break
        fi

        VIDEO_COUNT=$(jq '.videos | length' "$CURRENT_PAGE_FILE")

        # Get expected total from first page of each month
        if [ "$PAGE" -eq 1 ]; then
            MONTH_EXPECTED_COUNT=$(jq '.total // 0' "$CURRENT_PAGE_FILE")
            echo "  Expected videos for this month: $MONTH_EXPECTED_COUNT"
        fi

        # If no videos on this page, we're done with this month
        if [ "$VIDEO_COUNT" -eq 0 ]; then
            echo "  No more videos on page $PAGE."
            rm "$CURRENT_PAGE_FILE"
            break
        fi

        MONTH_VIDEO_COUNT=$((MONTH_VIDEO_COUNT + VIDEO_COUNT))
        echo "  Found $VIDEO_COUNT videos (month total: $MONTH_VIDEO_COUNT)"

        PAGE=$((PAGE + 1))
    done

    ACTUAL_VIDEO_COUNT=$((ACTUAL_VIDEO_COUNT + MONTH_VIDEO_COUNT))
    EXPECTED_VIDEO_COUNT=$((EXPECTED_VIDEO_COUNT + MONTH_EXPECTED_COUNT))
    echo "  Month ${CURRENT_YEAR}-${MONTH_PADDED} complete: $MONTH_VIDEO_COUNT / $MONTH_EXPECTED_COUNT videos"
    echo ""

    # Advance to next month
    CURRENT_MONTH=$((CURRENT_MONTH + 1))
    if [ "$CURRENT_MONTH" -gt 12 ]; then
        CURRENT_MONTH=1
        CURRENT_YEAR=$((CURRENT_YEAR + 1))
    fi
done

echo ""
echo "---------------- Summary ----------------"
echo "Expected Videos:         $EXPECTED_VIDEO_COUNT"
echo "Actual Videos Retrieved: $ACTUAL_VIDEO_COUNT"
echo "Total API Calls:         $TOTAL_API_CALLS"
echo "-----------------------------------------"

# Combine all videos into one JSON file
echo "Merging results into $OUTPUT_FILE..."

PAGE_FILES=("$TEMP_DIR"/page_*.json)
if [ -e "${PAGE_FILES[0]}" ]; then
    # Merge all page files.
    # Structure: { "videos": [ ... all videos flattened ... ], "total": ... }
    # We use jq to slurp all files, map to their .videos array, flatten it, and wrap it.
    jq -s --argjson total "$ACTUAL_VIDEO_COUNT" 'map(.videos) | add | {videos: ., total: $total}' "$TEMP_DIR"/page_*.json > "$OUTPUT_FILE"
else
    echo "{ \"videos\": [], \"total\": 0 }" > "$OUTPUT_FILE"
fi

echo "Done. Full video list saved to $OUTPUT_FILE"
