# runcloud-bash-scripts

> A production-grade Bash toolkit for RunCloud sysadmins managing WordPress fleets at scale.

Battle-tested across **20+ live servers** running OpenLiteSpeed/Nginx on Ubuntu 20/22/24, this repo bundles the scripts I actually run every day: full WordPress migrations between servers, per-app CVE scanning via the [WPVulnerability.net](https://www.wpvulnerability.net/) API, WP Security Audit, permission fixes, disk cleanup, my.cnf tuning, code freeze, batch wp-cli updates, server metrics with webhook reporting, and one-command self-update.

Pairs with [`runcloud-go`](https://github.com/codetot-web/runcloud-go) — a Docker-deployed Go dashboard that wires these scripts into per-app actions across your fleet.

**Why another toolkit?** RunCloud's panel covers provisioning. This covers everything *after* — the daily ops, migrations, security work, and cleanup that keeps a multi-tenant WordPress fleet healthy.

Author: [@khoipro](https://github.com/khoipro), @copilot

## Features
- [x] Install ioncube for all PHP versions
- [x] Migrate web application between RunCloud servers
- [x] Fix web applications permission (runcloud chown, file 644 folder 755)
- [x] Disk space cleanup (LiteSpeed cache, swap, journal logs)
- [x] Change SSH port
- [x] Debug WP-CLI issues
- [x] Update Node.js
- [x] Automatic Tweak my.cnf
- [x] Git untracked file cleanup (classify + commit or gitignore)
- [x] Batch update WP Site (using wp-cli)
- [x] WP Security audit installer and WP Security Audit
- [x] Server metrics collector with webhook reporting
- [x] Self-update (auto-pull latest from GitHub)
- [x] WordPress code freeze (lock filesystem + disable user management)
- [x] WP vulnerability check (CVE scanning via WPVulnerability.net API)

## Requirements
- OpenLitespeed/Nginx
- Ubuntu 20, 22 or 24 version

## Installation

Login as root and clone the repo:

```bash
cd /root
git clone https://github.com/codetot-web/runcloud-bash-scripts.git
cd runcloud-bash-scripts
chmod +x *.sh
```

## Scripts

### wp-migration.sh

Full WordPress migration between RunCloud servers. Handles database, config files, uploads, git submodules, and staging URL in one command.

**What it does:**
1. Exports database (wp-cli or mysqldump with corrupted table handling)
2. Transfers and imports database on destination
3. Syncs wp-config.php, .htaccess, .htninja
4. Syncs wp-content/uploads
5. Initializes git submodules on destination
6. Optionally updates site URL for staging (search-replace)

**Prerequisites:**
- SSH key auth from source to destination server
- Database and user must already exist on destination (create via RunCloud panel)
- Run as the `runcloud` user on the **source** server

**Setup SSH keys (first time only):**

```bash
./wp-migration.sh runcloud@destination-server.com --setup-ssh
```

**Migrate a site (same app name on both servers):**

```bash
./wp-migration.sh runcloud@destination-server.com myapp
```

**Migrate with a different app name on destination:**

```bash
./wp-migration.sh runcloud@destination-server.com myapp newapp
```

**Migrate with staging URL update:**

```bash
./wp-migration.sh runcloud@destination-server.com myapp --staging-url=http://myapp.example.temp-site.link
```

**Custom SSH port:**

```bash
./wp-migration.sh runcloud@destination-server.com:2222 myapp
```

**Full example (typical workflow):**

```bash
# 1. Setup SSH keys to destination (one-time)
./wp-migration.sh runcloud@sg3.codetot.org --setup-ssh

# 2. Run migration with staging URL
./wp-migration.sh runcloud@sg3.codetot.org myapp --staging-url=http://myapp.staging.temp-site.link
```

### fix-permission.sh / fix-permission-site.sh

Fix file ownership and permissions for RunCloud web applications.

```bash
./fix-permission.sh
./fix-permission-site.sh myapp
```

### install-ioncube.sh

Install ioncube loader for all PHP versions.

```bash
./install-ioncube.sh
```

### wp-security-audit-installer.sh / wp-security-audit.sh

Install and run WordPress security audits.

```bash
./wp-security-audit-installer.sh
./wp-security-audit.sh
```

### cleanup-disk.sh

Free up disk space by cleaning LiteSpeed caches, swap files, journal logs, and WordPress plugin caches. Shows disk usage before/after.

**What it cleans:**
- `wp-content/cache/*` — WordPress page cache
- `wp-content/litespeed/cssjs/*` — LiteSpeed minified CSS/JS
- `wp-content/wpvivid_image_optimization/*` — WPvivid optimization cache
- `/tmp/lsws-rc/swap/*` — LiteSpeed swap files (often 5-15G)
- `/home/runcloud/lscaches/*` — LiteSpeed external caches
- Systemd journal logs (vacuums to 500M)

All cleaned items regenerate automatically — no data loss.

**Clean all webapps + system:**

```bash
./cleanup-disk.sh
```

**Clean a specific webapp + system:**

```bash
./cleanup-disk.sh --site=myapp
```

**Clean system files only (no webapps):**

```bash
./cleanup-disk.sh --system-only
```

**Preview what would be cleaned (no deletions):**

```bash
./cleanup-disk.sh --dry-run
```

**Cron job examples (add via RunCloud Dashboard > Cron Job, run as `root`):**

```bash
# Daily — clean all webapp caches + system
0 0 * * *   /root/runcloud-bash-scripts/cleanup-disk.sh

# Weekly Sunday — system cleanup only
0 0 * * 0   /root/runcloud-bash-scripts/cleanup-disk.sh --system-only

# Daily — specific app only
0 0 * * *   /root/runcloud-bash-scripts/cleanup-disk.sh --site=myapp
```

### tweak-mycnf.sh

Auto-tune MariaDB/MySQL settings based on server RAM and CPU. Optimized for WordPress workloads on RunCloud servers.

**What it does:**
1. Detects server RAM and CPU cores
2. Detects config file pattern (sg5: `mariadb.cnf` vs sg3: `runcloud.cnf`)
3. Calculates optimal settings (~50% RAM for InnoDB buffer pool, scaled instances, IO capacity for SSD, etc.)
4. Backs up existing config before any changes
5. Applies settings and restarts MariaDB
6. Auto-rolls back if MariaDB fails to start

**Scaling rules:**

| Setting | Formula |
|---------|---------|
| `innodb_buffer_pool_size` | ~50% of total RAM |
| `innodb_buffer_pool_instances` | 1 per GB of buffer pool (max 8) |
| `tmp_table_size` | 64M (<4G), 96M (4-7G), 128M (8G+) |
| `innodb_io_capacity` | 2000 (assumes SSD) |
| `max_connections` | 300 (not default 4096) |
| `wait_timeout` | 300s (not default 28800s) |

**Auto-detect and apply:**

```bash
./tweak-mycnf.sh
```

**Preview changes without applying:**

```bash
./tweak-mycnf.sh --dry-run
```

**Show current MariaDB settings:**

```bash
./tweak-mycnf.sh --status
```

**Restore previous config:**

```bash
./tweak-mycnf.sh --restore
```

### server-metrics.sh

Collect server metrics (CPU, RAM, disk, load, uptime) and discover all web applications under `/home/*/webapps/`. Detects WordPress sites and checks for available updates (core, plugins, themes). Sends the JSON payload to any webhook endpoint with optional HMAC-SHA256 signing.

**What it collects:**
- CPU usage, load averages (1m/5m/15m)
- RAM total/used/percent
- Disk total/used/percent (root partition)
- Uptime in seconds
- Per-webapp: username, app name, disk usage in MB
- WordPress: version, site URL, available core/plugin/theme updates

**Print metrics to stdout (no HTTP request):**

```bash
./server-metrics.sh --print
```

**Send to a webhook endpoint:**

```bash
WEBHOOK_URL=https://example.com/api/webhooks/server-metrics ./server-metrics.sh
```

**Send with HMAC-SHA256 authentication:**

```bash
WEBHOOK_URL=https://example.com/api/webhooks/server-metrics \
WEBHOOK_SECRET=your-secret \
./server-metrics.sh
```

**Override hostname:**

```bash
WEBHOOK_URL=https://example.com/webhook \
HOSTNAME_OVERRIDE=my-server-01 \
./server-metrics.sh
```

**Cron job examples (run as `root`):**

```bash
# Every 5 minutes — send metrics to webhook
*/5 * * * * WEBHOOK_URL=https://example.com/webhook WEBHOOK_SECRET=your-secret /root/runcloud-bash-scripts/server-metrics.sh >> /var/log/server-metrics.log 2>&1

# Every hour — save metrics locally
0 * * * * /root/runcloud-bash-scripts/server-metrics.sh --print >> /var/log/server-metrics.json
```

**HMAC-SHA256 Signature:**

When `WEBHOOK_SECRET` is set, the script sends two headers:
- `X-Webhook-Signature` — HMAC-SHA256 of `{timestamp}.{payload}`
- `X-Webhook-Timestamp` — Unix timestamp of the request

Verify on the receiving end with timing-safe comparison (`hash_equals` in PHP, `hmac.compare_digest` in Python).

### self-update.sh

Auto-update the repository by pulling the latest changes from GitHub. Skips if already up to date. Automatically `chmod +x` all scripts after update.

```bash
./self-update.sh
```

**Cron job example (daily at 3:30 AM):**

```bash
30 3 * * * /root/runcloud-bash-scripts/self-update.sh >> /var/log/runcloud-bash-scripts-update.log 2>&1
```

### wp-freeze.sh

Lock a WordPress site's filesystem and admin capabilities after launch. Prevents plugin/theme installs, file edits, and user management — while keeping post publishing and media uploads fully functional.

**Two-layer freeze:**
- **Filesystem:** sets core files to read-only (`444`/`555`), blocks PHP execution in uploads
- **WordPress:** injects `DISALLOW_FILE_MODS`, `DISALLOW_FILE_EDIT`, `AUTOMATIC_UPDATER_DISABLED` into `wp-config.php`
- **Capability:** drops a mu-plugin that removes all user management capabilities and hides the Users menu

**Freeze a site:**

```bash
./wp-freeze.sh --site=myapp --action=freeze
```

**Unfreeze before a maintenance window:**

```bash
./wp-freeze.sh --site=myapp --action=unfreeze
```

**Check status:**

```bash
./wp-freeze.sh --site=myapp --action=status
# or all sites:
./wp-freeze.sh --action=status
```

**Preview changes without applying:**

```bash
./wp-freeze.sh --site=myapp --action=freeze --dry-run
```

**What admin can do after freeze:**

| Action | Works? |
|--------|--------|
| Create / edit / publish posts | Yes |
| Upload media | Yes |
| Install or update plugins/themes | No |
| Edit theme/plugin files in admin | No |
| Create / edit / delete users | No |
| WordPress auto-updates | No |

**Maintenance window workflow:**
```bash
# 1. Unfreeze before updates
./wp-freeze.sh --site=myapp --action=unfreeze
# 2. Run updates (plugins, core, etc.)
# 3. Re-freeze after updates
./wp-freeze.sh --site=myapp --action=freeze
```

### wp-vuln-check.sh

Check installed WordPress plugins and themes for known CVEs using the free [WPVulnerability.net](https://www.wpvulnerability.net) API. Reports vulnerability name, CVE ID, CVSS score, and severity.

**Check a site:**

```bash
./wp-vuln-check.sh --site=myapp
```

**Include WordPress core version check:**

```bash
./wp-vuln-check.sh --site=myapp --include-core
```

**JSON output (for automation):**

```bash
./wp-vuln-check.sh --site=myapp --json
```

**Check plugins only or themes only:**

```bash
./wp-vuln-check.sh --site=myapp --plugins-only
./wp-vuln-check.sh --site=myapp --themes-only
```

**Requirements:** `python3` and `curl` must be available on the server (standard on Ubuntu 20+).

### wp-git-cleanup.sh

Scan WordPress sites for untracked git files, classify them, and either report or commit them in logical groups. Adds production artifacts to `.gitignore` automatically. Skips frozen sites.

**Classification + commit order:**

| Group | Pattern | Commit message |
|-------|---------|----------------|
| `.gitignore` | Cache, backups, logs, litespeed, wpvivid, `.tmb/` | `chore: update .gitignore for production artifacts` |
| WP Core | `wp-admin/`, `wp-includes/`, root `wp-*.php` | `chore: track wp core files` |
| WP Themes | `wp-content/themes/THEME/` (one commit per theme) | `chore: track wp theme (THEME)` |
| WP Plugins | `wp-content/plugins/SLUG/` (one commit per plugin) | `chore: track wp plugin (SLUG)` |
| MU-Plugins | `wp-content/mu-plugins/` | `chore: track mu-plugins` |
| Languages | `wp-content/languages/` (`.mo`/`.po`/`.pot`/`.l10n.php`) | `chore: track wp languages` |

**Scan all sites (report only):**

```bash
./wp-git-cleanup.sh --action=scan
```

**Cleanup a specific site:**

```bash
./wp-git-cleanup.sh --site=myapp --action=cleanup
```

**Cleanup all sites:**

```bash
./wp-git-cleanup.sh --action=cleanup
```

**Preview changes without applying:**

```bash
./wp-git-cleanup.sh --site=myapp --action=cleanup --dry-run
```

**Notes:**
- Supports multi-user layout (`/home/*/webapps/`)
- Skips frozen sites (detected via `code-freeze.php` mu-plugin)
- Language `.json` files are auto-ignored (WP-generated JED hashes)
- Runs git as the site owner to avoid dubious ownership errors

### change-ssh-port.sh

Change the default SSH port.

```bash
./change-ssh-port.sh
```
