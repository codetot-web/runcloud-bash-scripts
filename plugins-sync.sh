#!/bin/bash
#
# plugins-sync.sh — Sync premium plugin zips from a reference store to the local plugins/ directory
#
# Reference store layout (per AGENTS.md + fleet convention):
#   ~/plugins/<slug>.zip                — single zip
#   ~/plugins/<slug>/                   — folder with main plugin file
#   ~/plugins/<slug>/<version>.zip      — versioned zip
#
# This script:
#   1. Inspects a reference repo (default: codetot-clients/<repo>) and lists plugin
#      versions actually deployed on that site.
#   2. Compares against the local ~/plugins/ store and prints what is missing or
#      behind.
#   3. Optionally downloads the latest zip from the WP.org / GitHub release page
#      for FREE plugins, OR leaves a clear "MISSING in store" report for PREMIUM
#      plugins (since we cannot download those without a license).
#
# Usage:
#   ./plugins-sync.sh --repo=codetot-clients/masanconsumer
#   ./plugins-sync.sh --repo=codetot-clients/masanconsumer --only=perfmatters,wpvivid-backup-pro
#   ./plugins-sync.sh --list-store
#   ./plugins-sync.sh --plugin=perfmatters --download   # download from WP.org (FREE only)
#
# Output: a markdown report printed to stdout. Use --json to print JSON instead.

set -uo pipefail

# --- defaults ---
REPO="codetot-clients/masanconsumer"
ONLY=""
LIST_STORE=0
JSON_OUT=0
PLUGIN=""
DOWNLOAD=0
STORE_DIR="${HOME}/plugins"

# --- colors ---
if [ -t 1 ]; then
  C_RESET=$'\033[0m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'; C_BOLD=$'\033[1m'
else
  C_RESET=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_BOLD=""
fi
info()    { echo "${C_BLUE}▸${C_RESET} $*"; }
ok()      { echo "${C_GREEN}✓${C_RESET} $*"; }
warn()    { echo "${C_YELLOW}!${C_RESET} $*"; }
err()     { echo "${C_RED}✗${C_RESET} $*" >&2; }
section() { echo -e "\n${C_BOLD}== $* ==${C_RESET}"; }

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

for i in "$@"; do
  case $i in
    --repo=*)      REPO="${i#*=}" ;;
    --only=*)      ONLY="${i#*=}" ;;
    --list-store)  LIST_STORE=1 ;;
    --json)        JSON_OUT=1 ;;
    --plugin=*)    PLUGIN="${i#*=}" ;;
    --download)    DOWNLOAD=1 ;;
    --help|-h)     usage ;;
    *) err "unknown arg: $i"; exit 1 ;;
  esac
done

# --- list store mode ---
if [ "$LIST_STORE" -eq 1 ]; then
  if [ ! -d "$STORE_DIR" ]; then
    err "store dir not found: $STORE_DIR"
    exit 1
  fi
  echo "Local store: $STORE_DIR"
  ls -la "$STORE_DIR"
  exit 0
fi

# --- helpers ---
ver_key() {
  # $1 = version string, prints "major minor patch" sorted tuple
  local s="$1"
  [ -z "$s" ] || [ "$s" = "?" ] && { echo "0 0 0"; return; }
  echo "$s" | awk -F'[.-]' '{ printf "%d %d %d\n", ($1+0), ($2+0), ($3+0) }'
}
ver_cmp() {
  # 0 if equal, 1 if a > b, -1 if a < b
  local a b
  a=$(ver_key "$1" | awk '{print $1}') || a=0
  b=$(ver_key "$2" | awk '{print $1}') || b=0
  [ "$a" -gt "$b" ] && echo 1 && return
  [ "$a" -lt "$b" ] && echo -1 && return
  a=$(ver_key "$1" | awk '{print $2}') || a=0
  b=$(ver_key "$2" | awk '{print $2}') || b=0
  [ "$a" -gt "$b" ] && echo 1 && return
  [ "$a" -lt "$b" ] && echo -1 && return
  a=$(ver_key "$1" | awk '{print $3}') || a=0
  b=$(ver_key "$2" | awk '{print $3}') || b=0
  [ "$a" -gt "$b" ] && echo 1 && return
  [ "$a" -lt "$b" ] && echo -1 && return
  echo 0
}

# Read main plugin file from GH and extract "Version:" line
# Tries standard main file names first, then falls back to listing the dir
# and picking the .php with the highest "Plugin Name:" header.
repo_plugin_ver() {
  local slug="$1" repo="$2"
  for c in "wp-content/plugins/${slug}/${slug}.php" \
           "wp-content/plugins/${slug}/plugin.php" \
           "wp-content/plugins/${slug}/index.php" \
           "wp-content/plugins/${slug}/load.php"; do
    local payload
    payload=$(gh api "repos/${repo}/contents/${c}" 2>/dev/null) || continue
    if echo "$payload" | grep -q '"content"'; then
      local v
      v=$(printf '%s' "$payload" | python3 -c 'import sys, base64, re, json
d = json.loads(sys.stdin.read())
content = base64.b64decode(d["content"]).decode("utf-8", errors="replace")
m = re.search(r"Version:\s*([0-9][^\s]+)", content)
print(m.group(1) if m else "?")
' 2>/dev/null)
      [ -n "$v" ] && [ "$v" != "?" ] && { echo "$v"; return; }
    fi
  done
  # Fallback: list the dir and read the first *.php we find
  local listing
  listing=$(gh api "repos/${repo}/contents/wp-content/plugins/${slug}" 2>/dev/null) || { echo "?"; return; }
  local php_path
  php_path=$(printf '%s' "$listing" | python3 -c 'import sys, json
try: d = json.loads(sys.stdin.read())
except: d = []
for e in d:
  if e.get("type") == "file" and e.get("name","").endswith(".php"):
    print(e["path"]); break
' 2>/dev/null)
  if [ -n "$php_path" ]; then
    local payload v
    payload=$(gh api "repos/${repo}/contents/${php_path}" 2>/dev/null) || { echo "?"; return; }
    v=$(printf '%s' "$payload" | python3 -c 'import sys, base64, re, json
d = json.loads(sys.stdin.read())
content = base64.b64decode(d["content"]).decode("utf-8", errors="replace")
m = re.search(r"Version:\s*([0-9][^\s]+)", content)
print(m.group(1) if m else "?")
' 2>/dev/null)
    [ -n "$v" ] && [ "$v" != "?" ] && { echo "$v"; return; }
  fi
  echo "?"
}

store_plugin_ver() {
  local slug="$1" store="$2"
  # Try folder
  if [ -d "$store/$slug" ]; then
    for f in "$store/$slug/$slug.php" "$store/$slug/plugin.php" "$store/$slug/index.php" "$store/$slug/load.php"; do
      [ -f "$f" ] || continue
      local v
      v=$(grep -m1 -oE 'Version:\s*[0-9][^ \r\n]*' "$f" | head -1 | awk '{print $2}')
      [ -n "$v" ] && { echo "$v"; return; }
    done
  fi
  # Try zips
  for z in "$store/${slug}"*.zip "$store/${slug//-/_}"*.zip; do
    [ -f "$z" ] || continue
    local v
    v=$(unzip -p "$z" 2>/dev/null | head -c 200000 | grep -m1 -aoE 'Version:\s*[0-9][^ \r\n]*' | head -1 | awk '{print $2}')
    [ -n "$v" ] && { echo "$v"; return; }
  done
  echo "?"
}

list_repo_plugins() {
  local repo="$1"
  gh api "repos/${repo}/contents/wp-content/plugins" 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); [print(e['name']) for e in d if e['type']=='dir' and e['name']!='index.php']"
}

is_premium() {
  case "$1" in
    *-pro|*-premium|advanced-custom-fields-pro|all-in-one-seo-pack-pro|perfmatters|facetwp|\
    seo-by-rank-math-pro|user-role-editor-pro|wp-mail-smtp-pro|permalink-manager-pro|\
    wpvivid-backup-pro|wp-all-import-pro|wp-all-export-pro|admin-columns-pro|\
    better-search-replace-pro|wp-fastest-cache|media-sync|wpml-*|sitepress-multilingual-cms|\
    polylang-pro|elementor-pro|gravityforms|gravity-forms*)
      return 0 ;;
    *) return 1 ;;
  esac
}

# --- single plugin download (FREE from WP.org) ---
wporg_download() {
  local slug="$1"
  local api
  api=$(curl -sL --max-time 20 "https://api.wordpress.org/plugins/info/1.2/${slug}.json" 2>/dev/null || true)
  if [ -z "$api" ] || ! echo "$api" | grep -q '"version"'; then
    err "$slug: not found on api.wordpress.org"
    return 1
  fi
  local ver
  ver=$(echo "$api" | python3 -c "import sys,json; print(json.load(sys.stdin).get('version','?'))")
  local url
  url=$(echo "$api" | python3 -c "import sys,json; print(json.load(sys.stdin).get('download_link',''))")
  if [ -z "$url" ]; then
    err "$slug: no download_link in WP.org response"
    return 1
  fi
  mkdir -p "$STORE_DIR"
  local out="$STORE_DIR/${slug}-${ver}.zip"
  info "downloading $slug v$ver -> $out"
  curl -sL --max-time 90 "$url" -o "$out"
  if [ -s "$out" ] && unzip -l "$out" >/dev/null 2>&1; then
    ok "$slug v$ver saved"
  else
    err "$slug: download failed or zip invalid"
    rm -f "$out"
    return 1
  fi
}

# --- single plugin download mode ---
if [ -n "$PLUGIN" ]; then
  if [ "$DOWNLOAD" -ne 1 ]; then
    err "--plugin requires --download"
    exit 1
  fi
  if is_premium "$PLUGIN"; then
    err "$PLUGIN is premium — cannot auto-download (need license)"
    exit 2
  fi
  wporg_download "$PLUGIN"
  exit $?
fi

# --- main: compare repo vs store ---
section "Reference repo: $REPO"
section "Local store:    $STORE_DIR"

if ! command -v gh >/dev/null 2>&1; then
  err "gh CLI not found"; exit 1
fi
if ! gh repo view "$REPO" >/dev/null 2>&1; then
  err "cannot access repo $REPO — run 'gh auth login' or check permissions"
  exit 1
fi

mapfile -t REPO_PLUGINS < <(list_repo_plugins "$REPO" | sort -u)
[ "${#REPO_PLUGINS[@]}" -eq 0 ] && { err "no plugins found in $REPO"; exit 1; }
info "found ${#REPO_PLUGINS[@]} plugins in repo"

# Apply --only filter
if [ -n "$ONLY" ]; then
  FILTERED=()
  for p in "${REPO_PLUGINS[@]}"; do
    if echo ",$ONLY," | grep -q ",$p,"; then
      FILTERED+=("$p")
    fi
  done
  REPO_PLUGINS=("${FILTERED[@]}")
  info "filtered to ${#REPO_PLUGINS[@]} plugins"
fi

# Premium set (from masanconsumer reference)
PREMIUM_LIST=(admin-columns-pro advanced-custom-fields-pro better-search-replace-pro \
  facetwp media-sync perfmatters permalink-manager-pro seo-by-rank-math-pro \
  sitepress-multilingual-cms user-role-editor-pro wp-all-export-pro wp-all-import-pro \
  wp-fastest-cache wp-mail-smtp-pro wpvivid-backup-pro wpml-all-import wpml-string-translation)

if [ "$JSON_OUT" -eq 1 ]; then
  echo "["
  first=1
  for p in "${REPO_PLUGINS[@]}"; do
    rv=$(repo_plugin_ver "$p" "$REPO")
    lv=$(store_plugin_ver "$p" "$STORE_DIR")
    cmp=$(ver_cmp "$rv" "$lv")
    isprem="free"
    for x in "${PREMIUM_LIST[@]}"; do
      [ "$x" = "$p" ] && isprem="premium"
    done
    [ $first -eq 0 ] && echo ","
    first=0
    printf '{"plugin":"%s","repo_version":"%s","store_version":"%s","cmp":%s,"type":"%s"}' \
      "$p" "$rv" "$lv" "$cmp" "$isprem"
  done
  echo ""
  echo "]"
  exit 0
fi

# Pretty markdown table
section "Inventory comparison (${#REPO_PLUGINS[@]} plugins)"
printf "%-40s %-10s %-10s %-6s %-10s\n" "PLUGIN" "REPO" "STORE" "GAP" "TYPE"
printf "%-40s %-10s %-10s %-6s %-10s\n" "----------------------------------------" "----------" "----------" "------" "----------"

BEHIND_FREE=()
BEHIND_PREM=()
MISSING_PREM=()
ALIGNED=0
TOTAL=0

for p in "${REPO_PLUGINS[@]}"; do
  TOTAL=$((TOTAL+1))
  rv=$(repo_plugin_ver "$p" "$REPO")
  lv=$(store_plugin_ver "$p" "$STORE_DIR")
  cmp=$(ver_cmp "$rv" "$lv")
  isprem="free"
  for x in "${PREMIUM_LIST[@]}"; do
    [ "$x" = "$p" ] && isprem="premium"
  done
  gap="="
  if [ "$cmp" = "1" ]; then
    if [ "$isprem" = "premium" ]; then
      gap="↑PREM"
      BEHIND_PREM+=("$p:$rv:$lv")
    else
      gap="↑FREE"
      BEHIND_FREE+=("$p:$rv:$lv")
    fi
  elif [ "$cmp" = "-1" ]; then
    gap="↓store"
  elif [ "$lv" = "?" ] && [ "$rv" != "?" ]; then
    if [ "$isprem" = "premium" ]; then
      gap="MISS"
      MISSING_PREM+=("$p:$rv")
    else
      gap="↑FREE"
      BEHIND_FREE+=("$p:$rv:?")
    fi
  elif [ "$rv" = "?" ]; then
    gap="-"
  else
    ALIGNED=$((ALIGNED+1))
  fi
  printf "%-40s %-10s %-10s %-6s %-10s\n" "$p" "$rv" "$lv" "$gap" "$isprem"
done

section "Summary"
echo "  Total plugins in repo: $TOTAL"
echo "  Aligned with store:    $ALIGNED"
echo "  Free plugins BEHIND:   ${#BEHIND_FREE[@]}  (run: $0 --plugin=SLUG --download)"
echo "  Premium BEHIND:        ${#BEHIND_PREM[@]}  (need license key to update)"
echo "  Premium MISSING:       ${#MISSING_PREM[@]}  (need license key to obtain)"

if [ "${#BEHIND_FREE[@]}" -gt 0 ]; then
  section "Free plugins behind (download with --plugin=SLUG --download)"
  for x in "${BEHIND_FREE[@]}"; do
    IFS=: read -r slug rv lv <<<"$x"
    echo "  $slug  repo=$rv  store=$lv"
  done
fi

if [ "${#BEHIND_PREM[@]}" -gt 0 ]; then
  section "Premium plugins behind (manual: obtain zip + license)"
  for x in "${BEHIND_PREM[@]}"; do
    IFS=: read -r slug rv lv <<<"$x"
    echo "  $slug  repo=$rv  store=$lv"
  done
fi

if [ "${#MISSING_PREM[@]}" -gt 0 ]; then
  section "Premium plugins missing from store entirely"
  for x in "${MISSING_PREM[@]}"; do
    IFS=: read -r slug rv <<<"$x"
    echo "  $slug  latest=$rv"
  done
fi
