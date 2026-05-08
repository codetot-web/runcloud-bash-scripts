#!/bin/bash
#
# fix-permission.sh — Fix ownership and permissions on every web app on the server.
#
# Iterates /home/*/webapps/*/ so it handles both panel-managed apps under
# /home/runcloud/webapps/ and webapps owned by custom system users (any /home/<user>/webapps/).
# The owner of each app is detected from the directory itself, not hardcoded.
#

for site in /home/*/webapps/*/; do
    [ -d "$site" ] || continue
    site_owner=$(stat -c '%U' "$site" 2>/dev/null || echo runcloud)
    [ "$site_owner" = "root" ] && site_owner="runcloud"
    site_group=$(stat -c '%G' "$site" 2>/dev/null || echo "$site_owner")

    echo "Processing $site (owner: $site_owner:$site_group) ..."
    sudo chown -R "$site_owner:$site_group" "$site" || echo "Failed to chown $site"
    find "$site" -type d -exec sudo chmod 755 {} \;
    find "$site" -type f -exec sudo chmod 644 {} \;
    echo "Done with $site"
done
