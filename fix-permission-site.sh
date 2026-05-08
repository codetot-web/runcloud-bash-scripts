#!/bin/bash
#
# fix-permission-site.sh — Fix file ownership and permissions for a RunCloud web app
#
# Usage:
#   ./fix-permission-site.sh --site=APPNAME    # fix one site
#   ./fix-permission-site.sh                   # fix all sites
#
# Excluded from chmod (permissions preserved, manual check required):
#   - wp-content/uploads/   (user-uploaded media, may have varying permissions)
#

TARGET_SITE=""

for i in "$@"; do
    case $i in
        --site=*)
            TARGET_SITE="${i#*=}"
            ;;
    esac
done

# fix_permissions: sets ownership to the site's actual owner (panel user 'runcloud'
# or a custom system user), then sets dirs to 755 and files to 644 — excluding
# wp-content/uploads/ which contains user-uploaded media and requires manual review.
#
# Uses `find -exec {} +` to batch paths per chmod call (fast),
# instead of `find -exec {} \;` (one subprocess per file — very slow).
fix_permissions() {
    local dir=$1
    local uploads_dir="$dir/wp-content/uploads"
    local site_owner site_group
    site_owner=$(stat -c '%U' "$dir" 2>/dev/null || echo runcloud)
    [ "$site_owner" = "root" ] && site_owner="runcloud"
    site_group=$(stat -c '%G' "$dir" 2>/dev/null || echo "$site_owner")

    echo "Processing $dir (owner: $site_owner:$site_group) ..."

    # 1. Fix ownership — only if any file is not owned by the site owner (skip if already correct)
    wrong_owner=$(sudo find "$dir" -not -user "$site_owner" -not -group "$site_group" 2>/dev/null | head -1)
    if [ -n "$wrong_owner" ]; then
        echo "  Fixing ownership..."
        sudo chown -R "$site_owner:$site_group" "$dir" || echo "Warning: chown failed for $dir"
    else
        echo "  Ownership OK — skipping chown"
    fi

    # 2. Fix directory permissions — exclude uploads/ (correct prune syntax)
    sudo find "$dir" -path "$uploads_dir" -prune \
        -o -type d -exec chmod 755 {} +

    # 3. Fix file permissions — exclude uploads/ (correct prune syntax)
    sudo find "$dir" -path "$uploads_dir" -prune \
        -o -type f -exec chmod 644 {} +

    # 4. Ensure uploads/ itself is accessible (755) but don't recurse
    if [ -d "$uploads_dir" ]; then
        sudo chmod 755 "$uploads_dir"
        echo "  Note: $uploads_dir excluded from recursive chmod — check manually if needed"
    fi

    echo "Done with $dir"
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
        fix_permissions "$SITE_PATH"
    else
        echo "Error: Site '$TARGET_SITE' not found under /home/*/webapps/"
        exit 1
    fi
else
    for site in /home/*/webapps/*/; do
        [ -d "$site" ] && fix_permissions "$site"
    done
fi
