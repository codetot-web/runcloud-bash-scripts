#!/bin/bash
# Automated ionCube Loader installation for OpenLiteSpeed PHP versions
# Auto-detects extension directories instead of hardcoding

set -e

IONCUBE_URL="https://downloads.ioncube.com/loader_downloads/ioncube_loaders_lin_x86-64.tar.gz"
TMP_DIR="/tmp/ioncube"
LSWS_DIR="/usr/local/lsws"

# Step 1: Download ionCube loaders
echo "Downloading ionCube loaders..."
rm -rf $TMP_DIR
mkdir -p $TMP_DIR
cd $TMP_DIR
wget -q $IONCUBE_URL -O ioncube.tar.gz
tar -zxf ioncube.tar.gz --strip-components=1

# Step 2: Loop through installed lsphp versions
for phpdir in ${LSWS_DIR}/lsphp*; do
  ver=$(basename "$phpdir" | sed 's/lsphp//')   # e.g. 81, 82, 83, 84
  major=$(echo $ver | cut -c1)                  # first digit (8)
  minor=$(echo $ver | cut -c2-)                 # second digit(s) (1,2,3,4)

  # Detect extension directory dynamically
  ext_dir=$(ls -d ${phpdir}/lib/php/* | head -n1)
  ini_dir="${phpdir}/etc/php/${major}.${minor}/mods-available"
  loader_file="${TMP_DIR}/ioncube_loader_lin_${major}.${minor}.so"

  if [[ -f "$loader_file" ]]; then
    echo "Installing ionCube for PHP ${major}.${minor}..."
    cp "$loader_file" "$ext_dir/"
    mkdir -p "$ini_dir"
    echo "zend_extension=$(basename $loader_file)" > "$ini_dir/ioncube.ini"
  else
    echo "⚠️ Skipping PHP ${major}.${minor}: loader file not found."
  fi
done

# Step 3: Restart OpenLiteSpeed services
echo "Restarting OpenLiteSpeed services..."
systemctl restart lsws-rc
killall lsphp || true

# Step 4: Verify installation
echo "Verifying ionCube installation..."
for phpdir in ${LSWS_DIR}/lsphp*; do
  ver=$(basename "$phpdir" | sed 's/lsphp//')
  "${phpdir}/bin/php" -m | grep -i ioncube || echo "ionCube not loaded for PHP ${ver}"
done

echo "✅ ionCube installation completed for all detected PHP versions."
