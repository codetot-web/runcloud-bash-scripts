# Changelog

All notable changes to `runcloud-bash-scripts` will be documented in this file.

## [1.2.0] — 2026-07-10

### Added

- **wp-ownership-audit.sh** — Scans WordPress webapps for file ownership issues that silently break sites:
  - Root-owned files in webapp directories (block wp-cli, cause 500 errors)
  - Wrong-user owned files (user A's webapp has files owned by user B)
  - ACL deny entries (`group:users-rc:---`) that prevent PHP-FPM from reading files
  - Supports `--site`, `--dirs-only` (quick check), `--fix` (auto-repair), `--format=json`

### Fixed

- **wp-health-check.sh**: Use FPM PHP binary for wp-cli probe instead of system CLI PHP.
  System PHP (`/usr/bin/php`) may lack extensions (e.g. `mysqli`) that the app's FPM
  PHP has, causing false-positive "MySQL extension missing" errors on RunCloud servers
  where the CLI and FPM PHP run different builds.
  - `detect_fpm_php()` already found the correct binary — now it is actually *used*
    as the PHP interpreter for all three wp-cli invocations (bare probe, DB eval,
    plugin list).
  - Falls back to system PHP gracefully when FPM binary cannot be detected.

## [1.1.0] — 2026-07-04

### Added

- `wp-ownership-audit.sh` — File ownership audit script

## [1.0.0] — 2026-06-27

### Added

- `wp-health-check.sh` — WordPress health auditor with probe loop (DB, plugin/theme fatals)
- `wp-vuln-check.sh` — WordPress vulnerability scanner
- `wp-update.sh` — WordPress core/plugin/theme updater
- `wp-security-audit.sh` — Full security audit (malware, webshells, file integrity)
- `litespeed-lockdown.sh` — Block PHP execution in uploads
- Various utility scripts (fix-permission, install-ioncube, etc.)
