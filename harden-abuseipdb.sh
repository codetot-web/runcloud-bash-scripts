#!/usr/bin/env bash
# harden-abuseipdb.sh v1.0.0 - Fail2Ban + AbuseIPDB integration
# Reads API key from /var/lib/abuseipdb/.env (ABUSEIPDB_API_KEY=...).
# Idempotent - safe to re-run.
set -euo pipefail

VERSION="1.0.0"
JAIL_DIR="/etc/fail2ban/jail.d"
ACTION_DIR="/etc/fail2ban/action.d"
BL_DIR="/var/lib/abuseipdb"
ENV_FILE="$BL_DIR/.env"
SYNC_DST="/usr/local/bin/abuseipdb-blacklist-sync.sh"
CRON_FILE="/etc/cron.d/abuseipdb-blacklist"
API="https://api.abuseipdb.com/api/v2"

R="\033[0;31m"; G="\033[0;32m"; Y="\033[1;33m"; NC="\033[0m"
info()  { echo -e "${G}[INFO]${NC}  $*"; }
warn()  { echo -e "${Y}[WARN]${NC}  $*"; }
error() { echo -e "${R}[ERROR]${NC} $*"; }
ok()    { echo -e "  ${G}ok${NC} $*"; }

DRY=0; C=0
for a in "$@"; do
  case "$a" in --dry-run) DRY=1;; *) error "Unknown: $a"; exit 1;; esac
done

require_root() { [ "$(id -u)" -eq 0 ] || { error "need root"; exit 1; }; }

detect_platform() {
  if systemctl is-active --quiet lsws-rc 2>/dev/null; then echo "runcloud"
  elif [ -f "/usr/sbin/apache2" ]; then echo "litesoup"
  else echo "unknown"; fi
}

load_env() {
  [ -f "$ENV_FILE" ] || { error "$ENV_FILE not found"; exit 1; }
  . "$ENV_FILE"
  [ -n "${ABUSEIPDB_API_KEY:-}" ] && return 0
  error "ABUSEIPDB_API_KEY not set in $ENV_FILE"; exit 1
}

write_file() {
  local p="$1" c="$2" m="${3:-644}"
  [ "$DRY" = "1" ] && { ok "[DRY] $p"; return; }
  local t; t="$(mktemp)"
  printf '%s' "$c" > "$t"
  if [ -f "$p" ] && cmp -s "$t" "$p" 2>/dev/null; then ok "$p"; rm -f "$t"; return; fi
  info "Writing $p"
  install -m "$m" -o root -g root "$t" "$p"
  rm -f "$t"; C=1
}

test_key() {
  [ "$DRY" = "1" ] && return 0
  local s
  s=$(curl -so /dev/null -w '%{http_code}' -G "$API/check" \
    --data-urlencode "ipAddress=8.8.8.8" -d "maxAgeInDays=1" \
    -H "Key: $ABUSEIPDB_API_KEY" -H "Accept: application/json" 2>/dev/null || echo "000")
  [ "$s" = "200" ] && { ok "API key valid"; return 0; }
  warn "API key HTTP $s"; return 1
}

# Write jail config with ONE logpath (fail2ban rejects duplicate logpath keys)
write_jail() {
  local name="$1" logpath="$2" maxretry="$3" bantime="$4" findtime="$5" port="${6:-http,https}"
  local c
  c="# managed by harden-abuseipdb.sh
[$name]
enabled = true
port = $port
maxretry = $maxretry
bantime = $bantime
findtime = $findtime
logpath = $logpath
"
  write_file "$JAIL_DIR/litesoup-${name#apache-}.local" "$c"
}

phase1_jails() {
  info "Phase 1: Extended Fail2Ban jails"; C=0
  local platform; platform="$(detect_platform)"
  info "Platform: $platform"

  if [ "$platform" = "runcloud" ]; then
    local alog="/usr/local/lsws/logs/access.log"
    local elog="/usr/local/lsws/logs/error.log"
  elif [ "$platform" = "litesoup" ]; then
    local alog="/var/log/apache2/*access.log"
    local elog="/var/log/apache2/*error.log"
  else
    warn "Unknown platform - guessing Apache paths"
    local alog="/var/log/apache2/*access.log"
    local elog="/var/log/apache2/*error.log"
  fi

  write_jail "apache-badbots"   "$alog" 1 86400 86400
  write_jail "apache-overflows" "$elog" 2 86400 600
  write_jail "apache-noscript"  "$elog" 3 86400 600

  [ "$C" = "1" ] && [ "$DRY" != "1" ] && systemctl restart fail2ban || true
}

phase2_action() {
  info "Phase 2: AbuseIPDB action"; C=0
  local action
  action="# managed by harden-abuseipdb.sh
[Definition]
actionban = lgm=\$(printf '%%.1000s\n' \"<matches>\"); curl -sSf \"$API/report\" -H \"Accept: application/json\" -H \"Key: $ABUSEIPDB_API_KEY\" --data-urlencode \"comment=\$lgm\" --data-urlencode \"ip=<ip>\" --data \"categories=<abuseipdb_category>\"
actionunban =

[Init]
abuseipdb_apikey = $ABUSEIPDB_API_KEY
abuseipdb_category = 18,22
"
  write_file "$ACTION_DIR/abuseipdb.local" "$action"

  local jailconf
  jailconf="# managed by harden-abuseipdb.sh
[DEFAULT]
action_abuseipdb = abuseipdb[abuseipdb_category=\"18,22,15\"]

[apache-badbots]
abuseipdb_category = 14,15

[apache-overflows]
abuseipdb_category = 15

[apache-noscript]
abuseipdb_category = 15

[apache-auth]
abuseipdb_category = 15,18

[sshd]
abuseipdb_category = 18,22
"
  write_file "$JAIL_DIR/litesoup-abuseipdb.local" "$jailconf"

  # Append action to each jail if not present
  for jn in sshd apache-auth apache-badbots apache-overflows apache-noscript; do
    local jf="$JAIL_DIR/litesoup-${jn#apache-}.local"
    [ -f "$jf" ] || continue
    grep -q 'action_abuseipdb' "$jf" 2>/dev/null && continue
    local jc; jc=$(cat "$jf")
    jc="${jc%"${jc##*[![:space:]]}"}"$'\n'"action = %(action_abuseipdb)s"$'\n'
    write_file "$jf" "$jc"
  done

  [ "$DRY" != "1" ] && systemctl restart fail2ban || true
}

phase3_blacklist() {
  info "Phase 3: Blacklist sync"; C=0
  [ "$DRY" != "1" ] && mkdir -p "$BL_DIR"

  local src
  src="$(dirname "$(readlink -f "$0")")/abuseipdb-blacklist-sync.sh"
  if [ -f "$src" ]; then
    install -m 755 -o root -g root "$src" "$SYNC_DST"
    info "Deployed $SYNC_DST"
  else
    warn "abuseipdb-blacklist-sync.sh not found next to installer"
  fi

  cron="# managed by harden-abuseipdb.sh
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
0 */6 * * * root $SYNC_DST >/dev/null 2>&1
"
  write_file "$CRON_FILE" "$cron"

  [ "$DRY" != "1" ] && [ -x "$SYNC_DST" ] && { info "Running initial sync..."; bash "$SYNC_DST" && ok "Initial sync done" || warn "Sync had issues"; }
}

main() {
  require_root
  echo ""; echo "=== harden-abuseipdb.sh v$VERSION ==="; echo "  Host: $(hostname)"; echo ""
  load_env
  test_key || { error "Key invalid"; exit 1; }
  phase1_jails; phase2_action; phase3_blacklist
  echo ""; ok "Done. Check /etc/fail2ban/ and $BL_DIR/sync.log"
}

main "$@"
