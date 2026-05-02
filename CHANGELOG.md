# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

## [0.0.1.1] - 2026-05-02

### Fixed

- `wp-migration.sh`: source path is now auto-detected by scanning `/home/*/webapps/<app>` instead of trusting `$USER`, which broke the script when invoked as root (`/home/root/webapps/...` doesn't exist) and didn't support custom system users on private servers. Override with `SRC_USER=<user>` if auto-detection picks the wrong match (#21).
- `wp-git-cleanup.sh`: detect stale `.git/index.lock` from a previously crashed run and abort cleanup with an actionable error instead of silently swallowing every subsequent `git commit` failure (#19). Commit and add operations now also surface their exit code rather than masking it with `2>/dev/null || true`.

## [0.0.1.0] - 2026-04-18

### Fixed

- Git cleanup now detects tracked files that match gitignore patterns and untracks them (`git rm --cached`), keeping files on disk but removing them from version control (e.g., `wp-content/wpvivid_image_optimization/`)
- Obsolete tracked files like `.maintenance-flags` are now deleted during cleanup, since per-site preferences are managed at root level by runcloud-go
- Scan mode reports tracked files that shouldn't be tracked (obsolete + artifact counts)
