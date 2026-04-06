# RunCloud - Bash scripts

Author: [@khoipro](https://github.com/khoipro), @copilot

## Features
- [x] Install ioncube for all PHP versions
- [x] Migrate web application between RunCloud servers
- [x] Fix web applications permission (runcloud chown, file 644 folder 755)
- [ ] Change SSH port
- [ ] Automatic Tweak my.cnf
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

### change-ssh-port.sh

Change the default SSH port.

```bash
./change-ssh-port.sh
```
