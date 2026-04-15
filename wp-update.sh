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
#   --dry-run            Show what would be updated without applying
#   --no-git             Skip git checks (not recommended)
#

set -euo pipefail

WEBROOT="/home/runcloud/webapps"
SITE=""
ACTION=""
EXCLUDE=""
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
        --exclude=*) EXCLUDE="${i#*=}" ;;
        --dry-run)   DRY_RUN=true ;;
        --no-git)    NO_GIT=true ;;
        --help|-h)
            awk 'NR==1{next} /^[^#]/{exit} {sub(/^# ?/,""); print}' "$0"
            exit 0
            ;;
        *) error "Unknown option: $i"; exit 1 ;;
    esac
done

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

    for plugin in $AVAILABLE; do
        # Check blacklist
        skip=false
        for excluded in "${EXCLUDE_LIST[@]}"; do
            excluded=$(echo "$excluded" | xargs) # trim whitespace
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

        if [ "$DRY_RUN" = true ]; then
            info "[dry-run] Would update: $plugin"
            UPDATED=$((UPDATED + 1))
            continue
        fi

        info "Updating: $plugin"
        if $WP plugin update "$plugin" 2>&1; then
            success "Updated: $plugin"
            UPDATED=$((UPDATED + 1))
        else
            error "Failed: $plugin"
            FAILED=$((FAILED + 1))
        fi
    done

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

    if [ "$DRY_RUN" = true ]; then
        $WP theme list --update=available --format=table 2>/dev/null || success "All themes up to date"
        return 0
    fi

    OUTPUT=$($WP theme update --all 2>&1 || true)
    echo "$OUTPUT"
    if echo "$OUTPUT" | grep -q "Success"; then
        success "Themes updated"
    elif echo "$OUTPUT" | grep -q "already up to date"; then
        success "All themes are up to date"
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
