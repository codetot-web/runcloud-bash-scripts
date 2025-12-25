#!/bin/bash

# === Usage ===
# ./wp-migration.sh user@host:port src_appname [dest_appname]
#
# Examples:
# - Same app name on both ends:
#   ./wp-migration.sh runcloud@sample.codetot.com:2018 myapp
#
# - Different app name on destination:
#   ./wp-migration.sh ecohome@sample.codetot.com:2018 srcapp destapp

set -euo pipefail

# === Parameters ===
if [ $# -lt 2 ] || [ $# -gt 3 ]; then
  echo "Usage: $0 user@host:port src_appname [dest_appname]"
  exit 1
fi

DEST_RAW="$1"           # e.g. ecohome@sg6.codetot.org:2018
SRC_APPNAME="$2"        # source app name
DEST_APPNAME="${3:-$SRC_APPNAME}"   # default to same as source

# Parse user, host, port
USERHOST="${DEST_RAW%:*}"             # strip :port
DEST_PORT="${DEST_RAW##*:}"           # port after last :
DEST_USER="${USERHOST%@*}"            # before @
DEST_HOST="${USERHOST#*@}"            # after @

# Paths
SRC_PATH="/home/$USER/webapps/$SRC_APPNAME"
DEST_PATH="/home/$DEST_USER/webapps/$DEST_APPNAME"

DATE="$(date +"%Y%m%d_%H%M%S")"
DB_FILE="db_export_${SRC_APPNAME}_${DATE}.sql"
LOG_FILE="/home/$USER/wp_uploads_${DEST_APPNAME}_${DATE}.log"

# === Pre-flight checks ===
echo "Source path: $SRC_PATH"
echo "Destination: $DEST_USER@$DEST_HOST:$DEST_PATH (port $DEST_PORT)"
if [ ! -d "$SRC_PATH" ]; then
  echo "Error: Source path not found: $SRC_PATH"
  exit 1
fi
if ! command -v wp >/dev/null 2>&1; then
  echo "Error: 'wp' CLI not found in PATH. Install WP-CLI or adjust PATH."
  exit 1
fi

# === Export Database ===
echo "Exporting database from $SRC_APPNAME..."
cd "$SRC_PATH"
wp db export "$DB_FILE"

# === Sync core config files ===
echo "Syncing wp-config.php..."
rsync -zaP -e "ssh -p $DEST_PORT" "$SRC_PATH/wp-config.php" \
  "$DEST_USER@$DEST_HOST:$DEST_PATH/"

if [ -f "$SRC_PATH/.htaccess" ]; then
  echo "Syncing .htaccess..."
  rsync -zaP -e "ssh -p $DEST_PORT" "$SRC_PATH/.htaccess" \
    "$DEST_USER@$DEST_HOST:$DEST_PATH/"
fi

if [ -f "$SRC_PATH/.htninja" ]; then
  echo "Syncing .htninja..."
  rsync -zaP -e "ssh -p $DEST_PORT" "$SRC_PATH/.htninja" \
    "$DEST_USER@$DEST_HOST:$DEST_PATH/"
fi

# === Sync uploads in background (nohup) ===
echo "Starting uploads sync in background with nohup..."
nohup rsync -zaP -e "ssh -p $DEST_PORT" \
  "$SRC_PATH/wp-content/uploads/" \
  "$DEST_USER@$DEST_HOST:$DEST_PATH/wp-content/uploads/" \
  > "$LOG_FILE" 2>&1 &

UPLOADS_PID=$!
echo "Uploads sync started (PID: $UPLOADS_PID)."
echo "Log file: $LOG_FILE"
echo "Monitor with: tail -f \"$LOG_FILE\""

# === Copy DB export ===
echo "Copying DB export to destination..."
rsync -zaP -e "ssh -p $DEST_PORT" "$SRC_PATH/$DB_FILE" \
  "$DEST_USER@$DEST_HOST:$DEST_PATH/"

# === Cleanup local DB export ===
rm -f "$SRC_PATH/$DB_FILE"

echo "✅ Migration kicked off."
echo "- Configs synced."
echo "- Database exported and transferred."
echo "- Uploads are syncing in background (see log above)."
