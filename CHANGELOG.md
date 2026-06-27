# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Added

- `wp-security-audit.sh`: Phase 1 fast malware pattern detection (before heavy ClamAV scan):
  - Known PHP shells: goods.php, shop.php at webapp root
  - Tiny File Manager: .tmb/*.php directory check
  - Backdoor block: wp-includes/blocks/ZEa/ directory
  - Cookie auth bypass: wp-login.php yrxc_uck backdoor
  - Obfuscated PHP: large single-line files (>50KB, <5 lines)
  - Suspicious root-level PHP files with eval/system/exec/base64_decode
  - Unusual files in wp-includes/ (non-core .php/.txt/.html)
  - Suspicious cron hooks via wp-cli option get (when wp-cli available)
  - Dependencies now optional (warn instead of exit 1) — Phase 1 runs without clamav/rkhunter
  - Summary score per-site: colored output (red/green) with issue count
  - `--install-deps` flag for one-command setup of clamav+rkhunter+chkrootkit

## [0.0.1.8] - 2026-05-22

### Added

- `chown-site.sh`: recursively chown a RunCloud webapp tree to `www-data:www-data` while excluding `wp-content/uploads`. The script defaults to the `runcloud` system user if `--user` is omitted, and accepts overrides like `--user=ubuntu` for sites hosted under a custom webapp owner.

### Fixed

- `wp-freeze.sh`: mu-plugins directory now stays readable by the web user after freeze. RunCloud sets ACL `group:users-rc:---` on wp-content subdirectories; when `freeze_permissions()` set mu-plugins to 555 and the directory was owned by root, the ACL blocked the runcloud user from listing it, causing a WordPress fatal error on every page load ("There has been a critical error on your website"). New `ensure_muplugins_accessible()` function chowns mu-plugins to the detected web user after the freeze, so owner permissions override the restrictive group ACL.

### Changed

- `wp-freeze.sh`: `find -exec chmod` calls changed from `\;` to `+` for better performance on large file trees.

## [0.0.1.7] - 2026-05-09

### Added

- `laravel-migration.sh`: full Laravel migration between RunCloud servers. Mirrors `wp-migration.sh` patterns (SSH multiplex, `--setup-ssh`, `--staging-url`, source-creds-on-dest DB import) but reads `.env`, syncs `storage/app` + `public/build`, and runs `composer install` + `artisan optimize` + `migrate --force` on the destination. Auto-detects the webapp's PHP version by parsing `path /usr/local/lsws/lsphpXX/bin/lsphp` from `/etc/lsws-rc/conf.d/<app>.d/handler.conf` so composer/artisan run with the correct CLI binary instead of the system `/usr/bin/php` (which is often older than what the app's composer.lock requires). Caller can override via `PHP_BINARY` env var. Also drops a root `.htaccess` rewriting `/` → `public/` so LSWS serves the Laravel front controller — current RunCloud panel doesn't expose the "Public Path" setting that older versions had, so without this `.htaccess` newly-created Laravel webapps return 404 at `/`. Flags: `--skip-composer`, `--skip-build`, `--skip-storage`, `--skip-migrate`. Tested on codetot-portal jp1 → sg4 migration.

## [0.0.1.6] - 2026-05-08

### Fixed

- `cleanup-disk.sh --site=NAME` no longer runs server-wide cleanup. The system-cleanup block (LiteSpeed swap at `/tmp/lsws-rc/swap`, every site's OLS cache under `/home/runcloud/lscaches/*/`, and `journalctl --vacuum`) ran unconditionally even when scoping to a single site, so an app-level "Cleanup" action from a dashboard would prune every other site's OLS cache too. When `--site` is given the script now only touches the target site's `wp-content/cache` plus its own `/home/runcloud/lscaches/<site>/` directory; swap, journal, and other sites' caches are left alone. Whole-fleet behaviour (no flags or `--system-only`) is unchanged.

## [0.0.1.5] - 2026-05-08

### Fixed

- `server-metrics.sh`: `git_dirty` detection now catches untracked files. The previous check used `git diff --quiet` plus `git diff --cached --quiet`, which only see modifications to tracked files and staged changes — newly installed plugins or theme directories that have never been committed don't show in either. Replaced with `git status --porcelain | head -1`, which covers modifications, staged changes, and untracked entries in a single call. Symptom: dashboards built on top of the JSON payload (e.g. runcloud-go) hid the "Git Cleanup" affordance even on repos with many untracked plugins.

## [0.0.1.4] - 2026-05-08

### Fixed

- Six scripts hardcoded `WEBROOT="/home/runcloud/webapps"`, so they silently failed on servers where webapps live under a custom system user (path layout `/home/<user>/webapps/<app>`). All now resolve the site path across `/home/runcloud/webapps` first, then `/home/*/webapps`, mirroring the pattern already used in `wp-plugin-push.sh`. Affected: `wp-update.sh`, `cleanup-disk.sh`, `wp-freeze.sh`, `fix-permission.sh`, `fix-permission-site.sh`, `debug-wp-cli.sh`.
- `fix-permission.sh` and `fix-permission-site.sh` no longer hardcode `chown runcloud:runcloud`. The owner of each web app is now read from the directory itself (`stat -c '%U:%G'`) before chowning, so files keep the correct owner on multi-tenant servers instead of being clobbered to `runcloud`.

## [0.0.1.3] - 2026-05-02

### Fixed

- `wp-migration.sh`: `$table_prefix` is now parsed correctly. The previous `sed "s/.*'//; s/'.*//"` was greedy and captured the trailing `;` instead of the prefix value, producing `prefix: ;` in logs and silently breaking step 6 (URL update would query `;options` and fail). Replaced with `awk -F"'"` + validation that the prefix matches `[A-Za-z0-9_]+` (#25).

## [0.0.1.2] - 2026-05-02

### Fixed

- `wp-migration.sh`: SSH connections are now multiplexed via `ControlMaster=auto` + `ControlPersist=10m`, so password (or key passphrase) is prompted at most once per migration instead of ~8 times across the db-export, rsync, config-sync, and url-update steps (#23).
- `wp-migration.sh`: database import errors are no longer masked. The mysql pipeline now uses `set -o pipefail` and propagates the real exit code, so connection or auth failures (e.g. `ERROR 1045 Access denied`) abort the migration with an actionable hint instead of being followed by a bogus "Database imported successfully" line (#23).

## [0.0.1.1] - 2026-05-02

### Fixed

- `wp-migration.sh`: source path is now auto-detected by scanning `/home/*/webapps/<app>` instead of trusting `$USER`, which broke the script when invoked as root (`/home/root/webapps/...` doesn't exist) and didn't support custom system users on private servers. Override with `SRC_USER=<user>` if auto-detection picks the wrong match (#21).
- `wp-git-cleanup.sh`: detect stale `.git/index.lock` from a previously crashed run and abort cleanup with an actionable error instead of silently swallowing every subsequent `git commit` failure (#19). Commit and add operations now also surface their exit code rather than masking it with `2>/dev/null || true`.

## [0.0.1.0] - 2026-04-18

### Fixed

- Git cleanup now detects tracked files that match gitignore patterns and untracks them (`git rm --cached`), keeping files on disk but removing them from version control (e.g., `wp-content/wpvivid_image_optimization/`)
- Obsolete tracked files like `.maintenance-flags` are now deleted during cleanup, since per-site preferences are managed at root level by runcloud-go
- Scan mode reports tracked files that shouldn't be tracked (obsolete + artifact counts)
