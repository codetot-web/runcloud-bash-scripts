#!/bin/bash
#
# wp-plugin-push.sh — Push a local plugin to WordPress apps on RunCloud servers
#
# Packages a local plugin folder (or uses an existing zip), uploads it via SCP,
# installs/updates it with wp-cli on every WP app found on the server(s), then
# verifies each site returns HTTP 200.
#
# Usage:
#   ./wp-plugin-push.sh --plugin=gravityforms --server=sg3.codetot.org
#   ./wp-plugin-push.sh --plugin=gravityforms --servers=sg3,sg5,vn01
#   ./wp-plugin-push.sh --plugin=gravityforms --all-servers
#   ./wp-plugin-push.sh --plugin=gravityforms --server=sg3.codetot.org --dry-run
#   ./wp-plugin-push.sh --plugin=gravityforms --server=sg3.codetot.org --site=myapp
#
# Options:
#   --plugin=SLUG            Required. Plugin slug (folder/zip name inside --plugins-dir)
#   --plugins-dir=PATH       Local directory containing plugin folders or zips
#                            Default: ~/Documents/Plugins/gravityforms_plugins
#   --server=HOSTNAME        Single server hostname (short name like "sg3" or full FQDN)
#   --servers=LIST           Comma-separated short server names (e.g. sg3,sg5,vn01)
#   --all-servers            Push to all known servers (see SERVERS list below)
#   --site=APPNAME           Limit to a single WP app on the server (default: all apps)
#   --port=N                 SSH port override (default: auto-detected per server)
#   --skip-verify            Skip HTTP 200 verification after install
#   --activate               Activate plugin after install (default: install only)
#   --dry-run                Show what would happen without making changes
#   --help, -h               Show this help
#

set -euo pipefail

# --- Built-in server list (from SERVERS.md) ---
# Format: "hostname:port" — stored as plain strings to avoid bash associative array issues
SERVER_LIST=(
    "sg2.codetot.org:22"
    "sg3.codetot.org:22"
    "sg5.codetot.org:22"
    "sg6.codetot.org:22"
    "sg7.codetot.org:22"
    "sg8.codetot.org:22"
    "sg9.codetot.org:2018"
    "jp1.codetot.org:22"
    "vn01.codetot.org:2018"
    "vn02.codetot.org:2018"
    "vn03.codetot.org:2018"
    "vn04.codetot.org:2018"
    "vn05.codetot.org:22"
    "vn06.codetot.org:22"
    "vn07.codetot.org:22"
    "vn08.codetot.org:2018"
    "vn09.codetot.org:22"
    "vn10.codetot.org:2018"
    "vn11.codetot.org:22"
    "vn16.codetot.org:2018"
)

# Look up the SSH port for a hostname from SERVER_LIST
server_port() {
    local host="$1"
    for entry in "${SERVER_LIST[@]}"; do
        if [ "${entry%%:*}" = "$host" ]; then
            echo "${entry##*:}"
            return
        fi
    done
    echo "${PORT_OVERRIDE:-22}"  # fallback to explicit override or 22
}

# Derive ALL_SERVERS from SERVER_LIST (just the hostnames)
ALL_SERVERS=()
for _entry in "${SERVER_LIST[@]}"; do
    ALL_SERVERS+=("${_entry%%:*}")
done
unset _entry

# --- Defaults ---
PLUGIN=""
PLUGINS_DIR="${HOME}/Documents/Plugins/gravityforms_plugins"
SERVERS_INPUT=""
USE_ALL_SERVERS=false
SITE_FILTER=""
PORT_OVERRIDE=""
SKIP_VERIFY=false
ACTIVATE=false
DRY_RUN=false

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
header()  { echo -e "\n${BOLD}==> $*${NC}"; }

# --- Argument parsing ---
for i in "$@"; do
    case $i in
        --plugin=*)       PLUGIN="${i#*=}" ;;
        --plugins-dir=*)  PLUGINS_DIR="${i#*=}" ;;
        --server=*)       SERVERS_INPUT+="${i#*=}," ;;
        --servers=*)      SERVERS_INPUT+="${i#*=}," ;;
        --all-servers)    USE_ALL_SERVERS=true ;;
        --site=*)         SITE_FILTER="${i#*=}" ;;
        --port=*)         PORT_OVERRIDE="${i#*=}" ;;
        --skip-verify)    SKIP_VERIFY=true ;;
        --activate)       ACTIVATE=true ;;
        --dry-run)        DRY_RUN=true ;;
        --help|-h)
            awk 'NR==1{next} /^[^#]/{exit} {sub(/^# ?/,""); print}' "$0"
            exit 0
            ;;
        *) error "Unknown option: $i"; exit 1 ;;
    esac
done

# --- Validate plugin slug (alphanumeric + hyphens only) ---
if [ -z "$PLUGIN" ]; then
    error "--plugin is required. Use --help for usage."
    exit 1
fi
if [[ ! "$PLUGIN" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    error "--plugin contains invalid characters (allowed: a-z, 0-9, _, -)"
    exit 1
fi

# --- Resolve target servers ---
TARGET_SERVERS=()

if [ "$USE_ALL_SERVERS" = true ]; then
    TARGET_SERVERS=("${ALL_SERVERS[@]}")
elif [ -n "$SERVERS_INPUT" ]; then
    IFS=',' read -ra raw_list <<< "${SERVERS_INPUT%,}"
    for entry in "${raw_list[@]}"; do
        entry="${entry// /}"
        # Expand short names (e.g. "sg3" → "sg3.codetot.org")
        if [[ "$entry" != *"."* ]]; then
            entry="${entry}.codetot.org"
        fi
        TARGET_SERVERS+=("$entry")
    done
else
    error "Specify --server=, --servers=, or --all-servers"
    exit 1
fi

if [ ${#TARGET_SERVERS[@]} -eq 0 ]; then
    error "No servers resolved from input"
    exit 1
fi

# --- Resolve plugin zip ---
# Priority: 1) PLUGINS_DIR/SLUG.zip  2) PLUGINS_DIR/SLUG/ (folder → zip it)  3) parent dir zip
resolve_plugin_zip() {
    local slug="$1"
    local dir="$2"
    local tmpzip=""

    # 1. Pre-built zip in the plugins dir: slug.zip or slug_*.zip
    for candidate in "$dir/${slug}.zip" "$dir/${slug}_"*.zip; do
        if [ -f "$candidate" ]; then
            echo "$candidate"
            return 0
        fi
    done

    # 2. Plugin folder inside plugins dir → zip on the fly
    if [ -d "$dir/$slug" ]; then
        tmpzip="/tmp/${slug}-push-$$.zip"
        info "Zipping $dir/$slug → $tmpzip"
        if [ "$DRY_RUN" = false ]; then
            (cd "$dir" && zip -qr "$tmpzip" "$slug")
        else
            info "[dry-run] Would zip: $dir/$slug → $tmpzip"
            tmpzip="[dry-run:$tmpzip]"
        fi
        echo "$tmpzip"
        return 0
    fi

    # 3. Check parent directory for slug.zip
    local parent
    parent="$(dirname "$dir")"
    for candidate in "$parent/${slug}.zip" "$parent/${slug}_"*.zip; do
        if [ -f "$candidate" ]; then
            echo "$candidate"
            return 0
        fi
    done

    return 1
}

PLUGIN_ZIP=""
PLUGIN_SOURCE=""  # original local path (folder or zip), for display

if ! PLUGIN_ZIP=$(resolve_plugin_zip "$PLUGIN" "$PLUGINS_DIR"); then
    error "Plugin '$PLUGIN' not found in $PLUGINS_DIR (tried .zip and folder)"
    error "Expected one of:"
    error "  $PLUGINS_DIR/${PLUGIN}.zip"
    error "  $PLUGINS_DIR/$PLUGIN/  (folder)"
    exit 1
fi

# Detect original source for version + display (before dry-run placeholder changes PLUGIN_ZIP)
if [ -d "$PLUGINS_DIR/$PLUGIN" ]; then
    PLUGIN_SOURCE="$PLUGINS_DIR/$PLUGIN/"
    PLUGIN_VERSION=$(grep -i "^[ \t]*\*\? *Version:" "$PLUGINS_DIR/$PLUGIN/${PLUGIN}.php" 2>/dev/null \
        | head -1 | sed 's/.*Version:[ \t]*//' | tr -d '\r' || echo "unknown")
elif [[ "$PLUGIN_ZIP" != "[dry-run:"* ]] && [ -f "$PLUGIN_ZIP" ]; then
    PLUGIN_SOURCE="$PLUGIN_ZIP"
    PLUGIN_VERSION=$(unzip -p "$PLUGIN_ZIP" "${PLUGIN}/${PLUGIN}.php" 2>/dev/null \
        | grep -i "^[ \t]*\*\? *Version:" | head -1 | sed 's/.*Version:[ \t]*//' | tr -d '\r' || echo "unknown")
else
    PLUGIN_SOURCE="$PLUGINS_DIR"
    PLUGIN_VERSION="unknown"
fi

info "Plugin: $PLUGIN  version: $PLUGIN_VERSION"
info "Source: $PLUGIN_SOURCE"

# --- SSH helper ---
ssh_cmd() {
    local host="$1" port="$2"
    echo "ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -p $port root@$host"
}

scp_cmd() {
    local host="$1" port="$2"
    echo "scp -o StrictHostKeyChecking=no -o ConnectTimeout=10 -P $port"
}

# --- Find all WP apps on a server ---
find_wp_apps() {
    local host="$1" port="$2"
    $(ssh_cmd "$host" "$port") \
        "find /home/*/webapps/*/wp-config.php 2>/dev/null | sed 's|/wp-config\.php||'" 2>/dev/null || true
}

# --- Get site URL via wp-cli ---
get_site_url() {
    local host="$1" port="$2" app_path="$3" owner="$4"
    $(ssh_cmd "$host" "$port") \
        "sudo -u $owner wp --path=$app_path option get siteurl 2>/dev/null" 2>/dev/null || true
}

# --- Install plugin via wp-cli on remote ---
install_plugin_remote() {
    local host="$1" port="$2" app_path="$3" owner="$4" remote_zip="$5"
    local activate_flag=""
    [ "$ACTIVATE" = true ] && activate_flag="--activate"
    $(ssh_cmd "$host" "$port") \
        "sudo -u $owner wp --path=$app_path plugin install $remote_zip --force $activate_flag 2>&1" || true
}

# --- Verify HTTP 200 ---
verify_http() {
    local url="$1"
    local code
    code=$(curl -skL --max-time 15 -o /dev/null -w "%{http_code}" "$url" 2>/dev/null || echo "000")
    echo "$code"
}

# --- Per-server push ---
push_to_server() {
    local host="$1"
    local port="${PORT_OVERRIDE:-$(server_port "$host")}"
    local remote_zip="/tmp/${PLUGIN}-push-$$.zip"

    header "Server: $host (port $port)"

    # Test SSH connectivity
    if ! $(ssh_cmd "$host" "$port") "exit 0" 2>/dev/null; then
        error "Cannot connect to $host:$port — skipping"
        return 1
    fi

    # Upload zip to server
    if [ "$DRY_RUN" = false ]; then
        info "Uploading $PLUGIN_SOURCE → $host:$remote_zip"
        $(scp_cmd "$host" "$port") "$PLUGIN_ZIP" "root@$host:$remote_zip" 2>/dev/null
    else
        info "[dry-run] Would upload: $PLUGIN_SOURCE → $host:$remote_zip"
    fi

    # Find WP apps
    local app_paths=()
    if [ -n "$SITE_FILTER" ]; then
        # Check the filtered site exists
        local filtered_path
        for base in /home/runcloud/webapps /home/*/webapps; do
            filtered_path="${base}/${SITE_FILTER}"
            if $(ssh_cmd "$host" "$port") "[ -f $filtered_path/wp-config.php ]" 2>/dev/null; then
                app_paths=("$filtered_path")
                break
            fi
        done
        if [ ${#app_paths[@]} -eq 0 ]; then
            warn "Site '$SITE_FILTER' not found on $host — skipping server"
            return 0
        fi
    else
        while IFS= read -r path; do
            [ -n "$path" ] && app_paths+=("$path")
        done < <(find_wp_apps "$host" "$port")
    fi

    if [ ${#app_paths[@]} -eq 0 ]; then
        warn "No WordPress apps found on $host"
        return 0
    fi

    info "Found ${#app_paths[@]} WP app(s)"

    local ok=0 fail=0 skip=0

    for app_path in "${app_paths[@]}"; do
        local app_name
        app_name=$(basename "$app_path")
        echo ""
        info "  App: $app_name ($app_path)"

        # Get site owner
        local owner
        owner=$($(ssh_cmd "$host" "$port") \
            "stat -c '%U' $app_path 2>/dev/null || echo runcloud" 2>/dev/null || echo "runcloud")
        [ "$owner" = "root" ] && owner="runcloud"

        if [ "$DRY_RUN" = true ]; then
            info "  [dry-run] Would install $PLUGIN v$PLUGIN_VERSION on $app_name (as $owner)"
            ok=$((ok + 1))
            continue
        fi

        # Install plugin
        local output
        output=$(install_plugin_remote "$host" "$port" "$app_path" "$owner" "$remote_zip")
        echo "  $output" | sed 's/^/    /'

        if echo "$output" | grep -qi "error\|fatal\|permission denied"; then
            error "  Install failed on $app_name"
            fail=$((fail + 1))
            continue
        fi

        success "  Installed $PLUGIN on $app_name"
        ok=$((ok + 1))

        # HTTP verification
        if [ "$SKIP_VERIFY" = false ]; then
            local site_url
            site_url=$(get_site_url "$host" "$port" "$app_path" "$owner")
            if [ -n "$site_url" ]; then
                local code
                code=$(verify_http "$site_url")
                if [ "$code" = "200" ]; then
                    success "  HTTP $code ✓  $site_url"
                else
                    warn "  HTTP $code ✗  $site_url  (site may need attention)"
                fi
            else
                warn "  Could not resolve site URL for $app_name — skipping HTTP check"
            fi
        fi
    done

    # Cleanup remote zip
    if [ "$DRY_RUN" = false ]; then
        $(ssh_cmd "$host" "$port") "rm -f $remote_zip" 2>/dev/null || true
    fi

    echo ""
    info "  $host summary — ok: $ok  failed: $fail  skipped: $skip"
}

# --- Cleanup local temp zip on exit ---
cleanup() {
    if [[ "${PLUGIN_ZIP:-}" == /tmp/*-push-*.zip ]]; then
        rm -f "$PLUGIN_ZIP" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# --- Main ---
echo ""
echo -e "${BOLD}wp-plugin-push — $PLUGIN${NC}"
[ "$DRY_RUN" = true ] && warn "DRY RUN MODE — no changes will be made"
echo ""
info "Target servers: ${TARGET_SERVERS[*]}"
[ -n "$SITE_FILTER" ] && info "Site filter:    $SITE_FILTER"
[ "$ACTIVATE" = true ] && info "Activate after install: yes"
[ "$SKIP_VERIFY" = true ] && info "HTTP verify: skipped"
echo ""

TOTAL_OK=0
TOTAL_FAIL=0

for server in "${TARGET_SERVERS[@]}"; do
    if push_to_server "$server"; then
        TOTAL_OK=$((TOTAL_OK + 1))
    else
        TOTAL_FAIL=$((TOTAL_FAIL + 1))
    fi
done

echo ""
echo -e "${BOLD}=== Summary ===${NC}"
success "Servers OK:     $TOTAL_OK"
[ "$TOTAL_FAIL" -gt 0 ] && error "Servers failed: $TOTAL_FAIL"
echo ""
