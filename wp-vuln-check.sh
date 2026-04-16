#!/bin/bash
#
# wp-vuln-check.sh — Check WordPress plugins/themes for known vulnerabilities
#
# Queries the free WPVulnerability.net API for each installed plugin and theme,
# reports any known CVEs with CVSS scores and severity.
#
# Usage:
#   ./wp-vuln-check.sh --site=APPNAME
#   ./wp-vuln-check.sh --site=APPNAME --json          # machine-readable output
#   ./wp-vuln-check.sh --site=APPNAME --plugins-only   # skip themes
#   ./wp-vuln-check.sh --site=APPNAME --themes-only    # skip plugins
#
# Options:
#   --site=NAME       Web app name (searches /home/*/webapps/)
#   --path=PATH       Full path to the web app (alternative to --site)
#   --json            Output raw JSON instead of formatted report
#   --plugins-only    Only check plugins
#   --themes-only     Only check themes
#   --include-core    Also check WP core version
#

set -euo pipefail

SITE=""
SITE_PATH=""
JSON_OUTPUT=false
CHECK_PLUGINS=true
CHECK_THEMES=true
CHECK_CORE=false

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# --- Parse arguments ---
for i in "$@"; do
    case $i in
        --site=*)       SITE="${i#*=}" ;;
        --path=*)       SITE_PATH="${i#*=}" ;;
        --json)         JSON_OUTPUT=true ;;
        --plugins-only) CHECK_THEMES=false ;;
        --themes-only)  CHECK_PLUGINS=false ;;
        --include-core) CHECK_CORE=true ;;
        --help|-h)
            awk 'NR==1{next} /^[^#]/{exit} {sub(/^# ?/,""); print}' "$0"
            exit 0
            ;;
        *) error "Unknown option: $i"; exit 1 ;;
    esac
done

# --- Resolve site path ---
if [ -n "$SITE_PATH" ]; then
    # --path= given directly
    SITE=$(basename "$SITE_PATH")
elif [ -n "$SITE" ]; then
    # --site= given, search across all users
    for base in /home/*/webapps/"$SITE"; do
        if [ -d "$base" ]; then
            SITE_PATH="$base"
            break
        fi
    done
    if [ -z "$SITE_PATH" ]; then
        error "Site '$SITE' not found under /home/*/webapps/"
        exit 1
    fi
else
    error "--site or --path is required. Use --help for usage."
    exit 1
fi

if [ ! -d "$SITE_PATH" ]; then
    error "Path not found: $SITE_PATH"
    exit 1
fi

if [ ! -f "$SITE_PATH/wp-config.php" ]; then
    error "'$SITE' is not a WordPress site (no wp-config.php)"
    exit 1
fi

# --- Find wp-cli ---
WP_CLI=""
for candidate in /usr/local/bin/wp /usr/bin/wp /RunCloud/Packages/RunCloudAgent/bin/wp-cli; do
    if [ -x "$candidate" ]; then
        WP_CLI="$candidate"
        break
    fi
done

if [ -z "$WP_CLI" ]; then
    error "wp-cli not found"
    exit 1
fi

# --- Detect site owner ---
SITE_OWNER=$(stat -c '%U' "$SITE_PATH" 2>/dev/null || stat -f '%Su' "$SITE_PATH" 2>/dev/null || echo "runcloud")
if [ "$SITE_OWNER" = "root" ]; then
    SITE_OWNER="runcloud"
fi

if [ "$(whoami)" = "$SITE_OWNER" ]; then
    WP="$WP_CLI --path=$SITE_PATH"
else
    WP="sudo -u $SITE_OWNER $WP_CLI --path=$SITE_PATH"
fi

API_BASE="https://www.wpvulnerability.net"

# --- Version comparison ---
# Returns 0 if $1 < $2, 1 if equal, 2 if $1 > $2
version_compare() {
    local a="$1" b="$2"
    if [ "$a" = "$b" ]; then echo 1; return; fi

    local IFS='.'
    read -ra va <<< "$a"
    read -ra vb <<< "$b"
    local max=${#va[@]}
    [ ${#vb[@]} -gt "$max" ] && max=${#vb[@]}

    for ((i=0; i<max; i++)); do
        local na="${va[$i]:-0}" nb="${vb[$i]:-0}"
        # Strip non-numeric suffix (e.g., "3beta1" -> "3")
        na="${na%%[!0-9]*}"
        nb="${nb%%[!0-9]*}"
        na="${na:-0}"
        nb="${nb:-0}"
        if [ "$na" -lt "$nb" ] 2>/dev/null; then echo 0; return; fi
        if [ "$na" -gt "$nb" ] 2>/dev/null; then echo 2; return; fi
    done
    echo 1
}

# Check if installed version is affected by a vulnerability operator
# Args: installed_version max_version max_operator unfixed
is_affected() {
    local installed="$1" max_ver="$2" max_op="$3" unfixed="$4"

    # Unfixed = all versions affected
    if [ "$unfixed" = "1" ]; then echo 1; return; fi

    [ -z "$max_ver" ] && { echo 0; return; }

    local cmp
    cmp=$(version_compare "$installed" "$max_ver")

    case "$max_op" in
        lt) [ "$cmp" -eq 0 ] && echo 1 || echo 0 ;;
        le) [ "$cmp" -le 1 ] && echo 1 || echo 0 ;;
        *)  echo 0 ;;
    esac
}

# --- Check a single component against the API ---
# Args: type (plugin|theme|core) slug version
# Outputs vulnerability lines
check_component() {
    local comp_type="$1" slug="$2" version="$3"
    local endpoint

    case "$comp_type" in
        plugin) endpoint="$API_BASE/plugin/$slug/" ;;
        theme)  endpoint="$API_BASE/theme/$slug/" ;;
        core)   endpoint="$API_BASE/core/$version/" ;;
    esac

    local response
    response=$(curl -s --connect-timeout 5 --max-time 10 "$endpoint" 2>/dev/null || echo "")

    if [ -z "$response" ]; then
        return
    fi

    # Check for API error
    local api_error
    api_error=$(echo "$response" | grep -oP '"error"\s*:\s*\K\d+' | head -1 || echo "0")
    if [ "$api_error" != "0" ]; then
        return
    fi

    # Extract vulnerabilities array — use python3 if available for reliable JSON parsing
    if command -v python3 &>/dev/null; then
        python3 -c "
import json, sys
try:
    data = json.loads(sys.stdin.read())
    vulns = data.get('data', {})
    if vulns is None:
        sys.exit(0)
    vulns = vulns.get('vulnerability', [])
    if not vulns:
        sys.exit(0)
    for v in vulns:
        op = v.get('operator', {}) or {}
        max_ver = op.get('max_version', '') or ''
        max_op = op.get('max_operator', '') or ''
        unfixed = op.get('unfixed', '0') or '0'
        # Get CVE
        cve = ''
        for s in (v.get('source') or []):
            sid = s.get('id', '')
            if sid.startswith('CVE-'):
                cve = sid
                break
        # Get CVSS score
        cvss = ''
        severity = ''
        for key in ['cvss3', 'cvss']:
            impact = v.get('impact', {}) or {}
            score_obj = impact.get(key)
            if score_obj and score_obj.get('score'):
                cvss = score_obj['score']
                severity = score_obj.get('severity', '')
                break
        name = v.get('name', '')
        uuid = v.get('uuid', '')
        print(f'{uuid}|{name}|{max_ver}|{max_op}|{unfixed}|{cve}|{cvss}|{severity}')
except:
    pass
" <<< "$response"
    fi
}

# --- Main ---

TOTAL_VULNS=0
CRITICAL_VULNS=0
HIGH_VULNS=0
VULN_ENTRIES=()
JSON_ENTRIES=()

if [ "$JSON_OUTPUT" = false ]; then
    info "Vulnerability check for: $SITE"
    echo ""
fi

# Check WP core
if [ "$CHECK_CORE" = true ]; then
    wp_ver=$(grep -oP "\\\$wp_version\s*=\s*'\K[^']+" "$SITE_PATH/wp-includes/version.php" 2>/dev/null || echo "")
    if [ -n "$wp_ver" ]; then
        [ "$JSON_OUTPUT" = false ] && info "Checking WordPress core $wp_ver..."
        while IFS='|' read -r uuid name max_ver max_op unfixed cve cvss severity; do
            [ -z "$uuid" ] && continue
            affected=$(is_affected "$wp_ver" "$max_ver" "$max_op" "$unfixed")
            if [ "$affected" = "1" ]; then
                TOTAL_VULNS=$((TOTAL_VULNS + 1))
                sev_upper=$(echo "$severity" | tr '[:lower:]' '[:upper:]')
                [ "$sev_upper" = "CRITICAL" ] && CRITICAL_VULNS=$((CRITICAL_VULNS + 1))
                [ "$sev_upper" = "HIGH" ] && HIGH_VULNS=$((HIGH_VULNS + 1))
                VULN_ENTRIES+=("core|wordpress|$wp_ver|$name|$cve|$cvss|$severity|$unfixed")
                JSON_ENTRIES+=("{\"type\":\"core\",\"slug\":\"wordpress\",\"version\":\"$wp_ver\",\"vuln\":\"$name\",\"cve\":\"$cve\",\"cvss\":\"$cvss\",\"severity\":\"$severity\",\"unfixed\":$( [ "$unfixed" = "1" ] && echo true || echo false)}")
            fi
        done < <(check_component "core" "" "$wp_ver")
    fi
fi

# Check plugins
if [ "$CHECK_PLUGINS" = true ]; then
    [ "$JSON_OUTPUT" = false ] && info "Fetching plugin list..."
    plugin_json=$($WP plugin list --fields=name,version,status,update,update_version --format=json 2>/dev/null || echo "[]")

    if command -v python3 &>/dev/null; then
        plugin_list=$(python3 -c "
import json, sys
try:
    plugins = json.loads(sys.stdin.read())
    for p in plugins:
        print(f\"{p['name']}|{p['version']}|{p.get('status','active')}\")
except:
    pass
" <<< "$plugin_json")
    else
        plugin_list=""
    fi

    plugin_count=0
    while IFS='|' read -r slug version status; do
        [ -z "$slug" ] && continue
        plugin_count=$((plugin_count + 1))
    done <<< "$plugin_list"

    [ "$JSON_OUTPUT" = false ] && info "Checking $plugin_count plugins against WPVulnerability API..."

    checked=0
    while IFS='|' read -r slug version status; do
        [ -z "$slug" ] && continue
        checked=$((checked + 1))

        while IFS='|' read -r uuid name max_ver max_op unfixed cve cvss severity; do
            [ -z "$uuid" ] && continue
            affected=$(is_affected "$version" "$max_ver" "$max_op" "$unfixed")
            if [ "$affected" = "1" ]; then
                TOTAL_VULNS=$((TOTAL_VULNS + 1))
                sev_upper=$(echo "$severity" | tr '[:lower:]' '[:upper:]')
                [ "$sev_upper" = "CRITICAL" ] && CRITICAL_VULNS=$((CRITICAL_VULNS + 1))
                [ "$sev_upper" = "HIGH" ] && HIGH_VULNS=$((HIGH_VULNS + 1))
                VULN_ENTRIES+=("plugin|$slug|$version|$name|$cve|$cvss|$severity|$unfixed")
                JSON_ENTRIES+=("{\"type\":\"plugin\",\"slug\":\"$slug\",\"version\":\"$version\",\"vuln\":\"$name\",\"cve\":\"$cve\",\"cvss\":\"$cvss\",\"severity\":\"$severity\",\"unfixed\":$( [ "$unfixed" = "1" ] && echo true || echo false)}")
            fi
        done < <(check_component "plugin" "$slug" "$version")
    done <<< "$plugin_list"
fi

# Check themes
if [ "$CHECK_THEMES" = true ]; then
    [ "$JSON_OUTPUT" = false ] && info "Fetching theme list..."
    theme_json=$($WP theme list --fields=name,version,status,update,update_version --format=json 2>/dev/null || echo "[]")

    if command -v python3 &>/dev/null; then
        theme_list=$(python3 -c "
import json, sys
try:
    themes = json.loads(sys.stdin.read())
    for t in themes:
        print(f\"{t['name']}|{t['version']}|{t.get('status','inactive')}\")
except:
    pass
" <<< "$theme_json")
    else
        theme_list=""
    fi

    theme_count=0
    while IFS='|' read -r slug version status; do
        [ -z "$slug" ] && continue
        theme_count=$((theme_count + 1))
    done <<< "$theme_list"

    [ "$JSON_OUTPUT" = false ] && info "Checking $theme_count themes against WPVulnerability API..."

    while IFS='|' read -r slug version status; do
        [ -z "$slug" ] && continue

        while IFS='|' read -r uuid name max_ver max_op unfixed cve cvss severity; do
            [ -z "$uuid" ] && continue
            affected=$(is_affected "$version" "$max_ver" "$max_op" "$unfixed")
            if [ "$affected" = "1" ]; then
                TOTAL_VULNS=$((TOTAL_VULNS + 1))
                sev_upper=$(echo "$severity" | tr '[:lower:]' '[:upper:]')
                [ "$sev_upper" = "CRITICAL" ] && CRITICAL_VULNS=$((CRITICAL_VULNS + 1))
                [ "$sev_upper" = "HIGH" ] && HIGH_VULNS=$((HIGH_VULNS + 1))
                VULN_ENTRIES+=("theme|$slug|$version|$name|$cve|$cvss|$severity|$unfixed")
                JSON_ENTRIES+=("{\"type\":\"theme\",\"slug\":\"$slug\",\"version\":\"$version\",\"vuln\":\"$name\",\"cve\":\"$cve\",\"cvss\":\"$cvss\",\"severity\":\"$severity\",\"unfixed\":$( [ "$unfixed" = "1" ] && echo true || echo false)}")
            fi
        done < <(check_component "theme" "$slug" "$version")
    done <<< "$theme_list"
fi

# --- Output ---

if [ "$JSON_OUTPUT" = true ]; then
    # Build JSON array
    json_out="["
    first=true
    for entry in "${JSON_ENTRIES[@]+"${JSON_ENTRIES[@]}"}"; do
        if [ "$first" = true ]; then
            first=false
        else
            json_out="$json_out,"
        fi
        json_out="$json_out$entry"
    done
    json_out="$json_out]"
    echo "$json_out"
    exit 0
fi

# Formatted report
echo ""
if [ "$TOTAL_VULNS" -eq 0 ]; then
    success "No known vulnerabilities found!"
else
    echo -e "${RED}${BOLD}Found $TOTAL_VULNS vulnerabilit$([ "$TOTAL_VULNS" -eq 1 ] && echo "y" || echo "ies")${NC}"
    [ "$CRITICAL_VULNS" -gt 0 ] && echo -e "  ${RED}Critical: $CRITICAL_VULNS${NC}"
    [ "$HIGH_VULNS" -gt 0 ] && echo -e "  ${MAGENTA}High: $HIGH_VULNS${NC}"
    echo ""

    # Sort by severity (critical first)
    severity_order() {
        case "$(echo "$1" | tr '[:upper:]' '[:lower:]')" in
            critical) echo 0 ;; high) echo 1 ;; medium) echo 2 ;; low) echo 3 ;; *) echo 9 ;;
        esac
    }

    # Print each vulnerability
    for entry in "${VULN_ENTRIES[@]}"; do
        IFS='|' read -r comp_type slug version name cve cvss severity unfixed <<< "$entry"
        sev_upper=$(echo "$severity" | tr '[:lower:]' '[:upper:]')

        # Color by severity
        case "$sev_upper" in
            CRITICAL) sev_color="$RED" ;;
            HIGH)     sev_color="$MAGENTA" ;;
            MEDIUM)   sev_color="$YELLOW" ;;
            *)        sev_color="$NC" ;;
        esac

        echo -e "  ${sev_color}[$sev_upper]${NC} ${BOLD}$slug${NC} ($version)"
        [ -n "$cve" ] && echo -e "    CVE: $cve"
        [ -n "$cvss" ] && echo -e "    CVSS: $cvss"
        echo -e "    $name"
        [ "$unfixed" = "1" ] && echo -e "    ${RED}⚠ No fix available${NC}"
        echo ""
    done
fi

echo ""
success "Done with $SITE"

# Append plugin/theme inventory + vuln data as JSON footer (used by dashboard)
echo ""
echo "---PLUGIN_INVENTORY---"
# Build vuln JSON array
vuln_json="["
vfirst=true
for entry in "${JSON_ENTRIES[@]+"${JSON_ENTRIES[@]}"}"; do
    if [ "$vfirst" = true ]; then vfirst=false; else vuln_json="$vuln_json,"; fi
    vuln_json="$vuln_json$entry"
done
vuln_json="$vuln_json]"
echo "{\"plugins\":${plugin_json:-[]},\"themes\":${theme_json:-[]},\"vulns\":$vuln_json}"
