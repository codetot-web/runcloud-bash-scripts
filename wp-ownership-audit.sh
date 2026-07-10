#!/bin/bash
#
# wp-ownership-audit.sh — Audit RunCloud webapp file ownership
#
# Scans all webapps under /home/*/webapps/ and reports files owned by root
# or by a user other than the expected site owner (the user whose home
# directory contains the webapp). Designed to catch permission drift that
# silently breaks site functionality:
#
#   - Root-owned WP core files → wp-cli fails with "Could not create directory"
#   - Root-owned plugin files → PHP-FPM can't read → 500 errors
#   - Wrong-user ACL (group:users-rc:---) → FPM access denied
#
# Usage:
#   ./wp-ownership-audit.sh                           # all webapps
#   ./wp-ownership-audit.sh --site=APPNAME             # single site
#   ./wp-ownership-audit.sh --format=tsv               # default
#   ./wp-ownership-audit.sh --format=json
#   ./wp-ownership-audit.sh --fix                      # auto-fix (chown to site owner)
#   ./wp-ownership-audit.sh --dirs-only                # only check top-level dirs, not deep scan
#
# Output (TSV): site<TAB>expected_user<TAB>current_user<TAB>path<TAB>note
#
# Exit codes:
#   0  no ownership issues found
#   1  at least one ownership issue found
#   2  script-level error

set -euo pipefail

WEBROOT_GLOB="/home/*/webapps"
SITE_FILTER=""
FORMAT="tsv"
AUTO_FIX=false
DIRS_ONLY=false

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*" >&2; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*" >&2; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*" >&2; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# --- Parse arguments ---
for arg in "$@"; do
    case $arg in
        --site=*)     SITE_FILTER="${arg#*=}" ;;
        --format=*)   FORMAT="${arg#*=}" ;;
        --fix)        AUTO_FIX=true ;;
        --dirs-only)  DIRS_ONLY=true ;;
        --help|-h)
            awk 'NR==1{next} /^[^#]/{exit} {sub(/^# ?/,""); print}' "$0"
            exit 0
            ;;
        *) error "Unknown option: $arg"; exit 2 ;;
    esac
done

case "$FORMAT" in tsv|json) ;; *) error "Invalid --format: $FORMAT"; exit 2 ;; esac

# --- Determine expected owner for a site path ---
# For /home/USER/webapps/SITENAME, expected owner is USER.
get_expected_owner() {
    local site_path="$1"
    # Resolve /home/*/webapps/SITENAME to the user component
    local user
    user=$(echo "$site_path" | sed -n 's|^/home/\([^/]*\)/webapps/.*|\1|p')
    echo "$user"
}

# --- Check if a user exists on the system ---
user_exists() {
    id "$1" &>/dev/null
    return $?
}

# --- Discover webapps ---
shopt -s nullglob
declare -a TARGETS=()
for path in $WEBROOT_GLOB/*/; do
    name=$(basename "$path")
    [ -n "$SITE_FILTER" ] && [ "$name" != "$SITE_FILTER" ] && continue
    TARGETS+=("$path")
done

if [ ${#TARGETS[@]} -eq 0 ]; then
    [ -n "$SITE_FILTER" ] && warn "No webapp named '$SITE_FILTER' found under $WEBROOT_GLOB"
    [ "$FORMAT" = "json" ] && echo "[]"
    exit 0
fi

ANY_ISSUE=0
declare -a OUTPUT_LINES=()
JSON_ENTRIES=()

# --- Audit a single path (file or directory) ---
audit_path() {
    local site_path="$1" target_path="$2" expected_user="$3" site_name="$4" label="$5"

    # Get current owner and group
    local current_user current_group
    current_user=$(stat -c '%U' "$target_path" 2>/dev/null || stat -f '%Su' "$target_path" 2>/dev/null || echo "unknown")
    current_group=$(stat -c '%G' "$target_path" 2>/dev/null || stat -f '%Sg' "$target_path" 2>/dev/null || echo "unknown")

    local issue=0
    local notes=""

    # Check owner mismatch
    if [ "$current_user" != "$expected_user" ] && [ "$current_user" != "root" ]; then
        # Owner is neither expected user nor root — wrong user
        notes="Owner '$current_user' — expected '$expected_user'"
        issue=1
    elif [ "$current_user" = "root" ]; then
        # Root-owned files in webapp — common issue
        notes="Root-owned file (expected '$expected_user')"
        issue=1
    fi

    # Check ACL for deny entries
    if command -v getfacl &>/dev/null; then
        local deny_group
        deny_group=$(getfacl "$target_path" 2>/dev/null | grep -E '^group:.*:---' | head -1 || true)
        if [ -n "$deny_group" ]; then
            local denied_group
            denied_group=$(echo "$deny_group" | sed 's/^group:\(.*\):---/\1/')
            if [ -n "$notes" ]; then
                notes="$notes + ACL deny: $denied_group"
            else
                notes="ACL deny on group '$denied_group' (expected '$expected_user')"
            fi
            issue=1
        fi
    fi

    [ "$issue" -eq 0 ] && return 0

    ANY_ISSUE=1
    case "$FORMAT" in
        tsv)
            echo -e "${site_name}\t${expected_user}\t${current_user}:${current_group}\t${label}\t${notes}"
            ;;
        json)
            JSON_ENTRIES+=("{\"site\":\"${site_name}\",\"expected_user\":\"${expected_user}\",\"current_owner\":\"${current_user}:${current_group}\",\"path\":\"${label}\",\"note\":$(echo "$notes" | jq -Rs .)}")
            ;;
    esac
}

# --- Scan a single site ---
scan_site() {
    local site_path="$1"
    local site_name
    site_name=$(basename "$site_path")
    local expected_user
    expected_user=$(get_expected_owner "$site_path")

    if [ -z "$expected_user" ] || ! user_exists "$expected_user"; then
        warn "Skipping $site_name — cannot determine expected owner (user '$expected_user' not found)"
        return 0
    fi

    if [ "$DIRS_ONLY" = true ]; then
        # Quick mode: only check key directories
        for dir in "$site_path" "$site_path/wp-content" "$site_path/wp-content/plugins" "$site_path/wp-content/themes" "$site_path/wp-includes" "$site_path/wp-admin"; do
            [ -d "$dir" ] && audit_path "$site_path" "$dir" "$expected_user" "$site_name" "${dir#$site_path/}"
        done
        # Check .git directory too
        [ -d "$site_path/.git" ] && audit_path "$site_path" "$site_path/.git" "$expected_user" "$site_name" ".git"
    else
        # Full scan: find all root-owned files and all files owned by wrong users
        # Phase 1: Root-owned files
        local root_count=0
        root_count=$(find "$site_path" -not -path '*/wp-content/uploads/*' -not -path '*/.git/*' -user root 2>/dev/null | wc -l)
        if [ "$root_count" -gt 0 ]; then
            ANY_ISSUE=1
            # Show top offending directories
            local top_root_dirs
            top_root_dirs=$(find "$site_path" -not -path '*/wp-content/uploads/*' -not -path '*/.git/*' -user root -type f 2>/dev/null | xargs -I{} dirname {} 2>/dev/null | sort | uniq -c | sort -rn | head -5 || true)
            
            case "$FORMAT" in
                tsv)
                    echo -e "${site_name}\t${expected_user}\troot\t(root-owned files)\t$root_count files owned by root"
                    if [ -n "$top_root_dirs" ]; then
                        echo "$top_root_dirs" | while read -r count dir; do
                            echo -e "${site_name}\t${expected_user}\troot\t${dir#$site_path/}\t$count root-owned files in this directory"
                        done
                    fi
                    ;;
                json)
                    JSON_ENTRIES+=("{\"site\":\"${site_name}\",\"expected_user\":\"${expected_user}\",\"current_owner\":\"root\",\"path\":\"(multiple)\",\"note\":\"$root_count root-owned files\"}")
                    ;;
            esac
        fi

        # Phase 2: Wrong-owner files (not root, not expected_user)
        local wrong_user_dirs
        wrong_user_dirs=$(find "$site_path" -not -path '*/wp-content/uploads/*' -not -path '*/.git/*' -not -user root -not -user "$expected_user" -type d 2>/dev/null | head -20 || true)
        if [ -n "$wrong_user_dirs" ]; then
            while IFS= read -r dir; do
                local owner
                owner=$(stat -c '%U' "$dir" 2>/dev/null || stat -f '%Su' "$dir" 2>/dev/null || echo "?")
                audit_path "$site_path" "$dir" "$expected_user" "$site_name" "${dir#$site_path/}"
            done <<< "$wrong_user_dirs"
        fi

        # Phase 3: Check ACL on key files
        if command -v getfacl &>/dev/null; then
            local acl_issues
            acl_issues=$(find "$site_path" -not -path '*/wp-content/uploads/*' -not -path '*/.git/*' -maxdepth 5 \
                -name 'wp-config.php' -o -name '*.php' -o -name '.htaccess' 2>/dev/null | head -50 || true)
            while IFS= read -r file; do
                [ -z "$file" ] && continue
                local deny
                deny=$(getfacl "$file" 2>/dev/null | grep -E '^group:.*:---' | head -1 || true)
                if [ -n "$deny" ]; then
                    local dgroup
                    dgroup=$(echo "$deny" | sed 's/^group:\(.*\):---/\1/')
                    audit_path "$site_path" "$file" "$expected_user" "$site_name" "${file#$site_path/} (ACL: $dgroup denied)"
                fi
            done <<< "$acl_issues"
        fi
    fi

    # Auto-fix if requested
    if [ "$AUTO_FIX" = true ] && [ "$ANY_ISSUE" -eq 1 ]; then
        info "Fixing ownership for $site_name → $expected_user ..."
        find "$site_path" -not -path '*/wp-content/uploads/*' -not -path '*/.git/*' \
            -not -user "$expected_user" -exec chown "$expected_user":"$expected_user" {} + 2>/dev/null || true
        ok "Fixed ownership for $site_name"
    fi
}

# --- Main ---
info "Scanning ${#TARGETS[@]} webapp(s) for ownership issues..."
for path in "${TARGETS[@]}"; do
    scan_site "$path"
done

# Summary
if [ "$ANY_ISSUE" -eq 0 ]; then
    ok "No ownership issues found across all webapps."
else
    warn "Ownership issues detected — review above."
fi

# JSON output
if [ "$FORMAT" = "json" ] && [ ${#JSON_ENTRIES[@]} -gt 0 ]; then
    echo "[$(IFS=,; echo "${JSON_ENTRIES[*]}")]"
fi

exit $ANY_ISSUE
