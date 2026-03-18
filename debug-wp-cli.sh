#!/bin/bash

# Configuration
BASE_PATH="/home/runcloud/webapps"

# Parse arguments
for i in "$@"; do
  case $i in
    --site=*)
      SITE_NAME="${i#*=}"
      shift
      ;;
  esac
done

# 1. Validation
if [ -z "$SITE_NAME" ]; then
    echo -e "\033[1;31mUsage: wp-check --site=\"sitename\"\033[0m"
    exit 1
fi

FULL_PATH="$BASE_PATH/$SITE_NAME"

if [ ! -d "$FULL_PATH" ]; then
    echo -e "\033[1;31mError: Directory $FULL_PATH not found.\033[0m"
    exit 1
fi

# 2. Permission Handling
# Get the owner of the index.php file (or the folder) to run as the correct user
SITE_OWNER=$(stat -c '%U' "$FULL_PATH")
CURRENT_USER=$(whoami)

# Prepare the WP command base
# If we are root, we sudo to the site owner. If we are already the owner, run normally.
if [ "$CURRENT_USER" = "root" ]; then
    WP_CMD="sudo -u $SITE_OWNER wp --allow-root"
elif [ "$CURRENT_USER" != "$SITE_OWNER" ]; then
    WP_CMD="sudo -u $SITE_OWNER wp"
else
    WP_CMD="wp"
fi

echo -e "\033[1;36mTarget Site: $SITE_NAME\033[0m"
echo -e "\033[1;36mRunning as : $SITE_OWNER\033[0m"
echo -e "\033[1;34m-----------------------------------------\033[0m"

# 3. Main Loop
# Get list of plugins (excluding the ones we skip)
PLUGINS=$($WP_CMD plugin list --field=name --skip-plugins --path="$FULL_PATH")

for plugin in $PLUGINS; do
    echo -n "Testing skip-plugins=$plugin... "
    
    # Run the eval check
    # We capture stderr too in case there's a helpful PHP error message
    output=$($WP_CMD eval 'echo "test";' --skip-plugins="$plugin" --path="$FULL_PATH" 2>/dev/null)
    
    if [ "$output" == "test" ]; then
        echo -e "\033[1;32m[SUCCESS]\033[0m"
        echo -e "\033[1;35m>>> Potential culprit found: $plugin\033[0m"
        echo -e "\033[1;34m-----------------------------------------\033[0m"
        
        read -p "Would you like to deactivate $plugin? (y/n): " confirm
        if [[ $confirm == [yY] ]]; then
            $WP_CMD plugin deactivate "$plugin" --path="$FULL_PATH"
            echo -e "\033[1;32mPlugin deactivated.\033[0m"
        fi
        exit 0
    else
        echo -e "\033[1;31m[STILL FAILING]\033[0m"
    fi
done

echo -e "\033[1;33mScan complete. No single plugin skip resolved the issue.\033[0m"
