#!/bin/bash
# tweak-mycnf.sh — Auto-tune MariaDB/MySQL for RunCloud servers
#
# Detects server RAM and CPU, then applies optimized my.cnf settings
# for WordPress workloads. Always creates a backup before changes.
#
# Usage:
#   ./tweak-mycnf.sh              # Auto-detect RAM and apply settings
#   ./tweak-mycnf.sh --dry-run    # Show what would be changed without applying
#   ./tweak-mycnf.sh --restore    # Restore the most recent backup
#   ./tweak-mycnf.sh --status     # Show current MariaDB key settings
#
# Config file detection:
#   - If /etc/mysql/mariadb.cnf has [mysqld] after !includedir → edits mariadb.cnf
#   - Otherwise → edits /etc/mysql/conf.d/runcloud.cnf
#
# Scaling rules:
#   innodb_buffer_pool_size   = ~50% of RAM
#   innodb_buffer_pool_instances = 1 per GB of buffer pool (max 8)
#   tmp_table_size            = scales with RAM
#   max_connections           = 300 (not default 4096)
#

set -euo pipefail

# ============================================================
# Color output
# ============================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
header() { echo -e "\n${CYAN}=== $1 ===${NC}"; }

# ============================================================
# Parse arguments
# ============================================================
DRY_RUN=false
RESTORE=false
STATUS_ONLY=false

for i in "$@"; do
    case $i in
        --dry-run)
            DRY_RUN=true
            ;;
        --restore)
            RESTORE=true
            ;;
        --status)
            STATUS_ONLY=true
            ;;
        --help|-h)
            head -20 "$0" | grep '^#' | sed 's/^# \?//'
            exit 0
            ;;
        *)
            error "Unknown option: $i"
            echo "Run with --help for usage."
            exit 1
            ;;
    esac
done

# ============================================================
# Check root
# ============================================================
if [ "$(id -u)" -ne 0 ]; then
    error "This script must be run as root."
    exit 1
fi

# ============================================================
# Check MariaDB is installed
# ============================================================
if ! command -v mariadbd &>/dev/null && ! command -v mysqld &>/dev/null; then
    error "MariaDB/MySQL not found."
    exit 1
fi

# ============================================================
# Status mode
# ============================================================
if [ "$STATUS_ONLY" = true ]; then
    header "Current MariaDB Settings"
    mysql -e "
        SELECT VERSION() AS MariaDB_Version;
        SHOW VARIABLES LIKE 'innodb_buffer_pool_size';
        SHOW VARIABLES LIKE 'innodb_buffer_pool_instances';
        SHOW VARIABLES LIKE 'innodb_log_file_size';
        SHOW VARIABLES LIKE 'innodb_flush_method';
        SHOW VARIABLES LIKE 'innodb_flush_log_at_trx_commit';
        SHOW VARIABLES LIKE 'innodb_io_capacity';
        SHOW VARIABLES LIKE 'max_connections';
        SHOW VARIABLES LIKE 'table_open_cache';
        SHOW VARIABLES LIKE 'tmp_table_size';
        SHOW VARIABLES LIKE 'performance_schema';
        SHOW VARIABLES LIKE 'wait_timeout';
        SHOW VARIABLES LIKE 'key_buffer_size';
    " 2>/dev/null
    # query_cache may not exist on MariaDB 10.6+
    mysql -e "SHOW VARIABLES LIKE 'query_cache_size'; SHOW VARIABLES LIKE 'query_cache_type';" 2>/dev/null || true
    exit 0
fi

# ============================================================
# Detect config file
# ============================================================
MARIADB_CNF="/etc/mysql/mariadb.cnf"
RUNCLOUD_CNF="/etc/mysql/conf.d/runcloud.cnf"
CONFIG_FILE=""

detect_config_file() {
    # Check if mariadb.cnf has [mysqld] AFTER !includedir lines (sg5 pattern)
    # In this case, mariadb.cnf overrides everything — we must edit it
    if [ -f "$MARIADB_CNF" ]; then
        local last_includedir last_mysqld
        last_includedir=$(grep -n '!includedir' "$MARIADB_CNF" 2>/dev/null | tail -1 | cut -d: -f1 || echo "0")
        last_mysqld=$(grep -n '^\[mysqld\]' "$MARIADB_CNF" 2>/dev/null | tail -1 | cut -d: -f1 || echo "0")

        if [ "$last_mysqld" -gt "$last_includedir" ] && [ "$last_mysqld" -gt 0 ]; then
            CONFIG_FILE="$MARIADB_CNF"
            info "Detected sg5 pattern: [mysqld] after !includedir in mariadb.cnf"
            return
        fi
    fi

    # Default: use runcloud.cnf (sg3 pattern)
    if [ -f "$RUNCLOUD_CNF" ]; then
        CONFIG_FILE="$RUNCLOUD_CNF"
        info "Detected sg3 pattern: using runcloud.cnf"
    else
        CONFIG_FILE="$MARIADB_CNF"
        info "Using mariadb.cnf (no runcloud.cnf found)"
    fi
}

detect_config_file

# ============================================================
# Restore mode
# ============================================================
if [ "$RESTORE" = true ]; then
    header "Restore"
    LATEST_BACKUP=$(ls -t "${CONFIG_FILE}.bak."* 2>/dev/null | head -1)
    if [ -z "$LATEST_BACKUP" ]; then
        error "No backup found for $CONFIG_FILE"
        exit 1
    fi
    info "Restoring from: $LATEST_BACKUP"
    cp "$LATEST_BACKUP" "$CONFIG_FILE"
    info "Restarting MariaDB..."
    systemctl restart mariadb
    info "Restore complete."
    exit 0
fi

# ============================================================
# Detect server specs
# ============================================================
header "Server Detection"

TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_RAM_GB=$(( TOTAL_RAM_KB / 1024 / 1024 ))
CPU_CORES=$(nproc)

# Round up for servers that report slightly under (e.g. 3.8G → 4G)
TOTAL_RAM_MB=$(( TOTAL_RAM_KB / 1024 ))
if [ $(( TOTAL_RAM_MB % 1024 )) -gt 512 ]; then
    TOTAL_RAM_GB=$(( TOTAL_RAM_GB + 1 ))
fi

info "RAM: ${TOTAL_RAM_GB}GB (${TOTAL_RAM_MB}MB actual)"
info "CPU: ${CPU_CORES} cores"
info "Config: $CONFIG_FILE"

# ============================================================
# Calculate settings based on RAM
# ============================================================
header "Calculating Settings"

# innodb_buffer_pool_size = ~50% of RAM
BUFFER_POOL_GB=$(( TOTAL_RAM_GB / 2 ))
if [ "$BUFFER_POOL_GB" -lt 1 ]; then
    BUFFER_POOL_GB=1
fi

# innodb_buffer_pool_instances = 1 per GB, max 8
BUFFER_POOL_INSTANCES=$BUFFER_POOL_GB
if [ "$BUFFER_POOL_INSTANCES" -gt 8 ]; then
    BUFFER_POOL_INSTANCES=8
fi

# tmp_table_size based on RAM
if [ "$TOTAL_RAM_GB" -ge 8 ]; then
    TMP_TABLE_SIZE="128M"
    MAX_HEAP_TABLE_SIZE="128M"
elif [ "$TOTAL_RAM_GB" -ge 4 ]; then
    TMP_TABLE_SIZE="96M"
    MAX_HEAP_TABLE_SIZE="96M"
else
    TMP_TABLE_SIZE="64M"
    MAX_HEAP_TABLE_SIZE="64M"
fi

# innodb_io_capacity — assume SSD on cloud servers
IO_CAPACITY=2000
IO_CAPACITY_MAX=4000

# IO threads — scale with CPU but cap at 4 for typical WordPress
IO_THREADS=4
if [ "$CPU_CORES" -lt 4 ]; then
    IO_THREADS=$CPU_CORES
fi

# Detect MariaDB version — query_cache removed in 10.6+
MARIADB_VERSION=$(mysql -e "SELECT VERSION();" -sN 2>/dev/null || echo "0.0.0")
MARIADB_MAJOR=$(echo "$MARIADB_VERSION" | grep -oP '^\d+' || echo "0")
MARIADB_MINOR=$(echo "$MARIADB_VERSION" | grep -oP '^\d+\.\d+' | cut -d. -f2 || echo "0")

HAS_QUERY_CACHE=true
if [ "$MARIADB_MAJOR" -gt 10 ] || { [ "$MARIADB_MAJOR" -eq 10 ] && [ "$MARIADB_MINOR" -ge 6 ]; }; then
    HAS_QUERY_CACHE=false
fi

# query_cache_size based on RAM (only for MariaDB < 10.6)
QUERY_CACHE_SIZE="64M"
if [ "$HAS_QUERY_CACHE" = true ]; then
    if [ "$TOTAL_RAM_GB" -ge 4 ]; then
        QUERY_CACHE_SIZE="128M"
    fi
fi

info "MariaDB version: $MARIADB_VERSION"
info "innodb_buffer_pool_size = ${BUFFER_POOL_GB}G"
info "innodb_buffer_pool_instances = ${BUFFER_POOL_INSTANCES}"
info "tmp_table_size = ${TMP_TABLE_SIZE}"
if [ "$HAS_QUERY_CACHE" = true ]; then
    info "query_cache_size = ${QUERY_CACHE_SIZE}"
else
    info "query_cache = skipped (removed in MariaDB 10.6+)"
fi
info "innodb_io_capacity = ${IO_CAPACITY}"
info "innodb_read/write_io_threads = ${IO_THREADS}"

# ============================================================
# Generate config
# ============================================================
GENERATED_CONFIG="[mysqld]
# === Generated by tweak-mycnf.sh ($(date +%F)) ===
# Server: ${TOTAL_RAM_GB}GB RAM / ${CPU_CORES} CPU
# MariaDB: ${MARIADB_VERSION}

# === Security ===
local-infile=0
skip-log-bin

# === Connections ===
max_connections=300
thread_cache_size=128
wait_timeout=300
interactive_timeout=300

# === Packet ===
max_allowed_packet=64M

# === InnoDB (~50% of RAM) ===
default_storage_engine=InnoDB
innodb_buffer_pool_size=${BUFFER_POOL_GB}G
innodb_buffer_pool_instances=${BUFFER_POOL_INSTANCES}
innodb_log_file_size=512M
innodb_log_buffer_size=64M
innodb_file_per_table=1
innodb_flush_log_at_trx_commit=2
innodb_flush_method=O_DIRECT
innodb_lock_wait_timeout=200
innodb_io_capacity=${IO_CAPACITY}
innodb_io_capacity_max=${IO_CAPACITY_MAX}
innodb_read_io_threads=${IO_THREADS}
innodb_write_io_threads=${IO_THREADS}

# === MyISAM ===
key_buffer_size=32M

# === Temp tables ===
tmp_table_size=${TMP_TABLE_SIZE}
max_heap_table_size=${MAX_HEAP_TABLE_SIZE}

# === Table & file cache ===
table_open_cache=4000
table_definition_cache=2000
open_files_limit=100000

# === Per-session buffers ===
sort_buffer_size=4M
read_buffer_size=2M
read_rnd_buffer_size=4M
join_buffer_size=4M"

# Add query cache only for MariaDB < 10.6
if [ "$HAS_QUERY_CACHE" = true ]; then
    GENERATED_CONFIG="${GENERATED_CONFIG}

# === Query cache (MariaDB < 10.6 only) ===
query_cache_type=1
query_cache_size=${QUERY_CACHE_SIZE}
query_cache_limit=4M
query_cache_min_res_unit=2k"
fi

GENERATED_CONFIG="${GENERATED_CONFIG}

# === Performance ===
performance_schema=OFF"

# ============================================================
# Dry run mode
# ============================================================
if [ "$DRY_RUN" = true ]; then
    header "Generated Config (Dry Run)"
    echo "$GENERATED_CONFIG"
    echo ""
    warn "No changes applied. Remove --dry-run to apply."
    exit 0
fi

# ============================================================
# Backup existing config
# ============================================================
header "Backup"

BACKUP_FILE="${CONFIG_FILE}.bak.$(date +%F-%H%M%S)"
cp "$CONFIG_FILE" "$BACKUP_FILE"
info "Backup saved: $BACKUP_FILE"

# Also backup other config files that might be affected
for extra in "$MARIADB_CNF" "$RUNCLOUD_CNF" "/etc/mysql/mariadb.conf.d/99-server.cnf"; do
    if [ -f "$extra" ] && [ "$extra" != "$CONFIG_FILE" ]; then
        cp "$extra" "${extra}.bak.$(date +%F-%H%M%S)" 2>/dev/null || true
    fi
done

# ============================================================
# Apply config
# ============================================================
header "Applying Config"

if [ "$CONFIG_FILE" = "$MARIADB_CNF" ]; then
    # sg5 pattern: replace existing [mysqld] section at end of file
    # Find the last [mysqld] and replace everything after it
    LAST_MYSQLD_LINE=$(grep -n '^\[mysqld\]' "$CONFIG_FILE" | tail -1 | cut -d: -f1)

    if [ -n "$LAST_MYSQLD_LINE" ] && [ "$LAST_MYSQLD_LINE" -gt 0 ]; then
        # Keep everything before the last [mysqld], then append new config
        head -n $(( LAST_MYSQLD_LINE - 1 )) "$CONFIG_FILE" > "${CONFIG_FILE}.tmp"
        echo "" >> "${CONFIG_FILE}.tmp"
        echo "$GENERATED_CONFIG" >> "${CONFIG_FILE}.tmp"
        mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
        info "Replaced [mysqld] section in $CONFIG_FILE"
    else
        # No [mysqld] section — append it
        echo "" >> "$CONFIG_FILE"
        echo "$GENERATED_CONFIG" >> "$CONFIG_FILE"
        info "Appended [mysqld] section to $CONFIG_FILE"
    fi
else
    # sg3 pattern: overwrite runcloud.cnf entirely
    echo "$GENERATED_CONFIG" > "$CONFIG_FILE"
    info "Wrote config to $CONFIG_FILE"
fi

# ============================================================
# Verify config before restart
# ============================================================
header "Verifying Config"

# Check that the settings will be picked up correctly
if command -v mariadbd &>/dev/null; then
    EFFECTIVE_POOL=$(mariadbd --print-defaults 2>/dev/null | tr ' ' '\n' | grep 'innodb_buffer_pool_size' | tail -1 || true)
    if [ -n "$EFFECTIVE_POOL" ]; then
        info "Effective: $EFFECTIVE_POOL"
    fi
fi

# ============================================================
# Restart MariaDB
# ============================================================
header "Restarting MariaDB"

if systemctl restart mariadb 2>/dev/null; then
    info "MariaDB restarted successfully."
else
    error "MariaDB failed to start! Restoring backup..."
    cp "$BACKUP_FILE" "$CONFIG_FILE"
    systemctl restart mariadb
    error "Restored from backup. Check: journalctl -u mariadb -n 50"
    exit 1
fi

# ============================================================
# Post-restart verification
# ============================================================
header "Verification"

VERIFY_QUERY="
    SHOW VARIABLES LIKE 'innodb_buffer_pool_size';
    SHOW VARIABLES LIKE 'innodb_buffer_pool_instances';
    SHOW VARIABLES LIKE 'innodb_log_file_size';
    SHOW VARIABLES LIKE 'innodb_flush_method';
    SHOW VARIABLES LIKE 'innodb_flush_log_at_trx_commit';
    SHOW VARIABLES LIKE 'innodb_io_capacity';
    SHOW VARIABLES LIKE 'max_connections';
    SHOW VARIABLES LIKE 'table_open_cache';
    SHOW VARIABLES LIKE 'tmp_table_size';
    SHOW VARIABLES LIKE 'wait_timeout';
    SHOW VARIABLES LIKE 'performance_schema';
"

if [ "$HAS_QUERY_CACHE" = true ]; then
    VERIFY_QUERY="${VERIFY_QUERY}
    SHOW VARIABLES LIKE 'query_cache_size';
    SHOW VARIABLES LIKE 'query_cache_type';
"
fi

mysql -e "$VERIFY_QUERY" 2>/dev/null

echo ""
info "Done! Settings applied for ${TOTAL_RAM_GB}GB RAM / ${CPU_CORES} CPU server."
info "Backup: $BACKUP_FILE"
info "Restore: ./tweak-mycnf.sh --restore"
