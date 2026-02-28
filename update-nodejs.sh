#!/bin/bash
#
# ============================================================
# Node.js Update Script (RunCloud Guide)
# ============================================================
# Usage:
#   1. Download a script
#        wget https://github.com/codetot-web/runcloud-bash-scripts/raw/refs/heads/main/update-nodejs.sh
#   2. Make it executable:
#        chmod +x update-node.sh
#   3. Run the script:
#        ./update-node.sh
#
# Description:
#   - This script updates Node.js to a user-specified version.
#   - It prompts you to enter the desired Node.js version (e.g., 20, 22).
#   - It removes any existing Node.js installation.
#   - It installs the requested version using NodeSource repositories.
#   - Finally, it verifies the installation by printing the installed
#     Node.js and npm versions.
#
# Notes:
#   - Requires sudo privileges.
#   - Works on Debian/Ubuntu-based systems.
#   - Example input: "20" will install Node.js v20.x.
#
# ============================================================

# Prompt user for desired Node.js version
read -p "Enter the Node.js version you want to install (e.g., 20, 22): " NODE_VERSION

# Validate input
if [[ -z "$NODE_VERSION" ]]; then
  echo "No version entered. Exiting."
  exit 1
fi

echo "Updating Node.js to version $NODE_VERSION..."

# Update package index
sudo apt update

# Install prerequisites
sudo apt install -y curl software-properties-common

# Remove old Node.js if installed
sudo apt remove -y nodejs

# Add NodeSource repository for chosen version
curl -fsSL https://deb.nodesource.com/setup_$NODE_VERSION.x | sudo -E bash -

# Install Node.js
sudo apt install -y nodejs

# Verify installation
echo "Node.js version installed:"
node -v
echo "npm version installed:"
npm -v

echo "Update complete!"
