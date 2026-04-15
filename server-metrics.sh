#!/bin/bash
#
# Server Metrics Reporter
# Collects CPU, RAM, disk, load metrics and web application info from a RunCloud
# server, then POSTs the JSON payload to any webhook endpoint with optional
# HMAC-SHA256 authentication.
#
# Usage:
#   WEBHOOK_URL=https://example.com/webhook WEBHOOK_SECRET=your-secret ./server-metrics.sh
#
# Print metrics to stdout only (no HTTP request):
#   ./server-metrics.sh --print
#
# Cron example (every 5 minutes):
#   */5 * * * * WEBHOOK_URL=https://example.com/webhook WEBHOOK_SECRET=your-secret /root/runcloud-bash-scripts/server-metrics.sh >> /var/log/server-metrics.log 2>&1
#
# Environment variables:
#   WEBHOOK_URL       - Full URL to POST metrics to (required unless --print)
#   WEBHOOK_SECRET    - HMAC-SHA256 secret for webhook authentication (optional)
#   HOSTNAME_OVERRIDE - Override system hostname (optional)
#

set -euo pipefail

PRINT_ONLY=false
QUICK_MODE=false
for arg in "$@"; do
    case "$arg" in
        --print) PRINT_ONLY=true ;;
        --quick) QUICK_MODE=true; PRINT_ONLY=true ;;  # quick = system metrics only, no app scan
    esac
done

if [ "$PRINT_ONLY" = false ] && [ -z "${WEBHOOK_URL:-}" ]; then
    echo "ERROR: WEBHOOK_URL is not set. Use --print to output metrics without sending." >&2
    exit 1
fi

SERVER_HOSTNAME="${HOSTNAME_OVERRIDE:-$(hostname -f 2>/dev/null || hostname)}"

# ── Collect metrics ──────────────────────────────────────────────────────────

# IP address (first non-loopback IPv4)
IP_ADDRESS=$(ip -4 addr show scope global 2>/dev/null | grep -oP 'inet \K[\d.]+' | head -1 || echo "")

# CPU usage (1-second sample via top)
CPU_PERCENT=$(top -bn2 -d1 2>/dev/null | grep '%Cpu' | tail -1 | awk '{print 100 - $8}' || echo "")
CPU_CORES=$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo "")

# Load averages
read -r LOAD_1M LOAD_5M LOAD_15M _ < /proc/loadavg 2>/dev/null || { LOAD_1M=""; LOAD_5M=""; LOAD_15M=""; }

# RAM (in MB)
RAM_INFO=$(free -m 2>/dev/null | awk '/^Mem:/ {print $2, $3}')
RAM_TOTAL_MB=$(echo "$RAM_INFO" | awk '{print $1}')
RAM_USED_MB=$(echo "$RAM_INFO" | awk '{print $2}')
if [ -n "$RAM_TOTAL_MB" ] && [ "$RAM_TOTAL_MB" -gt 0 ] 2>/dev/null; then
    RAM_PERCENT=$(awk "BEGIN {printf \"%.2f\", ($RAM_USED_MB / $RAM_TOTAL_MB) * 100}")
else
    RAM_TOTAL_MB=""
    RAM_USED_MB=""
    RAM_PERCENT=""
fi

# Disk (root partition, in MB)
DISK_INFO=$(df -BM / 2>/dev/null | awk 'NR==2 {gsub("M",""); print $2, $3}')
DISK_TOTAL_MB=$(echo "$DISK_INFO" | awk '{print $1}')
DISK_USED_MB=$(echo "$DISK_INFO" | awk '{print $2}')
if [ -n "$DISK_TOTAL_MB" ] && [ "$DISK_TOTAL_MB" -gt 0 ] 2>/dev/null; then
    DISK_PERCENT=$(awk "BEGIN {printf \"%.2f\", ($DISK_USED_MB / $DISK_TOTAL_MB) * 100}")
else
    DISK_TOTAL_MB=""
    DISK_USED_MB=""
    DISK_PERCENT=""
fi

# Uptime in seconds
UPTIME_SECONDS=$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo "")

# Current timestamp
REPORTED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Helper: run wp-cli with timeout that kills the entire process tree
wp_timeout() {
    local secs="$1"; shift
    timeout -k 5 "$secs" bash -c '"$@"' _ "$@" 2>/dev/null
}

# ── Discover web applications ──────────────────────────────────────────────
# Skipped in --quick mode (system metrics only, no wp-cli)

WEB_APPS_JSON="[]"
if [ "$QUICK_MODE" = false ] && [ -d /home ]; then
    WEB_APPS_ENTRIES=()
    for user_dir in /home/*/; do
        [ -d "$user_dir" ] || continue
        username=$(basename "$user_dir")
        webapps_dir="${user_dir}webapps"
        [ -d "$webapps_dir" ] || continue
        for app_dir in "$webapps_dir"/*/; do
            [ -d "$app_dir" ] || continue
            webapp_name=$(basename "$app_dir")
            app_path="${app_dir%/}"
            # Measure disk usage in MB (timeout after 30s to avoid hanging on huge dirs)
            app_disk_mb=$(timeout 30 du -sm "$app_path" 2>/dev/null | awk '{print $1}' || echo "")
            disk_field=""
            if [ -n "$app_disk_mb" ]; then
                disk_field=",\"disk_used_mb\":$app_disk_mb"
            fi

            # WordPress detection
            wp_fields=""
            if [ -f "$app_path/wp-includes/version.php" ]; then
                wp_fields=",\"is_wordpress\":true"

                # Extract version from PHP source (works without wp-cli)
                wp_ver=$(grep -oP "\\\$wp_version\s*=\s*'\K[^']+" "$app_path/wp-includes/version.php" 2>/dev/null || echo "")
                if [ -n "$wp_ver" ]; then
                    wp_fields="$wp_fields,\"wp_version\":\"$wp_ver\""
                fi

                # Find wp-cli binary (cron PATH may not include /usr/local/bin)
                WP_CLI=""
                for candidate in /usr/local/bin/wp /usr/bin/wp /RunCloud/Packages/RunCloudAgent/bin/wp-cli; do
                    if [ -x "$candidate" ]; then
                        WP_CLI="$candidate"
                        break
                    fi
                done

                if [ -n "$WP_CLI" ]; then
                    wp_siteurl=$(wp_timeout 15 sudo -u "$username" "$WP_CLI" option get siteurl --path="$app_path" | head -1 | tr -d '\r' || echo "")
                    if [ -n "$wp_siteurl" ]; then
                        wp_fields="$wp_fields,\"wp_siteurl\":\"$wp_siteurl\""
                    fi
                    wp_core_update=$(wp_timeout 30 sudo -u "$username" "$WP_CLI" core check-update --path="$app_path" --format=json | head -1 || echo "[]")
                    wp_core_ver=$(echo "$wp_core_update" | grep -oP '"version"\s*:\s*"\K[^"]+' | head -1 || echo "")
                    if [ -n "$wp_core_ver" ]; then
                        wp_fields="$wp_fields,\"wp_core_update\":\"$wp_core_ver\""
                    fi
                    wp_plugin_count=$(wp_timeout 30 sudo -u "$username" "$WP_CLI" plugin list --path="$app_path" --update=available --format=count | grep -oP '^\d+' || echo "")
                    if [ -n "$wp_plugin_count" ]; then
                        wp_fields="$wp_fields,\"wp_plugin_updates\":$wp_plugin_count"
                    fi
                    wp_theme_count=$(wp_timeout 30 sudo -u "$username" "$WP_CLI" theme list --path="$app_path" --update=available --format=count | grep -oP '^\d+' || echo "")
                    if [ -n "$wp_theme_count" ]; then
                        wp_fields="$wp_fields,\"wp_theme_updates\":$wp_theme_count"
                    fi
                fi
            fi

            # Git detection — run as site owner to avoid "dubious ownership" errors
            git_field=""
            if [ -d "$app_path/.git" ]; then
                git_url=$(sudo -u "$username" git -C "$app_path" remote get-url origin 2>/dev/null || echo "")
                if [ -n "$git_url" ]; then
                    git_field=",\"git_remote\":\"$git_url\""
                fi
                # Check for uncommitted changes (as site owner)
                if ! sudo -u "$username" git -C "$app_path" diff --quiet 2>/dev/null || \
                   ! sudo -u "$username" git -C "$app_path" diff --cached --quiet 2>/dev/null; then
                    git_field="$git_field,\"git_dirty\":true"
                fi
            fi

            # Freeze detection — check for code-freeze mu-plugin
            freeze_field=""
            if [ -f "$app_path/wp-content/mu-plugins/code-freeze.php" ]; then
                freeze_field=",\"is_frozen\":true"
            fi

            WEB_APPS_ENTRIES+=("{\"username\":\"$username\",\"webapp_name\":\"$webapp_name\",\"path\":\"$app_path\"$disk_field$wp_fields$git_field$freeze_field}")
        done
    done
    if [ ${#WEB_APPS_ENTRIES[@]} -gt 0 ]; then
        WEB_APPS_JSON=$(IFS=,; echo "[${WEB_APPS_ENTRIES[*]}]")
    fi
fi

# ── Build JSON payload ───────────────────────────────────────────────────────

json_field() {
    local key="$1" val="$2" type="${3:-string}"
    if [ -z "$val" ]; then
        echo "\"$key\":null"
    elif [ "$type" = "number" ]; then
        echo "\"$key\":$val"
    else
        echo "\"$key\":\"$val\""
    fi
}

PAYLOAD=$(cat <<EOF
{$(json_field hostname "$SERVER_HOSTNAME"),$(json_field ip_address "$IP_ADDRESS"),$(json_field cpu_percent "$CPU_PERCENT" number),$(json_field cpu_cores "$CPU_CORES" number),$(json_field load_1m "$LOAD_1M" number),$(json_field load_5m "$LOAD_5M" number),$(json_field load_15m "$LOAD_15M" number),$(json_field ram_total_mb "$RAM_TOTAL_MB" number),$(json_field ram_used_mb "$RAM_USED_MB" number),$(json_field ram_percent "$RAM_PERCENT" number),$(json_field disk_total_mb "$DISK_TOTAL_MB" number),$(json_field disk_used_mb "$DISK_USED_MB" number),$(json_field disk_percent "$DISK_PERCENT" number),$(json_field uptime_seconds "$UPTIME_SECONDS" number),$(json_field reported_at "$REPORTED_AT"),"web_apps":$WEB_APPS_JSON}
EOF
)

# ── Print-only mode ──────────────────────────────────────────────────────────

if [ "$PRINT_ONLY" = true ]; then
    echo "$PAYLOAD"
    exit 0
fi

# ── Sign and send ────────────────────────────────────────────────────────────

HEADERS=(-H "Content-Type: application/json" -H "Accept: application/json")

if [ -n "${WEBHOOK_SECRET:-}" ]; then
    TIMESTAMP=$(date +%s)
    SIGNATURE=$(printf '%s.%s' "$TIMESTAMP" "$PAYLOAD" | openssl dgst -sha256 -hmac "$WEBHOOK_SECRET" | awk '{print $NF}')
    HEADERS+=(-H "X-Webhook-Signature: $SIGNATURE" -H "X-Webhook-Timestamp: $TIMESTAMP")
fi

RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$WEBHOOK_URL" \
    "${HEADERS[@]}" \
    -d "$PAYLOAD" \
    --connect-timeout 10 \
    --max-time 30)

HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | head -n -1)

if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ]; then
    echo "[$(date -Iseconds)] OK ($HTTP_CODE): $BODY"
else
    echo "[$(date -Iseconds)] ERROR ($HTTP_CODE): $BODY" >&2
    exit 1
fi
