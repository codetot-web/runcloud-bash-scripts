#!/bin/bash
WEBROOT="/home/runcloud/webapps"

for site in "$WEBROOT"/*; do
    if [ -d "$site" ]; then
        echo "Processing $site ..."
        sudo chown -R runcloud:runcloud "$site" || echo "Failed to chown $site"
        find "$site" -type d -exec sudo chmod 755 {} \;
        find "$site" -type f -exec sudo chmod 644 {} \;
        echo "Done with $site"
    fi
done
