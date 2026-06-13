#!/bin/bash
#
# Shared defaults and helpers for the Procare media scripts.
# Constants in this sourced library are consumed by caller scripts.
# shellcheck disable=SC2034

DEFAULT_MEDIA_SELECTION=all
MEDIA_TYPES=(photo video)

DEFAULT_START_DATE="2023-01-01"
DEFAULT_END_DATE="2026-08-31"

DEFAULT_LIST_THROTTLE=0
DEFAULT_LIST_JITTER=1

DEFAULT_DOWNLOAD_LIMIT=0
DEFAULT_DOWNLOAD_THROTTLE=0
DEFAULT_DOWNLOAD_JITTER=0
DEFAULT_PARALLEL_DOWNLOADS=16
DEFAULT_MEDIA_TIMEZONE="America/New_York"

DEFAULT_CREDENTIALS_FILE="credentials.txt"
DEFAULT_PHOTO_LIST_FILE="raw_photo_list_response.json"
DEFAULT_VIDEO_LIST_FILE="raw_video_list_response.json"

media_plural() {
    case "$1" in
        photo) printf 'photos' ;;
        video) printf 'videos' ;;
        *) return 1 ;;
    esac
}

media_display_plural() {
    case "$1" in
        photo) printf 'Photos' ;;
        video) printf 'Videos' ;;
        *) return 1 ;;
    esac
}

default_list_file_for_media() {
    case "$1" in
        photo) printf '%s' "$DEFAULT_PHOTO_LIST_FILE" ;;
        video) printf '%s' "$DEFAULT_VIDEO_LIST_FILE" ;;
        *) return 1 ;;
    esac
}

media_is_selected() {
    local media=$1
    local selection=$2

    [ "$selection" = all ] || [ "$selection" = "$media" ]
}

validate_media_selection() {
    local selection=$1
    local label=${2:-media}

    case "$selection" in
        all|photo|video) return 0 ;;
        *)
            echo "Error: $label must be one of: all, photo, video"
            return 1
            ;;
    esac
}

validate_non_negative_integer() {
    local label=$1
    local value=$2

    if ! [[ "$value" =~ ^[0-9]+$ ]]; then
        echo "Error: $label must be a non-negative integer"
        return 1
    fi
}

validate_positive_integer() {
    local label=$1
    local value=$2

    if ! [[ "$value" =~ ^[0-9]+$ ]] || [ "$value" -lt 1 ]; then
        echo "Error: $label must be a positive integer"
        return 1
    fi
}

validate_yyyy_mm_dd_date() {
    local label=$1
    local value=$2
    local normalized

    if ! [[ "$value" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        echo "Error: $label must use YYYY-MM-DD format"
        return 1
    fi

    if ! normalized=$(date -j -f "%Y-%m-%d" "$value" "+%Y-%m-%d" 2>/dev/null) || [ "$normalized" != "$value" ]; then
        echo "Error: $label must be a valid date"
        return 1
    fi
}

sleep_with_jitter() {
    local throttle=$1
    local jitter=$2
    local message_prefix=$3
    local message_suffix=$4
    local rand_jitter
    local sleep_time

    if [ "$jitter" -gt 0 ]; then
        rand_jitter=$(( RANDOM % (jitter + 1) ))
    else
        rand_jitter=0
    fi
    sleep_time=$(( throttle + rand_jitter ))

    if [ "$sleep_time" -gt 0 ]; then
        printf '%s%s%s\n' "$message_prefix" "$sleep_time" "$message_suffix"
        sleep "$sleep_time"
    fi
}

trim_whitespace() {
    printf '%s' "$1" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'
}

load_credentials() {
    local credentials_file=${1:-$DEFAULT_CREDENTIALS_FILE}
    local credential

    if [ ! -f "$credentials_file" ]; then
        echo "Error: $credentials_file not found."
        return 1
    fi

    AUTH_TOKENS=()
    while IFS= read -r credential || [ -n "$credential" ]; do
        credential=${credential%$'\r'}
        credential=${credential%%#*}
        credential=$(trim_whitespace "$credential")

        case "$credential" in
            "")
                continue
                ;;
            Bearer\ *)
                credential=${credential#Bearer }
                ;;
            bearer\ *)
                credential=${credential#bearer }
                ;;
        esac

        credential=$(trim_whitespace "$credential")
        if [ -n "$credential" ]; then
            AUTH_TOKENS+=("$credential")
        fi
    done < "$credentials_file"

    if [ "${#AUTH_TOKENS[@]}" -eq 0 ]; then
        echo "Error: $credentials_file does not contain any credentials."
        return 1
    fi
}
