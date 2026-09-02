#!/bin/bash
# =============================================================================
# runcloud-to-litesoup-migration.sh
#
# Migrate a WordPress site from a RunCloud server to a litesoup server.
# Encodes the validated greenboog.com flow (2026-09): git-standard-first,
# site-create.sh --git-repo, direct rsync of uploads, DB export/import, the
# litesoup permission model (chmod 755/644 + chown litesoup), git re-sync.
#
# RUN THIS FROM THE LITESOUP TARGET SERVER (as root). It pulls from the source.
#
# Usage:
#   ./runcloud-to-litesoup-migration.sh \
#       --source=runcloud@SRC_IP[:port] \
#       --app=APPNAME \
#       [--name=SLUG] [--staging-url=https://app.chuyen.dev] [--setup-ssh]
#
#   --source=user@host[:port]   RunCloud source (SSH). Default port 22.
#   --app=APPNAME               Source webapp name (under /home/*/webapps/).
#   --name=SLUG                 Target litesoup app slug (default = APPNAME).
#   --staging-url=URL           Optional: set siteurl/home to a staging domain
#                               after import (e.g. https://app.chuyen.dev).
#   --setup-ssh                 Add THIS server's root pubkey to the source's
#                               root authorized_keys (for rsync/scp pull).
#   --skip-git-push             Do NOT commit+push the source git (default off).
#
# Prereqs on the target:
#   - litesoup stack installed (site-create.sh at /opt/litesoup/site/).
#   - litesoup user has a GitHub deploy key for the site's repo (see
#     litesoup-site-deploy skill: add key to khoipro account + ~/.ssh/config).
#   - Source reachable by SSH (--setup-ssh if not already keyed).
#
# Exit codes: 0 ok, 1 usage/validation, 2 provisioning, 3 data transfer,
#             4 db, 5 post-migrate.
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------- color helpers
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[ OK ]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; }

# ------------------------------------------------------------------ arg parsing
SOURCE=""; APP=""; SLUG=""; STAGING_URL=""; SETUP_SSH=false; SKIP_GIT_PUSH=false
for arg in "$@"; do
  case $arg in
    --source=*)    SOURCE="${arg#*=}" ;;
    --app=*)       APP="${arg#*=}" ;;
    --name=*)      SLUG="${arg#*=}" ;;
    --staging-url=*) STAGING_URL="${arg#*=}" ;;
    --setup-ssh)   SETUP_SSH=true ;;
    --skip-git-push) SKIP_GIT_PUSH=true ;;
    *) error "Unknown arg: $arg"; exit 1 ;;
  esac
done

if [ -z "$SOURCE" ] || [ -z "$APP" ]; then
  echo "Usage: $0 --source=user@host[:port] --app=APPNAME [--name=SLUG] [--staging-url=URL] [--setup-ssh]"
  exit 1
fi
SLUG="${SLUG:-$APP}"

# Parse source user@host[:port]
if [[ "$SOURCE" == *:* ]]; then
  SRC_USERHOST="${SOURCE%:*}"; SRC_PORT="${SOURCE##*:}"
else
  SRC_USERHOST="$SOURCE"; SRC_PORT="22"
fi
SRC_USER="${SRC_USERHOST%@*}"; SRC_HOST="${SRC_USERHOST#*@}"

# SSH multiplex so we authenticate once
SSH_CTRL="$(mktemp -d "${TMPDIR:-/tmp}/rclite-ssh.XXXXXX")"
trap 'rm -rf "$SSH_CTRL"' EXIT
SSH_OPTS="-o ControlMaster=auto -o ControlPath=$SSH_CTRL/%r@%h:%p -o ControlPersist=10m"
SSH_CMD="ssh $SSH_OPTS -p $SRC_PORT -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new"
RSYNC_SSH="ssh $SSH_OPTS -p $SRC_PORT"

# --------------------------------------------------------------- wp-cli locate
find_wp_cli() {
  for p in /usr/local/bin/wp /usr/bin/wp /opt/runcloud/wp-cli.phar; do
    [ -x "$p" ] && { echo "$p"; return; }
  done
  command -v wp 2>/dev/null || echo "wp"
}
WP_CLI="$(find_wp_cli)"

# ------------------------------------------------------------- SSH key bootstrap
if [ "$SETUP_SSH" = true ]; then
  info "Setting up SSH key auth to $SRC_USERHOST:$SRC_PORT"
  [ -f /root/.ssh/id_ed25519.pub ] || ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519 -N '' -q
  PUB=$(cat /root/.ssh/id_ed25519.pub)
  $SSH_CMD "$SRC_USERHOST" "
    mkdir -p /root/.ssh && chmod 700 /root/.ssh
    grep -qF '$PUB' /root/.ssh/authorized_keys 2>/dev/null || echo '$PUB' >> /root/.ssh/authorized_keys
    sort -u -o /root/.ssh/authorized_keys /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys"
  $SSH_CMD "$SRC_USERHOST" "echo OK" >/dev/null && success "SSH key auth to source working" || { error "SSH auth failed"; exit 1; }
fi

# ------------------------------------------------------------ validate source
info "Locating source webapp '$APP' on $SRC_HOST..."
SRC_PATH="$($SSH_CMD "$SRC_USERHOST" "ls -d /home/*/webapps/$APP 2>/dev/null | head -1")"
if [ -z "$SRC_PATH" ]; then
  error "Webapp '$APP' not found on source under /home/*/webapps/"
  exit 1
fi
SRC_OWNER="$($SSH_CMD "$SRC_USERHOST" "stat -c %U '$SRC_PATH'")"
info "Source: $SRC_PATH (owner=$SRC_OWNER)"

# ------------------------------------------------------ git-standard-first
info "Checking source git state..."
GIT_REPO="$($SSH_CMD "$SRC_USERHOST" "su - $SRC_OWNER -s /bin/bash -c 'cd $SRC_PATH && git remote get-url origin 2>/dev/null'")"
GIT_BRANCH="$($SSH_CMD "$SRC_USERHOST" "su - $SRC_OWNER -s /bin/bash -c 'cd $SRC_PATH && git rev-parse --abbrev-ref HEAD 2>/dev/null'")"
if [ -n "$GIT_REPO" ] && [ "$SKIP_GIT_PUSH" != true ]; then
  info "Committing + pushing source git ($GIT_BRANCH)..."
  $SSH_CMD "$SRC_USERHOST" "
    su - $SRC_OWNER -s /bin/bash -c '
      cd $SRC_PATH
      grep -qE \"^wpvivid_staging/\" .gitignore 2>/dev/null || echo \"wpvivid_staging/\" >> .gitignore
      grep -qE \"^\\.htaccess\\.bak\" .gitignore 2>/dev/null || echo \".htaccess.bak-*\" >> .gitignore
      git add -A
      git diff --cached --quiet || git commit -m \"chore: sync live state before litesoup migration\"
      git push origin $GIT_BRANCH'"
  success "Source git pushed"
elif [ -z "$GIT_REPO" ]; then
  warn "No git repo on source — will rsync whole tree instead of --git-repo"
fi

# ------------------------------------------------------------- determine PHP
SRC_PHP="$($SSH_CMD "$SRC_USERHOST" "grep -rhoE 'lsphp[0-9]+' /etc/lsws-rc/conf.d/$APP.vhosts.d/ 2>/dev/null | sort -u | head -1 | tr -d 'lsphp'")"
[ -z "$SRC_PHP" ] && SRC_PHP="8.2"
info "Source PHP: $SRC_PHP"

# ------------------------------------------------------- provision litesoup site
SITE_CREATE="/opt/litesoup/site/site-create.sh"
[ -x "$SITE_CREATE" ] || SITE_CREATE="$(find / -name site-create.sh 2>/dev/null | head -1)"
if [ -z "$SITE_CREATE" ]; then
  error "site-create.sh not found — is litesoup installed on this target?"
  exit 2
fi

if [ -n "$GIT_REPO" ]; then
  info "Provisioning litesoup site '$SLUG' from git $GIT_REPO @ $GIT_BRANCH..."
  bash "$SITE_CREATE" --name="$SLUG" --domain="$APP" --php="$SRC_PHP" --tier=medium \
    --tls=self-signed --email=admin@codetot.org --framework=wordpress \
    --git-repo="$GIT_REPO" --git-branch="$GIT_BRANCH" 2>&1 | tail -20
else
  info "Provisioning litesoup site '$SLUG' (fresh WP — will rsync whole tree)..."
  bash "$SITE_CREATE" --name="$SLUG" --domain="$APP" --php="$SRC_PHP" --tier=medium \
    --tls=self-signed --email=admin@codetot.org --framework=wordpress 2>&1 | tail -20
fi
DEST_PATH="/home/litesoup/webapps/$SLUG"
[ -d "$DEST_PATH" ] || { error "Provision failed — $DEST_PATH missing"; exit 2; }
success "Site provisioned at $DEST_PATH"

# --------------------------------------------------------------- rsync uploads
info "Syncing wp-content/uploads from source (direct pull)..."
mkdir -p "$DEST_PATH/wp-content/uploads"
EXCLUDES="--exclude='wp-config.php' --exclude='.git' --exclude='wp-content/cache' --exclude='wp-content/litespeed' --exclude='node_modules' --exclude='wpvivid_staging'"
if [ -z "$GIT_REPO" ]; then
  # no git: rsync whole webapp (minus env/cache)
  rsync -avz --delete -e "$RSYNC_SSH" $EXCLUDES \
    "$SRC_USERHOST:$SRC_PATH/" "$DEST_PATH/"
else
  # git clone already has code: only uploads + non-git dirs
  rsync -avz --delete -e "$RSYNC_SSH" \
    "$SRC_USERHOST:$SRC_PATH/wp-content/uploads/" "$DEST_PATH/wp-content/uploads/"
fi
success "Files synced"

# ------------------------------------------------------------- permission fix
info "Applying litesoup permission model (chown litesoup + 755/644)..."
chown -R litesoup:litesoup "$DEST_PATH"
find "$DEST_PATH" -type d -exec chmod 755 {} +
find "$DEST_PATH" -type f -exec chmod 644 {} +
success "Permissions set"

# ---------------------------------------------------------------- DB transfer
info "Exporting DB on source..."
DB_FILE="/tmp/${SLUG}_migrate.sql"
$SSH_CMD "$SRC_USERHOST" "su - $SRC_OWNER -s /bin/bash -c 'cd $SRC_PATH && $WP_CLI db export /tmp/${SLUG}_migrate.sql --allow-root'" >/dev/null
$SSH_CMD "$SRC_USERHOST" "chmod 644 /tmp/${SLUG}_migrate.sql"
scp $SSH_OPTS -P "$SRC_PORT" "$SRC_USERHOST:/tmp/${SLUG}_migrate.sql" "/tmp/${SLUG}_migrate.sql"
chown litesoup:litesoup "/tmp/${SLUG}_migrate.sql"

info "Importing DB into target..."
su - litesoup -s /bin/bash -c "cd $DEST_PATH && $WP_CLI db import /tmp/${SLUG}_migrate.sql --allow-root" >/dev/null
SRC_TABLES="$($SSH_CMD "$SRC_USERHOST" "su - $SRC_OWNER -s /bin/bash -c 'cd $SRC_PATH && $WP_CLI db query \"SELECT COUNT(*) FROM information_schema.tables WHERE table_schema=DATABASE();\" --allow-root' | tail -1")"
DST_TABLES="$(su - litesoup -s /bin/bash -c "cd $DEST_PATH && $WP_CLI db query 'SELECT COUNT(*) FROM information_schema.tables WHERE table_schema=DATABASE();' --allow-root" | tail -1)"
if [ "$SRC_TABLES" != "$DST_TABLES" ]; then
  error "Table count mismatch: source=$SRC_TABLES target=$DST_TABLES — re-run import"
  exit 4
fi
success "DB imported ($DST_TABLES tables match)"

# ------------------------------------------------------------- patch prefix
SRC_PREFIX="$($SSH_CMD "$SRC_USERHOST" "awk -F\"'\" '/^\\\$table_prefix[[:space:]]*=/ {print \$2; exit}' $SRC_PATH/wp-config.php")"
DST_PREFIX="$(awk -F"'" '/^\$table_prefix[[:space:]]*=/ {print $2; exit}' "$DEST_PATH/wp-config.php")"
if [ -n "$SRC_PREFIX" ] && [ "$SRC_PREFIX" != "$DST_PREFIX" ]; then
  info "Patching table_prefix $DST_PREFIX -> $SRC_PREFIX"
  sed -i "s/^\$table_prefix = .$DST_PREFIX.;/\$table_prefix = \"$SRC_PREFIX\";/" "$DEST_PATH/wp-config.php"
fi

# ------------------------------------------------------------- git re-sync
if [ -n "$GIT_REPO" ]; then
  info "Syncing target git to origin ($GIT_BRANCH)..."
  cp "$DEST_PATH/wp-config.php" /tmp/wp-config.php.bak
  cp "$DEST_PATH/.htaccess" /tmp/.htaccess.bak 2>/dev/null || true
  su - litesoup -s /bin/bash -c "cd $DEST_PATH && git fetch origin && git reset --hard origin/$GIT_BRANCH"
  cp /tmp/wp-config.php.bak "$DEST_PATH/wp-config.php"
  [ -f /tmp/.htaccess.bak ] && cp /tmp/.htaccess.bak "$DEST_PATH/.htaccess"
  chown litesoup:litesoup "$DEST_PATH/wp-config.php" "$DEST_PATH/.htaccess"
  success "Git synced"
fi

# ------------------------------------------------------------- staging URL
if [ -n "$STAGING_URL" ]; then
  info "Setting siteurl/home to $STAGING_URL..."
  su - litesoup -s /bin/bash -c "cd $DEST_PATH && \
    $WP_CLI search-replace 'https://$APP' '$STAGING_URL' --all-tables-with-prefix --skip-plugins --allow-root >/dev/null; \
    $WP_CLI option update siteurl '$STAGING_URL' --skip-plugins --allow-root >/dev/null; \
    $WP_CLI option update home '$STAGING_URL' --skip-plugins --allow-root >/dev/null"
  success "Staging URL set"
fi

# ------------------------------------------------------------- verify
info "Verifying target renders..."
HTTP_CODE="$(curl -sk -o /dev/null -w '%{http_code}' "https://${APP}/" 2>/dev/null || echo 000)"
TITLE="$(curl -sk "https://${APP}/" 2>/dev/null | grep -oiE '<title>[^<]*</title>' | head -1)"
success "Target HTTP $HTTP_CODE — $TITLE"

echo ""
echo "================================================================"
success "Migration of '$APP' -> '$SLUG' on $(hostname) COMPLETE"
echo "  Source:  $SRC_USERHOST:$SRC_PATH"
echo "  Target:  $DEST_PATH"
echo "  Git:     $GIT_REPO @ $GIT_BRANCH"
echo "  Tables:  $DST_TABLES (match source)"
[ -n "$STAGING_URL" ] && echo "  Staging: $STAGING_URL"
echo ""
echo "NEXT STEPS (manual):"
echo "  1. Create staging DNS *.chuyen.dev -> $(hostname -I | awk '{print $1}') (proxied=false)"
echo "  2. Add staging vhost + issue LE cert (see litesoup-site-deploy skill)"
echo "  3. Test staging: title, assets, /quantri/ login, product/cart/checkout"
echo "  4. Cutover: flip CF A record to this server (proxied=true), LE cert for prod domain"
echo "  5. Install W3 Total Cache (replace litespeed-cache on Apache target)"
echo "================================================================"