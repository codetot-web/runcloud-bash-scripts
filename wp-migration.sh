#!/bin/bash
# WordPress Migration Script for RunCloud Servers
#
# Migrates a WordPress site from the current server to a destination server:
# - Exports and imports database (reads credentials from wp-config.php)
# - Syncs wp-config.php, .htaccess, .htninja
# - Syncs wp-content/uploads
# - Initializes git submodules on destination
# - Optionally updates site URL for staging domain
#
# Prerequisites:
# - SSH key auth from source to destination (use --setup-ssh to configure)
# - wp-cli installed on both servers
# - Database and user must already exist on destination
#
# === Usage ===
# Run from source server as the runcloud user:
#
# ./wp-migration.sh user@host[:port] src_appname [dest_appname]
# ./wp-migration.sh user@host[:port] src_appname [dest_appname] --staging-url=http://example.temp-site.link
# ./wp-migration.sh user@host[:port] --setup-ssh
#
# Examples:
# Same app name:     ./wp-migration.sh runcloud@sg3.codetot.org myapp
# Different app:     ./wp-migration.sh runcloud@sg3.codetot.org myapp newapp
# With staging URL:  ./wp-migration.sh runcloud@sg3.codetot.org myapp --staging-url=http://myapp.temp-site.link
# Setup SSH keys:    ./wp-migration.sh runcloud@sg3.codetot.org --setup-ssh

set -euo pipefail

# ============================================================
# Color output
# ============================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ============================================================
# Parse arguments
# ============================================================
STAGING_URL=""
SETUP_SSH=false

POSITIONAL=()
for arg in "$@"; do
  case $arg in
    --staging-url=*)
      STAGING_URL="${arg#*=}"
      ;;
    --setup-ssh)
      SETUP_SSH=true
      ;;
    *)
      POSITIONAL+=("$arg")
      ;;
  esac
done

if [ ${#POSITIONAL[@]} -lt 1 ]; then
  echo "Usage: $0 user@host[:port] src_appname [dest_appname] [--staging-url=URL] [--setup-ssh]"
  exit 1
fi

DEST_RAW="${POSITIONAL[0]}"

# Parse destination: user@host[:port]
if [[ "$DEST_RAW" == *:* ]]; then
  USERHOST="${DEST_RAW%:*}"
  DEST_PORT="${DEST_RAW##*:}"
else
  USERHOST="$DEST_RAW"
  DEST_PORT="22"
fi

DEST_USER="${USERHOST%@*}"
DEST_HOST="${USERHOST#*@}"

SSH_CMD="ssh -p $DEST_PORT -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new"
RSYNC_SSH="ssh -p $DEST_PORT"

# ============================================================
# SSH key setup mode
# ============================================================
if [ "$SETUP_SSH" = true ]; then
  info "Setting up SSH key auth to $DEST_USER@$DEST_HOST:$DEST_PORT"

  if [ ! -f "$HOME/.ssh/id_ed25519.pub" ]; then
    info "Generating SSH key..."
    ssh-keygen -t ed25519 -f "$HOME/.ssh/id_ed25519" -N '' -q
  fi

  PUBKEY=$(cat "$HOME/.ssh/id_ed25519.pub")
  info "Adding public key to destination..."
  $SSH_CMD "$DEST_USER@$DEST_HOST" "
    mkdir -p ~/.ssh && chmod 700 ~/.ssh
    echo '$PUBKEY' >> ~/.ssh/authorized_keys
    sort -u -o ~/.ssh/authorized_keys ~/.ssh/authorized_keys
    chmod 600 ~/.ssh/authorized_keys
  "

  # Add host key to known_hosts
  ssh-keyscan -p "$DEST_PORT" "$DEST_HOST" >> "$HOME/.ssh/known_hosts" 2>/dev/null
  sort -u -o "$HOME/.ssh/known_hosts" "$HOME/.ssh/known_hosts"

  # Test connection
  if $SSH_CMD "$DEST_USER@$DEST_HOST" "echo 'OK'" &>/dev/null; then
    info "SSH key auth working!"
  else
    error "SSH key auth failed. You may need to add the key manually."
    exit 1
  fi
  exit 0
fi

# ============================================================
# Validate migration arguments
# ============================================================
if [ ${#POSITIONAL[@]} -lt 2 ]; then
  echo "Usage: $0 user@host[:port] src_appname [dest_appname] [--staging-url=URL]"
  exit 1
fi

SRC_APPNAME="${POSITIONAL[1]}"
DEST_APPNAME="${POSITIONAL[2]:-$SRC_APPNAME}"

# Resolve source user. RunCloud panel apps default to /home/runcloud/webapps,
# but private setups may use a different system user. Auto-detect by scanning
# /home/*/webapps/<appname>, with SRC_USER env var as override.
if [ -n "${SRC_USER:-}" ]; then
  SRC_PATH="/home/$SRC_USER/webapps/$SRC_APPNAME"
else
  shopt -s nullglob
  SRC_CANDIDATES=(/home/*/webapps/"$SRC_APPNAME")
  shopt -u nullglob

  if [ ${#SRC_CANDIDATES[@]} -eq 0 ]; then
    error "Webapp '$SRC_APPNAME' not found under /home/*/webapps/. Set SRC_USER=<user> if your webapps live elsewhere."
    exit 1
  elif [ ${#SRC_CANDIDATES[@]} -gt 1 ]; then
    error "Multiple webapps named '$SRC_APPNAME' found:"
    printf '  %s\n' "${SRC_CANDIDATES[@]}" >&2
    error "Set SRC_USER=<user> to disambiguate."
    exit 1
  fi

  SRC_PATH="${SRC_CANDIDATES[0]}"
  SRC_USER=$(awk -F/ '{print $3}' <<<"$SRC_PATH")
  info "Auto-detected source user: $SRC_USER"
fi

DEST_PATH="/home/$DEST_USER/webapps/$DEST_APPNAME"

DATE="$(date +"%Y%m%d_%H%M%S")"
DB_FILE="/tmp/db_export_${SRC_APPNAME}_${DATE}.sql.gz"

# ============================================================
# Validate source path
# ============================================================
if [ ! -d "$SRC_PATH" ]; then
  error "Source path does not exist: $SRC_PATH"
  exit 1
fi

if [ ! -f "$SRC_PATH/wp-config.php" ]; then
  error "wp-config.php not found in $SRC_PATH"
  exit 1
fi

# ============================================================
# Test SSH connection
# ============================================================
info "Testing SSH connection to $DEST_USER@$DEST_HOST:$DEST_PORT..."
if ! $SSH_CMD "$DEST_USER@$DEST_HOST" "echo 'OK'" &>/dev/null; then
  error "Cannot connect. Run: $0 $DEST_RAW --setup-ssh"
  exit 1
fi

# Validate destination path exists
if ! $SSH_CMD "$DEST_USER@$DEST_HOST" "[ -d '$DEST_PATH' ]"; then
  error "Destination path does not exist: $DEST_PATH"
  exit 1
fi

# ============================================================
# Read DB credentials from wp-config.php
# ============================================================
extract_wp_config() {
  local key="$1"
  grep "define.*'${key}'" "$SRC_PATH/wp-config.php" \
    | sed "s/.*'${key}'[[:space:]]*,[[:space:]]*'//; s/'.*//"
}

DB_NAME=$(extract_wp_config "DB_NAME")
DB_USER=$(extract_wp_config "DB_USER")
DB_PASS=$(extract_wp_config "DB_PASSWORD")
DB_HOST=$(extract_wp_config "DB_HOST")

# Read table prefix
TABLE_PREFIX=$(grep '^\$table_prefix' "$SRC_PATH/wp-config.php" \
  | sed "s/.*'//; s/'.*//" || echo "wp_")

if [ -z "$DB_NAME" ] || [ -z "$DB_USER" ] || [ -z "$DB_PASS" ]; then
  error "Could not read DB credentials from wp-config.php"
  exit 1
fi

info "Source: $SRC_PATH"
info "Destination: $DEST_USER@$DEST_HOST:$DEST_PATH (port $DEST_PORT)"
info "Database: $DB_NAME (prefix: $TABLE_PREFIX)"
echo ""

# ============================================================
# Step 1: Export database
# ============================================================
info "Step 1/6: Exporting database..."
if command -v wp &>/dev/null && wp core is-installed --path="$SRC_PATH" 2>/dev/null; then
  wp db export --path="$SRC_PATH" - | gzip > "$DB_FILE"
else
  mysqldump --single-transaction --skip-lock-tables \
    -u "$DB_USER" -p"$DB_PASS" -h "$DB_HOST" "$DB_NAME" \
    2>/tmp/migration_dump_err.log | gzip > "$DB_FILE"

  if [ -s /tmp/migration_dump_err.log ]; then
    warn "mysqldump warnings (non-fatal):"
    cat /tmp/migration_dump_err.log
    rm -f /tmp/migration_dump_err.log
  fi
fi

DB_SIZE=$(du -h "$DB_FILE" | cut -f1)
info "Database exported: $DB_FILE ($DB_SIZE)"

# ============================================================
# Step 2: Transfer and import database
# ============================================================
info "Step 2/6: Transferring database to destination..."
rsync -az -e "$RSYNC_SSH" "$DB_FILE" "$DEST_USER@$DEST_HOST:/tmp/"

REMOTE_DB_FILE="/tmp/$(basename "$DB_FILE")"

info "Importing database on destination..."
$SSH_CMD "$DEST_USER@$DEST_HOST" "
  gunzip -c '$REMOTE_DB_FILE' | mysql -u '$DB_USER' -p'$DB_PASS' -h '$DB_HOST' '$DB_NAME' 2>&1 \
    | grep -v 'Deprecated program name' || true
  rm -f '$REMOTE_DB_FILE'
"

rm -f "$DB_FILE"
info "Database imported successfully"

# ============================================================
# Step 3: Sync config files
# ============================================================
info "Step 3/6: Syncing config files..."

rsync -az -e "$RSYNC_SSH" "$SRC_PATH/wp-config.php" \
  "$DEST_USER@$DEST_HOST:$DEST_PATH/"
info "  wp-config.php synced"

if [ -f "$SRC_PATH/.htaccess" ]; then
  rsync -az -e "$RSYNC_SSH" "$SRC_PATH/.htaccess" \
    "$DEST_USER@$DEST_HOST:$DEST_PATH/"
  info "  .htaccess synced"
fi

if [ -f "$SRC_PATH/.htninja" ]; then
  rsync -az -e "$RSYNC_SSH" "$SRC_PATH/.htninja" \
    "$DEST_USER@$DEST_HOST:$DEST_PATH/"
  info "  .htninja synced"
fi

# ============================================================
# Step 4: Sync uploads
# ============================================================
if [ -d "$SRC_PATH/wp-content/uploads" ]; then
  UPLOADS_SIZE=$(du -sh "$SRC_PATH/wp-content/uploads/" 2>/dev/null | cut -f1)
  info "Step 4/6: Syncing uploads ($UPLOADS_SIZE)... this may take a while"
  rsync -az -e "$RSYNC_SSH" "$SRC_PATH/wp-content/uploads/" \
    "$DEST_USER@$DEST_HOST:$DEST_PATH/wp-content/uploads/"
  info "Uploads synced"
else
  info "Step 4/6: No uploads directory found, skipping"
fi

# ============================================================
# Step 5: Git submodules
# ============================================================
info "Step 5/6: Initializing git submodules on destination..."
$SSH_CMD "$DEST_USER@$DEST_HOST" "
  cd '$DEST_PATH'
  if [ -f .gitmodules ]; then
    git submodule update --init --recursive 2>&1
    echo 'Submodules initialized'
  else
    echo 'No .gitmodules found, skipping'
  fi
"

# ============================================================
# Step 6: Update site URL (optional)
# ============================================================
if [ -n "$STAGING_URL" ]; then
  info "Step 6/6: Updating site URL to $STAGING_URL..."

  # Get current URL from database on destination
  CURRENT_URL=$($SSH_CMD "$DEST_USER@$DEST_HOST" "
    mysql -u '$DB_USER' -p'$DB_PASS' -h '$DB_HOST' '$DB_NAME' -N \
      -e \"SELECT option_value FROM ${TABLE_PREFIX}options WHERE option_name='siteurl' LIMIT 1;\" 2>/dev/null
  ")

  if [ -n "$CURRENT_URL" ]; then
    info "  Current URL: $CURRENT_URL"
    info "  New URL: $STAGING_URL"

    $SSH_CMD "$DEST_USER@$DEST_HOST" "
      mysql -u '$DB_USER' -p'$DB_PASS' -h '$DB_HOST' '$DB_NAME' \
        -e \"UPDATE ${TABLE_PREFIX}options SET option_value='$STAGING_URL' WHERE option_name IN ('siteurl','home');\" 2>/dev/null
    "

    # If wp-cli is available on destination, do a full search-replace
    $SSH_CMD "$DEST_USER@$DEST_HOST" "
      if command -v wp &>/dev/null; then
        cd '$DEST_PATH'
        wp search-replace '$CURRENT_URL' '$STAGING_URL' --skip-columns=guid --all-tables 2>&1 || true
      fi
    "
    info "Site URL updated"
  else
    warn "Could not read current URL from database"
  fi
else
  info "Step 6/6: No staging URL provided, skipping URL update"
fi

# ============================================================
# Done
# ============================================================
echo ""
info "============================================"
info "Migration completed!"
info "============================================"
info "Source:      $SRC_PATH"
info "Destination: $DEST_USER@$DEST_HOST:$DEST_PATH"
if [ -n "$STAGING_URL" ]; then
  info "Staging URL: $STAGING_URL"
fi
echo ""
info "Post-migration checklist:"
info "  1. Verify the site loads at the destination URL"
info "  2. Check wp-admin login works"
info "  3. Verify uploads/images display correctly"
info "  4. Clear any cache plugins (LiteSpeed, etc.)"
