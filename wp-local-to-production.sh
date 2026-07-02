#!/bin/bash
#
# wp-local-to-production.sh — Sync a local WordPress site to a RunCloud
# production webapp.
#
# What it does:
# - Exports the local database from a WordPress site on this Mac
# - Imports it into the destination RunCloud database
# - Syncs local wp-content/uploads to the destination webapp
# - Syncs .htaccess and .htninja when present
# - Runs a production URL search-replace on the destination
#
# What it does NOT do:
# - It does not copy wp-config.php
# - It does not delete remote uploads by default
#
# Usage:
#   ./wp-local-to-production.sh runcloud@sg4.codetot.org "/Users/khoipro/Local Sites/cdev/app/public" \
#     --production-url=http://cdev.example.temp-site.link
#   ./wp-local-to-production.sh runcloud@sg4.codetot.org "/Users/khoipro/Local Sites/cdev/app/public" cdev \
#     --production-url=http://cdev.example.temp-site.link
#   ./wp-local-to-production.sh runcloud@sg4.codetot.org "/Users/khoipro/Local Sites/cdev/app/public" \
#     --setup-ssh --production-url=http://cdev.example.temp-site.link
#   ./wp-local-to-production.sh runcloud@sg4.codetot.org "/Users/khoipro/Local Sites/cdev/app/public" \
#     --dry-run --production-url=http://cdev.example.temp-site.link
#
# Notes:
# - Destination database credentials are read from the destination wp-config.php.
# - Local database credentials are read from the local wp-config.php.
# - RunCloud temp-site URLs are fine as the production-url target during staging.
#

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

POSITIONAL=()
PRODUCTION_URL=""
SKIP_UPLOADS=false
SKIP_SEARCH_REPLACE=false
SKIP_HTACCESS=false
SKIP_SUBMODULES=false
SETUP_SSH=false
DRY_RUN=false

for arg in "$@"; do
  case $arg in
    --production-url=*)
      PRODUCTION_URL="${arg#*=}"
      ;;
    --skip-uploads)
      SKIP_UPLOADS=true
      ;;
    --skip-search-replace)
      SKIP_SEARCH_REPLACE=true
      ;;
    --skip-htaccess)
      SKIP_HTACCESS=true
      ;;
    --skip-submodules)
      SKIP_SUBMODULES=true
      ;;
    --setup-ssh)
      SETUP_SSH=true
      ;;
    --dry-run)
      DRY_RUN=true
      ;;
    --help|-h)
      awk 'NR==1{next} /^[^#]/{exit} {sub(/^# ?/,""); print}' "$0"
      exit 0
      ;;
    *)
      POSITIONAL+=("$arg")
      ;;
  esac
done

if [ ${#POSITIONAL[@]} -lt 2 ]; then
  echo "Usage: $0 user@host[:port] /path/to/local/site/public [dest_appname] [--production-url=URL] [--setup-ssh] [--dry-run]"
  exit 1
fi

DEST_RAW="${POSITIONAL[0]}"
SRC_PATH="${POSITIONAL[1]%/}"
DEST_APPNAME="${POSITIONAL[2]:-}"

if [ -z "$PRODUCTION_URL" ]; then
  error "--production-url is required"
  exit 1
fi

if [[ "$DEST_RAW" == *:* ]]; then
  USERHOST="${DEST_RAW%:*}"
  DEST_PORT="${DEST_RAW##*:}"
else
  USERHOST="$DEST_RAW"
  DEST_PORT="22"
fi

DEST_USER="${USERHOST%@*}"
DEST_HOST="${USERHOST#*@}"
DEST_APPNAME="${DEST_APPNAME:-$(basename "$(dirname "$(dirname "$SRC_PATH")")")}"

if [ ! -d "$SRC_PATH" ]; then
  error "Source path does not exist: $SRC_PATH"
  exit 1
fi

if [ ! -f "$SRC_PATH/wp-config.php" ]; then
  error "wp-config.php not found in $SRC_PATH"
  exit 1
fi

SSH_CTRL_DIR="$(mktemp -d "${TMPDIR:-/tmp}/wp-local-prod-ssh.XXXXXX")"
trap 'rm -rf "$SSH_CTRL_DIR"' EXIT
SSH_OPTS="-o ControlMaster=auto -o ControlPath=$SSH_CTRL_DIR/%r@%h:%p -o ControlPersist=10m"
SSH_CMD="ssh $SSH_OPTS -p $DEST_PORT -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new"
RSYNC_SSH="ssh $SSH_OPTS -p $DEST_PORT"

extract_wp_config() {
  local key="$1"
  grep "define.*'${key}'" "$SRC_PATH/wp-config.php" \
    | sed "s/.*'${key}'[[:space:]]*,[[:space:]]*'//; s/'.*//" \
    | head -1
}

remote_extract_wp_config() {
  local key="$1"
  $SSH_CMD "$DEST_USER@$DEST_HOST" "
    grep \"define.*'${key}'\" '$DEST_PATH/wp-config.php' 2>/dev/null \
      | sed \"s/.*'${key}'[[:space:]]*,[[:space:]]*'//; s/'.*//\" \
      | head -1
  "
}

get_local_siteurl() {
  if command -v wp >/dev/null 2>&1 && wp core is-installed --path="$SRC_PATH" >/dev/null 2>&1; then
    wp option get siteurl --path="$SRC_PATH" 2>/dev/null | head -1 | tr -d '\r'
    return
  fi

  if [ "$DRY_RUN" = true ]; then
    return
  fi

  if ! command -v mysql >/dev/null 2>&1; then
    warn "mysql client not available; skipping local siteurl lookup" >&2
    return
  fi

  local db_name db_user db_pass db_host
  db_name=$(extract_wp_config "DB_NAME")
  db_user=$(extract_wp_config "DB_USER")
  db_pass=$(extract_wp_config "DB_PASSWORD")
  db_host=$(extract_wp_config "DB_HOST")
  local options_table="${SRC_TABLE_PREFIX}options"

  mysql -u "$db_user" -p"$db_pass" -h "$db_host" "$db_name" -N 2>/dev/null \
    -e "SELECT option_value FROM ${options_table} WHERE option_name='siteurl' LIMIT 1;" \
    | head -1 | tr -d '\r'
}

dump_local_db_with_php() {
  local db_name="$1"
  local db_user="$2"
  local db_pass="$3"
  local db_host="$4"

  DB_NAME="$db_name" \
  DB_USER="$db_user" \
  DB_PASSWORD="$db_pass" \
  DB_HOST="$db_host" \
  php <<'PHP'
<?php
$dbName = getenv('DB_NAME');
$dbUser = getenv('DB_USER');
$dbPass = getenv('DB_PASSWORD');
$dbHost = getenv('DB_HOST');

if ($dbName === false || $dbUser === false || $dbPass === false || $dbHost === false) {
    fwrite(STDERR, "Missing database environment variables\n");
    exit(1);
}

$dsn = null;
if (preg_match('#^([^:]+):(/.+)$#', $dbHost, $matches)) {
    $dsn = sprintf('mysql:unix_socket=%s;dbname=%s;charset=utf8mb4', $matches[2], $dbName);
} elseif (preg_match('#^([^:]+):([0-9]+)$#', $dbHost, $matches)) {
    $dsn = sprintf('mysql:host=%s;port=%s;dbname=%s;charset=utf8mb4', $matches[1], $matches[2], $dbName);
} else {
    $dsn = sprintf('mysql:host=%s;dbname=%s;charset=utf8mb4', $dbHost, $dbName);
}

$pdo = new PDO($dsn, $dbUser, $dbPass, [
    PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
    PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
    PDO::MYSQL_ATTR_INIT_COMMAND => 'SET NAMES utf8mb4',
]);

$quoteIdent = static function (string $identifier): string {
    return '`' . str_replace('`', '``', $identifier) . '`';
};

$quoteValue = static function ($value) use ($pdo): string {
    if ($value === null) {
        return 'NULL';
    }

    if (is_int($value) || is_float($value)) {
        return (string) $value;
    }

    return $pdo->quote((string) $value);
};

$out = fopen('php://stdout', 'wb');
fwrite($out, "-- WordPress database dump generated by wp-local-to-production.sh\n");
fwrite($out, "SET SQL_MODE='NO_AUTO_VALUE_ON_ZERO';\n");
fwrite($out, "SET FOREIGN_KEY_CHECKS=0;\n");
fwrite($out, "SET time_zone='+00:00';\n\n");

$tables = [];
$tableRows = $pdo->query("SHOW FULL TABLES WHERE Table_type = 'BASE TABLE'");
while ($row = $tableRows->fetch(PDO::FETCH_NUM)) {
    $tables[] = $row[0];
}

foreach ($tables as $table) {
    fwrite($out, "-- Table " . $table . "\n");
    fwrite($out, "DROP TABLE IF EXISTS " . $quoteIdent($table) . ";\n");

    $createRow = $pdo->query("SHOW CREATE TABLE " . $quoteIdent($table))->fetch(PDO::FETCH_NUM);
    fwrite($out, $createRow[1] . ";\n\n");

    $rows = $pdo->query("SELECT * FROM " . $quoteIdent($table));
    while ($row = $rows->fetch(PDO::FETCH_ASSOC)) {
        $columns = array_keys($row);
        $values = array_map($quoteValue, array_values($row));
        $columnSql = implode(', ', array_map($quoteIdent, $columns));
        $valueSql = implode(', ', $values);
        fwrite($out, "INSERT INTO " . $quoteIdent($table) . " ($columnSql) VALUES ($valueSql);\n");
    }

    fwrite($out, "\n");
}

fwrite($out, "SET FOREIGN_KEY_CHECKS=1;\n");
PHP
}

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

  ssh-keyscan -p "$DEST_PORT" "$DEST_HOST" >> "$HOME/.ssh/known_hosts" 2>/dev/null || true
  sort -u -o "$HOME/.ssh/known_hosts" "$HOME/.ssh/known_hosts" 2>/dev/null || true

  if $SSH_CMD "$DEST_USER@$DEST_HOST" "echo 'OK'" &>/dev/null; then
    success "SSH key auth working"
  else
    error "SSH key auth failed"
    exit 1
  fi
  exit 0
fi

if [ "$DRY_RUN" = true ]; then
  warn "Dry-run enabled: no database import, file sync, or search-replace will be executed."
fi

SRC_DB_NAME=$(extract_wp_config "DB_NAME")
SRC_DB_USER=$(extract_wp_config "DB_USER")
SRC_DB_PASS=$(extract_wp_config "DB_PASSWORD")
SRC_DB_HOST=$(extract_wp_config "DB_HOST")
SRC_TABLE_PREFIX=$(awk -F"'" '/^\$table_prefix[[:space:]]*=/ {print $2; exit}' "$SRC_PATH/wp-config.php")

if [ -z "$SRC_DB_NAME" ] || [ -z "$SRC_DB_USER" ] || [ -z "$SRC_DB_PASS" ]; then
  error "Could not read source DB credentials from wp-config.php"
  exit 1
fi

if [ -z "$SRC_TABLE_PREFIX" ]; then
  error "Could not parse \$table_prefix from $SRC_PATH/wp-config.php"
  exit 1
fi

if ! [[ "$SRC_TABLE_PREFIX" =~ ^[A-Za-z0-9_]+$ ]]; then
  error "Invalid source table prefix: '$SRC_TABLE_PREFIX'"
  exit 1
fi

DEST_PATH="/home/$DEST_USER/webapps/$DEST_APPNAME"

info "Testing SSH connection to $DEST_USER@$DEST_HOST:$DEST_PORT..."
if ! $SSH_CMD "$DEST_USER@$DEST_HOST" "echo 'OK'" &>/dev/null; then
  error "Cannot connect to destination. Re-run with --setup-ssh if needed."
  exit 1
fi

if ! $SSH_CMD "$DEST_USER@$DEST_HOST" "[ -d '$DEST_PATH' ]"; then
  error "Destination path does not exist: $DEST_PATH"
  exit 1
fi

DEST_DB_NAME=$(remote_extract_wp_config "DB_NAME")
DEST_DB_USER=$(remote_extract_wp_config "DB_USER")
DEST_DB_PASS=$(remote_extract_wp_config "DB_PASSWORD")
DEST_DB_HOST=$(remote_extract_wp_config "DB_HOST")
DEST_TABLE_PREFIX=$($SSH_CMD "$DEST_USER@$DEST_HOST" "awk -F\"'\" '/^\\\$table_prefix[[:space:]]*=/ {print \$2; exit}' '$DEST_PATH/wp-config.php'")

if [ -z "$DEST_DB_NAME" ] || [ -z "$DEST_DB_USER" ] || [ -z "$DEST_DB_PASS" ]; then
  error "Could not read destination DB credentials from $DEST_PATH/wp-config.php"
  exit 1
fi

if [ -z "$DEST_TABLE_PREFIX" ]; then
  error "Could not parse destination \$table_prefix from $DEST_PATH/wp-config.php"
  exit 1
fi

if ! [[ "$DEST_TABLE_PREFIX" =~ ^[A-Za-z0-9_]+$ ]]; then
  error "Invalid destination table prefix: '$DEST_TABLE_PREFIX'"
  exit 1
fi

SOURCE_SITEURL=$(get_local_siteurl)
if [ -z "$SOURCE_SITEURL" ]; then
  if [ "$DRY_RUN" = false ]; then
    warn "Could not read local siteurl — search-replace will fall back to production URL only"
  fi
fi

DATE="$(date +"%Y%m%d_%H%M%S")"
DB_FILE="/tmp/wp_local_prod_${DEST_APPNAME}_${DATE}.sql.gz"

info "Source:      $SRC_PATH"
info "Destination: $DEST_USER@$DEST_HOST:$DEST_PATH (port $DEST_PORT)"
info "Local DB:    $SRC_DB_NAME (prefix: $SRC_TABLE_PREFIX)"
info "Prod DB:     $DEST_DB_NAME (prefix: $DEST_TABLE_PREFIX)"
info "Target URL:  $PRODUCTION_URL"
echo ""

info "Step 1/6: Exporting local database..."
if [ "$DRY_RUN" = true ]; then
  info "  [dry-run] Would export local database to $DB_FILE"
else
  if command -v wp >/dev/null 2>&1 && wp core is-installed --path="$SRC_PATH" >/dev/null 2>&1; then
    wp db export --path="$SRC_PATH" - | gzip > "$DB_FILE"
  elif command -v mysqldump >/dev/null 2>&1; then
    mysqldump --single-transaction --skip-lock-tables \
      -u "$SRC_DB_USER" -p"$SRC_DB_PASS" -h "$SRC_DB_HOST" "$SRC_DB_NAME" \
      2>/tmp/wp-local-prod-dump.err | gzip > "$DB_FILE"
    if [ -s /tmp/wp-local-prod-dump.err ]; then
      warn "mysqldump warnings (non-fatal):"
      cat /tmp/wp-local-prod-dump.err
      rm -f /tmp/wp-local-prod-dump.err
    fi
  else
    info "  Falling back to PHP-based database dump"
    dump_local_db_with_php "$SRC_DB_NAME" "$SRC_DB_USER" "$SRC_DB_PASS" "$SRC_DB_HOST" | gzip > "$DB_FILE"
  fi

  DB_SIZE=$(du -h "$DB_FILE" | cut -f1)
  info "Database exported: $DB_FILE ($DB_SIZE)"
fi

info "Step 2/6: Transferring database to destination..."
if [ "$DRY_RUN" = true ]; then
  info "  [dry-run] Would rsync $DB_FILE to $DEST_USER@$DEST_HOST:/tmp/"
  info "  [dry-run] Would import gzipped database into $DEST_DB_NAME on destination"
else
  rsync -az -e "$RSYNC_SSH" "$DB_FILE" "$DEST_USER@$DEST_HOST:/tmp/"
  REMOTE_DB_FILE="/tmp/$(basename "$DB_FILE")"

  info "Importing database on destination..."
  if ! $SSH_CMD "$DEST_USER@$DEST_HOST" bash -s <<REMOTE
    set -euo pipefail
    gunzip -c '$REMOTE_DB_FILE' | mysql -u '$DEST_DB_USER' -p'$DEST_DB_PASS' -h '$DEST_DB_HOST' '$DEST_DB_NAME' 2> >(grep -v 'Deprecated program name' >&2)
    status=\$?
    rm -f '$REMOTE_DB_FILE'
    exit \$status
REMOTE
  then
    error "Database import failed on destination"
    rm -f "$DB_FILE"
    exit 1
  fi

  rm -f "$DB_FILE"
  info "Database imported successfully"
fi

info "Step 3/6: Syncing config files..."
if [ "$DRY_RUN" = true ]; then
  if [ -f "$SRC_PATH/.htaccess" ] && [ "$SKIP_HTACCESS" = false ]; then
    info "  [dry-run] Would sync .htaccess to $DEST_USER@$DEST_HOST:$DEST_PATH/"
  fi
  if [ -f "$SRC_PATH/.htninja" ] && [ "$SKIP_HTACCESS" = false ]; then
    info "  [dry-run] Would sync .htninja to $DEST_USER@$DEST_HOST:$DEST_PATH/"
  fi
else
  if [ -f "$SRC_PATH/.htaccess" ] && [ "$SKIP_HTACCESS" = false ]; then
    rsync -az -e "$RSYNC_SSH" "$SRC_PATH/.htaccess" "$DEST_USER@$DEST_HOST:$DEST_PATH/"
    info "  .htaccess synced"
  fi
  if [ -f "$SRC_PATH/.htninja" ] && [ "$SKIP_HTACCESS" = false ]; then
    rsync -az -e "$RSYNC_SSH" "$SRC_PATH/.htninja" "$DEST_USER@$DEST_HOST:$DEST_PATH/"
    info "  .htninja synced"
  fi
fi

if [ "$SKIP_UPLOADS" = false ]; then
  if [ -d "$SRC_PATH/wp-content/uploads" ]; then
    UPLOADS_SIZE=$(du -sh "$SRC_PATH/wp-content/uploads/" 2>/dev/null | cut -f1)
    info "Step 4/6: Syncing uploads ($UPLOADS_SIZE)..."
    if [ "$DRY_RUN" = true ]; then
      info "  [dry-run] Would rsync uploads to $DEST_USER@$DEST_HOST:$DEST_PATH/wp-content/uploads/"
    else
      rsync -az --chmod=Du=rwx,Dgo=rx,Fu=rw,Fgo=r -e "$RSYNC_SSH" "$SRC_PATH/wp-content/uploads/" \
        "$DEST_USER@$DEST_HOST:$DEST_PATH/wp-content/uploads/"
      $SSH_CMD "$DEST_USER@$DEST_HOST" "
        find '$DEST_PATH/wp-content/uploads' -type d -exec chmod 755 {} +
        find '$DEST_PATH/wp-content/uploads' -type f -exec chmod 644 {} +
      "
      info "Uploads synced"
    fi
  else
    info "Step 4/6: No uploads directory found, skipping"
  fi
else
  info "Step 4/6: Skipping uploads by request"
fi

info "Step 5/6: Initializing git submodules on destination..."
if [ "$SKIP_SUBMODULES" = false ]; then
  if [ "$DRY_RUN" = true ]; then
    info "  [dry-run] Would run git submodule update --init --recursive in $DEST_PATH"
  else
    $SSH_CMD "$DEST_USER@$DEST_HOST" "
      cd '$DEST_PATH'
      if [ -f .gitmodules ]; then
        git submodule update --init --recursive 2>&1
        echo 'Submodules initialized'
      else
        echo 'No .gitmodules found, skipping'
      fi
    "
  fi
else
  info "  Skipping git submodules by request"
fi

info "Step 6/6: Updating destination URLs..."
if [ -n "$SOURCE_SITEURL" ] && [ "$SKIP_SEARCH_REPLACE" = false ]; then
  SOURCE_HOST=$(printf '%s' "$SOURCE_SITEURL" | sed -E 's#^[a-zA-Z]+://##; s#/.*$##')
  if [ -n "$SOURCE_HOST" ]; then
    if [ "$DRY_RUN" = true ]; then
      info "  [dry-run] Would replace http://$SOURCE_HOST and https://$SOURCE_HOST with $PRODUCTION_URL"
      info "  [dry-run] Would update siteurl/home on destination to $PRODUCTION_URL"
    else
      $SSH_CMD "$DEST_USER@$DEST_HOST" "
        cd '$DEST_PATH'
        if command -v wp &>/dev/null; then
          wp search-replace 'http://$SOURCE_HOST' '$PRODUCTION_URL' --skip-columns=guid --all-tables 2>&1 || true
          wp search-replace 'https://$SOURCE_HOST' '$PRODUCTION_URL' --skip-columns=guid --all-tables 2>&1 || true
          wp option update siteurl '$PRODUCTION_URL' 2>&1 || true
          wp option update home '$PRODUCTION_URL' 2>&1 || true
        else
          mysql -u '$DEST_DB_USER' -p'$DEST_DB_PASS' -h '$DEST_DB_HOST' '$DEST_DB_NAME' \
            -e \"UPDATE ${DEST_TABLE_PREFIX}options SET option_value='$PRODUCTION_URL' WHERE option_name IN ('siteurl','home');\" 2>/dev/null
        fi
      "
      success "Destination URL updated"
    fi
  else
    warn "Could not derive source host from siteurl: $SOURCE_SITEURL"
  fi
else
  info "Step 6/6: Skipping search-replace by request or missing source URL"
fi

echo ""
if [ "$DRY_RUN" = true ]; then
  success "============================================"
  success "Dry-run completed"
  success "============================================"
  success "Source:      $SRC_PATH"
  success "Destination: $DEST_USER@$DEST_HOST:$DEST_PATH"
  success "Target URL:  $PRODUCTION_URL"
  echo ""
  info "No changes were made."
else
  success "============================================"
  success "Local to production sync completed!"
  success "============================================"
  success "Source:      $SRC_PATH"
  success "Destination: $DEST_USER@$DEST_HOST:$DEST_PATH"
  success "Target URL:  $PRODUCTION_URL"
  echo ""
  info "Post-sync checklist:"
  info "  1. Verify the production temp-site URL loads"
  info "  2. Check wp-admin login works"
  info "  3. Verify uploads/images display correctly"
  info "  4. Clear any caches and re-test key pages"
fi
