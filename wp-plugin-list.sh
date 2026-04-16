#!/bin/bash
#
# wp-plugin-list.sh — List WordPress plugins and themes as JSON
#
# Lightweight inventory script — no API calls, just wp-cli output.
# Used by the dashboard to show plugin/theme details in expanded view.
#
# Usage:
#   ./wp-plugin-list.sh --site=APPNAME
#   ./wp-plugin-list.sh --path=/home/user/webapps/APPNAME
#

set -euo pipefail

SITE=""
SITE_PATH=""

for i in "$@"; do
    case $i in
        --site=*) SITE="${i#*=}" ;;
        --path=*) SITE_PATH="${i#*=}" ;;
        --help|-h)
            awk 'NR==1{next} /^[^#]/{exit} {sub(/^# ?/,""); print}' "$0"
            exit 0
            ;;
        *) echo "Unknown option: $i" >&2; exit 1 ;;
    esac
done

# Resolve site path
if [ -n "$SITE_PATH" ]; then
    SITE=$(basename "$SITE_PATH")
elif [ -n "$SITE" ]; then
    for base in /home/*/webapps/"$SITE"; do
        if [ -d "$base" ]; then SITE_PATH="$base"; break; fi
    done
    [ -z "$SITE_PATH" ] && { echo "{\"error\":\"site '$SITE' not found\"}"; exit 1; }
else
    echo '{"error":"--site or --path is required"}'; exit 1
fi

if [ ! -f "$SITE_PATH/wp-config.php" ]; then
    echo '{"error":"not a WordPress site"}'; exit 1
fi

WP_CLI=""
for candidate in /usr/local/bin/wp /usr/bin/wp /RunCloud/Packages/RunCloudAgent/bin/wp-cli; do
    [ -x "$candidate" ] && WP_CLI="$candidate" && break
done
[ -z "$WP_CLI" ] && { echo '{"error":"wp-cli not found"}'; exit 1; }

SITE_OWNER=$(stat -c '%U' "$SITE_PATH" 2>/dev/null || stat -f '%Su' "$SITE_PATH" 2>/dev/null || echo "runcloud")
[ "$SITE_OWNER" = "root" ] && SITE_OWNER="runcloud"

if [ "$(whoami)" = "$SITE_OWNER" ]; then
    WP="$WP_CLI --path=$SITE_PATH"
else
    WP="sudo -u $SITE_OWNER $WP_CLI --path=$SITE_PATH"
fi

plugins=$($WP plugin list --fields=name,version,status,update,update_version --format=json 2>/dev/null || echo "[]")
themes=$($WP theme list --fields=name,version,status,update,update_version --format=json 2>/dev/null || echo "[]")

echo "{\"plugins\":$plugins,\"themes\":$themes}"
