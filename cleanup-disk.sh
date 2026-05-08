#!/bin/bash
#
# cleanup-disk.sh — Free up disk space on RunCloud servers
#
# Cleans LiteSpeed caches, swap files, journal logs, and optional
# WordPress plugin caches. Safe to run manually or via cron.
#
# Usage:
#   ./cleanup-disk.sh                    # Clean all webapps + system
#   ./cleanup-disk.sh --site=myapp       # Clean specific webapp + system
#   ./cleanup-disk.sh --system-only      # Clean system files only (no webapps)
#   ./cleanup-disk.sh --dry-run          # Show what would be cleaned without deleting
#
# What it cleans:
#   WordPress app:
#     - wp-content/cache/*
#     - wp-content/litespeed/cssjs/*
#     - wp-content/wpvivid_image_optimization/*
#   System:
#     - /tmp/lsws-rc/swap/*              (LiteSpeed swap files)
#     - /home/runcloud/lscaches/*/        (LiteSpeed external caches)
#     - journalctl vacuum to 500M        (systemd journal logs)
#
# Cron examples (add via RunCloud Dashboard > Cron Job):
#   Daily WP cache:   0 0 * * *   /root/runcloud-bash-scripts/cleanup-disk.sh
#   Weekly system:    0 0 * * 0   /root/runcloud-bash-scripts/cleanup-disk.sh --system-only
#   Specific app:     0 0 * * *   /root/runcloud-bash-scripts/cleanup-disk.sh --site=myapp
#

set -euo pipefail

LSCACHE_DIR="/home/runcloud/lscaches"
LSWS_SWAP="/tmp/lsws-rc/swap"
JOURNAL_MAX="500M"

TARGET_SITE=""
SYSTEM_ONLY=false
DRY_RUN=false

# --- Parse arguments ---
for i in "$@"; do
    case $i in
        --site=*)
            TARGET_SITE="${i#*=}"
            ;;
        --system-only)
            SYSTEM_ONLY=true
            ;;
        --dry-run)
            DRY_RUN=true
            ;;
        --help|-h)
            head -30 "$0" | grep '^#' | sed 's/^# \?//'
            exit 0
            ;;
        *)
            echo "Unknown option: $i"
            echo "Run with --help for usage."
            exit 1
            ;;
    esac
done

# --- Helpers ---
get_dir_size() {
    local dir="$1"
    if [ -d "$dir" ]; then
        du -sh "$dir" 2>/dev/null | cut -f1
    else
        echo "0"
    fi
}

clean_dir() {
    local dir="$1"
    local label="$2"
    if [ -d "$dir" ] && [ "$(ls -A "$dir" 2>/dev/null)" ]; then
        local size
        size=$(get_dir_size "$dir")
        if [ "$DRY_RUN" = true ]; then
            echo "[DRY RUN] Would clean $label ($size): $dir"
        else
            rm -rf "${dir:?}"/*
            echo "Cleaned $label ($size): $dir"
        fi
    fi
}

# --- Show disk usage before ---
echo "=== Disk Usage Before ==="
df -h / | tail -1 | awk '{printf "Used: %s / %s (%s) — Free: %s\n", $3, $2, $5, $4}'
echo ""

FREED_NOTE=""

# --- Clean WordPress app caches ---
if [ "$SYSTEM_ONLY" = false ]; then
    clean_app() {
        local app_path="$1"
        local app_name
        app_name=$(basename "$app_path")

        echo "--- App: $app_name ---"
        clean_dir "$app_path/wp-content/cache" "WP cache"
        clean_dir "$app_path/wp-content/litespeed/cssjs" "LiteSpeed CSS/JS cache"
        clean_dir "$app_path/wp-content/wpvivid_image_optimization" "WPvivid optimization cache"
    }

    if [ -n "$TARGET_SITE" ]; then
        SITE_PATH=""
        for base in /home/runcloud/webapps /home/*/webapps; do
            if [ -d "$base/$TARGET_SITE" ]; then
                SITE_PATH="$base/$TARGET_SITE"
                break
            fi
        done
        if [ -n "$SITE_PATH" ]; then
            clean_app "$SITE_PATH"
        else
            echo "Error: Site '$TARGET_SITE' not found under /home/*/webapps/"
            exit 1
        fi
    else
        for site in /home/*/webapps/*/; do
            [ -d "$site" ] && clean_app "$site"
        done
    fi
    echo ""
fi

# --- Clean system files ---
echo "--- System ---"

# LiteSpeed swap
clean_dir "$LSWS_SWAP" "LiteSpeed swap"

# LiteSpeed external caches
if [ -d "$LSCACHE_DIR" ]; then
    for cache_dir in "$LSCACHE_DIR"/*/; do
        if [ -d "$cache_dir" ]; then
            clean_dir "$cache_dir" "LiteSpeed external cache ($(basename "$cache_dir"))"
        fi
    done
fi

# Journal logs
if command -v journalctl &>/dev/null; then
    if [ "$DRY_RUN" = true ]; then
        local_journal_size=$(journalctl --disk-usage 2>/dev/null | grep -oP '[\d.]+[GMKT]' || echo "unknown")
        echo "[DRY RUN] Would vacuum journal logs to $JOURNAL_MAX (current: $local_journal_size)"
    else
        echo "Vacuuming journal logs to $JOURNAL_MAX..."
        journalctl --vacuum-size="$JOURNAL_MAX" 2>&1 | tail -3
    fi
fi

# --- Show disk usage after ---
echo ""
echo "=== Disk Usage After ==="
df -h / | tail -1 | awk '{printf "Used: %s / %s (%s) — Free: %s\n", $3, $2, $5, $4}'
