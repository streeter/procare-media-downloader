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

### Downloading Videos

#### Step 1: List Videos

```bash
./list_videos.sh
```

This iterates through each month in the configured date range, fetching all videos and saving them to `raw_video_list_response.json`.

The date range is configured at the top of the script:
```bash
START_YEAR=2023
START_MONTH=2
END_YEAR=2026
END_MONTH=2
```

#### Step 2: Download Videos

```bash
./download_videos.sh
```

Videos are saved to `videos/<video-id>.mp4`.

**Options:**

| Option | Description | Default |
|--------|-------------|---------|
| `-n <limit>` | Number of videos to download (0 = all) | 0 |
| `-t <seconds>` | Base sleep time between downloads | 2 |
| `-j <seconds>` | Max random jitter added to sleep | 2 |
| `-f <file>` | Input JSON file | raw_video_list_response.json |

**Examples:**

```bash
./download_videos.sh -n 10        # Download first 10 videos
./download_videos.sh -t 5 -j 3    # Custom throttling
```

---

### Downloading Photos

#### Step 1: List Photos

```bash
./list_photos.sh
```

This iterates through each month in the configured date range, fetching all photos and saving them to `raw_photo_list_response.json`.

The date range is configured at the top of the script:
```bash
START_YEAR=2023
START_MONTH=2
END_YEAR=2026
END_MONTH=2
```

#### Step 2: Download Photos

	```bash
	./download_photos.sh
	```

	Photos are saved to the `photos/` directory. Filenames are determined by the server's Content-Disposition header.

	**Options:**

	| Option | Description | Default |
	|--------|-------------|---------|
	| `-n <limit>` | Number of photos to download (0 = all) | 0 |
	| `-t <seconds>` | Base sleep time between downloads | 2 |
	| `-j <seconds>` | Max random jitter added to sleep | 2 |
	| `-f <file>` | Input JSON file | raw_photo_list_response.json |

	**Examples:**

	```bash
	./download_photos.sh -n 20        # Download first 20 photos
	./download_photos.sh -t 5 -j 3    # Custom throttling
	```

	---

## Resumable Downloads

	Both download scripts support resuming interrupted downloads:

	- **Videos**: Skips files that already exist in `videos/`
	- **Photos**: Tracks downloaded IDs in `photos/.downloaded_ids`

	If a download is interrupted, run the script again to continue where you left off.

## Output Files

	| File | Description |
	|------|-------------|
	| `raw_video_list_response.json` | Video metadata from API |
	| `raw_photo_list_response.json` | Photo metadata from API |
	| `videos/` | Downloaded MP4 video files |
	| `photos/` | Downloaded photo files |

## Notes

	- Authentication tokens expire periodically. If you receive authentication errors, obtain a new token.
	- Throttling is built-in to avoid overwhelming the server. The default is 2-4 seconds between requests.
	- The date range for both video and photo retrieval is configured via variables at the top of the respective list scripts.
	- Some photos might be missing the .jpg file extension
	- Some media may be listed but ultimately fail to download because they have already been deleted from the backend. The file will be saved with the response

```
<?xml version="1.0" encoding="UTF-8"?>
<Error><Code>AccessDenied</Code><Message>Access Denied</Message></Error>

SHA-1 0dde8fd9111d807e202b2fb37f8bcc4052fd861e
```
