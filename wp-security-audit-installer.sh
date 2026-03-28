#!/bin/bash
#
# WordPress Security Audit Installer
# Installs required packages and sets up environment
# Run as root: sudo ./wp-security-audit-installer.sh

echo "=== WP Security Audit Installer ==="

# Update package list
echo "[+] Updating package list..."
apt-get update -y

# Install ClamAV and daemon
echo "[+] Installing ClamAV..."
apt-get install -y clamav clamav-daemon

# Install Rkhunter
echo "[+] Installing Rkhunter..."
apt-get install -y rkhunter

# Install Chkrootkit
echo "[+] Installing Chkrootkit..."
apt-get install -y chkrootkit

# Update ClamAV database
echo "[+] Updating ClamAV virus database..."
freshclam

# Ensure log directory exists
echo "[+] Creating log directory /var/log/webapps..."
mkdir -p /var/log/webapps
chmod 755 /var/log/webapps

echo "=== Installation complete ==="
echo "You can now run wp-security-audit.sh to perform audits."
