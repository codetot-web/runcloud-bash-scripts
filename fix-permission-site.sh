#!/bin/bash
WEBROOT="/home/runcloud/webapps"
TARGET_SITE=""

# Parse arguments
for i in "$@"; do
    case $i in
        --site=*)
            TARGET_SITE="${i#*=}"
            shift
            ;;
        *)
            # Unknown option
            ;;
    esac
done

# Define the function to apply permissions
fix_permissions() {
    local dir=$1
    echo "Processing $dir ..."
    sudo chown -R runcloud:runcloud "$dir" || echo "Failed to chown $dir"
    find "$dir" -type d -exec sudo chmod 755 {} \;
    find "$dir" -type f -exec sudo chmod 644 :
    echo "Done with $dir"
}

if [ -n "$TARGET_SITE" ]; then
    # Run only for the specific site
    SITE_PATH="$WEBROOT/$TARGET_SITE"
    if [ -d "$SITE_PATH" ]; then
        fix_permissions "$SITE_PATH"
    else
        echo "Error: Site $TARGET_SITE not found in $WEBROOT"
        exit 1
    fi
else
    # Original loop for all sites
    for site in "$WEBROOT"/*; do
        if [ -d "$site" ]; then
            fix_permissions "$site"
        fi
    done
fi
