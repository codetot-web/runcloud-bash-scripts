#!/bin/bash
# Laravel Migration Script for RunCloud Servers
#
# Migrates a Laravel app from the current server to a destination server:
# - Exports and imports database (reads credentials from .env)
# - Syncs .env (optionally rewriting APP_URL for staging)
# - Syncs storage/app and public/build
# - Initializes git submodules on destination
# - Runs composer install, php artisan storage:link + optimize on destination
#
# Prerequisites:
# - SSH key auth from source to destination (use --setup-ssh to configure)
# - PHP + composer installed on destination
# - Database and DB user must already exist on destination with same NAME/USER
#   as source (passwords differ — caller is expected to ALTER USER beforehand,
#   or the script's import will fail loudly)
#
# === Usage ===
# Run from source server (typically as root or the runcloud user):
#
# ./laravel-migration.sh user@host[:port] src_appname [dest_appname] [flags]
# ./laravel-migration.sh user@host[:port] --setup-ssh
#
# Flags:
#   --staging-url=URL    Override APP_URL on destination (e.g. http://staging.example.com)
#   --skip-composer      Skip `composer install` on destination
#   --skip-build         Skip syncing public/build (assets)
#   --skip-storage       Skip syncing storage/app
#   --skip-migrate       Skip `php artisan migrate --force`
#   --setup-ssh          Set up SSH key auth, then exit
#
# Examples:
# Same app name:    ./laravel-migration.sh runcloud@sg4.codetot.org myapp
# Different app:    ./laravel-migration.sh runcloud@sg4.codetot.org myapp newapp
# With staging URL: ./laravel-migration.sh runcloud@sg4.codetot.org myapp --staging-url=http://staging.tld
# Setup SSH keys:   ./laravel-migration.sh runcloud@sg4.codetot.org --setup-ssh

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
SKIP_COMPOSER=false
SKIP_BUILD=false
SKIP_STORAGE=false
SKIP_MIGRATE=false

POSITIONAL=()
for arg in "$@"; do
  case $arg in
    --staging-url=*) STAGING_URL="${arg#*=}" ;;
    --setup-ssh)     SETUP_SSH=true ;;
    --skip-composer) SKIP_COMPOSER=true ;;
    --skip-build)    SKIP_BUILD=true ;;
    --skip-storage)  SKIP_STORAGE=true ;;
    --skip-migrate)  SKIP_MIGRATE=true ;;
    *)               POSITIONAL+=("$arg") ;;
  esac
done

if [ ${#POSITIONAL[@]} -lt 1 ]; then
  echo "Usage: $0 user@host[:port] src_appname [dest_appname] [--staging-url=URL] [--skip-composer] [--skip-build] [--skip-storage] [--skip-migrate] [--setup-ssh]"
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

# Multiplex SSH so caller is prompted at most once.
SSH_CTRL_DIR="$(mktemp -d "${TMPDIR:-/tmp}/laravel-migration-ssh.XXXXXX")"
trap 'rm -rf "$SSH_CTRL_DIR"' EXIT
SSH_OPTS="-o ControlMaster=auto -o ControlPath=$SSH_CTRL_DIR/%r@%h:%p -o ControlPersist=10m"

SSH_CMD="ssh $SSH_OPTS -p $DEST_PORT -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new"
RSYNC_SSH="ssh $SSH_OPTS -p $DEST_PORT"

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

  ssh-keyscan -p "$DEST_PORT" "$DEST_HOST" >> "$HOME/.ssh/known_hosts" 2>/dev/null
  sort -u -o "$HOME/.ssh/known_hosts" "$HOME/.ssh/known_hosts"

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

# Resolve source path. SRC_USER env var overrides auto-detection.
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

if [ ! -f "$SRC_PATH/.env" ]; then
  error ".env not found in $SRC_PATH"
  exit 1
fi

if [ ! -f "$SRC_PATH/artisan" ]; then
  warn "No artisan file at $SRC_PATH — is this really a Laravel app?"
fi

# ============================================================
# Test SSH connection
# ============================================================
info "Testing SSH connection to $DEST_USER@$DEST_HOST:$DEST_PORT..."
if ! $SSH_CMD "$DEST_USER@$DEST_HOST" "echo 'OK'" &>/dev/null; then
  error "Cannot connect. Run: $0 $DEST_RAW --setup-ssh"
  exit 1
fi

if ! $SSH_CMD "$DEST_USER@$DEST_HOST" "[ -d '$DEST_PATH' ]"; then
  error "Destination path does not exist: $DEST_PATH"
  exit 1
fi

# ============================================================
# Read DB credentials from .env
# ============================================================
# .env values may be quoted or unquoted; strip surrounding quotes if present.
extract_env() {
  local key="$1"
  awk -F= -v k="$key" '
    $1 == k {
      sub(/^[^=]*=/, "")
      # strip leading/trailing whitespace
      sub(/^[[:space:]]+/, "")
      sub(/[[:space:]]+$/, "")
      # strip optional surrounding quotes
      if (match($0, /^".*"$/) || match($0, /^'\''.*'\''$/)) {
        $0 = substr($0, 2, length($0)-2)
      }
      print
      exit
    }
  ' "$SRC_PATH/.env"
}

DB_CONNECTION=$(extract_env "DB_CONNECTION")
DB_NAME=$(extract_env "DB_DATABASE")
DB_USER=$(extract_env "DB_USERNAME")
DB_PASS=$(extract_env "DB_PASSWORD")
DB_HOST=$(extract_env "DB_HOST")
DB_PORT=$(extract_env "DB_PORT")
APP_URL=$(extract_env "APP_URL")

[ -z "$DB_HOST" ] && DB_HOST="127.0.0.1"
[ -z "$DB_PORT" ] && DB_PORT="3306"

if [ "$DB_CONNECTION" != "mysql" ] && [ "$DB_CONNECTION" != "mariadb" ]; then
  error "Unsupported DB_CONNECTION: '$DB_CONNECTION' (only mysql/mariadb supported)"
  exit 1
fi

if [ -z "$DB_NAME" ] || [ -z "$DB_USER" ] || [ -z "$DB_PASS" ]; then
  error "Could not read DB credentials from .env (DB_DATABASE/DB_USERNAME/DB_PASSWORD)"
  exit 1
fi

info "Source: $SRC_PATH"
info "Destination: $DEST_USER@$DEST_HOST:$DEST_PATH (port $DEST_PORT)"
info "Database: $DB_NAME (user: $DB_USER, host: $DB_HOST:$DB_PORT)"
info "App URL (source): $APP_URL"
[ -n "$STAGING_URL" ] && info "App URL (override): $STAGING_URL"
echo ""

# ============================================================
# Step 1: Export database
# ============================================================
info "Step 1/6: Exporting database..."
mysqldump --single-transaction --skip-lock-tables \
  -u "$DB_USER" -p"$DB_PASS" -h "$DB_HOST" -P "$DB_PORT" "$DB_NAME" \
  2>/tmp/laravel_migration_dump_err.log | gzip > "$DB_FILE"

if [ -s /tmp/laravel_migration_dump_err.log ]; then
  # mysqldump emits "Deprecated program name" on Ubuntu 24 — non-fatal.
  if grep -qv 'Deprecated program name' /tmp/laravel_migration_dump_err.log; then
    warn "mysqldump warnings:"
    grep -v 'Deprecated program name' /tmp/laravel_migration_dump_err.log || true
  fi
  rm -f /tmp/laravel_migration_dump_err.log
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
if ! $SSH_CMD "$DEST_USER@$DEST_HOST" bash -s <<REMOTE
  gunzip -c '$REMOTE_DB_FILE' | mysql -u '$DB_USER' -p'$DB_PASS' -h '$DB_HOST' -P '$DB_PORT' '$DB_NAME' 2> >(grep -v 'Deprecated program name' >&2)
  status=\$?
  rm -f '$REMOTE_DB_FILE'
  exit \$status
REMOTE
then
  error "Database import failed on destination."
  error "Hint: ensure DB '$DB_NAME' and user '$DB_USER' with matching password exist on $DEST_HOST"
  error "  ssh root@$DEST_HOST \"mysql -e \\\"ALTER USER '$DB_USER'@'%' IDENTIFIED BY '<source-password>'; FLUSH PRIVILEGES;\\\"\""
  rm -f "$DB_FILE"
  exit 1
fi

rm -f "$DB_FILE"
info "Database imported successfully"

# ============================================================
# Step 3: Sync .env (with optional APP_URL override)
# ============================================================
info "Step 3/6: Syncing .env..."

if [ -n "$STAGING_URL" ]; then
  # Stream a modified .env to destination via SSH (avoids touching source file).
  info "  Rewriting APP_URL → $STAGING_URL"
  awk -v new_url="$STAGING_URL" '
    BEGIN { FS=OFS="=" }
    /^APP_URL[[:space:]]*=/ { print "APP_URL=" new_url; next }
    { print }
  ' "$SRC_PATH/.env" \
    | $SSH_CMD "$DEST_USER@$DEST_HOST" "cat > '$DEST_PATH/.env' && chmod 640 '$DEST_PATH/.env'"
else
  rsync -az -e "$RSYNC_SSH" "$SRC_PATH/.env" "$DEST_USER@$DEST_HOST:$DEST_PATH/.env"
fi
info "  .env synced"

# ============================================================
# Step 4: Sync storage/app and public/build
# ============================================================
if [ "$SKIP_STORAGE" = false ] && [ -d "$SRC_PATH/storage/app" ]; then
  STORAGE_SIZE=$(du -sh "$SRC_PATH/storage/app/" 2>/dev/null | cut -f1)
  info "Step 4/6: Syncing storage/app ($STORAGE_SIZE)..."
  rsync -az --delete -e "$RSYNC_SSH" \
    "$SRC_PATH/storage/app/" \
    "$DEST_USER@$DEST_HOST:$DEST_PATH/storage/app/"
  info "  storage/app synced"
else
  info "Step 4/6: Skipping storage/app sync"
fi

if [ "$SKIP_BUILD" = false ] && [ -d "$SRC_PATH/public/build" ]; then
  BUILD_SIZE=$(du -sh "$SRC_PATH/public/build/" 2>/dev/null | cut -f1)
  info "  Syncing public/build ($BUILD_SIZE)..."
  rsync -az --delete -e "$RSYNC_SSH" \
    "$SRC_PATH/public/build/" \
    "$DEST_USER@$DEST_HOST:$DEST_PATH/public/build/"
  info "  public/build synced"
fi

# Ensure destination LSWS routes / → public/index.php. RunCloud panel's "Public
# Path" setting writes a `context /` block in handler.conf, but newer RunCloud
# versions may not expose that toggle. As a portable workaround, drop a root
# .htaccess that rewrites to public/ — the vhost has autoLoadHtaccess enabled,
# so this gets picked up without touching RunCloud-managed configs. Skip if a
# root .htaccess already exists (don't clobber user customisations).
info "  Ensuring root .htaccess routes / → public/..."
$SSH_CMD "$DEST_USER@$DEST_HOST" "
  if [ ! -f '$DEST_PATH/.htaccess' ]; then
    cat > '$DEST_PATH/.htaccess' <<'HTACCESS'
<IfModule mod_rewrite.c>
    RewriteEngine On
    RewriteCond %{REQUEST_URI} !^/public/
    RewriteRule ^(.*)$ public/\$1 [L]
</IfModule>
HTACCESS
    echo '  root .htaccess created'
  else
    echo '  root .htaccess already exists, leaving alone'
  fi
"

# ============================================================
# Step 5: Git submodules + composer install
# ============================================================
info "Step 5/6: Detecting PHP binary + running composer on destination..."
# RunCloud writes `path /usr/local/lsws/lsphpXX/bin/lsphp` into the webapp's
# handler.conf. Reuse the same lsphpXX directory for the CLI binary so we don't
# fall back to the system /usr/bin/php (which is often older than what the app
# requires). Allow caller override via PHP_BINARY env var.
$SSH_CMD "$DEST_USER@$DEST_HOST" bash -s <<REMOTE
  set -e
  cd '$DEST_PATH'

  # Resolve PHP binary
  PHP_BIN="\${PHP_BINARY:-}"
  if [ -z "\$PHP_BIN" ]; then
    HANDLER="/etc/lsws-rc/conf.d/$DEST_APPNAME.d/handler.conf"
    if [ -r "\$HANDLER" ]; then
      LSPHP_DIR=\$(awk '/^[[:space:]]*path[[:space:]]/ && \$2 ~ /lsphp[0-9]+/ {
        sub(/\/bin\/lsphp\$/, "", \$2); print \$2; exit
      }' "\$HANDLER")
      if [ -n "\$LSPHP_DIR" ] && [ -x "\$LSPHP_DIR/bin/php" ]; then
        PHP_BIN="\$LSPHP_DIR/bin/php"
      fi
    fi
  fi
  [ -z "\$PHP_BIN" ] && PHP_BIN=\$(command -v php || echo /usr/bin/php)
  echo "Using PHP binary: \$PHP_BIN (\$(\$PHP_BIN -v | head -1))"

  if [ -f .gitmodules ]; then
    git submodule update --init --recursive 2>&1
    echo 'Submodules initialized'
  fi

  if [ '$SKIP_COMPOSER' = 'false' ]; then
    COMPOSER_BIN=\$(command -v composer 2>/dev/null || true)
    if [ -n "\$COMPOSER_BIN" ]; then
      "\$PHP_BIN" "\$COMPOSER_BIN" install --no-dev --optimize-autoloader --no-interaction 2>&1 | tail -10
    else
      echo 'composer not found — skipping'
    fi
  fi

  # Step 6: Artisan
  echo '--- Running artisan commands ---'
  "\$PHP_BIN" artisan storage:link 2>&1 || true
  "\$PHP_BIN" artisan config:clear 2>&1 || true
  "\$PHP_BIN" artisan route:clear 2>&1 || true
  "\$PHP_BIN" artisan view:clear 2>&1 || true
  "\$PHP_BIN" artisan cache:clear 2>&1 || true
  if [ '$SKIP_MIGRATE' = 'false' ]; then
    "\$PHP_BIN" artisan migrate --force 2>&1 || true
  fi
  "\$PHP_BIN" artisan config:cache 2>&1 || true
  "\$PHP_BIN" artisan route:cache 2>&1 || true
  "\$PHP_BIN" artisan view:cache 2>&1 || true
REMOTE

# ============================================================
# Done
# ============================================================
echo ""
info "============================================"
info "Migration completed!"
info "============================================"
info "Source:      $SRC_PATH"
info "Destination: $DEST_USER@$DEST_HOST:$DEST_PATH"
[ -n "$STAGING_URL" ] && info "Staging URL: $STAGING_URL"
echo ""
info "Post-migration checklist:"
info "  1. Visit the destination URL and confirm the app loads"
info "  2. Test login / a few key flows"
info "  3. Set up cron: * * * * * cd $DEST_PATH && php artisan schedule:run >> /dev/null 2>&1"
info "  4. Set up queue worker (supervisor) if QUEUE_CONNECTION != sync"
info "  5. Verify storage permissions (chown -R runcloud:runcloud storage bootstrap/cache)"
info ""
info "Note: a root .htaccess was created to route / → public/. If RunCloud panel"
info "exposes a Public Path setting on your version, prefer setting it to /public"
info "and removing the root .htaccess — that yields a cleaner LSWS context block."
