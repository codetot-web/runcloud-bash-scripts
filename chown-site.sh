#!/usr/bin/env bash
#
# chown-site.sh — Recursively chown a RunCloud webapp to www-data, excluding uploads
#
# Source:
#   https://gist.githubusercontent.com/khoipro/8fd5e07b25ed8a5904257b0c0b969ad3/raw/d2c4816379789c2b3f5d5d8c5d67bbfab0ddb92a/chown-site.sh
#
# Usage:
#   ./chown-site.sh --site=meatdeli
#   ./chown-site.sh --site=meatdeli --user=ubuntu
#
# Options:
#   --site=NAME   Required. Web app name under /home/<user>/webapps/
#   --user=NAME   Optional. Webapp system user. Defaults to runcloud.
#

set -euo pipefail

SITE=""
SITE_USER="runcloud"

show_help() {
  awk 'NR==1{next} /^[^#]/{exit} {sub(/^# ?/,""); print}' "$0"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --site=*)
      SITE="${1#*=}"
      shift
      ;;
    --site)
      SITE="${2:-}"
      shift 2
      ;;
    --user=*)
      SITE_USER="${1#*=}"
      shift
      ;;
    --user)
      SITE_USER="${2:-}"
      shift 2
      ;;
    --help|-h)
      show_help
      exit 0
      ;;
    *)
      echo "Usage: $0 --site=<site-name> [--user=<system-user>]" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$SITE" ]]; then
  echo "Missing required flag: --site" >&2
  exit 1
fi

if [[ -z "$SITE_USER" ]]; then
  echo "Missing value for --user" >&2
  exit 1
fi

ROOT="/home/$SITE_USER/webapps/$SITE"
UPLOADS="$ROOT/wp-content/uploads"

if [[ ! -d "$ROOT" ]]; then
  echo "Site path not found: $ROOT" >&2
  exit 1
fi

sudo find "$ROOT" \
  \( -path "$UPLOADS" -o -path "$UPLOADS/*" \) -prune -o \
  -exec chown www-data:www-data {} +
