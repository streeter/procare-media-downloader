#!/bin/bash
#
# list_media.sh - Fetch paginated photo and video lists from Procare API
#
# Description:
#   Retrieves photos and/or videos from the Procare parent portal API by
#   iterating through 1-month date ranges and paginating within each month.
#   Results are merged into the existing JSON list files used by
#   download_media.sh.
#
# Prerequisites:
#   - credentials.txt: File containing one Bearer auth token per line
#   - jq: Required for JSON parsing
#   - curl: Required for API requests
#
# Output:
#   - raw_photo_list_response.json: Combined JSON with all photos
#     Format: { "photos": [...], "total": <count> }
#   - raw_video_list_response.json: Combined JSON with all videos
#     Format: { "videos": [...], "total": <count> }
#
# Usage:
#   ./list_media.sh
#   ./list_media.sh -s 2024-01-15
#   ./list_media.sh -m photo
#   ./list_media.sh -m video
#   ./list_media.sh -h
#
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=media_common.sh
. "$SCRIPT_DIR/media_common.sh"

START_DATE=$DEFAULT_START_DATE
END_DATE=$DEFAULT_END_DATE
THROTTLE=$DEFAULT_LIST_THROTTLE
JITTER=$DEFAULT_LIST_JITTER
MEDIA_SELECTION=$DEFAULT_MEDIA_SELECTION
TEMP_DIRS=()

cleanup() {
    local temp_dir

    if [ "${#TEMP_DIRS[@]}" -eq 0 ]; then
        return
    fi

    for temp_dir in "${TEMP_DIRS[@]}"; do
        if [ -n "$temp_dir" ] && [ -d "$temp_dir" ]; then
            rm -rf "$temp_dir"
        fi
    done
}
trap cleanup EXIT

usage() {
    cat <<EOF
Usage: $0 [-s YYYY-MM-DD] [-e YYYY-MM-DD] [-m all|photo|video] [-t throttle_sec] [-j jitter_sec] [-h]

Fetch paginated Procare media lists into JSON files.

Options:
  -s: Start date to list from (default: $DEFAULT_START_DATE)
  -e: End date to list through (default: $DEFAULT_END_DATE)
  -m: Media to list: all, photo, or video (default: $DEFAULT_MEDIA_SELECTION)
  -t: Base sleep time between API calls (default: $DEFAULT_LIST_THROTTLE)
  -j: Max random jitter added to sleep (default: $DEFAULT_LIST_JITTER)
  -h: Show this help message

Outputs:
  photo: $DEFAULT_PHOTO_LIST_FILE
  video: $DEFAULT_VIDEO_LIST_FILE
EOF
    exit "${1:-1}"
}

while getopts "s:e:m:t:j:h" opt; do
    case "$opt" in
        s) START_DATE=$OPTARG ;;
        e) END_DATE=$OPTARG ;;
        m) MEDIA_SELECTION=$OPTARG ;;
        t) THROTTLE=$OPTARG ;;
        j) JITTER=$OPTARG ;;
        h) usage 0 ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))

if [ "$#" -gt 0 ]; then
    echo "Error: unexpected argument: $1"
    usage
fi

validate_media_selection "$MEDIA_SELECTION" "-m" || exit 1
validate_non_negative_integer "-t" "$THROTTLE" || exit 1
validate_non_negative_integer "-j" "$JITTER" || exit 1
validate_yyyy_mm_dd_date "-s" "$START_DATE" || exit 1
validate_yyyy_mm_dd_date "-e" "$END_DATE" || exit 1

if [ "${START_DATE//-/}" -gt "${END_DATE//-/}" ]; then
    echo "Error: -s must be on or before -e"
    exit 1
fi

START_YEAR=${START_DATE%%-*}
START_MONTH_DAY=${START_DATE#*-}
START_MONTH=$((10#${START_MONTH_DAY%%-*}))
START_DAY=$((10#${START_DATE##*-}))
END_YEAR=${END_DATE%%-*}
END_MONTH_DAY=${END_DATE#*-}
END_MONTH=$((10#${END_MONTH_DAY%%-*}))
END_DAY=$((10#${END_DATE##*-}))

load_credentials "$DEFAULT_CREDENTIALS_FILE" || exit 1

# Function to get last day of month (macOS compatible)
get_last_day() {
    local year=$1
    local month=$2
    if [ "$month" -eq 12 ]; then
        echo 31
    else
        local next_month=$((month + 1))
        local next_month_padded
        next_month_padded=$(printf "%02d" "$next_month")
        date -j -v-1d -f "%Y-%m-%d" "${year}-${next_month_padded}-01" +%d 2>/dev/null
    fi
}

# Function to make API call with throttling
fetch_page() {
    local auth_token=$1
    local url=$2
    local output_file=$3

    sleep_with_jitter "$THROTTLE" "$JITTER" "  Sleeping for " "s..."

    curl -s "$url" \
      -H 'Accept: application/json' \
      -H "Authorization: Bearer $auth_token" \
      -H 'history-data: 1' \
      -o "$output_file"
}

list_media_type() {
    local media_type=$1
    local plural
    local display_plural
    local base_url
    local output_file
    local temp_dir
    local expected_count=0
    local actual_count=0
    local total_api_calls=0
    local file_index=0
    local credential_index
    local current_year
    local current_month
    local month_padded
    local last_day
    local range_start_day
    local range_end_day
    local date_from
    local date_to
    local page
    local month_count
    local month_expected_count
    local url
    local current_page_file
    local item_count
    local page_files

    plural=$(media_plural "$media_type")
    display_plural=$(media_display_plural "$media_type")
    base_url="https://api-school.procareconnect.com/api/web/parent/${plural}/"
    output_file=$(default_list_file_for_media "$media_type")

    temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/list_${plural}.XXXXXX")
    TEMP_DIRS+=("$temp_dir")

    echo "Starting ${media_type} list retrieval (month by month)..."
    echo "Date range: ${START_DATE} to ${END_DATE}"
    echo "Credentials: ${#AUTH_TOKENS[@]}"
    echo "Throttle: ${THROTTLE}s base + ${JITTER}s max jitter"
    echo ""

    for ((credential_index = 0; credential_index < ${#AUTH_TOKENS[@]}; credential_index++)); do
        local auth_token=${AUTH_TOKENS[$credential_index]}
        local credential_number=$((credential_index + 1))
        echo "=== Credential ${credential_number}/${#AUTH_TOKENS[@]} ==="

        current_year=$START_YEAR
        current_month=$START_MONTH

        while true; do
            if [ "$current_year" -gt "$END_YEAR" ]; then
                echo "Reached end year $END_YEAR."
                break
            fi
            if [ "$current_year" -eq "$END_YEAR" ] && [ "$current_month" -gt "$END_MONTH" ]; then
                echo "Reached end month ${END_YEAR}-$(printf "%02d" "$END_MONTH")."
                break
            fi

            month_padded=$(printf "%02d" "$current_month")
            last_day=$(get_last_day "$current_year" "$current_month")
            range_start_day=1
            range_end_day=$((10#$last_day))

            if [ "$current_year" -eq "$START_YEAR" ] && [ "$current_month" -eq "$START_MONTH" ]; then
                range_start_day=$START_DAY
            fi
            if [ "$current_year" -eq "$END_YEAR" ] && [ "$current_month" -eq "$END_MONTH" ]; then
                range_end_day=$END_DAY
            fi

            date_from="${current_year}-${month_padded}-$(printf "%02d" "$range_start_day")%2000%3A00"
            date_to="${current_year}-${month_padded}-$(printf "%02d" "$range_end_day")%2023%3A59"

            echo "=== Fetching ${current_year}-${month_padded} ${plural} (${current_year}-${month_padded}-$(printf "%02d" "$range_start_day") to ${current_year}-${month_padded}-$(printf "%02d" "$range_end_day")) for credential ${credential_number}/${#AUTH_TOKENS[@]} ==="

            page=1
            month_count=0
            month_expected_count=0

            while true; do
                echo "  Fetching page $page..."

                url="${base_url}?page=${page}&filters%5B${media_type}%5D%5Bdatetime_from%5D=${date_from}&filters%5B${media_type}%5D%5Bdatetime_to%5D=${date_to}"

                file_index=$((file_index + 1))
                current_page_file="${temp_dir}/page_$(printf "%05d" "$file_index").json"

                if ! fetch_page "$auth_token" "$url" "$current_page_file"; then
                    echo "  Error: Curl command failed for page $page."
                    rm -f "$current_page_file"
                    break
                fi
                total_api_calls=$((total_api_calls + 1))

                if ! jq -e . "$current_page_file" >/dev/null 2>&1; then
                    echo "  Error: Invalid JSON response on page $page."
                    cat "$current_page_file"
                    rm -f "$current_page_file"
                    break
                fi

                item_count=$(jq --arg key "$plural" '.[$key] | length' "$current_page_file")

                if [ "$page" -eq 1 ]; then
                    month_expected_count=$(jq '.total // 0' "$current_page_file")
                    echo "  Expected ${plural} for this month: $month_expected_count"
                fi

                if [ "$item_count" -eq 0 ]; then
                    echo "  No more ${plural} on page $page."
                    rm "$current_page_file"
                    break
                fi

                month_count=$((month_count + item_count))
                echo "  Found $item_count ${plural} (month total: $month_count)"

                page=$((page + 1))
            done

            actual_count=$((actual_count + month_count))
            expected_count=$((expected_count + month_expected_count))
            echo "  Month ${current_year}-${month_padded} complete: $month_count / $month_expected_count ${plural}"
            echo ""

            current_month=$((current_month + 1))
            if [ "$current_month" -gt 12 ]; then
                current_month=1
                current_year=$((current_year + 1))
            fi
        done
    done

    echo ""
    echo "---------------- Summary ----------------"
    echo "Credentials Processed:   ${#AUTH_TOKENS[@]}"
    echo "Expected ${display_plural}:         $expected_count"
    echo "Actual ${display_plural} Retrieved: $actual_count"
    echo "Total API Calls:         $total_api_calls"
    echo "-----------------------------------------"

    echo "Merging results into $output_file..."

    page_files=("$temp_dir"/page_*.json)
    if [ -e "${page_files[0]}" ]; then
        jq -s --arg key "$plural" --argjson total "$actual_count" 'map(.[$key]) | add | {($key): ., total: $total}' "$temp_dir"/page_*.json > "$output_file"
    else
        jq -n --arg key "$plural" '{($key): [], total: 0}' > "$output_file"
    fi

    rm -rf "$temp_dir"
    echo "Done. Full ${media_type} list saved to $output_file"
    echo ""
}

case "$MEDIA_SELECTION" in
    all)
        for media_type in "${MEDIA_TYPES[@]}"; do
            list_media_type "$media_type"
        done
        ;;
    photo|video)
        list_media_type "$MEDIA_SELECTION"
        ;;
esac
