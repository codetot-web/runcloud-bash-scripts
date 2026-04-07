#!/bin/bash
#
# Self-Update: pull latest changes from the remote repository.
#
# Usage:
#   /root/runcloud-bash-scripts/self-update.sh
#
# Cron example (daily at 3:30 AM):
#   30 3 * * * /root/runcloud-bash-scripts/self-update.sh >> /var/log/runcloud-bash-scripts-update.log 2>&1
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ ! -d "$SCRIPT_DIR/.git" ]; then
    echo "[$(date -Iseconds)] ERROR: $SCRIPT_DIR is not a git repository" >&2
    exit 1
fi

cd "$SCRIPT_DIR"

# Fetch and check for updates
git fetch origin main --quiet 2>/dev/null

LOCAL=$(git rev-parse HEAD)
REMOTE=$(git rev-parse origin/main)

if [ "$LOCAL" = "$REMOTE" ]; then
    echo "[$(date -Iseconds)] Already up to date ($LOCAL)"
    exit 0
fi

echo "[$(date -Iseconds)] Updating from $LOCAL to $REMOTE ..."
git pull origin main --quiet 2>/dev/null
chmod +x *.sh

echo "[$(date -Iseconds)] Updated to $(git rev-parse --short HEAD): $(git log -1 --format='%s')"
