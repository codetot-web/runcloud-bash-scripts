# Changelog

All notable changes to `runcloud-bash-scripts` will be documented in this file.

## [1.1.0] — 2026-07-04

### Fixed

- **wp-health-check.sh**: Use FPM PHP binary for wp-cli probe instead of system CLI PHP.
  System PHP (`/usr/bin/php`) may lack extensions (e.g. `mysqli`) that the app's FPM
  PHP has, causing false-positive "MySQL extension missing" errors on RunCloud servers
  where the CLI and FPM PHP run different builds.
  - `detect_fpm_php()` already found the correct binary — now it is actually *used*
    as the PHP interpreter for all three wp-cli invocations (bare probe, DB eval,
    plugin list).
  - Falls back to system PHP gracefully when FPM binary cannot be detected.

## [1.0.0] — 2026-06-27

### Added

- `wp-health-check.sh` — WordPress health auditor with probe loop (DB, plugin/theme fatals)
- `wp-vuln-check.sh` — WordPress vulnerability scanner
- `wp-update.sh` — WordPress core/plugin/theme updater
- `wp-security-audit.sh` — Full security audit (malware, webshells, file integrity)
- `litespeed-lockdown.sh` — Block PHP execution in uploads
- Various utility scripts (fix-permission, install-ioncube, etc.)
