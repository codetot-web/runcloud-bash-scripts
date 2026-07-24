#!/bin/bash
# Automated ionCube Loader installation for:
#   - OpenLiteSpeed (lsws)
#   - RunCloud/nginx (PHP-FPM via RunCloud rc packages)
#   - Standard PHP-FPM (Ondrej PPA / litesoup / vanilla Ubuntu)
#
# Detects which PHP installations exist and installs for each.

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
  systemctl restart lsws-rc 2>/dev/null || true
  killall lsphp 2>/dev/null || true

  echo "Verifying OpenLiteSpeed installation..."
  for phpdir in ${LSWS_DIR}/lsphp*; do
    ver=$(basename "$phpdir" | sed 's/lsphp//')
    "${phpdir}/bin/php" -m 2>/dev/null | grep -i ioncube || echo "ionCube not loaded for PHP ${ver}"
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
      systemctl restart php${ver}rc-fpm 2>/dev/null || true
    else
      echo "⚠️ Skipping RunCloud PHP ${major}.${minor}: loader not found."
    fi
  done

  echo "Verifying RunCloud/nginx installation..."
  for phpdir in /RunCloud/Packages/php*rc; do
    ver=$(basename "$phpdir" | sed 's/php//;s/rc//')
    "/RunCloud/Packages/php${ver}rc/bin/php" -m 2>/dev/null | grep -i ioncube || echo "ionCube not loaded for PHP ${ver}rc"
  done
}

##############################################
# Function: Install ionCube for standard PHP
# (Ondrej PPA, vanilla Ubuntu, litesoup/Apache)
##############################################
install_standard() {
  # Detect standard PHP installations by looking for php-fpm services
  # (e.g. php8.3-fpm, php8.2-fpm, php8.1-fpm)
  for service in $(systemctl list-units --type=service --state=running 2>/dev/null \
    | grep -oP 'php[0-9]+\.[0-9]+-fpm' \
    | sort -u); do
    ver="${service%-fpm}"  # e.g. php8.3
    major="${ver#php}"     # e.g. 8.3
    major_digit="${major%.*}"
    minor_digit="${major#*.}"

    # Find extension directory via php-config (works for Ondrej PPA)
    php_config="/usr/bin/php-config${major}"
    if [ ! -x "$php_config" ]; then
      echo "⚠️ Skipping standard PHP ${major}: php-config${major} not found."
      continue
    fi
    ext_dir="$($php_config --extension-dir 2>/dev/null)" || continue

    loader_file="${TMP_DIR}/ioncube_loader_lin_${major_digit}.${minor_digit}.so"
    if [[ ! -f "$loader_file" ]]; then
      echo "⚠️ Skipping standard PHP ${major}: loader not found (${loader_file})."
      continue
    fi

    echo "Installing ionCube for standard PHP ${major}..."
    cp "$loader_file" "$ext_dir/"

    # Write ini to mods-available and enable via phpenmod
    ini_file="/etc/php/${major}/mods-available/ioncube.ini"
    mkdir -p "$(dirname "$ini_file")"
    echo "zend_extension=ioncube_loader_lin_${major_digit}.${minor_digit}.so" > "$ini_file"

    # Enable for both cli and fpm SAPIs
    phpenmod -v "${major}" -s cli ioncube 2>/dev/null || true
    phpenmod -v "${major}" -s fpm ioncube 2>/dev/null || true

    # Reload FPM (not restart — preserves connections)
    systemctl reload "${service}" 2>/dev/null || systemctl restart "${service}" 2>/dev/null || true
  done

  echo "Verifying standard PHP installation..."
  for service in $(systemctl list-units --type=service --state=running 2>/dev/null \
    | grep -oP 'php[0-9]+\.[0-9]+-fpm' \
    | sort -u); do
    ver="${service%-fpm}"
    # Use the FPM binary or fallback to CLI binary
    php_bin="/usr/bin/php${ver#php}"
    if [ -x "$php_bin" ]; then
      "$php_bin" -m 2>/dev/null | grep -i ioncube || echo "ionCube not loaded for PHP ${ver#php}"
    fi
  done
}

##############################################
# Run all installers if directories exist
##############################################
if ls /usr/local/lsws/lsphp* >/dev/null 2>&1; then
  install_lsws
fi

if ls /RunCloud/Packages/php*rc >/dev/null 2>&1; then
  install_runcloud
fi

# Standard PHP (Ondrej PPA / litesoup) — detect by php-fpm services
if systemctl list-units --type=service --state=running 2>/dev/null \
   | grep -qP 'php[0-9]+\.[0-9]+-fpm'; then
  install_standard
fi

echo "✅ ionCube installation completed for all detected PHP versions."
