#!/usr/bin/env bash
# abuseipdb-blacklist-sync.sh — Download + apply AbuseIPDB blacklist
# Reads ABUSEIPDB_API_KEY from /var/lib/abuseipdb/.env
set -euo pipefail

BL_DIR="/var/lib/abuseipdb"
ENV_FILE="$BL_DIR/.env"
BLACKLIST_FILE="$BL_DIR/blacklist.txt"
BLACKLIST_JSON="$BL_DIR/blacklist.json"
LOG_FILE="$BL_DIR/sync.log"
CONFIDENCE_MIN=75
NFT_CHAIN="abuseipdb-blacklist"
API_BASE="https://api.abuseipdb.com/api/v2"

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }
info() { echo -e "\033[32m[INFO]\033[0m  $*"; }
warn() { echo -e "\033[33m[WARN]\033[0m  $*"; }

[ -f "$ENV_FILE" ] || { warn "$ENV_FILE not found"; exit 1; }
. "$ENV_FILE"
[ -n "${ABUSEIPDB_API_KEY:-}" ] || { warn "ABUSEIPDB_API_KEY not set"; exit 1; }

FW=""
if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active -q firewalld 2>/dev/null; then FW="firewalld"
elif command -v nft >/dev/null 2>&1; then FW="nftables"
elif command -v iptables >/dev/null 2>&1; then FW="iptables"
else log "ERROR: No firewall"; exit 1; fi
info "Firewall: $FW"

mkdir -p "$BL_DIR"
info "Downloading blacklist (confidence >= $CONFIDENCE_MIN)..."
HTTP=$(curl -so "$BLACKLIST_JSON" -w '%{http_code}' -G "$API_BASE/blacklist" \
  -d "confidenceMinimum=$CONFIDENCE_MIN" -d "limit=500" \
  -H "Key: $ABUSEIPDB_API_KEY" -H "Accept: application/json" 2>/dev/null || echo "000")
[ "$HTTP" = "200" ] || { log "ERROR: HTTP $HTTP"; warn "Download failed"; rm -f "$BLACKLIST_JSON"; exit 1; }

python3 -c "
import json
with open('$BLACKLIST_JSON') as f:
    data = json.load(f)
ips = [i['ipAddress'] for i in data.get('data', [])]
with open('$BLACKLIST_FILE', 'w') as out:
    for ip in ips: out.write(ip + chr(10))
print(len(ips))
" 2>>"$LOG_FILE" || { warn "Parse failed"; exit 1; }

COUNT=$(wc -l < "$BLACKLIST_FILE" 2>/dev/null || echo 0)
log "Downloaded $COUNT IPs"
info "Downloaded $COUNT IPs"
[ "$COUNT" -eq 0 ] && { info "Nothing to block"; exit 0; }

# Apply firewall rules
case "$FW" in
  nftables)
    nft add table ip filter 2>/dev/null || true
    nft add chain ip filter "$NFT_CHAIN" 2>/dev/null || true
    nft flush chain ip filter "$NFT_CHAIN" 2>/dev/null || true
    while IFS= read -r ip; do [ -z "$ip" ] && continue
      nft add rule ip filter "$NFT_CHAIN" ip saddr "$ip" drop 2>/dev/null || true
    done < "$BLACKLIST_FILE"
    nft list chain ip filter input 2>/dev/null | grep -q "jump $NFT_CHAIN" || \
      nft add rule ip filter input jump "$NFT_CHAIN" 2>/dev/null || true
    ;;
  firewalld)
    while IFS= read -r ip; do [ -z "$ip" ] && continue
      firewall-cmd --add-rich-rule="rule family='ipv4' source address='$ip' drop" 2>/dev/null || true
    done < "$BLACKLIST_FILE"
    firewall-cmd --runtime-to-permanent 2>/dev/null || true
    ;;
  iptables)
    while IFS= read -r ip; do [ -z "$ip" ] && continue
      iptables -C INPUT -s "$ip" -j DROP 2>/dev/null || \
        iptables -A INPUT -s "$ip" -j DROP 2>/dev/null || true
    done < "$BLACKLIST_FILE"
    ;;
esac

log "Sync complete - $COUNT IPs blocked"
info "Blocked $COUNT IPs"
