#!/bin/bash
#
# wp-freeze.sh — WordPress Code Freeze for RunCloud servers
#
# Locks a WordPress site's filesystem and admin capabilities to prevent
# unauthorized code changes after launch. Content publishing (posts, uploads)
# remains fully functional.
#
# Usage:
#   ./wp-freeze.sh --site=APPNAME --action=freeze      # Freeze a specific site
#   ./wp-freeze.sh --site=APPNAME --action=unfreeze    # Unfreeze a specific site
#   ./wp-freeze.sh --site=APPNAME --action=status      # Check freeze status
#   ./wp-freeze.sh --action=freeze                     # Freeze all sites
#   ./wp-freeze.sh --site=APPNAME --action=freeze --dry-run
#
# What freeze does:
#   Filesystem layer:
#     - Sets core files/dirs to read-only (444/555)
#     - Sets wp-config.php to 440, .htaccess to 444
#     - Blocks PHP execution in wp-content/uploads/ via .htaccess
#     - Leaves wp-content/uploads/ permissions unchanged
#   WordPress layer (wp-config.php constants):
#     - DISALLOW_FILE_EDIT      — disables in-admin theme/plugin editor
#     - DISALLOW_FILE_MODS      — blocks plugin/theme installs and updates
#     - AUTOMATIC_UPDATER_DISABLED — disables WordPress auto-updates
#   Capability layer (mu-plugin):
#     - Removes create/edit/delete/promote user capabilities from all roles
#     - Hides Users menu in wp-admin
#
# What stays functional after freeze:
#   - Creating, editing, publishing posts
#   - Media uploads (wp-content/uploads/ is excluded)
#   - Comments and all other DB-only operations
#   - Admins changing their own password
#
# Maintenance window workflow:
#   1. wp-freeze.sh --site=APPNAME --action=unfreeze
#   2. Run updates (plugins, core, etc.)
#   3. wp-freeze.sh --site=APPNAME --action=freeze
#
# Relates to: codetot-workspace/runcloud#1, #2
#

set -euo pipefail

WEBROOT="/home/runcloud/webapps"
TARGET_SITE=""
ACTION=""
DRY_RUN=false

# Sentinel markers for injected blocks
FREEZE_MARKER_START="# === CODE FREEZE — managed by wp-freeze.sh ==="
FREEZE_MARKER_END="# === END CODE FREEZE ==="
WPCONFIG_MARKER_START="// === CODE FREEZE — managed by wp-freeze.sh ==="
WPCONFIG_MARKER_END="// === END CODE FREEZE ==="

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
dry()     { echo -e "${YELLOW}[DRY]${NC}   $*"; }

# --- Parse arguments ---
for i in "$@"; do
    case $i in
        --site=*)
            TARGET_SITE="${i#*=}"
            ;;
        --action=*)
            ACTION="${i#*=}"
            ;;
        --dry-run)
            DRY_RUN=true
            ;;
        --help|-h)
            awk 'NR==1{next} /^[^#]/{exit} {sub(/^# ?/,""); print}' "$0"
            exit 0
            ;;
        *)
            error "Unknown option: $i"
            echo "Run with --help for usage."
            exit 1
            ;;
    esac
done

# --- Validate ---
if [ -z "$ACTION" ]; then
    error "--action is required (freeze | unfreeze | status)"
    exit 1
fi

if [[ "$ACTION" != "freeze" && "$ACTION" != "unfreeze" && "$ACTION" != "status" ]]; then
    error "Unknown action: $ACTION. Must be freeze, unfreeze, or status."
    exit 1
fi

# --- mu-plugin content ---
MUPLUGIN_CONTENT='<?php
/**
 * Plugin Name: Code Freeze
 * Description: Restricts user management during code freeze. Auto-installed by wp-freeze.sh.
 * Version: 1.0
 */

add_filter('"'"'user_has_cap'"'"', function($allcaps) {
    $blocked = [
        '"'"'create_users'"'"', '"'"'edit_users'"'"', '"'"'delete_users'"'"',
        '"'"'promote_users'"'"', '"'"'remove_users'"'"', '"'"'list_users'"'"',
    ];
    foreach ($blocked as $cap) {
        $allcaps[$cap] = false;
    }
    return $allcaps;
}, 10, 4);

add_action('"'"'admin_menu'"'"', function() {
    remove_menu_page('"'"'users.php'"'"');
}, 999);
'

# --- Helpers ---

run_cmd() {
    # Run a command or print it in dry-run mode
    if [ "$DRY_RUN" = true ]; then
        dry "$*"
    else
        eval "$@"
    fi
}

is_frozen() {
    local site_path="$1"
    local wpconfig="$site_path/wp-config.php"
    if [ -f "$wpconfig" ] && grep -q "CODE FREEZE" "$wpconfig" 2>/dev/null; then
        return 0
    fi
    return 1
}

inject_wpconfig_constants() {
    local wpconfig="$1"

    if grep -q "CODE FREEZE" "$wpconfig" 2>/dev/null; then
        info "wp-config.php constants already present — skipping"
        return
    fi

    local block
    block=$(printf '%s\n%s\n%s\n%s\n%s\n' \
        "$WPCONFIG_MARKER_START" \
        "define('DISALLOW_FILE_EDIT', true);" \
        "define('DISALLOW_FILE_MODS', true);" \
        "define('AUTOMATIC_UPDATER_DISABLED', true);" \
        "$WPCONFIG_MARKER_END")

    if [ "$DRY_RUN" = true ]; then
        dry "Would inject CODE FREEZE constants into $wpconfig"
    else
        # Inject before the "That's all" line, or append before closing PHP if not found
        if grep -q "That's all, stop editing" "$wpconfig"; then
            sed -i "/That's all, stop editing/i\\
${WPCONFIG_MARKER_START}\\
define('DISALLOW_FILE_EDIT', true);\\
define('DISALLOW_FILE_MODS', true);\\
define('AUTOMATIC_UPDATER_DISABLED', true);\\
${WPCONFIG_MARKER_END}\\
" "$wpconfig"
        else
            echo "" >> "$wpconfig"
            echo "$block" >> "$wpconfig"
        fi
        success "Injected CODE FREEZE constants into wp-config.php"
    fi
}

remove_wpconfig_constants() {
    local wpconfig="$1"

    if ! grep -q "CODE FREEZE" "$wpconfig" 2>/dev/null; then
        info "wp-config.php constants not present — skipping"
        return
    fi

    if [ "$DRY_RUN" = true ]; then
        dry "Would remove CODE FREEZE constants from $wpconfig"
    else
        # Remove lines between and including sentinel markers
        sed -i "/CODE FREEZE — managed by wp-freeze\.sh/,/END CODE FREEZE/d" "$wpconfig"
        success "Removed CODE FREEZE constants from wp-config.php"
    fi
}

inject_uploads_htaccess() {
    local uploads_dir="$1"
    local htaccess="$uploads_dir/.htaccess"

    mkdir -p "$uploads_dir" 2>/dev/null || true

    if [ -f "$htaccess" ] && grep -q "CODE FREEZE" "$htaccess" 2>/dev/null; then
        info "uploads/.htaccess PHP block already present — skipping"
        return
    fi

    local block
    block=$(printf '%s\n<FilesMatch "\\.php$">\n    Order Allow,Deny\n    Deny from all\n</FilesMatch>\n%s\n' \
        "$FREEZE_MARKER_START" "$FREEZE_MARKER_END")

    if [ "$DRY_RUN" = true ]; then
        dry "Would inject PHP execution block into $htaccess"
    else
        echo "" >> "$htaccess"
        printf '%s\n<FilesMatch "\\.php$">\n    Order Allow,Deny\n    Deny from all\n</FilesMatch>\n%s\n' \
            "$FREEZE_MARKER_START" "$FREEZE_MARKER_END" >> "$htaccess"
        success "Injected PHP execution block into uploads/.htaccess"
    fi
}

remove_uploads_htaccess_block() {
    local htaccess="$1/wp-content/uploads/.htaccess"

    if [ ! -f "$htaccess" ] || ! grep -q "CODE FREEZE" "$htaccess" 2>/dev/null; then
        info "uploads/.htaccess PHP block not present — skipping"
        return
    fi

    if [ "$DRY_RUN" = true ]; then
        dry "Would remove CODE FREEZE block from $htaccess"
    else
        sed -i "/CODE FREEZE — managed by wp-freeze\.sh/,/END CODE FREEZE/d" "$htaccess"
        # Remove any trailing blank lines we left
        sed -i '/^$/N;/^\n$/d' "$htaccess" || true
        success "Removed CODE FREEZE block from uploads/.htaccess"
    fi
}

deploy_muplugin() {
    local site_path="$1"
    local muplugins_dir="$site_path/wp-content/mu-plugins"
    local plugin_file="$muplugins_dir/code-freeze.php"

    if [ "$DRY_RUN" = true ]; then
        dry "Would create $plugin_file"
        return
    fi

    mkdir -p "$muplugins_dir"
    echo "$MUPLUGIN_CONTENT" > "$plugin_file"
    success "Deployed code-freeze.php mu-plugin"
}

remove_muplugin() {
    local site_path="$1"
    local plugin_file="$site_path/wp-content/mu-plugins/code-freeze.php"

    if [ ! -f "$plugin_file" ]; then
        info "code-freeze.php mu-plugin not present — skipping"
        return
    fi

    if [ "$DRY_RUN" = true ]; then
        dry "Would delete $plugin_file"
    else
        rm -f "$plugin_file"
        success "Removed code-freeze.php mu-plugin"
    fi
}

freeze_permissions() {
    local site_path="$1"

    if [ "$DRY_RUN" = true ]; then
        dry "Would chmod core dirs to 555 and files to 444 (excluding wp-content/uploads/)"
        dry "Would chmod wp-config.php to 440"
        dry "Would chmod .htaccess to 444"
        return
    fi

    # Core WordPress dirs and files (exclude uploads)
    find "$site_path" \
        -not \( -path "$site_path/wp-content/uploads" -prune \) \
        -not \( -path "$site_path/wp-content/uploads/*" -prune \) \
        -type d -exec chmod 555 {} \;

    find "$site_path" \
        -not \( -path "$site_path/wp-content/uploads" -prune \) \
        -not \( -path "$site_path/wp-content/uploads/*" -prune \) \
        -type f -exec chmod 444 {} \;

    # wp-config.php: owner+group read only, no others
    [ -f "$site_path/wp-config.php" ] && chmod 440 "$site_path/wp-config.php"

    success "Set filesystem to read-only (444/555), uploads/ excluded"
}

restore_permissions() {
    local site_path="$1"

    if [ "$DRY_RUN" = true ]; then
        dry "Would restore dirs to 755 and files to 644"
        dry "Would restore wp-config.php to 640"
        return
    fi

    find "$site_path" -type d -exec chmod 755 {} \;
    find "$site_path" -type f -exec chmod 644 {} \;

    [ -f "$site_path/wp-config.php" ] && chmod 640 "$site_path/wp-config.php"

    # Ensure uploads stays writable by web process
    [ -d "$site_path/wp-content/uploads" ] && \
        find "$site_path/wp-content/uploads" -type d -exec chmod 755 {} \; && \
        find "$site_path/wp-content/uploads" -type f -exec chmod 644 {} \;

    success "Restored filesystem permissions (644/755)"
}

# --- Actions ---

do_freeze() {
    local site_path="$1"
    local app_name
    app_name=$(basename "$site_path")

    echo ""
    echo "=== Freezing: $app_name ==="

    if is_frozen "$site_path"; then
        warn "$app_name is already frozen — skipping"
        return
    fi

    if [ ! -f "$site_path/wp-config.php" ]; then
        warn "$app_name: wp-config.php not found — is this a WordPress site? Skipping."
        return
    fi

    # 1. Deploy mu-plugin first (while files are still writable)
    deploy_muplugin "$site_path"

    # 2. Inject wp-config.php constants
    inject_wpconfig_constants "$site_path/wp-config.php"

    # 3. Inject uploads/.htaccess PHP block
    inject_uploads_htaccess "$site_path/wp-content/uploads"

    # 4. Freeze filesystem permissions (last — locks everything including the mu-plugin)
    freeze_permissions "$site_path"

    success "$app_name: FROZEN"
}

do_unfreeze() {
    local site_path="$1"
    local app_name
    app_name=$(basename "$site_path")

    echo ""
    echo "=== Unfreezing: $app_name ==="

    if ! is_frozen "$site_path"; then
        warn "$app_name is not frozen — skipping"
        return
    fi

    # 1. Restore filesystem permissions first (so we can edit files again)
    restore_permissions "$site_path"

    # 2. Remove mu-plugin
    remove_muplugin "$site_path"

    # 3. Remove wp-config.php constants
    remove_wpconfig_constants "$site_path/wp-config.php"

    # 4. Remove uploads/.htaccess PHP block
    remove_uploads_htaccess_block "$site_path"

    success "$app_name: UNFROZEN"
}

do_status() {
    local site_path="$1"
    local app_name
    app_name=$(basename "$site_path")

    if [ ! -f "$site_path/wp-config.php" ]; then
        echo "  $app_name: NOT A WORDPRESS SITE"
        return
    fi

    if is_frozen "$site_path"; then
        echo -e "  ${RED}[FROZEN]${NC}   $app_name"
        # Show what's active
        [ -f "$site_path/wp-content/mu-plugins/code-freeze.php" ] && \
            echo "             mu-plugin: present"
        [ -f "$site_path/wp-content/uploads/.htaccess" ] && \
            grep -q "CODE FREEZE" "$site_path/wp-content/uploads/.htaccess" 2>/dev/null && \
            echo "             uploads PHP block: present"
        local wp_perm
        wp_perm=$(stat -c "%a" "$site_path/wp-config.php" 2>/dev/null || stat -f "%Lp" "$site_path/wp-config.php" 2>/dev/null)
        echo "             wp-config.php: $wp_perm"
    else
        echo -e "  ${GREEN}[UNFROZEN]${NC} $app_name"
    fi
}

# --- Main ---

if [ "$DRY_RUN" = true ]; then
    echo -e "${YELLOW}=== DRY RUN MODE — no changes will be made ===${NC}"
fi

run_on_site() {
    local site_path="$1"
    case "$ACTION" in
        freeze)   do_freeze "$site_path" ;;
        unfreeze) do_unfreeze "$site_path" ;;
        status)   do_status "$site_path" ;;
    esac
}

if [ -n "$TARGET_SITE" ]; then
    SITE_PATH="$WEBROOT/$TARGET_SITE"
    if [ ! -d "$SITE_PATH" ]; then
        error "Site '$TARGET_SITE' not found in $WEBROOT"
        exit 1
    fi
    run_on_site "$SITE_PATH"
else
    if [ "$ACTION" = "status" ]; then
        echo "=== Code Freeze Status — All Sites ==="
    fi
    for site in "$WEBROOT"/*/; do
        [ -d "$site" ] && run_on_site "$site"
    done
fi

echo ""
