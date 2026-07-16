# Changelog

All notable changes to `runcloud-bash-scripts` will be documented in this file.

## [1.3.0] — 2026-07-16

### Added

- **harden-abuseipdb.sh** — Automated Fail2Ban + AbuseIPDB integration:
  - Reads API key from `/var/lib/abuseipdb/.env` (never committed to repo)
  - Extends Fail2Ban with 3 additional jails: `apache-badbots`, `apache-overflows`, `apache-noscript`
  - Detects platform (RunCloud vs litesoup/Apache) and uses correct log paths
  - Configures AbuseIPDB reporting action on all bans (categories: 14/15/18/22)
  - Installs blacklist sync script + cron (every 6h)
  - Idempotent: safe to re-run
  - Supports `--dry-run` for preview

- **abuseipdb-blacklist-sync.sh** — Standalone blacklist sync script:
  - Downloads AbuseIPDB blacklist (confidence >= 75%, limit 500 IPs)
  - Blocks IPs via nftables, firewalld, or iptables (auto-detected)
  - Reads API key from `.env` file (shared with installer)
  - Logs to `/var/lib/abuseipdb/sync.log`

### Fixed

- **harden-abuseipdb.sh**: Single `logpath` per jail (fail2ban rejects duplicate keys)
- **harden-abuseipdb.sh**: Double-`%%` escape in actionban `printf` format string (fail2ban uses `%` as escape char)

## [1.2.0] — 2026-07-10

### Added

- **wp-ownership-audit.sh** — Scans WordPress webapps for file ownership issues

### Fixed

- **wp-health-check.sh**: Use FPM PHP binary for wp-cli probe

## [1.1.0] — 2026-07-04

### Added

- `wp-ownership-audit.sh` — File ownership audit script

## [1.0.0] — 2026-06-27

### Added

- Initial scripts: wp-health-check, wp-vuln-check, wp-update, wp-security-audit, litespeed-lockdown
