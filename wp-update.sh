#!/bin/bash
#
# wp-update.sh — WordPress update manager for RunCloud servers
#
# Updates WordPress plugins, themes, or core with blacklist support.
# Only runs on git-tracked projects (uncommitted changes = abort).
#
# Usage:
#   ./wp-update.sh --site=APPNAME --action=plugins                    # update all plugins
#   ./wp-update.sh --site=APPNAME --action=plugins --exclude=acf-pro,gravityforms
#   ./wp-update.sh --site=APPNAME --action=themes                     # update all themes
#   ./wp-update.sh --site=APPNAME --action=core                       # update WordPress core
#   ./wp-update.sh --site=APPNAME --action=all                        # plugins + themes + core
#   ./wp-update.sh --site=APPNAME --action=plugins --dry-run          # show what would update
#   ./wp-update.sh --site=APPNAME --action=status                     # show pending updates
#
# Options:
#   --site=NAME          Required. Web app name under /home/runcloud/webapps/
#   --action=ACTION      Required. One of: plugins, themes, core, all, status
#   --exclude=LIST       Comma-separated plugin slugs to skip (only for plugins action)
#   --exclude-themes=LIST  Comma-separated theme slugs to skip (only for themes action)
#   --skip-themes        Skip ALL theme updates
#   --dry-run            Show what would be updated without applying
#   --no-git             Skip git checks (not recommended)
#

set -euo pipefail

WEBROOT="/home/runcloud/webapps"
SITE=""
ACTION=""
EXCLUDE=""
EXCLUDE_THEMES=""
SKIP_THEMES=false
DRY_RUN=false
NO_GIT=false

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

# --- Parse arguments ---
for i in "$@"; do
    case $i in
        --site=*)    SITE="${i#*=}" ;;
        --action=*)  ACTION="${i#*=}" ;;
        --exclude=*)        EXCLUDE="${i#*=}" ;;
        --exclude-themes=*) EXCLUDE_THEMES="${i#*=}" ;;
        --skip-themes)      SKIP_THEMES=true ;;
        --dry-run)          DRY_RUN=true ;;
        --no-git)           NO_GIT=true ;;
        --help|-h)
            awk 'NR==1{next} /^[^#]/{exit} {sub(/^# ?/,""); print}' "$0"
            exit 0
            ;;
        *) error "Unknown option: $i"; exit 1 ;;
    esac
done

# --- Validate slug lists (only allow alphanumeric, hyphens, underscores, commas) ---
validate_slug_list() {
    local name="$1" value="$2"
    if [ -n "$value" ] && [[ ! "$value" =~ ^[a-zA-Z0-9_,\ -]+$ ]]; then
        error "$name contains invalid characters (allowed: a-z, 0-9, _, -, comma)"
        exit 1
    fi
}
validate_slug_list "--exclude" "$EXCLUDE"
validate_slug_list "--exclude-themes" "$EXCLUDE_THEMES"

# --- Validate ---
if [ -z "$SITE" ] || [ -z "$ACTION" ]; then
    error "--site and --action are required. Use --help for usage."
    exit 1
fi

SITE_PATH="$WEBROOT/$SITE"
if [ ! -d "$SITE_PATH" ]; then
    error "Site '$SITE' not found at $SITE_PATH"
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

# Detect site owner — run wp-cli as the correct user, not root
SITE_OWNER=$(stat -c '%U' "$SITE_PATH" 2>/dev/null || stat -f '%Su' "$SITE_PATH" 2>/dev/null || echo "runcloud")
if [ "$SITE_OWNER" = "root" ]; then
    SITE_OWNER="runcloud"
fi
info "Site owner: $SITE_OWNER"

if [ "$(whoami)" = "$SITE_OWNER" ]; then
    WP="$WP_CLI --path=$SITE_PATH"
else
    WP="sudo -u $SITE_OWNER $WP_CLI --path=$SITE_PATH"
fi

# --- Detect site PHP version (FPM/LSPHP, not CLI) ---
# RunCloud uses per-site FPM pools or LiteSpeed LSAPI.
# The CLI php -v may differ from the web PHP version, causing compatibility issues.
SITE_PHP_VERSION=""
SITE_PHP_BIN=""

# Method 1: nginx + PHP-FPM pools (/etc/phpXYrc/fpm.d/SITE.conf)
for phpdir in /etc/php85rc /etc/php84rc /etc/php83rc /etc/php82rc /etc/php81rc /etc/php80rc /etc/php74rc /etc/php73rc /etc/php72rc; do
    if [ -f "$phpdir/fpm.d/$SITE.conf" ]; then
        ver=$(basename "$phpdir" | sed 's/^php//;s/rc$//' | sed 's/\(.\)\(.\)/\1.\2/')
        SITE_PHP_VERSION="$ver"
        break
    fi
done

# Method 2: OpenLiteSpeed LSAPI (grep lsphp path from vhost config)
if [ -z "$SITE_PHP_VERSION" ]; then
    lsphp_path=$(grep -r 'lsphp' /etc/lsws-rc/conf.d/"$SITE".d/ /etc/lsws-rc/conf.d/"$SITE".vhosts.d/ 2>/dev/null | grep -oP '/usr/local/lsws/lsphp\K[0-9]+' | head -1 || true)
    if [ -n "$lsphp_path" ]; then
        SITE_PHP_VERSION=$(echo "$lsphp_path" | sed 's/\(.\)\(.\)/\1.\2/')
    fi
fi

# Method 3: create a temp PHP file and curl it via the site's domain
# This tests the actual PHP version the web server uses (most reliable).
if [ -z "$SITE_PHP_VERSION" ]; then
    _ver_file="$SITE_PATH/.php-version-check-$$-$(date +%s).php"
    echo '<?php echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' > "$_ver_file"
    chown "$SITE_OWNER":"$SITE_OWNER" "$_ver_file" 2>/dev/null || true
    _ver_filename=$(basename "$_ver_file")
    # Detect site URL from wp-config or wp-cli
    _site_url=$($WP option get siteurl 2>/dev/null || grep -oP "define\s*\(\s*'WP_SITEURL'\s*,\s*'\\K[^']+" "$SITE_PATH/wp-config.php" 2>/dev/null || true)
    if [ -n "$_site_url" ]; then
        _web_php=$(curl -skL --max-time 5 "${_site_url}/${_ver_filename}" 2>/dev/null || true)
        if [[ "$_web_php" =~ ^[0-9]+\.[0-9]+$ ]]; then
            SITE_PHP_VERSION="$_web_php"
            info "Detected web PHP via HTTP probe: $SITE_PHP_VERSION"
        fi
    fi
    rm -f "$_ver_file" 2>/dev/null || true
fi

# Fallback: use CLI version (WARN: may differ from web PHP)
if [ -z "$SITE_PHP_VERSION" ]; then
    SITE_PHP_VERSION=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || echo "")
    warn "Using CLI PHP version ($SITE_PHP_VERSION) — web PHP may differ!"
fi

# Find the PHP binary matching the detected version (for syntax checks)
if [ -n "$SITE_PHP_VERSION" ]; then
    php_tag=$(echo "$SITE_PHP_VERSION" | tr -d '.')
    # Try RunCloud FPM binary first, then LiteSpeed binary
    for candidate in "/RunCloud/Packages/php${php_tag}rc/bin/php" "/usr/local/lsws/lsphp${php_tag}/bin/php"; do
        if [ -x "$candidate" ]; then
            SITE_PHP_BIN="$candidate"
            break
        fi
    done
    info "Site PHP version (web): $SITE_PHP_VERSION"
fi

# --- Helper: compare version strings (returns 0 if $1 >= $2) ---
version_gte() {
    [ "$(printf '%s\n' "$1" "$2" | sort -V | head -n1)" = "$2" ]
}

# --- Helper: PHP syntax check on a directory ---
# Returns 0 if all PHP files pass, 1 if any parse error found.
# Sets SYNTAX_ERR with the first error message.
php_syntax_check() {
    local dir="$1"
    SYNTAX_ERR=""
    [ -z "$SITE_PHP_BIN" ] && return 0
    [ ! -d "$dir" ] && return 0
    SYNTAX_ERR=$(find "$dir" -name '*.php' -print0 | xargs -0 "$SITE_PHP_BIN" -l 2>&1 | grep -i "parse error" | head -1 || true)
    [ -z "$SYNTAX_ERR" ] && return 0
    return 1
}

# --- Helper: rollback a plugin or theme via git ---
git_rollback() {
    local type="$1" slug="$2"  # type = plugins or themes
    if [ -d "$SITE_PATH/.git" ]; then
        local git_cmd="sudo -u $SITE_OWNER git"
        $git_cmd -C "$SITE_PATH" checkout -- "wp-content/$type/$slug/" 2>/dev/null || true
        success "Rolled back: $slug"
    else
        error "Cannot rollback without git — disable $slug manually!"
    fi
}

# --- Git command setup ---
GIT_CMD="sudo -u $SITE_OWNER git"

# --- Git check ---
if [ "$NO_GIT" = false ] && [ -d "$SITE_PATH/.git" ]; then
    cd "$SITE_PATH"
    # Run git as site owner to avoid "dubious ownership" errors
    GIT_CMD="sudo -u $SITE_OWNER git"
    if ! $GIT_CMD diff --quiet 2>/dev/null || ! $GIT_CMD diff --cached --quiet 2>/dev/null; then
        # Check if it's a real dirty state or just a git ownership error
        status_output=$($GIT_CMD status --short 2>&1)
        if echo "$status_output" | grep -q "dubious ownership"; then
            warn "Git ownership mismatch — adding safe.directory"
            git config --global --add safe.directory "$SITE_PATH" 2>/dev/null || true
            # Retry as root with safe.directory
            if ! git diff --quiet 2>/dev/null; then
                error "Git repo has uncommitted changes. Commit or stash first."
                error "  cd $SITE_PATH && git status"
                exit 1
            fi
        else
            error "Git repo has uncommitted changes. Commit or stash first."
            error "  cd $SITE_PATH && git status"
            exit 1
        fi
    fi
    info "Git status: clean"
fi

# --- Status action ---
show_status() {
    info "WordPress core:"
    $WP core version 2>/dev/null || echo "  (unknown)"
    CORE_UPDATE=$($WP core check-update --format=table 2>/dev/null || true)
    if [ -n "$CORE_UPDATE" ]; then
        echo "$CORE_UPDATE"
    else
        success "Core is up to date"
    fi

    echo ""
    info "Plugins with updates:"
    $WP plugin list --update=available --format=table 2>/dev/null || success "All plugins up to date"

    echo ""
    info "Themes with updates:"
    $WP theme list --update=available --format=table 2>/dev/null || success "All themes up to date"
}

# --- Plugin update ---
update_plugins() {
    info "Checking plugin updates for $SITE..."

    # Get list of plugins with updates
    AVAILABLE=$($WP plugin list --update=available --field=name 2>/dev/null || true)
    if [ -z "$AVAILABLE" ]; then
        success "All plugins are up to date"
        return 0
    fi

    # Build exclude list
    IFS=',' read -ra EXCLUDE_LIST <<< "$EXCLUDE"

    UPDATED=0
    SKIPPED=0
    FAILED=0

    while IFS= read -r plugin; do
        [ -z "$plugin" ] && continue
        # Check blacklist
        skip=false
        for excluded in "${EXCLUDE_LIST[@]}"; do
            excluded="${excluded#"${excluded%%[![:space:]]*}"}"  # trim leading
            excluded="${excluded%"${excluded##*[![:space:]]}"}"  # trim trailing
            if [ -n "$excluded" ] && [ "$plugin" = "$excluded" ]; then
                skip=true
                break
            fi
        done

        if [ "$skip" = true ]; then
            warn "Skipped: $plugin (excluded)"
            SKIPPED=$((SKIPPED + 1))
            continue
        fi

        # Check PHP compatibility before updating
        if [ -n "$SITE_PHP_VERSION" ]; then
            REQUIRES_PHP=$($WP plugin get "$plugin" --field=requires_php 2>/dev/null || true)
            if [ -n "$REQUIRES_PHP" ] && ! version_gte "$SITE_PHP_VERSION" "$REQUIRES_PHP"; then
                warn "Skipped: $plugin (requires PHP $REQUIRES_PHP, site runs $SITE_PHP_VERSION)"
                SKIPPED=$((SKIPPED + 1))
                continue
            fi
        fi

        if [ "$DRY_RUN" = true ]; then
            info "[dry-run] Would update: $plugin"
            UPDATED=$((UPDATED + 1))
            continue
        fi

        info "Updating: $plugin"
        if $WP plugin update "$plugin" 2>&1; then
            # Post-update: verify PHP syntax with site's FPM/LSPHP version
            if ! php_syntax_check "$SITE_PATH/wp-content/plugins/$plugin"; then
                error "PHP $SITE_PHP_VERSION syntax error: $SYNTAX_ERR"
                warn "Rolling back: $plugin"
                git_rollback plugins "$plugin"
                FAILED=$((FAILED + 1))
                continue
            fi
            success "Updated: $plugin"
            UPDATED=$((UPDATED + 1))
        else
            error "Failed: $plugin"
            FAILED=$((FAILED + 1))
        fi
    done <<< "$AVAILABLE"

    echo ""
    if [ "$DRY_RUN" = true ]; then
        info "[dry-run] Would update $UPDATED plugins, skip $SKIPPED"
    else
        info "Updated: $UPDATED, Skipped: $SKIPPED, Failed: $FAILED"
    fi
}

# --- Theme update ---
update_themes() {
    info "Checking theme updates for $SITE..."

    if [ "$SKIP_THEMES" = true ]; then
        warn "Skipped: all theme updates (--skip-themes)"
        return 0
    fi

    # Get list of themes with updates
    AVAILABLE=$($WP theme list --update=available --field=name 2>/dev/null || true)
    if [ -z "$AVAILABLE" ]; then
        success "All themes are up to date"
        return 0
    fi

    # Build exclude list
    IFS=',' read -ra THEME_EXCLUDE_LIST <<< "$EXCLUDE_THEMES"

    UPDATED=0
    SKIPPED=0
    FAILED=0

    while IFS= read -r theme; do
        [ -z "$theme" ] && continue
        # Check exclusion list
        skip=false
        for excluded in "${THEME_EXCLUDE_LIST[@]}"; do
            excluded="${excluded#"${excluded%%[![:space:]]*}"}"  # trim leading
            excluded="${excluded%"${excluded##*[![:space:]]}"}"  # trim trailing
            if [ -n "$excluded" ] && [ "$theme" = "$excluded" ]; then
                skip=true
                break
            fi
        done

        if [ "$skip" = true ]; then
            warn "Skipped: $theme (excluded)"
            SKIPPED=$((SKIPPED + 1))
            continue
        fi

        # Check PHP compatibility before updating
        if [ -n "$SITE_PHP_VERSION" ]; then
            REQUIRES_PHP=$($WP theme get "$theme" --field=requires_php 2>/dev/null || true)
            if [ -n "$REQUIRES_PHP" ] && ! version_gte "$SITE_PHP_VERSION" "$REQUIRES_PHP"; then
                warn "Skipped: $theme (requires PHP $REQUIRES_PHP, site runs $SITE_PHP_VERSION)"
                SKIPPED=$((SKIPPED + 1))
                continue
            fi
        fi

        if [ "$DRY_RUN" = true ]; then
            info "[dry-run] Would update: $theme"
            UPDATED=$((UPDATED + 1))
            continue
        fi

        info "Updating: $theme"
        if $WP theme update "$theme" 2>&1; then
            # Post-update: verify PHP syntax with site's FPM/LSPHP version
            if ! php_syntax_check "$SITE_PATH/wp-content/themes/$theme"; then
                error "PHP $SITE_PHP_VERSION syntax error: $SYNTAX_ERR"
                warn "Rolling back: $theme"
                git_rollback themes "$theme"
                FAILED=$((FAILED + 1))
                continue
            fi
            success "Updated: $theme"
            UPDATED=$((UPDATED + 1))
        else
            error "Failed: $theme"
            FAILED=$((FAILED + 1))
        fi
    done <<< "$AVAILABLE"

    echo ""
    if [ "$DRY_RUN" = true ]; then
        info "[dry-run] Would update $UPDATED themes, skip $SKIPPED"
    else
        info "Updated: $UPDATED, Skipped: $SKIPPED, Failed: $FAILED"
    fi
}

# --- Core update ---
update_core() {
    info "Checking core update for $SITE..."

    CURRENT=$($WP core version 2>/dev/null || echo "unknown")
    info "Current version: $CURRENT"

    if [ "$DRY_RUN" = true ]; then
        $WP core check-update --format=table 2>/dev/null || success "Core is up to date"
        return 0
    fi

    OUTPUT=$($WP core update 2>&1 || true)
    echo "$OUTPUT"
    if echo "$OUTPUT" | grep -q "Success"; then
        NEW=$($WP core version 2>/dev/null || echo "unknown")
        success "Core updated: $CURRENT → $NEW"
        # Run database update
        $WP core update-db 2>&1 || true
    elif echo "$OUTPUT" | grep -q "already up-to-date\|already the latest"; then
        success "Core is already up to date ($CURRENT)"
    fi
}

# --- Git commit after update ---
git_commit() {
    if [ "$NO_GIT" = false ] && [ -d "$SITE_PATH/.git" ] && [ "$DRY_RUN" = false ]; then
        cd "$SITE_PATH"
        if ! git diff --quiet 2>/dev/null; then
            sudo -u "$SITE_OWNER" git add -A 2>/dev/null || git add -A
            sudo -u "$SITE_OWNER" git commit -m "chore: wp-update $ACTION $(date +%Y-%m-%d)" --quiet 2>/dev/null || \
                git commit -m "chore: wp-update $ACTION $(date +%Y-%m-%d)" --quiet 2>/dev/null || true
            success "Changes committed to git (as $SITE_OWNER)"
        else
            info "No changes to commit"
        fi
    fi
}

# --- Main ---
case "$ACTION" in
    status)
        show_status
        ;;
    plugins)
        update_plugins
        git_commit
        ;;
    themes)
        update_themes
        git_commit
        ;;
    core)
        update_core
        git_commit
        ;;
    all)
        update_plugins
        update_themes
        update_core
        git_commit
        ;;
    *)
        error "Unknown action: $ACTION. Use: plugins, themes, core, all, status"
        exit 1
        ;;
esac

echo ""
success "Done with $SITE ($ACTION)"
