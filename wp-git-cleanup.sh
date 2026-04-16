#!/bin/bash
#
# wp-git-cleanup.sh — Git untracked file cleanup for WordPress on RunCloud
#
# Scans WordPress sites for untracked git files, classifies them, and either
# reports or commits them in logical groups (core, theme, plugin) while adding
# production artifacts to .gitignore.
#
# Usage:
#   ./wp-git-cleanup.sh --site=APPNAME --action=scan           # report only
#   ./wp-git-cleanup.sh --site=APPNAME --action=cleanup        # commit + gitignore
#   ./wp-git-cleanup.sh --action=scan                          # scan all sites
#   ./wp-git-cleanup.sh --action=cleanup                       # cleanup all sites
#   ./wp-git-cleanup.sh --site=APPNAME --action=cleanup --dry-run
#
# Options:
#   --site=NAME      Web app name under /home/*/webapps/ (omit for all sites)
#   --action=ACTION  Required. One of: scan, cleanup
#   --dry-run        Show what would happen without making changes
#
# Classification + commit order:
#   1. .gitignore    — add production artifact patterns, commit .gitignore
#   2. WP Core       — wp-admin/, wp-includes/, root wp-*.php, etc.
#   3. WP Themes     — wp-content/themes/THEME/ (one commit per theme)
#   4. WP Plugins    — wp-content/plugins/SLUG/ (one commit per plugin)
#   5. MU-Plugins    — wp-content/mu-plugins/
#   6. Remaining     — reported but not auto-committed
#

set -euo pipefail

TARGET_SITE=""
ACTION=""
DRY_RUN=false

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
dry()     { echo -e "${YELLOW}[DRY]${NC}  $*"; }

# --- Parse arguments ---
for i in "$@"; do
    case $i in
        --site=*)    TARGET_SITE="${i#*=}" ;;
        --action=*)  ACTION="${i#*=}" ;;
        --dry-run)   DRY_RUN=true ;;
        --help|-h)
            awk 'NR==1{next} /^[^#]/{exit} {sub(/^# ?/,""); print}' "$0"
            exit 0
            ;;
        *) error "Unknown option: $i"; exit 1 ;;
    esac
done

if [ -z "$ACTION" ]; then
    error "--action is required (scan or cleanup). Use --help for usage."
    exit 1
fi

if [ "$ACTION" != "scan" ] && [ "$ACTION" != "cleanup" ]; then
    error "Unknown action: $ACTION. Use: scan, cleanup"
    exit 1
fi

# --- Gitignore patterns for production artifacts ---
# These patterns will be added to .gitignore if not already present
GITIGNORE_PATTERNS=(
    "# Production artifacts — managed by wp-git-cleanup.sh"
    ".maintenance-flags"
    ".maintenance-exclude"
    "litespeed.conf"
    ".htninja"
    "*.bak"
    "error_log"
    "debug.log"
    "wp-content/nfwlog/"
    "wp-content/wflogs/"
    "wp-content/litespeed/"
    "wp-content/.litespeed_conf.dat"
    "wp-content/wpvividbackups/"
    "wp-content/updraft/"
    "wp-content/ai1wm-backups/"
    "wp-content/backup*/"
    "wp-content/et-cache/"
    "wp-content/cache/"
    "wp-content/advanced-cache.php"
    "wp-content/object-cache.php"
    "wp-content/wp-cache-config.php"
    "wp-content/db.php"
    "wp-content/wpvivid*/"
    "wp-content/languages/**/*.json"
    ".tmb/"
)

# --- Helper: detect site owner ---
detect_owner() {
    local path="$1"
    local owner
    owner=$(stat -c '%U' "$path" 2>/dev/null || stat -f '%Su' "$path" 2>/dev/null || echo "runcloud")
    if [ "$owner" = "root" ]; then
        owner="runcloud"
    fi
    echo "$owner"
}

# --- Helper: run git as site owner ---
run_git() {
    local owner="$1" path="$2"
    shift 2
    if [ "$(whoami)" = "$owner" ]; then
        git -C "$path" "$@"
    else
        sudo -u "$owner" git -C "$path" "$@"
    fi
}

# --- Helper: get untracked files ---
get_untracked() {
    local owner="$1" path="$2"
    run_git "$owner" "$path" ls-files --others --exclude-standard 2>/dev/null || true
}

# --- Classify untracked files ---
# Populates associative arrays for each category
classify_files() {
    local untracked_file="$1"

    # Reset category arrays
    CORE_FILES=()
    THEME_FILES=()       # associative: populated via THEME_GROUPS
    PLUGIN_FILES=()      # associative: populated via PLUGIN_GROUPS
    MU_PLUGIN_FILES=()
    LANGUAGE_FILES=()
    GITIGNORE_FILES=()
    REMAINING_FILES=()

    # Associative arrays for per-slug grouping
    declare -gA THEME_GROUPS=()
    declare -gA PLUGIN_GROUPS=()

    while IFS= read -r file; do
        [ -z "$file" ] && continue

        # Check gitignore-worthy patterns first
        if is_gitignore_candidate "$file"; then
            GITIGNORE_FILES+=("$file")
        # WP Core: wp-admin/, wp-includes/, root-level wp-*.php, index.php, etc.
        elif [[ "$file" == wp-admin/* ]] || [[ "$file" == wp-includes/* ]] || \
             [[ "$file" =~ ^wp-[^/]+\.php$ ]] || \
             [[ "$file" == "index.php" ]] || [[ "$file" == "xmlrpc.php" ]] || \
             [[ "$file" == "license.txt" ]] || [[ "$file" == "readme.html" ]]; then
            CORE_FILES+=("$file")
        # Languages — track .mo/.po/.pot/.l10n.php, ignore .json (auto-generated JED hashes)
        elif [[ "$file" == wp-content/languages/* ]]; then
            if [[ "$file" == *.json ]]; then
                GITIGNORE_FILES+=("$file")
            else
                LANGUAGE_FILES+=("$file")
            fi
        # MU-Plugins
        elif [[ "$file" == wp-content/mu-plugins/* ]]; then
            MU_PLUGIN_FILES+=("$file")
        # Plugins: extract slug from wp-content/plugins/SLUG/...
        elif [[ "$file" == wp-content/plugins/* ]]; then
            local slug
            slug=$(echo "$file" | cut -d/ -f3)
            if [ -n "$slug" ]; then
                PLUGIN_GROUPS["$slug"]=1
            fi
        # Themes: extract name from wp-content/themes/THEME/...
        elif [[ "$file" == wp-content/themes/* ]]; then
            local theme
            theme=$(echo "$file" | cut -d/ -f3)
            if [ -n "$theme" ]; then
                THEME_GROUPS["$theme"]=1
            fi
        # Everything else
        else
            REMAINING_FILES+=("$file")
        fi
    done < "$untracked_file"
}

# --- Check if file matches gitignore-worthy patterns ---
is_gitignore_candidate() {
    local file="$1"
    case "$file" in
        .maintenance-flags|.maintenance-exclude) return 0 ;;
        litespeed.conf|.htninja) return 0 ;;
        *.bak) return 0 ;;
        error_log|debug.log|*.log) return 0 ;;
        wp-content/nfwlog/*) return 0 ;;
        wp-content/wflogs/*) return 0 ;;
        wp-content/litespeed/*) return 0 ;;
        wp-content/.litespeed_conf.dat) return 0 ;;
        wp-content/wpvividbackups/*) return 0 ;;
        wp-content/updraft/*) return 0 ;;
        wp-content/ai1wm-backups/*) return 0 ;;
        wp-content/backup*) return 0 ;;
        wp-content/et-cache/*) return 0 ;;
        wp-content/cache/*) return 0 ;;
        wp-content/advanced-cache.php) return 0 ;;
        wp-content/object-cache.php) return 0 ;;
        wp-content/wp-cache-config.php) return 0 ;;
        wp-content/db.php) return 0 ;;
        wp-content/fonts/*) return 0 ;;
        wp-content/ladipage/*) return 0 ;;
        wp-content/wpvivid*) return 0 ;;
        .tmb/*) return 0 ;;
        *) return 1 ;;
    esac
}

# --- Scan a single site ---
scan_site() {
    local site_path="$1"
    local webapp_name
    webapp_name=$(basename "$site_path")

    # Must be a git repo
    if [ ! -d "$site_path/.git" ]; then
        return 0
    fi

    # Must be WordPress
    if [ ! -f "$site_path/wp-includes/version.php" ]; then
        return 0
    fi

    # Skip frozen sites
    if is_frozen "$site_path"; then
        warn "=== $webapp_name — FROZEN, skipping ==="
        return 0
    fi

    local owner
    owner=$(detect_owner "$site_path")

    # Get untracked files into a temp file
    local tmp_untracked
    tmp_untracked=$(mktemp)
    trap "rm -f $tmp_untracked" RETURN
    get_untracked "$owner" "$site_path" > "$tmp_untracked"

    local total
    total=$(wc -l < "$tmp_untracked" | tr -d ' ')
    if [ "$total" -eq 0 ]; then
        return 0
    fi

    # Classify
    classify_files "$tmp_untracked"

    # Print summary
    echo ""
    info "=== $webapp_name ($site_path) — $total untracked ==="

    [ ${#GITIGNORE_FILES[@]} -gt 0 ]  && info "  gitignore:   ${#GITIGNORE_FILES[@]} files"
    [ ${#CORE_FILES[@]} -gt 0 ]       && info "  wp-core:     ${#CORE_FILES[@]} files"

    if [ ${#THEME_GROUPS[@]} -gt 0 ]; then
        for theme in "${!THEME_GROUPS[@]}"; do
            local count
            count=$(grep -c "^wp-content/themes/$theme/" "$tmp_untracked" 2>/dev/null || echo "0")
            info "  theme/$theme: $count files"
        done
    fi

    if [ ${#PLUGIN_GROUPS[@]} -gt 0 ]; then
        for plugin in "${!PLUGIN_GROUPS[@]}"; do
            local count
            count=$(grep -c "^wp-content/plugins/$plugin/" "$tmp_untracked" 2>/dev/null || echo "0")
            info "  plugin/$plugin: $count files"
        done
    fi

    [ ${#MU_PLUGIN_FILES[@]} -gt 0 ]  && info "  mu-plugins:  ${#MU_PLUGIN_FILES[@]} files"
    [ ${#LANGUAGE_FILES[@]} -gt 0 ]   && info "  languages:   ${#LANGUAGE_FILES[@]} files"
    [ ${#REMAINING_FILES[@]} -gt 0 ]  && warn "  remaining:   ${#REMAINING_FILES[@]} files"

    if [ ${#REMAINING_FILES[@]} -gt 0 ]; then
        for f in "${REMAINING_FILES[@]}"; do
            echo "    ? $f"
        done
    fi

    rm -f "$tmp_untracked"
    trap - RETURN
}

# --- Cleanup a single site ---
cleanup_site() {
    local site_path="$1"
    local webapp_name
    webapp_name=$(basename "$site_path")

    # Must be a git repo + WordPress
    if [ ! -d "$site_path/.git" ] || [ ! -f "$site_path/wp-includes/version.php" ]; then
        return 0
    fi

    # Skip frozen sites
    if is_frozen "$site_path"; then
        warn "=== $webapp_name — FROZEN, skipping ==="
        return 0
    fi

    local owner
    owner=$(detect_owner "$site_path")

    # Get untracked files into a temp file
    local tmp_untracked
    tmp_untracked=$(mktemp)
    get_untracked "$owner" "$site_path" > "$tmp_untracked"

    local total
    total=$(wc -l < "$tmp_untracked" | tr -d ' ')
    if [ "$total" -eq 0 ]; then
        rm -f "$tmp_untracked"
        return 0
    fi

    echo ""
    info "=== Cleanup: $webapp_name — $total untracked ==="

    # Classify
    classify_files "$tmp_untracked"

    local commits_made=0

    # Step 1: Update .gitignore
    if [ ${#GITIGNORE_FILES[@]} -gt 0 ]; then
        update_gitignore "$site_path" "$owner"
        commits_made=$((commits_made + 1))
    fi

    # Step 2: WP Core
    if [ ${#CORE_FILES[@]} -gt 0 ]; then
        commit_files "$owner" "$site_path" "chore: track wp core files" "${CORE_FILES[@]}"
        commits_made=$((commits_made + 1))
    fi

    # Step 3: Themes (one commit per theme)
    if [ ${#THEME_GROUPS[@]} -gt 0 ]; then
        for theme in "${!THEME_GROUPS[@]}"; do
            local theme_files=()
            while IFS= read -r f; do
                [ -n "$f" ] && theme_files+=("$f")
            done < <(grep "^wp-content/themes/$theme/" "$tmp_untracked" 2>/dev/null || true)

            if [ ${#theme_files[@]} -gt 0 ]; then
                commit_files "$owner" "$site_path" "chore: track wp theme ($theme)" "${theme_files[@]}"
                commits_made=$((commits_made + 1))
            fi
        done
    fi

    # Step 4: Plugins (one commit per plugin)
    if [ ${#PLUGIN_GROUPS[@]} -gt 0 ]; then
        for plugin in "${!PLUGIN_GROUPS[@]}"; do
            local plugin_files=()
            while IFS= read -r f; do
                [ -n "$f" ] && plugin_files+=("$f")
            done < <(grep "^wp-content/plugins/$plugin/" "$tmp_untracked" 2>/dev/null || true)

            if [ ${#plugin_files[@]} -gt 0 ]; then
                commit_files "$owner" "$site_path" "chore: track wp plugin ($plugin)" "${plugin_files[@]}"
                commits_made=$((commits_made + 1))
            fi
        done
    fi

    # Step 5: MU-Plugins
    if [ ${#MU_PLUGIN_FILES[@]} -gt 0 ]; then
        commit_files "$owner" "$site_path" "chore: track mu-plugins" "${MU_PLUGIN_FILES[@]}"
        commits_made=$((commits_made + 1))
    fi

    # Step 6: Languages
    if [ ${#LANGUAGE_FILES[@]} -gt 0 ]; then
        commit_files "$owner" "$site_path" "chore: track wp languages" "${LANGUAGE_FILES[@]}"
        commits_made=$((commits_made + 1))
    fi

    # Step 7: Report remaining
    if [ ${#REMAINING_FILES[@]} -gt 0 ]; then
        warn "Remaining unclassified files (${#REMAINING_FILES[@]}):"
        for f in "${REMAINING_FILES[@]}"; do
            echo "    ? $f"
        done
    fi

    if [ "$DRY_RUN" = true ]; then
        dry "Would make $commits_made commits for $webapp_name"
    else
        success "$commits_made commits for $webapp_name"
    fi

    rm -f "$tmp_untracked"
}

# --- Update .gitignore with production patterns ---
update_gitignore() {
    local site_path="$1" owner="$2"
    local gitignore="$site_path/.gitignore"
    local added=0

    # Check which patterns are missing
    local missing_patterns=()
    for pattern in "${GITIGNORE_PATTERNS[@]}"; do
        # Skip comment lines for the grep check
        if [[ "$pattern" == "#"* ]]; then
            continue
        fi
        if [ -f "$gitignore" ] && grep -qF "$pattern" "$gitignore" 2>/dev/null; then
            continue
        fi
        missing_patterns+=("$pattern")
    done

    if [ ${#missing_patterns[@]} -eq 0 ]; then
        info "  .gitignore already up to date"
        return 0
    fi

    if [ "$DRY_RUN" = true ]; then
        dry "  Would add ${#missing_patterns[@]} patterns to .gitignore"
        return 0
    fi

    # Append missing patterns
    {
        echo ""
        echo "# Production artifacts — managed by wp-git-cleanup.sh"
        for pattern in "${missing_patterns[@]}"; do
            echo "$pattern"
        done
    } >> "$gitignore"

    # Fix ownership
    chown "$owner:$owner" "$gitignore" 2>/dev/null || true

    # Commit .gitignore
    run_git "$owner" "$site_path" add .gitignore 2>/dev/null
    run_git "$owner" "$site_path" commit -m "chore: update .gitignore for production artifacts" --quiet 2>/dev/null || true
    success "  .gitignore updated (${#missing_patterns[@]} patterns added)"
}

# --- Commit a group of files ---
commit_files() {
    local owner="$1" site_path="$2" message="$3"
    shift 3
    local files=("$@")
    local count=${#files[@]}

    if [ "$DRY_RUN" = true ]; then
        dry "  $message ($count files)"
        return 0
    fi

    # Add files in batches to avoid argument too long
    local batch_size=100
    local i=0
    while [ $i -lt $count ]; do
        local batch=("${files[@]:$i:$batch_size}")
        run_git "$owner" "$site_path" add -- "${batch[@]}" 2>/dev/null || true
        i=$((i + batch_size))
    done

    # Commit
    run_git "$owner" "$site_path" commit -m "$message" --quiet 2>/dev/null || true
    success "  $message ($count files)"
}

# --- Check if site is frozen ---
is_frozen() {
    local site_path="$1"
    [ -f "$site_path/wp-content/mu-plugins/code-freeze.php" ]
}

# --- Find site path (supports multi-user layout) ---
find_site_path() {
    local site_name="$1"
    for user_dir in /home/*/; do
        [ -d "$user_dir" ] || continue
        local candidate="${user_dir}webapps/$site_name"
        if [ -d "$candidate" ]; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

# --- Iterate all sites ---
iterate_all_sites() {
    local callback="$1"
    for user_dir in /home/*/; do
        [ -d "$user_dir" ] || continue
        local webapps_dir="${user_dir}webapps"
        [ -d "$webapps_dir" ] || continue
        for app_dir in "$webapps_dir"/*/; do
            [ -d "$app_dir" ] || continue
            "$callback" "${app_dir%/}"
        done
    done
}

# --- Main ---
if [ -n "$TARGET_SITE" ]; then
    SITE_PATH=$(find_site_path "$TARGET_SITE") || {
        error "Site '$TARGET_SITE' not found"
        exit 1
    }
    case "$ACTION" in
        scan)    scan_site "$SITE_PATH" ;;
        cleanup) cleanup_site "$SITE_PATH" ;;
    esac
else
    case "$ACTION" in
        scan)    iterate_all_sites scan_site ;;
        cleanup) iterate_all_sites cleanup_site ;;
    esac
fi

echo ""
success "Done ($ACTION)"
