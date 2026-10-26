# Premium plugin updates (`wp-premium-update.sh`)

Premium (licensed) plugins — WPML/OTGS, Gravity Forms, ACF PRO, Perfmatters,
WooCommerce Multilingual — are not on WordPress.org, so they can't be updated
with `wp plugin update`. They are installed from version-pinned zips in the
private store [`codetot-web/premium-plugins`](https://github.com/codetot-web/premium-plugins),
deployed to each server at `/root/premium-plugins/`.

`wp-premium-update.sh` does that install **behind a PHP-version gate**, because
installing a package whose PHP floor the site does not meet is a documented way
to take a site down.

## Why the gate exists

Two failure modes, both white-screen:

```
PHP Fatal error: Uncaught RuntimeException: Composer detected issues in your
platform: Your Composer dependencies require a PHP version ">= 8.1.0".
  (thrown by vendor/composer/platform_check.php at autoload time)
```

```
PHP Parse error: syntax error, unexpected '|'     <- PHP 8.0+ union types
```

Real incident: **perfmatters 2.6.7** declares `Requires PHP: 8.1` and
auto-deactivated itself on five PHP 7.4 sites, killing their custom `/quantri/`
login URL. The plugin stays installed but inactive — the site looks fine until
someone needs the feature.

The web PHP version is routinely **lower** than the CLI version (`php -v` says
8.3 while the FPM/LSAPI serving the site runs 8.1), so the script never trusts
`php -v`. It detects the version the site is actually served by.

## Deploy the store to a server

The fleet boxes clone `runcloud-bash-scripts` over HTTPS with no credentials,
and the store is private — so the zips are **rsync'd**, not git-pulled:

```bash
# from the control box (us1)
rsync -az -e 'ssh -p <port>' /path/to/premium-plugins/*.zip \
    root@<server>:/root/premium-plugins/
```

`wp-premium-update.sh` looks for zips in this order:

1. `--zips-dir=DIR` (explicit)
2. `<script dir>/premium-plugins` (git submodule, if you mount the store)
3. `/root/premium-plugins` (rsync — the fleet default)
4. `<script dir>/plugins` (packages committed into the repo)

## Usage

```bash
# audit every WordPress site on the box (dry-run, the default)
sudo ./wp-premium-update.sh --all-sites

# audit one site
sudo ./wp-premium-update.sh --site=APPNAME

# apply what passes the gate
sudo ./wp-premium-update.sh --all-sites --apply

# one plugin only
sudo ./wp-premium-update.sh --site=APPNAME --plugin=perfmatters --apply

# also install packages the site does not have yet
sudo ./wp-premium-update.sh --all-sites --install --apply

# machine-readable
sudo ./wp-premium-update.sh --all-sites --json
```

## How a site/package pair is judged

For each (site, package):

1. **PHP floor** — the higher of the package's `Requires PHP:` header and the
   version pinned in `vendor/composer/platform_check.php` (composer throws
   before any plugin code runs, so it wins when stricter).
2. **Site PHP** — detected from the stack, in order:
   - RunCloud nginx: `/etc/php<XY>rc/fpm.d/<app>.conf`
   - RunCloud OLS: `/etc/lsws-rc/conf.d/<app>.d/handler.conf` → `lsphpNN`
   - litesoup/Apache: vhost `SetHandler proxy:unix:/run/php/…-php<X.Y>-fpm.sock`,
     matched by file name, then `ServerName`/`ServerAlias`, then **`DocumentRoot`**
     (webapp `dichvu-website` lives in `dichvu.website.conf`, so name matching
     alone misses real sites).
3. If site PHP < package floor → **BLOCKED**. Nothing is written. The report
   names the required version. There is no automatic override:
   `--allow-php-gate-bypass` exists for the case where you are *about to*
   upgrade that box's PHP and want to stage the plugin first — read it twice.
4. If the floor is met (or the package declares none) → the package's top-level
   PHP files are **linted with the site's own php binary** (`php -l`). A parse
   error blocks the update even when the header claims compatibility — this
   catches packages that use newer syntax than they advertise.
5. Only then is the update applied.

If the site's PHP cannot be detected at all, the site is **blocked**, not
guessed: a wrong PHP assumption is exactly what takes a site down.

## What an apply does

- keeps `<slug>.bak-<ts>` next to the plugin (`--skip-backup` to disable)
- **moves the old folder aside and extracts fresh** — never extracts on top of
  the old folder, which leaves files from the previous version behind
- `chown` to the site owner and `755`/`644` perms (a root extract leaves
  `root:root`, which the PHP worker cannot read → silent fatal)
- re-reads the on-disk `Version:` header and reports a mismatch
- re-activates the plugin if it was active, then **verifies it is still active**
  — an auto-deactivate means it fatalled on load → automatic rollback
- HTTP check on `siteurl`; a non-200/301/302 triggers an automatic rollback
  from the `.bak` and a re-check
- flushes WP object cache and LiteSpeed cache
- commits per plugin on git-tracked sites, e.g.
  `chore(plugin): perfmatters 2.6.7 -> 2.6.9 (premium zip, PHP 8.1)`

A failed `git add` is reported loudly, never swallowed: when `.git/objects/*`
is root-owned (a root `git fetch` leaves it that way) the add fails and a bare
`git diff --cached --quiet` then looks like "nothing to commit". The script
prints the error and the exact `chown` to run.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | everything planned/applied, nothing blocked or failed |
| 2 | at least one update failed (a rollback happened) |

Blocked sites are not an error — they are a report. Check the summary line
`blocked: N` and the per-site `⊘` lines.

## Fleet rollout

```bash
# 1. deploy the script + the store to every server
sqlite3 ~/.rc/rc.db "SELECT hostname||' '||ssh_port FROM servers;" | while read h p; do
    rsync -az -e "ssh -p $p" wp-premium-update.sh root@$h:/root/runcloud-bash-scripts/
    ssh -p $p root@$h 'chmod +x /root/runcloud-bash-scripts/wp-premium-update.sh'
    rsync -az -e "ssh -p $p" premium-plugins/*.zip root@$h:/root/premium-plugins/
done

# 2. audit everywhere first — read the blocked list before applying anything
sqlite3 ~/.rc/rc.db "SELECT hostname||' '||ssh_port FROM servers;" | while read h p; do
    echo "=== $h ==="
    ssh -p $p root@$h 'cd /root/runcloud-bash-scripts && ./wp-premium-update.sh --all-sites' 2>&1 | tail -12
done

# 3. apply only after the audit is clean
```

Never run step 3 on a box where step 2 reported `blocked:` sites you did not
expect — that is the signal that some site's PHP is older than the packages you
are about to push.
