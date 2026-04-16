#!/bin/bash
#
# WordPress Security Audit Script
# Usage: wp-security-audit.sh [--site=APPNAME] [--folder=/path/to/webapp]
# Logs suspicious findings per webapp folder
# Stops if required packages are missing
#
# Options:
#   --site=NAME      Scan a single site by app name (resolves to /home/*/webapps/NAME)
#   --folder=PATH    Scan a specific folder path
#   (no args)        Scan all sites under /home/*/webapps/*

DATE=$(date '+%Y-%m-%d %H:%M:%S')

# Default scan path
SCANPATHS="/home/*/webapps/*"

# Parse arguments
for arg in "$@"; do
  case $arg in
    --site=*)
      SITE="${arg#*=}"
      # Resolve site path — support any user, not just runcloud
      MATCH=$(find /home/*/webapps -maxdepth 1 -name "$SITE" -type d 2>/dev/null | head -1)
      if [ -z "$MATCH" ]; then
        echo "ERROR: Site '$SITE' not found under /home/*/webapps/"
        exit 1
      fi
      SCANPATHS="$MATCH"
      ;;
    --folder=*)
      SCANPATHS="${arg#*=}"
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
    -path "*/cache" -prune -o \
    -type f ! -regex '.*\.\(jpg\|jpeg\|png\|gif\|svg\|pdf\|docx\|xlsx\|zip\|mp4\|mp3\)$' \
    -print >> $LOGFILE 2>&1

  # --- Plugin audit: suspicious patterns ---
  echo "[Plugin Audit - base64]" >> $LOGFILE
  grep -R --include="*.php" --exclude-dir="cache" "base64" "$SCANPATH/wp-content/plugins/" >> $LOGFILE 2>&1

  echo "[Plugin Audit - redirects]" >> $LOGFILE
  grep -R --include="*.php" --exclude-dir="cache" "wp_redirect" "$SCANPATH/wp-content/plugins/" >> $LOGFILE 2>&1
  grep -R --include="*.php" --exclude-dir="cache" "header(" "$SCANPATH/wp-content/plugins/" >> $LOGFILE 2>&1
  grep -R --include="*.js" --exclude-dir="cache" "window.location" "$SCANPATH/wp-content/plugins/" >> $LOGFILE 2>&1

  echo "[Plugin Audit - mobile conditions]" >> $LOGFILE
  grep -R --include="*.php" --exclude-dir="cache" "wp_is_mobile" "$SCANPATH/wp-content/plugins/" >> $LOGFILE 2>&1
  grep -R --include="*.php" --exclude-dir="cache" "HTTP_USER_AGENT" "$SCANPATH/wp-content/plugins/" >> $LOGFILE 2>&1
  grep -R --include="*.js" --exclude-dir="cache" "navigator.userAgent" "$SCANPATH/wp-content/plugins/" >> $LOGFILE 2>&1

  echo "=== End of Audit for $APPNAME ===" >> $LOGFILE
done
