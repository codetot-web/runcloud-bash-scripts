#!/bin/bash
#
# wp-health-check.sh — WordPress health auditor for RunCloud servers
#
# Discovers all WordPress webapps on the local server and probes each via
# `wp eval` invoked through the site's actual FPM/LSPHP binary. Bypasses
# Cloudflare entirely so sites in Under Attack Mode don't produce false
# positives, and catches real failures: DB connection broken, plugin/theme
# fatals, PHP version mismatches.
#
# FPM PHP binary detection: detect_fpm_php() finds the app's PHP binary
# from RunCloud FPM pools or OpenLiteSpeed LSAPI. If found, it is used as
# the PHP interpreter for wp-cli — this is critical because the system CLI
# PHP (/usr/bin/php) may lack extensions (e.g. mysqli) that the FPM PHP
# has, causing false-positive "MySQL extension missing" errors.
#
# Usage:
#   ./wp-health-check.sh                            # all sites, fails only
#   ./wp-health-check.sh --site=APPNAME             # single site
#   ./wp-health-check.sh --all                      # include ok and skip rows
#   ./wp-health-check.sh --format=tsv               # default
#   ./wp-health-check.sh --format=json
#   ./wp-health-check.sh --timeout=30               # wp-cli timeout per site
#   ./wp-health-check.sh --dry-run                  # show discovered sites + FPM versions, do not probe
#
# Output (TSV, columns: site<TAB>php<TAB>status<TAB>error_excerpt):
#   absoluteasiatravel	7.4	fail	PHP Fatal error: Uncaught Error: Class 'WP_Foo' not found in /home/...
#
# Exit codes:
#   0  every probed site is ok
#   1  at least one site reported fail
#   2  script-level error (no wp-cli phar found, no webapps directory, etc.)
#

set -euo pipefail

WEBROOT_GLOB="/home/*/webapps"
SITE_FILTER=""
SHOW_ALL=0
FORMAT="tsv"
TIMEOUT=30
DRY_RUN=0

# --- Colors (only for stderr diagnostic lines) ---
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*" >&2; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*" >&2; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# --- Parse arguments ---
for arg in "$@"; do
    case $arg in
        --site=*)     SITE_FILTER="${arg#*=}" ;;
        --all)        SHOW_ALL=1 ;;
        --format=*)   FORMAT="${arg#*=}" ;;
        --timeout=*)  TIMEOUT="${arg#*=}" ;;
        --dry-run)    DRY_RUN=1 ;;
        --help|-h)
            awk 'NR==1{next} /^[^#]/{exit} {sub(/^# ?/,""); print}' "$0"
            exit 0
            ;;
        *) error "Unknown option: $arg"; exit 2 ;;
    esac
done

case "$FORMAT" in tsv|json) ;; *) error "Invalid --format: $FORMAT"; exit 2 ;; esac
[[ "$TIMEOUT" =~ ^[0-9]+$ ]] || { error "Invalid --timeout: $TIMEOUT"; exit 2; }
[[ -z "$SITE_FILTER" || "$SITE_FILTER" =~ ^[a-zA-Z0-9_-]+$ ]] || { error "Invalid --site: $SITE_FILTER"; exit 2; }

# --- Discover wp-cli phar (same search order as wp-update.sh:96-103) ---
WP_CLI=""
for candidate in /usr/local/bin/wp /usr/bin/wp /RunCloud/Packages/RunCloudAgent/bin/wp-cli; do
    if [ -x "$candidate" ]; then
        WP_CLI="$candidate"
        break
    fi
done
if [ -z "$WP_CLI" ] && [ "$DRY_RUN" -eq 0 ]; then
    error "wp-cli not found in /usr/local/bin/wp, /usr/bin/wp, /RunCloud/Packages/RunCloudAgent/bin/wp-cli"
    exit 2
fi

# --- Discover webapps ---
shopt -s nullglob
declare -a TARGETS=()
# shellcheck disable=SC2086 # intentional glob expansion of WEBROOT_GLOB
for path in $WEBROOT_GLOB/*/; do
    name=$(basename "$path")
    [ -n "$SITE_FILTER" ] && [ "$name" != "$SITE_FILTER" ] && continue
    [ -f "$path/wp-config.php" ] || continue
    TARGETS+=("$path")
done

if [ ${#TARGETS[@]} -eq 0 ]; then
    [ -n "$SITE_FILTER" ] && warn "No WordPress site named '$SITE_FILTER' found"
    [ "$FORMAT" = "json" ] && echo "[]"
    exit 0
fi

# --- detect_fpm_php <site_path> <site_name> ---
# Prints "<version>\t<binary>" on stdout, or returns 1 if undetectable.
# Reuses logic from wp-update.sh:130-145.
detect_fpm_php() {
    local site_path="$1" site_name="$2" ver="" bin=""

    # Method 1: nginx + PHP-FPM pools (/etc/phpXYrc/fpm.d/SITE.conf)
    for phpdir in /etc/php85rc /etc/php84rc /etc/php83rc /etc/php82rc /etc/php81rc /etc/php80rc /etc/php74rc /etc/php73rc /etc/php72rc; do
        if [ -f "$phpdir/fpm.d/$site_name.conf" ]; then
            local tag
            tag=$(basename "$phpdir" | sed 's/^php//;s/rc$//')
            ver=$(echo "$tag" | sed 's/\(.\)\(.\)/\1.\2/')
            bin="/RunCloud/Packages/php${tag}rc/bin/php"
            [ -x "$bin" ] && { echo -e "$ver\t$bin"; return 0; }
        fi
    done

    # Method 2: OpenLiteSpeed LSAPI
    local lsphp_tag
    lsphp_tag=$(grep -hr 'lsphp' \
        /etc/lsws-rc/conf.d/"$site_name".d/ \
        /etc/lsws-rc/conf.d/"$site_name".vhosts.d/ 2>/dev/null \
        | grep -oP '/usr/local/lsws/lsphp\K[0-9]+' | head -1 || true)
    if [ -n "$lsphp_tag" ]; then
        ver=$(echo "$lsphp_tag" | sed 's/\(.\)\(.\)/\1.\2/')
        bin="/usr/local/lsws/lsphp${lsphp_tag}/bin/php"
        [ -x "$bin" ] && { echo -e "$ver\t$bin"; return 0; }
    fi

    return 1
}

# --- Dry-run output: list discovered sites + FPM versions ---
if [ "$DRY_RUN" -eq 1 ]; then
    for path in "${TARGETS[@]}"; do
        name=$(basename "$path")
        if det=$(detect_fpm_php "$path" "$name"); then
            php=$(echo "$det" | cut -f1)
            bin=$(echo "$det" | cut -f2)
            echo -e "$name\t$php\t$bin"
        else
            echo -e "$name\t-\t(no FPM PHP detected)"
        fi
    done
    exit 0
fi

# --- Probe each site ---
ANY_FAIL=0
declare -a OUTPUT_LINES=()

for path in "${TARGETS[@]}"; do
    name=$(basename "$path")
    status="ok"
    error_excerpt=""

    # Detect FPM PHP version and binary
    php_ver="-"
    php_bin=""
    if det=$(detect_fpm_php "$path" "$name"); then
        php_ver=$(echo "$det" | cut -f1)
        php_bin=$(echo "$det" | cut -f2)
    fi

    # Find site owner
    if [ -f "$path/wp-config.php" ]; then
        SITE_OWNER=$(stat -c '%U' "$path/wp-config.php" 2>/dev/null || stat -f '%Su' "$path/wp-config.php" 2>/dev/null || echo "root")
    else
        SITE_OWNER="root"
    fi

    if [ -z "$SITE_OWNER" ] || [ "$SITE_OWNER" = "root" ]; then
        info "Skipping $name (no site owner detected)"
        continue
    fi

    # Use FPM PHP binary if detected — system CLI PHP may lack extensions (e.g. mysqli)
    if [ -n "${php_bin-}" ] && [ -x "$php_bin" ]; then
        WP_CMD="$php_bin $WP_CLI"
    else
        WP_CMD="$WP_CLI"
    fi

    # Health probe: wp eval + db check
    probe_output=$(sudo -u "$SITE_OWNER" $WP_CMD --path="$path" --skip-plugins --skip-themes eval 'echo "WP_PROBE_OK";' 2>&1) || true

    if echo "$probe_output" | grep -q "WP_PROBE_OK"; then
        # wp-cli works with bare WP — now check plugins/themes active
        full_probe=$(sudo -u "$SITE_OWNER" $WP_CMD --path="$path" eval '
            echo "DB_OK:";
            global $wpdb;
            echo $wpdb->check_database_version() ? "versions_ok" : "version_mismatch";
            echo "|";
            echo function_exists("is_blog_installed") && is_blog_installed() ? "installed" : "not_installed";
        ' 2>&1) || true

        if echo "$full_probe" | grep -qi "error\|fatal\|exception\|could not\|connection refused\|Access denied\|Unknown database"; then
            status="fail"
            error_excerpt=$(echo "$full_probe" | grep -i "error\|fatal\|exception\|could not\|connection refused\|Access denied\|Unknown database" | head -3 | tr '\n' ' ')
            ANY_FAIL=1
        fi

        # Check plugin/theme fatals by loading with plugins
        plugin_probe=$(sudo -u "$SITE_OWNER" $WP_CMD --path="$path" --skip-themes plugin list --format=csv 2>&1 | head -1) || true
        if echo "$plugin_probe" | grep -qi "error\|fatal\|Fatal"; then
            status="fail"
            error_excerpt="$error_excerpt PluginList: $(echo "$plugin_probe" | head -1)"
            ANY_FAIL=1
        fi
    else
        # wp-cli itself failed
        status="fail"
        error_excerpt=$(echo "$probe_output" | head -3 | tr '\n' ' ')
        ANY_FAIL=1
    fi

    # Collect output
    FAIL_MARKER=""
    [ "$status" = "fail" ] && FAIL_MARKER=" (FAIL)" && info "${RED}${name}${NC}: DB/plugin probe failed — ${error_excerpt}"

    case "$FORMAT" in
        tsv)
            echo -e "${name}\t${php_ver}\t${status}\t${error_excerpt}"
            ;;
        json)
            OUTPUT_LINES+=("{\"site\":\"$name\",\"php\":\"$php_ver\",\"status\":\"$status\",\"error\":$(echo "$error_excerpt" | jq -Rs .)}")
            ;;
    esac
done

# JSON final output if requested
if [ "$FORMAT" = "json" ] && [ ${#OUTPUT_LINES[@]} -gt 0 ]; then
    echo "[$(IFS=,; echo "${OUTPUT_LINES[*]}")]"
fi

exit $ANY_FAIL
