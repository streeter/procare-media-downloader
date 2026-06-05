# Procare Media Downloader

A set of bash scripts to bulk download videos and photos from the Procare parent portal.

## Prerequisites

- **curl**: For making HTTP requests
- **jq**: For JSON parsing (`brew install jq` on macOS)
- **credentials.txt**: A file containing your Procare Bearer authentication token

## Setup

### Getting Your Authentication Token

1. Log in to [schools.procareconnect.com](https://schools.procareconnect.com) in your browser
2. Open Developer Tools (F12 or Cmd+Option+I)
3. Go to the Network tab
4. Navigate to a page that loads media (e.g. https://schools.procareconnect.com/dashboard)
5. Find a request to `api-school.procareconnect.com`
6. Copy the value after `Bearer ` in the `Authorization` header
7. Save this token to `credentials.txt` (no newline at the end)

```bash
echo -n "your_token_here" > credentials.txt
```

## Usage

### Listing Videos

```bash
./list_videos.sh
```

This iterates through each month in the configured date range, fetching all videos and saving them to `raw_video_list_response.json`.

The date range is configured at the top of the script:
```bash
START_YEAR=2023
START_MONTH=1
END_YEAR=2026
END_MONTH=8
```

### Listing Photos

```bash
./list_photos.sh
```

This iterates through each month in the configured date range, fetching all photos and saving them to `raw_photo_list_response.json`.

The date range is configured at the top of the script:
```bash
START_YEAR=2023
START_MONTH=1
END_YEAR=2026
END_MONTH=8
```

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
| `-n <limit>` | Number of each media type to download (0 = all) | 0 |
| `-t <seconds>` | Base sleep time between downloads | 0 |
| `-j <seconds>` | Max random jitter added to sleep | 0 |
| `-p <file>` | Photo input JSON file | raw_photo_list_response.json |
| `-v <file>` | Video input JSON file | raw_video_list_response.json |
| `-m <media>` | Media to download: `all`, `photo`, or `video` | all |
| `-P`, `--parallel <count>` | Parallel downloads per media type | 4 |
| `-h`, `--help` | Show usage help | n/a |

**Examples:**

```bash
./download_media.sh -n 10        # Download first 10 photos and first 10 videos
./download_media.sh -t 5 -j 3    # Custom throttling
./download_media.sh -m photo     # Download photos only
./download_media.sh -P 8         # Run up to 8 downloads at a time
```

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
| `videos/` | Downloaded video files |
| `photos/` | Downloaded photo files |

## Notes

- Authentication tokens expire periodically. If you receive authentication errors, obtain a new token.
- Use `-t` and `-j` with `download_media.sh` to throttle downloads.
- Use `-P` or `--parallel` to control concurrent downloads.
- The date range for both video and photo retrieval is configured via variables at the top of the respective list scripts.
- Downloaded filenames use each item's `created_at` value so files sort chronologically by name.
- On macOS, `download_media.sh` sets file creation time with `SetFile` when available and always tries to set modified time with `touch`.
- Some media may be listed but ultimately fail to download because they have already been deleted from the backend. Failed downloads are not moved into `photos/` or `videos/`.
