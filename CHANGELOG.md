# Changelog

All notable changes to `runcloud-bash-scripts` will be documented in this file.

## [v0.0.2.2] — 2026-10-26

### Added

- **`wp-premium-update.sh`** — PHP-version-gated updater for premium (licensed)
  plugins, installed from the private store `codetot-web/premium-plugins`
  (deployed to servers at `/root/premium-plugins/`). For every (site, package)
  it:
  - reads the package's PHP floor from the `Requires PHP:` header **and**
    `vendor/composer/platform_check.php` (composer throws at autoload, before any
    plugin code runs, so the stricter of the two wins);
  - detects the PHP version the site is **actually served by** — RunCloud nginx
    `fpm.d`, RunCloud OLS `handler.conf`, or litesoup/Apache `proxy:fcgi` socket
    (matched by vhost name, `ServerName`/`ServerAlias`, then `DocumentRoot`,
    because webapp `dichvu-website` lives in `dichvu.website.conf`). Never
    `php -v`: the CLI binary is routinely a different major than the web PHP;
  - **BLOCKS** (writes nothing) when the site is below the floor, naming the
    required version. No automatic override — `--allow-php-gate-bypass` is for
    staging ahead of a planned PHP upgrade;
  - **lints** the package's top-level PHP files with the *site's own* php binary
    before installing, so a package that uses newer syntax than it advertises is
    caught pre-install;
  - blocks the site entirely if its PHP cannot be detected (a wrong PHP
    assumption is what takes a site down).
  Apply is dry-run by default; `--apply` keeps `<slug>.bak-<ts>`, moves the old
  folder aside and extracts fresh (never on top), fixes ownership to the site
  owner, re-reads the on-disk version, re-activates a previously-active plugin
  and **verifies it is still active**, checks HTTP and **auto-rolls-back** on a
  non-200/301/302, flushes caches, and commits per plugin.
- `docs/premium-plugin-update.md` — gate rationale (the perfmatters 2.6.7 on
  PHP 7.4 incident), store deployment by rsync, per-stack PHP detection, exit
  codes, fleet rollout procedure.

### Fixed

- **Swallowed `git add` failure in the per-plugin commit path.** When
  `.git/objects/<xx>` dirs are root-owned (a root `git fetch` leaves them that
  way), `git add` fails with `insufficient permission for adding an object to
  repository database` — and a bare `git diff --cached --quiet` then reports no
  diff, which is indistinguishable from "nothing to commit". The update landed
  on disk with no commit and the revert safety net silently did not exist. Any
  output from `git add` is now treated as a failure, printed with the exact
  `chown` to run.
- **`version_cmp` compared only 3 components**, so Gravity Forms'
  `3.1.3.4` vs `3.1.3.10` compared **equal** and a real update would have been
  skipped. Now compares 4.
- **`zip_entry_php` returned false negatives under `set -o pipefail`**:
  `unzip -p … | grep -q 'Plugin Name:'` fails when grep exits early and unzip
  takes SIGPIPE, so packages whose entry file was not first alphabetically
  (Gravity Forms' `gravityforms.php`) read as having no version header. The body
  is now captured before matching.

## [v0.0.2.1] — 2026-08-05

### Changed

- **Remove ClamAV/rootkit deep scan** from `wp-security-audit.sh` and
  `wp-security-audit-installer.sh`. The ClamAV + rkhunter + chkrootkit deep
  scan caused high CPU load on production servers (see litesoup work item #4).
  The audit now runs fast pattern detection only (malware shells, obfuscated
  files, WP core integrity, suspicious cron hooks, uploads audit) — no extra
  packages required. Removed the `--install-deps` flag and the dependency
  availability checks. Security relies on LiteSoup WAF + Apache hardening.

## [v0.0.2.0] — 2026-07-24

### Added

- **litesoup/Apache compatibility** — Both `cleanup-disk.sh` and `install-ioncube.sh`
  now work on Apache + PHP-FPM stacks (Ondrej PPA / vanilla / litesoup).

- **`cleanup-disk.sh`**: Added Divi/Builder cache (`wp-content/et-cache`) and apt
  package cache cleanup (`apt-get autoclean`). LiteSpeed paths are silently skipped
  on Apache hosts via existing `[ -d "$dir" ]` guards. (`cleanup-disk.sh`)

- **`install-ioncube.sh`**: Added `install_standard()` function that detects
  standard PHP-FPM services (`phpX.Y-fpm`), finds extension dirs via
  `php-configX.Y --extension-dir`, writes ini to
  `/etc/php/X.Y/mods-available/`, enables via `phpenmod`, and reloads FPM
  gracefully. Runs alongside existing OpenLiteSpeed and RunCloud installers
  — auto-detects which stacks are present. (`install-ioncube.sh`)

## [v0.0.1.10] — 2026-07-16

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

- **abuseipdb-blacklist-sync.sh**: Graceful handling of HTTP 429 (rate limit) — skips cycle instead of failing
- **harden-abuseipdb.sh**: Include `runcloud-agent` and `sshd-ddos` jails in AbuseIPDB action wiring
- **abuseipdb-blacklist-sync.sh**: Reduce cron frequency to every 12h to stay within API rate limits
- **harden-abuseipdb.sh**: Single `logpath` per jail (fail2ban rejects duplicate keys)
- **harden-abuseipdb.sh**: Double-`%%` escape in actionban `printf` format string (fail2ban uses `%` as escape char)

## [v0.0.1.9] — 2026-07-10

### Added

- **wp-ownership-audit.sh** — Scans WordPress webapps for file ownership issues

### Fixed

- **wp-health-check.sh**: Use FPM PHP binary for wp-cli probe

## [v0.0.1.8] — 2026-07-04

### Added

- **wp-ownership-audit.sh** — File ownership audit script

## [v0.0.1.7] — 2026-06-27

### Added

- Initial scripts: wp-health-check, wp-vuln-check, wp-update, wp-security-audit, litespeed-lockdown

## 2026-10-14
- New: `plugins-sync.sh` — compare a reference WP repo (e.g. `codetot-clients/masanconsumer`) against the local `~/plugins/` store; classify each plugin as aligned / behind / missing, and download the latest FREE plugin zip from api.wordpress.org. Premium plugins (rank-math-pro, perfmatters, wpvivid-backup-pro, etc.) are listed separately and must be obtained manually with a valid license.
- New: `plugins/.gitkeep` — landing folder for the premium plugin zips. `wp-plugin-push.sh --plugins-dir` defaults to it.
