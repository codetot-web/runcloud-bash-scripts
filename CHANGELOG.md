# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

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
