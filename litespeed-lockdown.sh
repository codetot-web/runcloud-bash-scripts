#!/bin/bash
# litespeed-lockdown.sh — Block PHP execution in wp-content/uploads for all sites
# vn06 version - RunCloud OpenLiteSpeed
# Run on each server after git pull

set -euo pipefail

for site_dir in /home/*/webapps/*/; do
  [ -d "$site_dir" ] || continue
  appname=$(basename "$site_dir")
  conf="/etc/lsws-rc/extra.d/${appname}.rewrite.lockdown.conf"
  [ -f "$conf" ] && continue
  echo "Creating $conf"
  cat > "$conf" << "CONF"
# Block PHP execution in uploads
RewriteCond %{REQUEST_URI} /wp-content/uploads/.*\.php [NC]
RewriteRule .* - [F,L]
CONF
done

echo "Restarting Litespeed..."
/usr/local/lsws/bin/lswsctrl restart 2>&1
echo "Done."
