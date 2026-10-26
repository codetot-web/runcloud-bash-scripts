#!/bin/bash
#
# wp-premium-update.sh — PHP-version-gated premium plugin updater
#
# Premium (licensed) plugins can't be updated through WordPress.org, so they are
# installed from the zips in this repo's plugins/ directory. Those packages often
# declare a PHP floor that the SITE'S WEB PHP does not meet, and installing them
# anyway is how a site goes white:
#
#   PHP Fatal error: Uncaught RuntimeException: Composer detected issues in your
#   platform: Your Composer dependencies require a PHP version ">= 8.1.0".
#     (thrown by vendor/composer/platform_check.php)
#
#   PHP Parse error: syntax error, unexpected '|'      <- union types, PHP 8.0+
#
# Real incident: perfmatters 2.6.7 declares Requires PHP 8.1 and auto-deactivated
# itself on five PHP 7.4 sites, killing their custom /quantri/ login URL.
#
# This script therefore treats the PHP requirement as a HARD GATE, not a warning:
#
#   1. detect the PHP version the SITE is actually served by (not `php -v`, which
#      reports the CLI binary and is routinely a different version),
#   2. read the package's requirement from its plugin header AND, when present,
#      from vendor/composer/platform_check.php (the authoritative composer floor),
#   3. lint the package's entry files with the SITE'S OWN php binary before
#      installing anything,
#   4. refuse (BLOCKED) when the site is below the floor — no override by default.
#
# A site that cannot take a package is reported, never silently skipped.
#
# Usage:
#   sudo ./wp-premium-update.sh --all-sites                    # audit every site (dry-run)
#   sudo ./wp-premium-update.sh --site=APPNAME                 # audit one site
#   sudo ./wp-premium-update.sh --all-sites --apply            # update everything that passes
#   sudo ./wp-premium-update.sh --site=APPNAME --plugin=perfmatters --apply
#   sudo ./wp-premium-update.sh --all-sites --json             # machine-readable audit
#
# Options:
#   --site=NAME        Web app name (repeatable). Resolved across /home/*/webapps/
#   --all-sites        Every WordPress site under --webroot
#   --webroot=PATH     Site root (default: auto-detect /home/*/webapps)
#   --zips-dir=DIR     Directory of <slug>.<version>.zip (default: <script dir>/plugins)
#   --plugin=SLUG      Limit to one plugin slug (repeatable)
#   --apply            Make changes. Default is dry-run.
#   --dry-run          Print the plan only (default)
#   --install          Also install packages that are NOT yet present on a site
#   --skip-http        Skip the post-apply HTTP 200 check
#   --skip-backup      Do not keep <slug>.bak-<ts> (NOT recommended)
#   --allow-php-gate-bypass
#                      DANGEROUS. Update even when the site's PHP is below the
#                      package floor. Only for a box you are about to upgrade.
#   --json             Print the plan/result as JSON
#   -h, --help         Show this help
#
# Safety:
#   - dry-run by default; nothing is written without --apply
#   - the PHP gate is per (site, package) and checked against the WEB PHP version
#   - packages are linted with the site's php binary before install
#   - the existing plugin folder is moved aside, never overwritten in place
#     (an override leaves stale files from the old version behind)
#   - ownership is fixed to the site owner after extract (root:root breaks PHP)
#   - HTTP 500/0 after an update rolls that plugin back automatically
#   - per-plugin git commit on git-tracked sites (the revert safety net)
#   - a plugin that was active is re-activated and verified active
#
set -uo pipefail

# --- Defaults -------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Where the premium zips live. First existing wins:
#   1. --zips-dir=...                    (explicit)
#   2. <script dir>/premium-plugins      (git submodule of the private store)
#   3. /root/premium-plugins             (rsync-deployed copy — the fleet default)
#   4. <script dir>/plugins              (packages committed straight into the repo)
# The private store is NOT git-clonable from a fleet box (those boxes clone over
# HTTPS with no credentials and the store is private), so on servers the zips
# arrive by rsync into /root/premium-plugins. See docs/premium-plugin-update.md.
ZIPS_DIR=""
WEBROOT=""
SITES=()
PLUGIN_FILTER=()
ALL_SITES=0
APPLY=0
INSTALL_MISSING=0
SKIP_HTTP=0
SKIP_BACKUP=0
BYPASS_GATE=0
JSON=0
TS="$(date +%Y%m%d-%H%M%S)"

# --- Colors (only when stdout is a tty) -----------------------------------
if [ -t 1 ]; then
    C_RESET=$'\033[0m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'; C_BOLD=$'\033[1m'
else
    C_RESET=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_BOLD=""
fi
info()  { [ "$JSON" -eq 1 ] || echo "${C_BLUE}▸${C_RESET} $*"; }
ok()    { [ "$JSON" -eq 1 ] || echo "${C_GREEN}✓${C_RESET} $*"; }
warn()  { [ "$JSON" -eq 1 ] || echo "${C_YELLOW}!${C_RESET} $*"; }
err()   { echo "${C_RED}✗${C_RESET} $*" >&2; }
blocked(){ [ "$JSON" -eq 1 ] || echo "${C_RED}⊘${C_RESET} $*"; }
section(){ [ "$JSON" -eq 1 ] || echo -e "\n${C_BOLD}== $* ==${C_RESET}"; }

# --- Args -----------------------------------------------------------------
for arg in "$@"; do
    case "$arg" in
        --site=*)        SITES+=("${arg#*=}") ;;
        --all-sites)     ALL_SITES=1 ;;
        --webroot=*)     WEBROOT="${arg#*=}" ;;
        --zips-dir=*)    ZIPS_DIR="${arg#*=}" ;;
        --plugin=*)      PLUGIN_FILTER+=("${arg#*=}") ;;
        --apply)         APPLY=1 ;;
        --dry-run)       APPLY=0 ;;
        --install)       INSTALL_MISSING=1 ;;
        --skip-http)     SKIP_HTTP=1 ;;
        --skip-backup)   SKIP_BACKUP=1 ;;
        --allow-php-gate-bypass) BYPASS_GATE=1 ;;
        --json)          JSON=1 ;;
        -h|--help)
            sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) err "Unknown option: $arg (see --help)"; exit 1 ;;
    esac
done

# --- Validate -------------------------------------------------------------
if [ "${#SITES[@]}" -eq 0 ] && [ "$ALL_SITES" -eq 0 ]; then
    err "Specify --site=NAME (repeatable) or --all-sites. See --help."
    exit 1
fi
if [ -z "$ZIPS_DIR" ]; then
    for cand in "${SCRIPT_DIR}/premium-plugins" /root/premium-plugins "${SCRIPT_DIR}/plugins"; do
        if [ -d "$cand" ] && [ -n "$(find "$cand" -maxdepth 1 -name '*.zip' -type f 2>/dev/null | head -1)" ]; then
            ZIPS_DIR="$cand"; break
        fi
    done
fi
if [ -z "$ZIPS_DIR" ] || [ ! -d "$ZIPS_DIR" ]; then
    err "zips dir not found. Looked for:"
    err "  \${SCRIPT_DIR}/premium-plugins, /root/premium-plugins, \${SCRIPT_DIR}/plugins"
    err "Deploy the store first (see docs/premium-plugin-update.md) or pass --zips-dir=DIR."
    exit 1
fi
ZIPS=()
while IFS= read -r z; do ZIPS+=("$z"); done < <(find "$ZIPS_DIR" -maxdepth 1 -name '*.zip' -type f | sort)
if [ "${#ZIPS[@]}" -eq 0 ]; then
    err "no *.zip in $ZIPS_DIR — nothing to do"
    exit 1
fi

# --- wp-cli ---------------------------------------------------------------
WP_CLI=""
for candidate in /usr/local/bin/wp /usr/bin/wp /RunCloud/Packages/RunCloudAgent/bin/wp-cli; do
    if [ -x "$candidate" ]; then WP_CLI="$candidate"; break; fi
done
if [ -z "$WP_CLI" ]; then err "wp-cli not found"; exit 1; fi

# --- Helpers --------------------------------------------------------------

# version_cmp A B -> prints "<", "=", ">"
# Compares up to FOUR numeric components (Gravity Forms ships 3.1.3.4, and
# 3.1.3.4 vs 3.1.3.10 must not compare equal). Non-numeric suffixes are stripped.
version_cmp() {
    local a="$1" b="$2"
    # Intentional word splitting on the '.' IFS: version components.
    local IFS='.'
    local -a ap bp
    read -r -a ap <<< "$a"
    read -r -a bp <<< "$b"
    local i an bn
    for i in 0 1 2 3; do
        an="${ap[$i]:-0}"; bn="${bp[$i]:-0}"
        an="${an%%[!0-9]*}"; bn="${bn%%[!0-9]*}"
        an="${an:-0}"; bn="${bn:-0}"
        if [ "$an" -lt "$bn" ]; then echo "<"; return; fi
        if [ "$an" -gt "$bn" ]; then echo ">"; return; fi
    done
    echo "="
}

# detect_web_php <site_name> <site_path>
# Prints "<version>\t<php_binary>" for the PHP the SITE is served by.
# Covers the three stacks in the fleet:
#   1. RunCloud nginx  — per-app FPM pool at /etc/php<XY>rc/fpm.d/<app>.conf
#   2. RunCloud OLS    — /etc/lsws-rc/conf.d/<app>.d/handler.conf -> lsphpNN
#   3. litesoup Apache — vhost SetHandler proxy:unix:/run/php/litesoup-php<X.Y>-fpm.sock
# Never falls back to `php -v`: the CLI binary is frequently a different major
# than the FPM/LSAPI serving the site, and trusting it is the original incident.
detect_web_php() {
    local site="$1" path="$2" ver="" bin="" src=""

    # 1. RunCloud nginx FPM pools
    local phpdir tag
    for phpdir in /etc/php85rc /etc/php84rc /etc/php83rc /etc/php82rc \
                  /etc/php81rc /etc/php80rc /etc/php74rc /etc/php73rc /etc/php72rc; do
        if [ -f "$phpdir/fpm.d/${site}.conf" ]; then
            tag=$(basename "$phpdir" | sed 's/^php//;s/rc$//')
            ver=$(printf '%s' "$tag" | sed 's/\(.\)\(.\)/\1.\2/')
            bin="/RunCloud/Packages/php${tag}rc/bin/php"
            [ -x "$bin" ] || bin=""
            src="fpm.d"
            break
        fi
    done

    # 2. RunCloud OpenLiteSpeed
    if [ -z "$ver" ] && [ -f "/etc/lsws-rc/conf.d/${site}.d/handler.conf" ]; then
        tag=$(grep -oP 'path\s+/usr/local/lsws/lsphp\K[0-9]+(?=/bin/lsphp)' \
                "/etc/lsws-rc/conf.d/${site}.d/handler.conf" 2>/dev/null | head -1 || true)
        if [ -n "$tag" ]; then
            ver=$(printf '%s' "$tag" | sed 's/^\(.\)\(.\)/\1.\2/')
            bin="/usr/local/lsws/lsphp${tag}/bin/php"
            [ -x "$bin" ] || bin=""
            src="ols"
        fi
    fi

    # 3. litesoup / Apache + PHP-FPM (proxy fcgi socket in the vhost)
    if [ -z "$ver" ] && [ -d /etc/apache2/sites-enabled ]; then
        local vc
        vc="/etc/apache2/sites-enabled/${site}.conf"
        if [ ! -f "$vc" ]; then
            vc=$(grep -lE "Server(Name|Alias)[[:space:]]+${site}(\.|$|[[:space:]])" \
                    /etc/apache2/sites-enabled/*.conf 2>/dev/null | head -1 || true)
        fi
        # The vhost file name and ServerName often differ from the webapp name
        # (webapp "dichvu-website" -> vhost "dichvu.website.conf"), so name
        # matching alone misses real sites. Fall back to DocumentRoot: the vhost
        # whose docroot is this site path is authoritative.
        if [ -z "$vc" ] || [ ! -f "$vc" ]; then
            vc=$(grep -lE "^[[:space:]]*DocumentRoot[[:space:]]+\"?${path}(/public)?/?\"?(/|[[:space:]]|$)" \
                    /etc/apache2/sites-enabled/*.conf 2>/dev/null | head -1 || true)
        fi
        if [ -n "$vc" ] && [ -f "$vc" ]; then
            ver=$(grep -oP 'php\K[0-9]+\.[0-9]+(?=-fpm\.sock)' "$vc" 2>/dev/null | head -1 || true)
            if [ -n "$ver" ]; then
                local sock
                sock=$(ls /run/php/*php"${ver}"-fpm.sock 2>/dev/null | head -1 || true)
                if [ -n "$sock" ]; then
                    bin=$(ls /usr/bin/php"${ver}" /usr/local/bin/php"${ver}" 2>/dev/null | head -1 || true)
                fi
                src="apache"
            fi
        fi
    fi

    [ -z "$ver" ] && return 1
    printf '%s\t%s\t%s\n' "$ver" "${bin:--}" "${src:-?}"
    return 0
}

# zip_entry_php <zip> <slug> -> the plugin's main file path inside the zip
zip_entry_php() {
    local zip="$1" slug="$2" f body
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        # Capture first, then match. `unzip -p ... | grep -q` returns non-zero under
        # `set -o pipefail`: grep -q exits on the first match, unzip takes SIGPIPE,
        # and the pipeline is reported as failed even though the pattern matched.
        body="$(unzip -p "$zip" "${slug}/${f}" 2>/dev/null | head -c 20000)"
        case "$body" in
            *"Plugin Name:"*) echo "$f"; return 0 ;;
        esac
    done < <(unzip -Z1 "$zip" 2>/dev/null | awk -F/ -v s="$slug" '$1==s && $2 ~ /\.php$/ && NF==2 {print $2}')
    return 1
}

# zip_header <zip> <slug> <field> -> header value (Version, Requires PHP, ...)
zip_header() {
    local zip="$1" slug="$2" field="$3" entry
    entry="$(zip_entry_php "$zip" "$slug")" || return 1
    unzip -p "$zip" "${slug}/${entry}" 2>/dev/null \
        | grep -E "^[[:space:]]*\*?[[:space:]]*${field}:" \
        | head -1 \
        | sed -E "s@^[[:space:]]*\*?[[:space:]]*${field}:[[:space:]]*@@; s@[[:space:]]+\$@@; s@\*/.*\$@@"
}

# zip_composer_floor <zip> <slug> -> "8.1.0" from vendor/composer/platform_check.php
# This is the authoritative floor: the file throws at autoload time, before any
# plugin code runs, so a site below it goes fatal even if the header is silent.
zip_composer_floor() {
    local zip="$1" slug="$2" body id
    body="$(unzip -p "$zip" "${slug}/vendor/composer/platform_check.php" 2>/dev/null || true)"
    [ -n "$body" ] || return 1
    id="$(printf '%s' "$body" | grep -oP 'PHP_VERSION_ID\s*<\s*\K[0-9]+' | head -1 || true)"
    [ -n "$id" ] || return 1
    # 80100 -> 8.1.0
    printf '%s.%s.%s\n' "$((id / 10000))" "$(( (id / 100) % 100 ))" "$((id % 100))"
}

# required_php <zip> <slug> -> effective PHP floor for the package (may be empty)
required_php() {
    local zip="$1" slug="$2" hdr floor
    hdr="$(zip_header "$zip" "$slug" 'Requires PHP' || true)"
    floor="$(zip_composer_floor "$zip" "$slug" || true)"
    # composer's platform_check is stricter than the header — take the higher
    if [ -n "$hdr" ] && [ -n "$floor" ]; then
        if [ "$(version_cmp "$hdr" "$floor")" = "<" ]; then echo "$floor"; else echo "$hdr"; fi
    elif [ -n "$hdr" ]; then echo "$hdr"
    elif [ -n "$floor" ]; then echo "$floor"
    fi
}

# lint_zip <zip> <slug> <php_bin> -> 0 if every top-level entry file parses
# Runs the SITE's own php binary, so a parse error is caught before the package
# ever lands in wp-content/plugins/.
lint_zip() {
    local zip="$1" slug="$2" bin="$3" tmp f rc=0
    [ "$bin" = "-" ] && return 0            # no binary to lint with; header gate stands
    [ -x "$bin" ] || return 0
    tmp="$(mktemp -d)"
    unzip -qo "$zip" -d "$tmp" 2>/dev/null || { rm -rf "$tmp"; return 0; }
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        if ! "$bin" -l "${tmp}/${slug}/${f}" >/dev/null 2>&1; then
            echo "parse-error:${f}" >&2
            rc=1
        fi
    done < <(find "${tmp}/${slug}" -maxdepth 1 -name '*.php' -type f -printf '%f\n' 2>/dev/null)
    rm -rf "$tmp"
    return $rc
}

# find_wp_sites -> newline list of "name<TAB>path"
find_wp_sites() {
    local base
    if [ -n "$WEBROOT" ]; then
        [ -d "$WEBROOT" ] && for d in "$WEBROOT"/*/; do
            [ -f "${d}wp-config.php" ] && printf '%s\t%s\n' "$(basename "$d")" "${d%/}"
        done
        return
    fi
    for base in /home/*/webapps; do
        [ -d "$base" ] || continue
        for d in "$base"/*/; do
            [ -f "${d}wp-config.php" ] && printf '%s\t%s\n' "$(basename "$d")" "${d%/}"
        done
    done
}

http_code() {
    local url="$1"
    curl -skL --max-time 20 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || echo "000"
}

# --- Resolve target sites -------------------------------------------------
TARGETS=()
if [ "$ALL_SITES" -eq 1 ]; then
    while IFS=$'\t' read -r n p; do [ -n "$n" ] && TARGETS+=("${n}|${p}"); done < <(find_wp_sites)
else
    for s in "${SITES[@]}"; do
        found=""
        for base in /home/*/webapps; do
            if [ -d "${base}/${s}" ] && [ -f "${base}/${s}/wp-config.php" ]; then
                found="${s}|${base}/${s}"; break
            fi
        done
        if [ -z "$found" ]; then
            err "site '$s' not found as a WordPress app under /home/*/webapps/"
            continue
        fi
        TARGETS+=("$found")
    done
fi

if [ "${#TARGETS[@]}" -eq 0 ]; then
    err "no WordPress sites resolved"
    exit 1
fi

# --- Banner ---------------------------------------------------------------
if [ "$JSON" -eq 0 ]; then
    echo ""
    echo "${C_BOLD}wp-premium-update — ${#TARGETS[@]} site(s), ${#ZIPS[@]} package(s)${C_RESET}"
    echo "  zips:   $ZIPS_DIR"
    [ "$APPLY" -eq 1 ] && warn "APPLY MODE — changes will be made" || info "dry-run — nothing will be changed"
    [ "$BYPASS_GATE" -eq 1 ] && err "PHP GATE BYPASS ENABLED — sites below a package's PHP floor will be updated anyway"
fi

# --- Result accumulators --------------------------------------------------
JSON_ROWS=()
N_PLANNED=0; N_APPLIED=0; N_FAILED=0; N_BLOCKED=0; N_UPTODATE=0; N_NOTINSTALLED=0

# --- Main loop ------------------------------------------------------------
for entry in "${TARGETS[@]}"; do
    SITE_NAME="${entry%%|*}"
    SITE_PATH="${entry##*|}"
    SITE_OWNER="$(stat -c '%U' "$SITE_PATH" 2>/dev/null || echo root)"
    [ "$SITE_OWNER" = "root" ] && SITE_OWNER="runcloud"

    section "Site: $SITE_NAME  ($SITE_PATH)"
    info "owner: $SITE_OWNER"

    PHP_INFO="$(detect_web_php "$SITE_NAME" "$SITE_PATH" || true)"
    if [ -z "$PHP_INFO" ]; then
        err "  cannot detect the WEB php version for this site — refusing to touch it."
        err "  (a wrong PHP assumption is exactly what takes a site down; fix detection first)"
        N_BLOCKED=$((N_BLOCKED+1))
        JSON_ROWS+=("{\"site\":\"$SITE_NAME\",\"plugin\":\"*\",\"action\":\"blocked\",\"reason\":\"php-version-undetectable\"}")
        continue
    fi
    SITE_PHP="$(printf '%s' "$PHP_INFO" | cut -f1)"
    SITE_PHP_BIN="$(printf '%s' "$PHP_INFO" | cut -f2)"
    PHP_SRC="$(printf '%s' "$PHP_INFO" | cut -f3)"
    info "web PHP: ${C_BOLD}${SITE_PHP}${C_RESET}  (detected via ${PHP_SRC}, bin: ${SITE_PHP_BIN})"

    # Installed plugins (one call, not one per package)
    INSTALLED="$(sudo -u "$SITE_OWNER" "$WP_CLI" --path="$SITE_PATH" --skip-plugins --skip-themes \
                    plugin list --format=csv --fields=name,version,status 2>/dev/null || true)"
    if [ -z "$INSTALLED" ]; then
        err "  wp-cli could not list plugins for this site — skipping (site may be broken already)"
        N_BLOCKED=$((N_BLOCKED+1))
        JSON_ROWS+=("{\"site\":\"$SITE_NAME\",\"plugin\":\"*\",\"action\":\"blocked\",\"reason\":\"wp-cli-failed\"}")
        continue
    fi

    SITE_URL="$(sudo -u "$SITE_OWNER" "$WP_CLI" --path="$SITE_PATH" --skip-plugins --skip-themes \
                    option get siteurl 2>/dev/null || true)"

    SITE_APPLIED=0
    for zip in "${ZIPS[@]}"; do
        fname="$(basename "$zip")"
        base="${fname%.zip}"
        slug="${base%%.*}"

        # --plugin filter (--plugin=SLUG, repeatable). No filter => every package.
        if [ "${#PLUGIN_FILTER[@]}" -gt 0 ]; then
            want=0
            for pf in "${PLUGIN_FILTER[@]}"; do
                if [ "$pf" = "$slug" ]; then want=1; break; fi
            done
            [ "$want" -eq 1 ] || continue
        fi

        # Package metadata (header, not filename)
        PKG_VER="$(zip_header "$zip" "$slug" 'Version' || true)"
        if [ -z "$PKG_VER" ]; then
            warn "  ${slug}: no Version: header in ${fname} — skipping (corrupt or wrong slug)"
            continue
        fi
        PKG_PHP_REQ="$(required_php "$zip" "$slug" || true)"

        # Installed version / status
        line="$(printf '%s\n' "$INSTALLED" | awk -F, -v s="$slug" 'NR>1 && $1==s {print $2"\t"$3}' | head -1)"
        INST_VER=""; INST_STATUS=""
        if [ -n "$line" ]; then INST_VER="$(printf '%s' "$line" | cut -f1)"; INST_STATUS="$(printf '%s' "$line" | cut -f2)"; fi

        if [ -z "$INST_VER" ]; then
            if [ "$INSTALL_MISSING" -eq 0 ]; then
                N_NOTINSTALLED=$((N_NOTINSTALLED+1))
                continue
            fi
            ACTION="install"
            CUR="(not installed)"
        else
            cmp="$(version_cmp "$INST_VER" "$PKG_VER")"
            if [ "$cmp" = ">" ] || [ "$cmp" = "=" ]; then
                N_UPTODATE=$((N_UPTODATE+1))
                continue
            fi
            ACTION="update"
            CUR="$INST_VER"
        fi

        # ---- PHP GATE ----
        if [ -n "$PKG_PHP_REQ" ]; then
            if [ "$(version_cmp "$SITE_PHP" "$PKG_PHP_REQ")" = "<" ]; then
                if [ "$BYPASS_GATE" -eq 0 ]; then
                    blocked "  ${slug}: BLOCKED  site PHP ${SITE_PHP} < package requires ${PKG_PHP_REQ}  (${CUR} -> ${PKG_VER})"
                    blocked "      → upgrade this site's PHP to >= ${PKG_PHP_REQ} first, or leave it on ${CUR}"
                    N_BLOCKED=$((N_BLOCKED+1))
                    JSON_ROWS+=("{\"site\":\"$SITE_NAME\",\"plugin\":\"$slug\",\"action\":\"blocked\",\"site_php\":\"$SITE_PHP\",\"requires_php\":\"$PKG_PHP_REQ\",\"installed\":\"${INST_VER:-none}\",\"package\":\"$PKG_VER\"}")
                    continue
                else
                    warn "  ${slug}: PHP gate BYPASSED (site ${SITE_PHP} < requires ${PKG_PHP_REQ}) — proceeding because --allow-php-gate-bypass"
                fi
            fi
        else
            info "  ${slug}: package declares no PHP floor — relying on the lint gate"
        fi

        # ---- LINT GATE (site's own php binary) ----
        if ! lint_out="$(lint_zip "$zip" "$slug" "$SITE_PHP_BIN" 2>&1)"; then
            blocked "  ${slug}: BLOCKED  package does not parse under PHP ${SITE_PHP}: ${lint_out}"
            N_BLOCKED=$((N_BLOCKED+1))
            JSON_ROWS+=("{\"site\":\"$SITE_NAME\",\"plugin\":\"$slug\",\"action\":\"blocked\",\"site_php\":\"$SITE_PHP\",\"reason\":\"lint\",\"detail\":\"${lint_out//\"/}\"}")
            continue
        fi

        # ---- Plan ----
        N_PLANNED=$((N_PLANNED+1))
        req_note="${PKG_PHP_REQ:-none}"
        if [ "$APPLY" -eq 0 ]; then
            ok "  ${slug}: would ${ACTION}  ${CUR} -> ${PKG_VER}   (site PHP ${SITE_PHP} >= ${req_note}, lint OK)"
            JSON_ROWS+=("{\"site\":\"$SITE_NAME\",\"plugin\":\"$slug\",\"action\":\"plan-${ACTION}\",\"site_php\":\"$SITE_PHP\",\"requires_php\":\"${PKG_PHP_REQ:-}\",\"installed\":\"${INST_VER:-none}\",\"package\":\"$PKG_VER\"}")
            continue
        fi

        # ---- Apply ----
        PLUG_DIR="${SITE_PATH}/wp-content/plugins"
        TARGET_DIR="${PLUG_DIR}/${slug}"
        BACKUP=""

        if [ -d "$TARGET_DIR" ] && [ "$SKIP_BACKUP" -eq 0 ]; then
            BACKUP="${TARGET_DIR}.bak-${TS}"
            if cp -a "$TARGET_DIR" "$BACKUP" 2>/dev/null; then
                info "  ${slug}: backed up -> $(basename "$BACKUP")"
            else
                err "  ${slug}: backup failed — NOT touching this plugin"
                N_FAILED=$((N_FAILED+1))
                JSON_ROWS+=("{\"site\":\"$SITE_NAME\",\"plugin\":\"$slug\",\"action\":\"failed\",\"reason\":\"backup-failed\"}")
                continue
            fi
        fi

        WAS_ACTIVE=0
        [ "$INST_STATUS" = "active" ] && WAS_ACTIVE=1

        # Clean replace: move the old folder aside, extract fresh.
        # Never extract on top of the old folder — that leaves files from the
        # previous version behind and produces phantom fatals.
        [ -d "$TARGET_DIR" ] && mv "$TARGET_DIR" "${TARGET_DIR}.old-${TS}"
        if ! unzip -qo "$zip" -d "$PLUG_DIR" 2>/dev/null; then
            err "  ${slug}: extract failed — rolling back"
            rm -rf "$TARGET_DIR"
            [ -d "${TARGET_DIR}.old-${TS}" ] && mv "${TARGET_DIR}.old-${TS}" "$TARGET_DIR"
            N_FAILED=$((N_FAILED+1))
            JSON_ROWS+=("{\"site\":\"$SITE_NAME\",\"plugin\":\"$slug\",\"action\":\"failed\",\"reason\":\"extract-failed\"}")
            continue
        fi
        rm -rf "${TARGET_DIR}.old-${TS}"

        # Ownership: an extract as root leaves root:root, which the FPM/LSAPI
        # worker cannot read -> silent fatal. Fix to the site owner immediately.
        SITE_GROUP="$(stat -c '%G' "$SITE_PATH" 2>/dev/null || echo "$SITE_OWNER")"
        chown -R "${SITE_OWNER}:${SITE_GROUP}" "$TARGET_DIR" 2>/dev/null || true
        find "$TARGET_DIR" -type d -exec chmod 755 {} + 2>/dev/null || true
        find "$TARGET_DIR" -type f -exec chmod 644 {} + 2>/dev/null || true

        # Verify the version actually moved (never trust the tool's success msg)
        NEW_VER="$(zip_header "$zip" "$slug" 'Version' || true)"
        ON_DISK="$(grep -hE '^[[:space:]]*\*?[[:space:]]*Version:' "${TARGET_DIR}"/*.php 2>/dev/null \
                    | head -1 | sed -E 's@^[[:space:]]*\*?[[:space:]]*Version:[[:space:]]*@@' | tr -d '\r' || true)"
        if [ -n "$ON_DISK" ] && [ "$ON_DISK" != "$NEW_VER" ]; then
            warn "  ${slug}: on-disk version ${ON_DISK} != package ${NEW_VER} (entry file may differ)"
        fi

        # Re-activate if it was active, and confirm
        if [ "$WAS_ACTIVE" -eq 1 ]; then
            sudo -u "$SITE_OWNER" "$WP_CLI" --path="$SITE_PATH" plugin activate "$slug" >/dev/null 2>&1 || true
            NOW_STATUS="$(sudo -u "$SITE_OWNER" "$WP_CLI" --path="$SITE_PATH" --skip-plugins --skip-themes \
                            plugin get "$slug" --field=status 2>/dev/null || true)"
            if [ "$NOW_STATUS" != "active" ]; then
                warn "  ${slug}: was active, now '${NOW_STATUS}' — it deactivated itself (usually a fatal on load)"
                if [ -n "$BACKUP" ] && [ -d "$BACKUP" ]; then
                    rm -rf "$TARGET_DIR"; mv "$BACKUP" "$TARGET_DIR"
                    chown -R "${SITE_OWNER}:${SITE_GROUP}" "$TARGET_DIR" 2>/dev/null || true
                    sudo -u "$SITE_OWNER" "$WP_CLI" --path="$SITE_PATH" plugin activate "$slug" >/dev/null 2>&1 || true
                    err "  ${slug}: ROLLED BACK to ${CUR} (auto-deactivate after update)"
                    N_FAILED=$((N_FAILED+1))
                    JSON_ROWS+=("{\"site\":\"$SITE_NAME\",\"plugin\":\"$slug\",\"action\":\"rolled-back\",\"reason\":\"auto-deactivated\"}")
                    continue
                fi
            fi
        fi

        # HTTP check + auto-rollback
        if [ "$SKIP_HTTP" -eq 0 ] && [ -n "$SITE_URL" ]; then
            code="$(http_code "$SITE_URL")"
            if [ "$code" != "200" ] && [ "$code" != "301" ] && [ "$code" != "302" ]; then
                err "  ${slug}: site returns HTTP ${code} after update — rolling back"
                if [ -n "$BACKUP" ] && [ -d "$BACKUP" ]; then
                    rm -rf "$TARGET_DIR"; mv "$BACKUP" "$TARGET_DIR"
                    chown -R "${SITE_OWNER}:${SITE_GROUP}" "$TARGET_DIR" 2>/dev/null || true
                    sudo -u "$SITE_OWNER" "$WP_CLI" --path="$SITE_PATH" plugin activate "$slug" >/dev/null 2>&1 || true
                    code2="$(http_code "$SITE_URL")"
                    err "  ${slug}: rolled back — site now HTTP ${code2}"
                fi
                N_FAILED=$((N_FAILED+1))
                JSON_ROWS+=("{\"site\":\"$SITE_NAME\",\"plugin\":\"$slug\",\"action\":\"rolled-back\",\"reason\":\"http-$code\"}")
                continue
            fi
            info "  ${slug}: HTTP ${code} after update"
        fi

        # Flush caches so the new version is actually served
        sudo -u "$SITE_OWNER" "$WP_CLI" --path="$SITE_PATH" cache flush >/dev/null 2>&1 || true
        sudo -u "$SITE_OWNER" "$WP_CLI" --path="$SITE_PATH" litespeed-purge all >/dev/null 2>&1 || true

        # Per-plugin git commit (the revert safety net).
        # `git add` can print "insufficient permission for adding an object to
        # repository database" when .git/objects/<xx> dirs are root-owned (a root
        # `git fetch` leaves them that way) — and the failure must be surfaced, not
        # swallowed: a bare `git diff --cached --quiet` then reports NO diff, which
        # is indistinguishable from "nothing to commit". The update would land on
        # disk with no commit and the revert safety net would silently not exist.
        # So: any output from `git add` is treated as a failure.
        if [ -d "${SITE_PATH}/.git" ]; then
            add_err="$(sudo -u "$SITE_OWNER" git -C "$SITE_PATH" add "wp-content/plugins/${slug}" 2>&1)"
            if [ -n "$add_err" ]; then
                warn "  ${slug}: git add FAILED — updated on disk but NOT committed:"
                printf '%s\n' "$add_err" | head -2 | sed 's/^/        /'
                case "$add_err" in
                    *"insufficient permission"*|*"Permission denied"*)
                        warn "        fix: chown -R ${SITE_OWNER}:${SITE_OWNER} ${SITE_PATH}/.git  then commit manually" ;;
                esac
            elif ! sudo -u "$SITE_OWNER" git -C "$SITE_PATH" diff --cached --quiet 2>/dev/null; then
                if sudo -u "$SITE_OWNER" git -C "$SITE_PATH" commit -q \
                        -m "chore(plugin): ${slug} ${CUR} -> ${PKG_VER} (premium zip, PHP ${SITE_PHP})" 2>/dev/null; then
                    info "  ${slug}: committed"
                else
                    warn "  ${slug}: git commit failed (change is on disk, not committed)"
                fi
            else
                info "  ${slug}: nothing staged (plugin is gitignored on this site)"
            fi
        fi

        ok "  ${slug}: ${ACTION}d  ${CUR} -> ${PKG_VER}   (site PHP ${SITE_PHP})"
        N_APPLIED=$((N_APPLIED+1))
        SITE_APPLIED=$((SITE_APPLIED+1))
        JSON_ROWS+=("{\"site\":\"$SITE_NAME\",\"plugin\":\"$slug\",\"action\":\"${ACTION}ed\",\"site_php\":\"$SITE_PHP\",\"requires_php\":\"${PKG_PHP_REQ:-}\",\"from\":\"${INST_VER:-none}\",\"to\":\"$PKG_VER\"}")
    done

    [ "$SITE_APPLIED" -eq 0 ] && info "  (no changes for this site)"
done

# --- Summary --------------------------------------------------------------
if [ "$JSON" -eq 1 ]; then
    printf '[%s]\n' "$(printf '%s\n' "${JSON_ROWS[@]}" | paste -sd, -)"
    exit 0
fi

section "Summary"
echo "  mode:            $([ "$APPLY" -eq 1 ] && echo APPLY || echo dry-run)"
echo "  candidates:      ${N_PLANNED}"
echo "  ${C_GREEN}applied:${C_RESET}         ${N_APPLIED}"
echo "  ${C_RED}blocked:${C_RESET}         ${N_BLOCKED}   (PHP floor not met / undetectable)"
echo "  ${C_RED}failed:${C_RESET}          ${N_FAILED}"
echo "  up to date:      ${N_UPTODATE}"
echo "  not installed:   ${N_NOTINSTALLED}   (use --install to add them)"
[ "$APPLY" -eq 0 ] && echo "" && info "Run again with --apply to execute."
echo ""
[ "$N_FAILED" -gt 0 ] && exit 2
exit 0
