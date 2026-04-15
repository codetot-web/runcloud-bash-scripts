#!/bin/bash
#
# fix-permission-site.sh — Fix file ownership and permissions for a RunCloud web app
#
# Usage:
#   ./fix-permission-site.sh --site=APPNAME    # fix one site
#   ./fix-permission-site.sh                   # fix all sites
#

WEBROOT="/home/runcloud/webapps"
TARGET_SITE=""

for i in "$@"; do
    case $i in
        --site=*)
            TARGET_SITE="${i#*=}"
            ;;
    esac
done

# fix_permissions: sets ownership to runcloud:runcloud,
# directories to 755, files to 644.
# Uses `find -exec {} +` to batch paths per chmod call (fast),
# instead of `find -exec {} \;` (one subprocess per file — very slow on large sites).
fix_permissions() {
    local dir=$1
    echo "Processing $dir ..."
    sudo chown -R runcloud:runcloud "$dir" || echo "Warning: chown failed for $dir"
    sudo find "$dir" -type d -exec chmod 755 {} +
    sudo find "$dir" -type f -exec chmod 644 {} +
    echo "Done with $dir"
}

if [ -n "$TARGET_SITE" ]; then
    SITE_PATH="$WEBROOT/$TARGET_SITE"
    if [ -d "$SITE_PATH" ]; then
        fix_permissions "$SITE_PATH"
    else
        echo "Error: Site '$TARGET_SITE' not found in $WEBROOT"
        exit 1
    fi
else
    for site in "$WEBROOT"/*/; do
        [ -d "$site" ] && fix_permissions "$site"
    done
fi
