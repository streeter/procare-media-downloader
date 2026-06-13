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
#   ./list_media.sh --start-date 2024-01-15
#   ./list_media.sh -m photo
#   ./list_media.sh -m video
#   ./list_media.sh --retry-failed-downloads
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
RETRY_FAILED_DOWNLOADS=0
FAILED_DOWNLOADS_FILE=$DEFAULT_FAILED_DOWNLOADS_FILE
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
Usage: $0 [-s|--start-date YYYY-MM-DD] [-e|--end-date YYYY-MM-DD] [-m|--media all|photo|video] [-t|--throttle throttle_sec] [-j|--jitter jitter_sec] [-R|--retry-failed-downloads] [-F|--failed-downloads-file file] [-h|--help]

Fetch paginated Procare media lists into JSON files.

Options:
  -s, --start-date: Start date to list from (default: $DEFAULT_START_DATE)
  -e, --end-date: End date to list through (default: $DEFAULT_END_DATE)
  -m, --media: Media to list: all, photo, or video (default: $DEFAULT_MEDIA_SELECTION)
  -t, --throttle: Base sleep time between API calls (default: $DEFAULT_LIST_THROTTLE)
  -j, --jitter: Max random jitter added to sleep (default: $DEFAULT_LIST_JITTER)
  -R, --retry-failed-downloads: Refresh only media IDs recorded as HTTP 403 download failures
  -F, --failed-downloads-file: JSONL file created by download_media.sh (default: $DEFAULT_FAILED_DOWNLOADS_FILE)
  -h, --help: Show this help message

Outputs:
  photo: $DEFAULT_PHOTO_LIST_FILE
  video: $DEFAULT_VIDEO_LIST_FILE
EOF
    exit "${1:-1}"
}

ARGS=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --start-date)
            shift
            if [ "$#" -eq 0 ]; then
                echo "Error: --start-date requires a value"
                exit 1
            fi
            ARGS+=("-s" "$1")
            ;;
        --start-date=*)
            ARGS+=("-s" "${1#*=}")
            ;;
        --end-date)
            shift
            if [ "$#" -eq 0 ]; then
                echo "Error: --end-date requires a value"
                exit 1
            fi
            ARGS+=("-e" "$1")
            ;;
        --end-date=*)
            ARGS+=("-e" "${1#*=}")
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
        --retry-failed-downloads)
            ARGS+=("-R")
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

while getopts "s:e:m:t:j:RF:h" opt; do
    case "$opt" in
        s) START_DATE=$OPTARG ;;
        e) END_DATE=$OPTARG ;;
        m) MEDIA_SELECTION=$OPTARG ;;
        t) THROTTLE=$OPTARG ;;
        j) JITTER=$OPTARG ;;
        R) RETRY_FAILED_DOWNLOADS=1 ;;
        F) FAILED_DOWNLOADS_FILE=$OPTARG ;;
        h) usage 0 ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))

if [ "$#" -gt 0 ]; then
    echo "Error: unexpected argument: $1"
    usage
fi

validate_media_selection "$MEDIA_SELECTION" "-m/--media" || exit 1
validate_non_negative_integer "-t/--throttle" "$THROTTLE" || exit 1
validate_non_negative_integer "-j/--jitter" "$JITTER" || exit 1
validate_yyyy_mm_dd_date "-s/--start-date" "$START_DATE" || exit 1
validate_yyyy_mm_dd_date "-e/--end-date" "$END_DATE" || exit 1

if [ "${START_DATE//-/}" -gt "${END_DATE//-/}" ]; then
    echo "Error: --start-date must be on or before --end-date"
    exit 1
fi

if [ "$RETRY_FAILED_DOWNLOADS" -eq 1 ]; then
    if [ ! -f "$FAILED_DOWNLOADS_FILE" ]; then
        echo "Error: failed downloads file '$FAILED_DOWNLOADS_FILE' not found"
        exit 1
    fi

    if ! jq -s . "$FAILED_DOWNLOADS_FILE" >/dev/null 2>&1; then
        echo "Error: failed downloads file '$FAILED_DOWNLOADS_FILE' is not valid JSONL"
        exit 1
    fi
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

write_failed_retry_filters() {
    local media_type=$1
    local ids_file=$2
    local months_file=$3

    jq -sr --arg media "$media_type" '
        [.[] | select(.media == $media and (.http_status | tostring) == "403") | .id]
        | unique
        | .[]
    ' "$FAILED_DOWNLOADS_FILE" > "$ids_file"

    jq -sr --arg media "$media_type" '
        [.[] | select(.media == $media and (.http_status | tostring) == "403") | .created_at[0:7]]
        | map(select(test("^[0-9]{4}-[0-9]{2}$")))
        | unique
        | .[]
    ' "$FAILED_DOWNLOADS_FILE" > "$months_file"
}

merge_refreshed_retry_records() {
    local plural=$1
    local output_file=$2
    local ids_file=$3
    local temp_dir=$4
    local refreshed_file
    local merged_file
    local refreshed_count
    local page_files

    refreshed_file="${temp_dir}/refreshed_${plural}.json"
    merged_file="${temp_dir}/merged_${plural}.json"
    page_files=("$temp_dir"/page_*.json)

    if [ -e "${page_files[0]}" ]; then
        jq -s --arg key "$plural" --rawfile ids "$ids_file" '
            ($ids | split("\n") | map(select(length > 0))) as $failed_ids
            | (map(.[$key] // []) | add // [])
            | map(select(.id as $id | $failed_ids | index($id)))
            | unique_by(.id)
            | {($key): ., total: length}
        ' "$temp_dir"/page_*.json > "$refreshed_file"
    else
        jq -n --arg key "$plural" '{($key): [], total: 0}' > "$refreshed_file"
    fi

    refreshed_count=$(jq --arg key "$plural" '.[$key] | length' "$refreshed_file")
    echo "Found $refreshed_count refreshed ${plural} matching recorded 403 failures."

    if [ -f "$output_file" ]; then
        jq -s --arg key "$plural" '
            .[0] as $old
            | .[1] as $new
            | ($new[$key] // []) as $new_items
            | ($new_items | map(.id)) as $new_ids
            | ((($old[$key] // []) | map(select(.id as $id | ($new_ids | index($id) | not)))) + $new_items) as $items
            | {($key): $items, total: ($items | length)}
        ' "$output_file" "$refreshed_file" > "$merged_file"
    else
        cp "$refreshed_file" "$merged_file"
    fi

    mv "$merged_file" "$output_file"
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
    local retry_ids_file
    local retry_months_file
    local retry_failed_count
    local month_key

    plural=$(media_plural "$media_type")
    display_plural=$(media_display_plural "$media_type")
    base_url="https://api-school.procareconnect.com/api/web/parent/${plural}/"
    output_file=$(default_list_file_for_media "$media_type")

    temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/list_${plural}.XXXXXX")
    TEMP_DIRS+=("$temp_dir")

    if [ "$RETRY_FAILED_DOWNLOADS" -eq 1 ]; then
        retry_ids_file="${temp_dir}/retry_ids.txt"
        retry_months_file="${temp_dir}/retry_months.txt"
        write_failed_retry_filters "$media_type" "$retry_ids_file" "$retry_months_file"
        retry_failed_count=$(wc -l < "$retry_ids_file" | tr -d '[:space:]')

        if [ "$retry_failed_count" -eq 0 ]; then
            echo "No recorded HTTP 403 ${plural} failures in $FAILED_DOWNLOADS_FILE."
            rm -rf "$temp_dir"
            return
        fi
    else
        retry_ids_file=""
        retry_months_file=""
        retry_failed_count=0
    fi

    if [ "$RETRY_FAILED_DOWNLOADS" -eq 1 ]; then
        echo "Starting ${media_type} retry refresh for $retry_failed_count recorded HTTP 403 failure(s)..."
    else
        echo "Starting ${media_type} list retrieval (month by month)..."
    fi
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
            month_key="${current_year}-${month_padded}"

            if [ "$RETRY_FAILED_DOWNLOADS" -eq 1 ] && ! grep -qx "$month_key" "$retry_months_file"; then
                current_month=$((current_month + 1))
                if [ "$current_month" -gt 12 ]; then
                    current_month=1
                    current_year=$((current_year + 1))
                fi
                continue
            fi

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

    if [ "$RETRY_FAILED_DOWNLOADS" -eq 1 ]; then
        echo "Merging refreshed failed records into $output_file..."
        merge_refreshed_retry_records "$plural" "$output_file" "$retry_ids_file" "$temp_dir"
        rm -rf "$temp_dir"
        echo "Done. Refreshed ${media_type} records saved to $output_file"
        echo ""
        return
    fi

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
