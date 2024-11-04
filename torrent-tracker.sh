#!/bin/bash

# Dependencies required: sqlite3, jq, curl

# Set up flags
URL=""
API_KEY=""
DB_NAME=""
DB_PATH=""
TYPE=""
TIME_THRESHOLD=168 # Default to one week in hours (7 days)
GRACE_PERIOD=168 # Grace period in hours before deleting old entries (7 days)

# Parse flags
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --url)
      URL="$2"
      shift 2
      ;;
    --api-key)
      API_KEY="$2"
      shift 2
      ;;
    --type)
      TYPE="$2"
      shift 2
      ;;
    --db-name)
      DB_NAME="$2"
      shift 2
      ;;
    --time-threshold)
      TIME_THRESHOLD="$2"
      shift 2
      ;;
    --grace-period)
      GRACE_PERIOD="$2"
      shift 2
      ;;
    *)
      echo "Unknown option $1"
      exit 1
      ;;
  esac
done

if [ -z "$URL" ] || [ -z "$API_KEY" ] || [ -z "$TYPE" ] || [ -z "$DB_NAME" ]; then
  echo "Error: --url, --api-key, --type, and --db-name are required."
  exit 1
fi

# Set the database path
DB_PATH="./${DB_NAME%.db}.db"

# Initialize the database if it doesn't exist
if [ ! -f "$DB_PATH" ]; then
  echo "Initializing the database at $DB_PATH"
  sqlite3 "$DB_PATH" "CREATE TABLE torrents (id TEXT PRIMARY KEY, added_at DATETIME, progress INTEGER, last_seen DATETIME, last_progress DATETIME);"
fi

# Define the API endpoint based on the type provided
if [ "$TYPE" == "radarr" ]; then
  API_ENDPOINT="$URL/api/v3/queue?apikey=$API_KEY"
elif [ "$TYPE" == "sonarr" ]; then
  API_ENDPOINT="$URL/api/v3/queue?apikey=$API_KEY"
else
  echo "Error: Invalid type. Must be 'radarr' or 'sonarr'."
  exit 1
fi

# Initialize pagination variables
PAGE=1
PAGE_SIZE=50
TORRENT_LIST=()

# Fetch active downloads with pagination
while true; do
  echo "Fetching page $PAGE of active downloads from $URL"
  RESPONSE=$(curl -s "$API_ENDPOINT&page=$PAGE&pageSize=$PAGE_SIZE")
  if [ $? -ne 0 ]; then
    echo "Error: Unable to connect to $URL."
    exit 1
  fi

  # Extract the current page's torrent records
  CURRENT_PAGE_TORRENTS=$(echo "$RESPONSE" | jq -c '.records[]')
  CURRENT_PAGE_COUNT=$(echo "$CURRENT_PAGE_TORRENTS" | jq -s 'length')

  if [ "$CURRENT_PAGE_COUNT" -eq 0 ]; then
    # No more records, exit the loop
    break
  fi

  # Filter for torrents that are downloading, in error, or failed but **not queued** and add to the list
  FILTERED_TORRENTS=$(echo "$CURRENT_PAGE_TORRENTS" | jq -c 'select(.status != "queued" and (.trackedDownloadState == "downloading" or .trackedDownloadState == "error" or .trackedDownloadState == "failed")) | {id: .downloadId, total_size: .size, size_left: .sizeleft}')
  while IFS= read -r torrent; do
    TORRENT_LIST+=("$torrent")
  done <<< "$FILTERED_TORRENTS"

  # If the number of torrents fetched is less than the page size, we are done
  if [ "$CURRENT_PAGE_COUNT" -lt $PAGE_SIZE ]; then
    break
  fi

  # Move to the next page
  PAGE=$((PAGE + 1))
done

# Function to convert bytes to human-readable units with precision
convert_size() {
  local size=$1
  if [ "$size" -lt 1024 ]; then
    echo "${size} B"
  elif [ "$size" -lt 1048576 ]; then
    printf "%.2f KB" "$(echo "scale=2; $size / 1024" | bc)"
  elif [ "$size" -lt 1073741824 ]; then
    printf "%.2f MB" "$(echo "scale=2; $size / 1048576" | bc)"
  else
    printf "%.2f GB" "$(echo "scale=2; $size / 1073741824" | bc)"
  fi
}

# Get the current date in seconds since Unix epoch
CURRENT_DATE=$(date +%s)

# Iterate over the active torrents
for torrent in "${TORRENT_LIST[@]}"; do
  TORRENT_ID=$(echo "$torrent" | jq -r '.id')
  TOTAL_SIZE=$(echo "$torrent" | jq -r '.total_size')
  SIZE_LEFT=$(echo "$torrent" | jq -r '.size_left')
  PROGRESS=$((TOTAL_SIZE - SIZE_LEFT))

  if [ -z "$TORRENT_ID" ]; then
    echo "Warning: Torrent ID is missing. Skipping."
    continue
  fi

  # Convert progress to human-readable units
  PROGRESS_HR=$(convert_size $PROGRESS)
  TOTAL_SIZE_HR=$(convert_size $TOTAL_SIZE)

  # Check if the torrent is already in the database
  ADDED_AT=$(sqlite3 "$DB_PATH" "SELECT added_at FROM torrents WHERE id = '$TORRENT_ID';")
  if [ -z "$ADDED_AT" ]; then
    echo "Adding new torrent (ID: $TORRENT_ID) to the database with downloaded progress: $PROGRESS_HR of $TOTAL_SIZE_HR"
    # Insert new torrent into the database with the current date
    sqlite3 "$DB_PATH" "INSERT INTO torrents (id, added_at, progress, last_seen, last_progress) VALUES ('$TORRENT_ID', $CURRENT_DATE, $PROGRESS, $CURRENT_DATE, $CURRENT_DATE);"
  else
    # Update the progress if it has changed
    PREVIOUS_PROGRESS=$(sqlite3 "$DB_PATH" "SELECT progress FROM torrents WHERE id = '$TORRENT_ID';")
    if [ "$PROGRESS" != "$PREVIOUS_PROGRESS" ]; then
      PROGRESS_DELTA=$((PROGRESS - PREVIOUS_PROGRESS))
      # Use appropriate units for delta
      PROGRESS_DELTA_HR="$(convert_size $PROGRESS_DELTA)"
      # Convert previous and current to human-readable with decimals
      PREVIOUS_PROGRESS_HR=$(convert_size $PREVIOUS_PROGRESS)
      PROGRESS_HR=$(convert_size $PROGRESS)
      if [ "$PROGRESS_DELTA" -gt 0 ]; then
        echo "Updating progress for torrent (ID: $TORRENT_ID). Previous downloaded: $PREVIOUS_PROGRESS_HR, Current downloaded: $PROGRESS_HR, Increased by: $PROGRESS_DELTA_HR"
      else
        echo "Updating progress for torrent (ID: $TORRENT_ID). Previous downloaded: $PREVIOUS_PROGRESS_HR, Current downloaded: $PROGRESS_HR, No change."
      fi
      sqlite3 "$DB_PATH" "UPDATE torrents SET progress = $PROGRESS, last_progress = $CURRENT_DATE, last_seen = $CURRENT_DATE WHERE id = '$TORRENT_ID';"
    else
      HOURS_SINCE_LAST_PROGRESS=$(( (CURRENT_DATE - $(sqlite3 "$DB_PATH" "SELECT last_progress FROM torrents WHERE id = '$TORRENT_ID';")) / 3600 ))
      echo "No progress for torrent (ID: $TORRENT_ID). Last progress was $HOURS_SINCE_LAST_PROGRESS hours ago. Current downloaded: $PROGRESS_HR of $TOTAL_SIZE_HR."
      sqlite3 "$DB_PATH" "UPDATE torrents SET last_seen = $CURRENT_DATE WHERE id = '$TORRENT_ID';"
    fi
  fi

done

# Clean up old entries in the database that are no longer in the active download list
echo "Cleaning up old entries in the database"
EXISTING_IDS=$(for torrent in "${TORRENT_LIST[@]}"; do echo "$torrent" | jq -r '.id'; done)
ALL_DB_IDS=$(sqlite3 "$DB_PATH" "SELECT id FROM torrents;")

for DB_ID in $ALL_DB_IDS; do
  if ! echo "$EXISTING_IDS" | grep -q "$DB_ID"; then
    LAST_SEEN=$(sqlite3 "$DB_PATH" "SELECT last_seen FROM torrents WHERE id = '$DB_ID';")
    if (( (CURRENT_DATE - LAST_SEEN) > (GRACE_PERIOD * 3600) )); then
      echo "Deleting old torrent entry with ID: $DB_ID from the database after exceeding grace period"
      curl -s -X DELETE "$URL/api/v3/queue/$DB_ID?apikey=$API_KEY" && echo "Successfully removed torrent (ID: $DB_ID) from downloader"
      sqlite3 "$DB_PATH" "DELETE FROM torrents WHERE id = '$DB_ID';"
    else
      echo "Torrent ID: $DB_ID has not exceeded grace period. Last seen: $(date -d @$LAST_SEEN '+%Y-%m-%d %H:%M')."
    fi
  else
    # Check if the progress has not changed beyond the time threshold
    LAST_PROGRESS=$(sqlite3 "$DB_PATH" "SELECT last_progress FROM torrents WHERE id = '$DB_ID';")
    HOURS_SINCE_LAST_PROGRESS=$(( (CURRENT_DATE - LAST_PROGRESS) / 3600 ))
    if (( HOURS_SINCE_LAST_PROGRESS > TIME_THRESHOLD )); then
      echo "Deleting torrent entry with ID: $DB_ID from the database and downloader due to no progress beyond threshold (Threshold: $TIME_THRESHOLD hours, Last progress: $HOURS_SINCE_LAST_PROGRESS hours ago)"
      curl -s -X DELETE "$URL/api/v3/queue/$DB_ID?apikey=$API_KEY" && echo "Successfully removed torrent (ID: $DB_ID) from downloader"
      sqlite3 "$DB_PATH" "DELETE FROM torrents WHERE id = '$DB_ID';"
    fi
  fi
done

echo "Script execution completed."
exit 0
