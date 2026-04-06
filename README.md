# RunCloud - Bash scripts

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
- [ ] Batch update WP Site (using wp-cli)
- [x] WP Security audit installer and WP Security Audit

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

### change-ssh-port.sh

Change the default SSH port.

```bash
./change-ssh-port.sh
```
