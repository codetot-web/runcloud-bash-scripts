#!/bin/bash
#
# WordPress Security Audit Script
# Usage: wp-security-audit.sh [--site=APPNAME] [--folder=/path/to/webapp] [--install-deps]
#   --site=NAME      Scan a single site by app name (resolves to /home/*/webapps/NAME)
#   --folder=PATH    Scan a specific folder path
#   --install-deps   Install missing dependencies (clamav, rkhunter, chkrootkit)
#   (no args)        Scan all sites under /home/*/webapps/*
#
# Two-phase scan:
#   Phase 1 — Fast patterns: goods.php, shop.php, .tmb/, ZEa/, wp-login backdoor
#   Phase 2 — Deep scan: ClamAV + rootkit checks (if tools installed)

DATE=$(date '+%Y-%m-%d %H:%M:%S')
INSTALL_DEPS=false

# Color output
red()   { echo -e "\033[31m$1\033[0m"; }
green() { echo -e "\033[32m$1\033[0m"; }
yellow(){ echo -e "\033[33m$1\033[0m"; }

# Default scan path
SCANPATH="/home/*/webapps/*"

# Parse arguments
for arg in "$@"; do
  case $arg in
    --site=*)
      SITE="${arg#*=}"
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
    --install-deps)
      INSTALL_DEPS=true
      ;;
  esac
done

# Ensure log directory exists
mkdir -p /var/log/webapps

# --- Dependency install ---
if [ "$INSTALL_DEPS" = true ]; then
  echo "[+] Installing ClamAV + rkhunter + chkrootkit..."
  apt-get update -y
  apt-get install -y clamav clamav-daemon rkhunter chkrootkit
  freshclam 2>/dev/null || true
  echo "[+] Dependencies installed."
fi

# --- Check required packages (soft warn, no exit) ---
CLAMAV_AVAIL=false
RKHUNTER_AVAIL=false
CHKROOTKIT_AVAIL=false

command -v clamscan >/dev/null 2>&1 && CLAMAV_AVAIL=true
command -v rkhunter >/dev/null 2>&1 && RKHUNTER_AVAIL=true
command -v chkrootkit >/dev/null 2>&1 && CHKROOTKIT_AVAIL=true

if ! $CLAMAV_AVAIL && ! $RKHUNTER_AVAIL && ! $CHKROOTKIT_AVAIL; then
  yellow "[!] No security tools installed (clamav, rkhunter, chkrootkit)."
  yellow "    Run with --install-deps as root, or install manually."
  yellow "    Phase 1 (fast pattern checks) will still run.\n"
fi

# ======================================================================
# Phase 1: Fast Malware Pattern Detection
# ======================================================================

# --- Helper: check a specific path pattern under scanpath ---
check_file_exists() {
  local desc="$1"
  local pattern="$2"
  local severity="$3"  # CRITICAL / HIGH / MEDIUM / LOW
  if [ -f "$pattern" ] || [ -d "$pattern" ]; then
    case "$severity" in
      CRITICAL) red "[${severity}] ${desc}: ${pattern}" ;;
      HIGH)     red "[${severity}] ${desc}: ${pattern}" ;;
      MEDIUM)   yellow "[${severity}] ${desc}: ${pattern}" ;;
      *)        echo "[${severity}] ${desc}: ${pattern}" ;;
    esac
    return 0
  fi
  return 1
}

check_grep() {
  local desc="$1"
  local grep_args="$2"
  local target="$3"
  local severity="$4"
  local results
  results=$(eval "grep -l $grep_args \"$target\" 2>/dev/null")
  if [ -n "$results" ]; then
    local count
    count=$(echo "$results" | wc -l)
    case "$severity" in
      CRITICAL) red "[${severity}] ${desc}: ${count} file(s)" ;;
      HIGH)     red "[${severity}] ${desc}: ${count} file(s)" ;;
      MEDIUM)   yellow "[${severity}] ${desc}: ${count} file(s)" ;;
      *)        echo "[${severity}] ${desc}: ${count} file(s)" ;;
    esac
    echo "$results" | while read -r f; do echo "         $f"; done
    return 0
  fi
  return 1
}

for SCANPATH in $SCANPATHS; do
  APPNAME=$(basename "$SCANPATH")
  LOGFILE="/var/log/webapps/${APPNAME}.log"
  ISSUES=0

  echo ""
  echo "================================================"
  echo " WP Security Audit - $DATE "
  echo " Target: $SCANPATH "
  echo "================================================"

  # ---- Phase 1: Fast Pattern Detection ----

  echo ""
  echo "--- Phase 1: Fast Malware Pattern Detection ---"

  # 1. Known malware PHP shells at root
  check_file_exists "Known PHP shell (goods.php)" "$SCANPATH/goods.php" "CRITICAL" && ISSUES=$((ISSUES+1))
  check_file_exists "Known PHP shell (shop.php)" "$SCANPATH/shop.php" "CRITICAL" && ISSUES=$((ISSUES+1))

  # 2. Tiny File Manager (.tmb/ directory)
  if [ -d "$SCANPATH/.tmb" ]; then
    tmb_files=$(find "$SCANPATH/.tmb" -name "*.php" 2>/dev/null)
    if [ -n "$tmb_files" ]; then
      red "[CRITICAL] Tiny File Manager (.tmb/) — ${APPNAME}/.tmb/ contains PHP files"
      echo "$tmb_files" | while read -r f; do echo "         $f"; done
      ISSUES=$((ISSUES+1))
    fi
  fi

  # 3. Backdoor block directory (wp-includes/blocks/ZEa/)
  if [ -d "$SCANPATH/wp-includes/blocks/ZEa" ]; then
    red "[CRITICAL] Suspicious block directory (ZEa): ${SCANPATH}/wp-includes/blocks/ZEa/"
    ls -la "$SCANPATH/wp-includes/blocks/ZEa/" 2>/dev/null
    ISSUES=$((ISSUES+1))
  fi

  # 4. wp-login.php backdoor (cookie auth bypass)
  if [ -f "$SCANPATH/wp-login.php" ]; then
    if grep -q "yrxc_uck" "$SCANPATH/wp-login.php" 2>/dev/null; then
      red "[CRITICAL] wp-login.php backdoor detected (cookie auth bypass: yrxc_uck)"
      ISSUES=$((ISSUES+1))
    fi
  fi

  # 5. Suspicious PHP files at webapp root (eval, system, exec, passthru, shell_exec)
  echo ""
  echo "[Suspicious PHP functions in root files]"
  suspicious_root=$(find "$SCANPATH" -maxdepth 1 -name "*.php" -exec grep -lE '(base64_decode|eval\(|system\(|exec\(|passthru\(|shell_exec\(|popen\()' {} \; 2>/dev/null)
  if [ -n "$suspicious_root" ]; then
    yellow "[MEDIUM] Suspicious PHP functions in root-level files:"
    echo "$suspicious_root" | while read -r f; do
      if [ "$(basename "$f")" = "index.php" ]; then
        # index.php usually has legit use
        continue
      fi
      echo "         $f"
      ISSUES=$((ISSUES+1))
    done
  fi

  # 6. Obfuscated PHP files (high entropy filenames, large single-line PHP)
  echo ""
  echo "[Obfuscated PHP check]"
  obfuscated=$(find "$SCANPATH" -maxdepth 1 -name "*.php" -size +50k 2>/dev/null)
  if [ -n "$obfuscated" ]; then
    for f in $obfuscated; do
      lineno=$(wc -l < "$f" 2>/dev/null)
      fname=$(basename "$f")
      # Skip known WP files
      case "$fname" in
        wp-config.php|wp-settings.php|wp-load.php) continue ;;
      esac
      if [ "$lineno" -lt 5 ]; then
        red "[HIGH] Obfuscated/large PHP file (${lineno} lines, $(du -h "$f" | cut -f1)): $f"
        ISSUES=$((ISSUES+1))
      fi
    done
  fi

  # 7. Unusual .php files in wp-includes (not part of core)
  echo ""
  echo "[Unauthorized files in wp-includes]"
  if [ -d "$SCANPATH/wp-includes" ]; then
    unexpected_wpinc=$(find "$SCANPATH/wp-includes" -maxdepth 1 -name "*.php" ! -name "*.php" 2>/dev/null | head -20)
    # Actually find files that shouldn't be at wp-includes root level
    unexpected_wpinc=$(find "$SCANPATH/wp-includes" -maxdepth 1 -type f \( -name "*.php" -o -name "*.txt" -o -name "*.html" \) ! -name "class-wp-*" ! -name "wp-*" ! -name "rest-api" ! -name ".*" 2>/dev/null | head -20)
    if [ -n "$unexpected_wpinc" ]; then
      yellow "[MEDIUM] Unusual files in wp-includes/:"
      echo "$unexpected_wpinc"
      ISSUES=$((ISSUES+1))
    fi
  fi

  # 8. Suspicious cron entries / wp_options backdoor
  echo ""
  echo "[Suspicious cron entries]"
  if command -v wp >/dev/null 2>&1 || [ -f "/usr/local/bin/wp" ] || [ -f "/usr/bin/wp" ]; then
    WP_CLI=""
    for p in /usr/local/bin/wp /usr/bin/wp; do
      [ -x "$p" ] && WP_CLI="$p" && break
    done
    if [ -n "$WP_CLI" ] && [ -f "$SCANPATH/wp-config.php" ]; then
      # Find site owner
      SITE_OWNER=$(stat -c '%U' "$SCANPATH/wp-config.php" 2>/dev/null || stat -f '%Su' "$SCANPATH/wp-config.php" 2>/dev/null)
      cron_hooks=$(sudo -u "$SITE_OWNER" "$WP_CLI" --path="$SCANPATH" option get cron 2>/dev/null | grep -oE '"[a-z_]+"' | head -10)
      suspicious_hooks=$(echo "$cron_hooks" | grep -E '(check|verify|ping|shell|eval|exec|admin_ajax)' 2>/dev/null || true)
      if [ -n "$suspicious_hooks" ]; then
        yellow "[MEDIUM] Suspicious cron hooks detected:"
        echo "$suspicious_hooks"
        ISSUES=$((ISSUES+1))
      fi
    fi
  fi

  # ---- Phase 2: Deep Scan (tools required) ----
  echo ""
  echo "--- Phase 2: Deep Scan (ClamAV + Rootkit) ---"

  if $CLAMAV_AVAIL; then
    echo "[ClamAV Scan]"
    clamscan -r "$SCANPATH" --bell -i \
      --exclude-dir="^$SCANPATH/wp-content/cache" \
      2>&1 | tee -a "$LOGFILE" | tail -5
  else
    yellow "[SKIP] ClamAV not installed"
  fi

  if $RKHUNTER_AVAIL; then
    echo "[Rkhunter]"
    rkhunter --check --sk 2>&1 | tee -a "$LOGFILE" | tail -3
  else
    yellow "[SKIP] rkhunter not installed"
  fi

  if $CHKROOTKIT_AVAIL; then
    echo "[Chkrootkit]"
    chkrootkit 2>&1 | tee -a "$LOGFILE" | tail -3
  else
    yellow "[SKIP] chkrootkit not installed"
  fi

  # ---- Uploads folder audit ----
  echo ""
  echo "[Uploads Folder Audit]"
  if [ -d "$SCANPATH/wp-content/uploads" ]; then
    find "$SCANPATH/wp-content/uploads" \
      -path "*/cache" -prune -o \
      -type f ! -regex '.*\.\(jpg\|jpeg\|png\|gif\|svg\|pdf\|docx\|xlsx\|zip\|mp4\|mp3\)$' \
      -print 2>/dev/null | tee -a "$LOGFILE"
  fi

  # ---- Summary ----
  echo ""
  echo "================================================"
  if [ "$ISSUES" -gt 0 ]; then
    red "  SUMMARY: ${ISSUES} issue(s) found in ${APPNAME}"
  else
    green "  SUMMARY: No issues found in ${APPNAME}"
  fi
  echo "  Log: ${LOGFILE}"
  echo "================================================"

done
