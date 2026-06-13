# Procare Media Downloader

A set of bash scripts to bulk download videos and photos from the Procare parent portal.

## Prerequisites

- **curl**: For making HTTP requests
- **jq**: For JSON parsing (`brew install jq` on macOS)
- **credentials.txt**: A file containing one Procare Bearer authentication token per line
- **exiftool**: Optional; writes embedded creation time and GPS metadata when available (`brew install exiftool` on macOS)

## Setup

### Getting Your Authentication Token

1. Log in to [schools.procareconnect.com](https://schools.procareconnect.com) in your browser
2. Open Developer Tools (F12 or Cmd+Option+I)
3. Go to the Network tab
4. Navigate to a page that loads media (e.g. https://schools.procareconnect.com/dashboard)
5. Find a request to `api-school.procareconnect.com`
6. Copy the value after `Bearer ` in the `Authorization` header
7. Save this token to `credentials.txt`, one credential per line. If your account has access to multiple schools, repeat the capture after switching the pinned school and add each school's token on its own line.

```bash
printf '%s\n' "school_one_token_here" "school_two_token_here" > credentials.txt
```

Anything after `#` on a credential line is treated as a comment.

### Optional Geotagging

If `geotag.json` exists, `download_media.sh` uses it to add the same GPS coordinates to downloaded photos and videos when `exiftool` supports the media format. The real `geotag.json` file is ignored by git. Start from the checked-in example:

```bash
cp geotag.example.json geotag.json
```

Then edit `geotag.json`:

```json
{
  "lat": 40.7128,
  "long": -74.0060
}
```

The downloader also accepts `latitude`/`longitude` or `lat`/`lng` keys. Use `--geotag-file <file>` to point at a different local JSON file.

## Usage

### Listing Media

```bash
./list_media.sh
```

This iterates through each credential and each month in the selected date range, fetching all videos and photos and saving the merged results to `raw_video_list_response.json` and `raw_photo_list_response.json`.

The date range defaults are configured in `media_common.sh`:
```bash
DEFAULT_START_DATE="2023-01-01"
DEFAULT_END_DATE="2026-08-31"
```

Use `-s YYYY-MM-DD` or `--start-date YYYY-MM-DD` to pass a different start date, and `-e YYYY-MM-DD` or `--end-date YYYY-MM-DD` to pass a different end date:

```bash
./list_media.sh -s 2024-01-15
./list_media.sh --start-date 2024-01-15 --end-date 2024-12-31
```

Use `-m photo`, `--media photo`, `-m video`, or `--media video` to list only one media type. Use `-h` or `--help` to show the script help.

### Downloading Media

After generating the photo and video list files, download both media types:

```bash
./download_media.sh
```

Photos are saved to `photos/YYYY-MM-DD HHMM <photo-id>.<ext>`.
Videos are saved to `videos/YYYY-MM-DD HHMM <video-id>.<ext>`.

**Options:**

| Option | Description | Default |
|--------|-------------|---------|
| `-n`, `--limit <limit>` | Number of each media type to download (0 = all) | 0 |
| `-t`, `--throttle <seconds>` | Base sleep time between downloads | 0 |
| `-j`, `--jitter <seconds>` | Max random jitter added to sleep | 0 |
| `-p`, `--photo-input <file>` | Photo input JSON file | raw_photo_list_response.json |
| `-v`, `--video-input <file>` | Video input JSON file | raw_video_list_response.json |
| `-g`, `--geotag-file <file>` | Optional local GPS JSON file | geotag.json |
| `-F`, `--failed-downloads-file <file>` | JSONL log for HTTP 403 failures | failed_media_downloads.jsonl |
| `-m`, `--media <media>` | Media to download: `all`, `photo`, or `video` | all |
| `-P`, `--parallel <count>` | Parallel downloads per media type | 16 |
| `-h`, `--help` | Show usage help | n/a |

**Examples:**

```bash
./download_media.sh -n 10        # Download first 10 photos and first 10 videos
./download_media.sh -t 5 -j 3    # Custom throttling
./download_media.sh --media photo # Download photos only
./download_media.sh -P 8         # Run up to 8 downloads at a time
```

When a download URL returns HTTP 403, the downloader records the media ID, media type, URL field, timestamp, and URL in `failed_media_downloads.jsonl`. After refreshing credentials, ask the list script to re-fetch the months containing those failed IDs and merge any refreshed records back into the normal raw JSON files:

```bash
./list_media.sh --retry-failed-downloads
./download_media.sh
```

Use `--failed-downloads-file <file>` with either script if you want to keep a separate retry log.

## Resumable Downloads

The download script supports resuming interrupted downloads:

- **Videos**: Skips files that already exist in `videos/`
- **Photos**: Skips files that already exist in `photos/`

If a download is interrupted, run the script again to continue where you left off.

## Output Files

| File | Description |
|------|-------------|
| `raw_video_list_response.json` | Video metadata from API |
| `raw_photo_list_response.json` | Photo metadata from API |
| `failed_media_downloads.jsonl` | HTTP 403 download failures for retry refresh |
| `videos/` | Downloaded video files |
| `photos/` | Downloaded photo files |

## Notes

- Authentication tokens expire periodically. If you receive authentication errors, obtain a new token for each school and update each line in `credentials.txt`.
- Use `-t`/`--throttle` and `-j`/`--jitter` with `download_media.sh` to throttle downloads.
- Use `-P` or `--parallel` to control concurrent downloads.
- Shared defaults and validation helpers live in `media_common.sh` so listing and downloading stay in sync.
- Downloaded filenames use each item's `created_at` value, interpreted as Eastern time, so files sort chronologically by name.
- When `exiftool` is available, `download_media.sh` writes embedded photo/video creation metadata from `created_at`, interpreted as Eastern time. If `geotag.json` exists, it also writes GPS coordinates to media formats that support them. Existing files are checked first; files with the expected embedded metadata are left untouched, while files with missing or stale metadata are repaired.
- On macOS, `download_media.sh` sets filesystem creation time with `SetFile` when available and always tries to set modified time with `touch`.
- Some media may be listed but ultimately fail to download because they have already been deleted from the backend. Failed downloads are not moved into `photos/` or `videos/`.
