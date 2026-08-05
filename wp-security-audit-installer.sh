#!/bin/bash
#
# WordPress Security Audit Installer
# Sets up environment for wp-security-audit.sh (fast pattern scan)
# Run as root: sudo ./wp-security-audit-installer.sh
#
# NOTE: ClamAV/rootkit tools (clamav, rkhunter, chkrootkit) are NO LONGER
# installed — the deep scan was removed (2026-08-05) because it causes high
# CPU load on production servers. wp-security-audit.sh now runs fast pattern
# detection only, which needs no extra packages.

echo "=== WP Security Audit Installer ==="

# Ensure log directory exists
echo "[+] Creating log directory /var/log/webapps..."
mkdir -p /var/log/webapps
chmod 755 /var/log/webapps

echo "=== Installation complete ==="
echo "You can now run wp-security-audit.sh to perform audits."