#!/bin/bash

# Example run: ./debug-wp-cli.sh --site="abc"

# Default base path
BASE_PATH="/home/runcloud/webapps"

# Parse arguments
for i in "$@"; do
  case $i in
    --site=*)
      SITE_NAME="${i#*=}"
      shift
      ;;
    *)
      ;;
  esac
done

# Check if site name was provided
if [ -z "$SITE_NAME" ]; then
    echo -e "\033[1;31mError: Missing --site=\"name\" argument.\033[0m"
    exit 1
fi

FULL_PATH="$BASE_PATH/$SITE_NAME"

# Check if the directory exists
if [ ! -d "$FULL_PATH" ]; then
    echo -e "\033[1;31mError: Directory $FULL_PATH not found.\033[0m"
    exit 1
fi

echo -e "\033[1;36mScanning site: $SITE_NAME at $FULL_PATH\033[0m"

# Main Loop
# We use --path to target the specific directory globally
for plugin in $(wp plugin list --field=name --skip-plugins --path="$FULL_PATH"); do
    echo -e "\033[1;34m-----------------------------------------\033[0m"
    echo -e "\033[1;33mTesting with --skip-plugins=$plugin...\033[0m"
    
    output=$(wp eval 'echo "test";' --skip-plugins="$plugin" --path="$FULL_PATH" 2>/dev/null)
    
    if [ ! -z "$output" ]; then
        echo -e "\033[1;32mSuccess! Output: $output\033[0m"
        echo -e "\033[1;35mProblem likely caused by: $plugin\033[0m"
        echo -e "\033[1;34m-----------------------------------------\033[0m"
        exit 0 # Found it, we can stop entirely
    else
        echo -e "\033[1;31mNo output. Moving to the next plugin.\033[0m"
    fi
done

echo -e "\033[1;32mFinished scanning all plugins.\033[0m"
