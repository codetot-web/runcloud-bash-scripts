#!/bin/bash
# Automated ionCube Loader installation for OpenLiteSpeed and RunCloud/nginx PHP versions

set -e

IONCUBE_URL="https://downloads.ioncube.com/loader_downloads/ioncube_loaders_lin_x86-64.tar.gz"
TMP_DIR="/tmp/ioncube"

echo "Downloading ionCube loaders..."
rm -rf $TMP_DIR
mkdir -p $TMP_DIR
cd $TMP_DIR
wget -q $IONCUBE_URL -O ioncube.tar.gz
tar -zxf ioncube.tar.gz --strip-components=1

##############################################
# Function: Install ionCube for OpenLiteSpeed
##############################################
install_lsws() {
  LSWS_DIR="/usr/local/lsws"
  for phpdir in ${LSWS_DIR}/lsphp*; do
    ver=$(basename "$phpdir" | sed 's/lsphp//')   # e.g. 81, 82, 83, 84
    major=$(echo $ver | cut -c1)
    minor=$(echo $ver | cut -c2-)

    ext_dir=$(ls -d ${phpdir}/lib/php/* | head -n1)
    ini_dir="${phpdir}/etc/php/${major}.${minor}/mods-available"
    loader_file="${TMP_DIR}/ioncube_loader_lin_${major}.${minor}.so"

    if [[ -f "$loader_file" ]]; then
      echo "Installing ionCube for OpenLiteSpeed PHP ${major}.${minor}..."
      cp "$loader_file" "$ext_dir/"
      mkdir -p "$ini_dir"
      echo "zend_extension=$(basename $loader_file)" > "$ini_dir/ioncube.ini"
    else
      echo "⚠️ Skipping OpenLiteSpeed PHP ${major}.${minor}: loader not found."
    fi
  done

  echo "Restarting OpenLiteSpeed services..."
  systemctl restart lsws-rc
  killall lsphp || true

  echo "Verifying OpenLiteSpeed installation..."
  for phpdir in ${LSWS_DIR}/lsphp*; do
    ver=$(basename "$phpdir" | sed 's/lsphp//')
    "${phpdir}/bin/php" -m | grep -i ioncube || echo "ionCube not loaded for PHP ${ver}"
  done
}

##############################################
# Function: Install ionCube for RunCloud/nginx
##############################################
install_runcloud() {
  for phpdir in /RunCloud/Packages/php*rc; do
    ver=$(basename "$phpdir" | sed 's/php//;s/rc//')   # e.g. 81, 82, 83, 84
    major=$(echo $ver | cut -c1)
    minor=$(echo $ver | cut -c2-)

    ext_dir=$(ls -d ${phpdir}/lib/php/extensions/* | head -n1)
    ini_dir="/etc/php${ver}rc/conf.d"
    loader_file="${TMP_DIR}/ioncube_loader_lin_${major}.${minor}.so"

    if [[ -f "$loader_file" ]]; then
      echo "Installing ionCube for RunCloud/nginx PHP ${major}.${minor}..."
      cp "$loader_file" "$ext_dir/"
      mkdir -p "$ini_dir"
      echo "zend_extension=$(basename $loader_file)" > "$ini_dir/ioncube.ini"
      systemctl restart php${ver}rc-fpm
    else
      echo "⚠️ Skipping RunCloud PHP ${major}.${minor}: loader not found."
    fi
  done

  echo "Verifying RunCloud/nginx installation..."
  for phpdir in /RunCloud/Packages/php*rc; do
    ver=$(basename "$phpdir" | sed 's/php//;s/rc//')
    "/RunCloud/Packages/php${ver}rc/bin/php" -m | grep -i ioncube || echo "ionCube not loaded for PHP ${ver}rc"
  done
}

##############################################
# Run both installers if directories exist
##############################################
if ls /usr/local/lsws/lsphp* >/dev/null 2>&1; then
  install_lsws
fi

if ls /RunCloud/Packages/php*rc >/dev/null 2>&1; then
  install_runcloud
fi

echo "✅ ionCube installation completed for all detected PHP versions (OpenLiteSpeed & RunCloud/nginx)."
