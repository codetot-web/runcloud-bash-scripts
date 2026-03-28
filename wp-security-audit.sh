#!/bin/bash
#
# WordPress Security Audit Script
# Usage: wp-security-audit.sh [--folder=/path/to/webapp]
# Logs suspicious findings per webapp folder
# Stops if required packages are missing

DATE=$(date '+%Y-%m-%d %H:%M:%S')

# Default scan path
SCANPATHS="/home/*/webapps/*"

# Parse optional --folder argument
for arg in "$@"; do
  case $arg in
    --folder=*)
      SCANPATHS="${arg#*=}"
      shift
      ;;
  esac
done

# Ensure log directory exists
mkdir -p /var/log/webapps

# --- Check required packages ---
REQUIRED_PKGS=("clamscan" "rkhunter" "chkrootkit")

for pkg in "${REQUIRED_PKGS[@]}"; do
  if ! command -v $pkg >/dev/null 2>&1; then
    echo "ERROR: Required package '$pkg' is not installed. Please run wp-security-audit-installer.sh first."
    exit 1
  fi
done

# --- Run audit ---
for SCANPATH in $SCANPATHS; do
  APPNAME=$(basename "$SCANPATH")
  LOGFILE="/var/log/webapps/${APPNAME}.log"

  echo "========================================" >> $LOGFILE
  echo " WP Security Audit - $DATE " >> $LOGFILE
  echo " Target: $SCANPATH " >> $LOGFILE
  echo "========================================" >> $LOGFILE

  # --- ClamAV scan (excluding cache) ---
  echo "[ClamAV Scan]" >> $LOGFILE
  clamscan -r "$SCANPATH" --bell -i \
    --exclude-dir="^$SCANPATH/wp-content/cache" \
    >> $LOGFILE 2>&1

  # --- Rootkit checks ---
  echo "[Rkhunter]" >> $LOGFILE
  rkhunter --check --sk >> $LOGFILE 2>&1

  echo "[Chkrootkit]" >> $LOGFILE
  chkrootkit >> $LOGFILE 2>&1

  # --- Uploads folder audit: flag non-media files ---
  echo "[Uploads Folder Audit]" >> $LOGFILE
  find "$SCANPATH/wp-content/uploads" \
    -type f ! -regex '.*\.\(jpg\|jpeg\|png\|gif\|svg\|pdf\|docx\|xlsx\|zip\|mp4\|mp3\)$' \
    >> $LOGFILE 2>&1

  # --- Plugin audit: suspicious patterns ---
  echo "[Plugin Audit - base64]" >> $LOGFILE
  grep -R --include="*.php" "base64" "$SCANPATH/wp-content/plugins/" >> $LOGFILE 2>&1

  echo "[Plugin Audit - redirects]" >> $LOGFILE
  grep -R --include="*.php" "wp_redirect" "$SCANPATH/wp-content/plugins/" >> $LOGFILE 2>&1
  grep -R --include="*.php" "header(" "$SCANPATH/wp-content/plugins/" >> $LOGFILE 2>&1
  grep -R --include="*.js" "window.location" "$SCANPATH/wp-content/plugins/" >> $LOGFILE 2>&1

  echo "[Plugin Audit - mobile conditions]" >> $LOGFILE
  grep -R --include="*.php" "wp_is_mobile" "$SCANPATH/wp-content/plugins/" >> $LOGFILE 2>&1
  grep -R --include="*.php" "HTTP_USER_AGENT" "$SCANPATH/wp-content/plugins/" >> $LOGFILE 2>&1
  grep -R --include="*.js" "navigator.userAgent" "$SCANPATH/wp-content/plugins/" >> $LOGFILE 2>&1

  echo "=== End of Audit for $APPNAME ===" >> $LOGFILE
done
