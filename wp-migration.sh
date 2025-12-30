#!/bin/bash
# The Bash script to help you migration the Runcloud application from one to another 
# - copy wp-config.php
# - copy .htaccess
# - copy .htninja
# - copy wp-content/uploads
# 
# Notice: It does not copy a whole project since you can make backup and restore to another server
# Our team setup Git for every project so we don't need to copy a full project
# 
# === Usage ===
# ./wp-migration.sh user@host:port sampleapp [destapp]
#
# Example:
# Same app: ./wp-migration.sh runcloud@sample.server.com:22 sampleapp
# Different app: ./wp-migration.sh ecohome@sample.server.com:22 sampleapp destapp

set -euo pipefail

if [ $# -lt 2 ] || [ $# -gt 3 ]; then
  echo "Usage: $0 user@host:port src_appname [dest_appname]"
  exit 1
fi

DEST_RAW="$1"
SRC_APPNAME="$2"
DEST_APPNAME="${3:-$SRC_APPNAME}"

USERHOST="${DEST_RAW%:*}"             # strip :port
DEST_PORT="${DEST_RAW##*:}"           # port after last :
DEST_USER="${USERHOST%@*}"            # before @
DEST_HOST="${USERHOST#*@}"            # after @

SRC_PATH="/home/$USER/webapps/$SRC_APPNAME"
DEST_PATH="/home/$DEST_USER/webapps/$DEST_APPNAME"

DATE="$(date +"%Y%m%d_%H%M%S")"
DB_FILE="db_export_${SRC_APPNAME}_${DATE}.sql"

echo "Source path: $SRC_PATH"
echo "Destination: $DEST_USER@$DEST_HOST:$DEST_PATH (port $DEST_PORT)"

# === Export Database ===
cd "$SRC_PATH" || exit
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

# === Sync uploads in foreground ===
echo "Syncing uploads folder (this may take a while)..."
rsync -zaP -e "ssh -p $DEST_PORT" "$SRC_PATH/wp-content/uploads/" \
  "$DEST_USER@$DEST_HOST:$DEST_PATH/wp-content/uploads/"

# === Copy DB export ===
echo "Copying DB export..."
rsync -zaP -e "ssh -p $DEST_PORT" "$SRC_PATH/$DB_FILE" \
  "$DEST_USER@$DEST_HOST:$DEST_PATH/"

rm -f "$SRC_PATH/$DB_FILE"

echo "✅ Migration completed. Uploads finished in foreground."
