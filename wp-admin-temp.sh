#!/usr/bin/env bash
# =============================================================================
# WordPress Temporary Administrator
# WP-CLI only — no direct SQL access
#
# Author: Amir Hossein Pouya
# Repository: https://github.com/amirpooya784/wp-admin-temp.sh
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly SCRIPT_NAME="wp-admin-temp.sh"
readonly SCRIPT_VERSION="1.0.0"
readonly RAW_URL="https://raw.githubusercontent.com/amirpooya784/wp-admin-temp.sh/main/wp-admin-temp.sh"
readonly TEMP_USERNAME="isadmin"
readonly TEMP_DISPLAY_NAME="Temporary Support Administrator"
readonly META_KEY="_wp_admin_temp_owner"
readonly META_VALUE="amirpooya784/wp-admin-temp.sh"

ACTION="create"
HOST_USER=""
DOMAIN=""
PANEL="local"
HOME_DIR=""
WP_PATH=""
WP_BIN=""
RUNUSER_BIN=""
SITE_URL=""
PASSWORD=""
STATE_DIR=""
STATE_SCRIPT=""
STATE_FILE=""

# -----------------------------------------------------------------------------
# Colors and compact UI
# -----------------------------------------------------------------------------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    readonly RESET=$'\033[0m'
    readonly BOLD=$'\033[1m'
    readonly CYAN=$'\033[38;5;45m'
    readonly BLUE=$'\033[38;5;39m'
    readonly GREEN=$'\033[38;5;42m'
    readonly YELLOW=$'\033[38;5;214m'
    readonly RED=$'\033[38;5;196m'
    readonly GRAY=$'\033[38;5;245m'
else
    readonly RESET=""
    readonly BOLD=""
    readonly CYAN=""
    readonly BLUE=""
    readonly GREEN=""
    readonly YELLOW=""
    readonly RED=""
    readonly GRAY=""
fi

banner() {
    printf '\n%b╭──────────────────────────────────────────────╮%b\n' "$CYAN$BOLD" "$RESET"
    printf '%b│  WordPress Temporary Admin                   │%b\n' "$CYAN$BOLD" "$RESET"
    printf '%b│  WP-CLI only  •  v%-25s│%b\n' "$CYAN" "$SCRIPT_VERSION" "$RESET"
    printf '%b╰──────────────────────────────────────────────╯%b\n\n' "$CYAN$BOLD" "$RESET"
}

ok()   { printf '%b✓%b %s\n' "$GREEN" "$RESET" "$1"; }
info() { printf '%b›%b %s\n' "$BLUE" "$RESET" "$1"; }
warn() { printf '%b!%b %s\n' "$YELLOW" "$RESET" "$1" >&2; }
fail() { printf '\n%b✕ %s%b\n\n' "$RED$BOLD" "$1" "$RESET" >&2; exit 1; }

cleanup_secret() {
    PASSWORD=""
    unset PASSWORD 2>/dev/null || true
}
trap cleanup_secret EXIT

usage() {
    cat <<EOF
Usage:
  bash ${SCRIPT_NAME}
  bash ${SCRIPT_NAME} --delete
  bash ${SCRIPT_NAME} --version
EOF
}

parse_args() {
    (( $# <= 1 )) || fail "Only one option is allowed."

    case "${1:-}" in
        ""|create|--create) ACTION="create" ;;
        delete|--delete) ACTION="delete" ;;
        -h|--help) usage; exit 0 ;;
        -v|--version) printf '%s %s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"; exit 0 ;;
        *) fail "Unknown option: ${1}" ;;
    esac
}

need() {
    command -v "$1" >/dev/null 2>&1 || fail "Missing command: $1"
}

# -----------------------------------------------------------------------------
# Hosting and WordPress path detection
# -----------------------------------------------------------------------------
validate_host_user() {
    [[ "$HOST_USER" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$ ]] \
        || fail "Invalid hosting username."
}

validate_domain() {
    DOMAIN="${DOMAIN,,}"
    DOMAIN="${DOMAIN%.}"

    [[ "$DOMAIN" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] \
        || fail "Invalid domain."
    [[ "$DOMAIN" != *..* ]] || fail "Invalid domain."
}

detect_panel() {
    local has_cpanel=0
    local has_directadmin=0

    [[ -x /usr/local/cpanel/cpanel || -d /var/cpanel/users ]] && has_cpanel=1
    [[ -x /usr/local/directadmin/directadmin || -d /usr/local/directadmin/data/users ]] && has_directadmin=1

    if (( has_cpanel && has_directadmin )); then
        fail "Both cPanel and DirectAdmin were detected."
    elif (( has_cpanel )); then
        PANEL="cpanel"
    elif (( has_directadmin )); then
        PANEL="directadmin"
    else
        fail "cPanel or DirectAdmin was not detected."
    fi
}

load_home_dir() {
    local passwd_row

    passwd_row="$(getent passwd "$HOST_USER" || true)"
    [[ -n "$passwd_row" ]] || fail "Hosting account not found."

    HOME_DIR="$(cut -d: -f6 <<<"$passwd_row")"
    [[ -d "$HOME_DIR" ]] || fail "Hosting home directory not found."
}

cpanel_docroot() {
    local metadata="/var/cpanel/userdata/${HOST_USER}/${DOMAIN}"
    local docroot=""

    [[ -f "$metadata" ]] || fail "Domain is not assigned to this cPanel account."

    docroot="$(
        sed -n '/^[[:space:]]*documentroot:[[:space:]]*/ {
            s/^[[:space:]]*documentroot:[[:space:]]*//
            p
            q
        }' "$metadata"
    )"

    docroot="${docroot#\"}"
    docroot="${docroot%\"}"
    docroot="${docroot#\'}"
    docroot="${docroot%\'}"

    [[ -n "$docroot" ]] || fail "Document root was not found."
    printf '%s\n' "$docroot"
}

directadmin_docroot() {
    local config="/usr/local/directadmin/data/users/${HOST_USER}/domains/${DOMAIN}.conf"

    [[ -f "$config" ]] || fail "Domain is not assigned to this DirectAdmin account."
    printf '%s/domains/%s/public_html\n' "${HOME_DIR%/}" "$DOMAIN"
}

resolve_wp_path() {
    local candidate=""
    local safe_home=""

    need realpath

    if (( EUID == 0 )); then
        need getent
        RUNUSER_BIN="$(command -v runuser || true)"
        if [[ -z "$RUNUSER_BIN" && -x /usr/sbin/runuser ]]; then
            RUNUSER_BIN="/usr/sbin/runuser"
        fi
        [[ -n "$RUNUSER_BIN" && -x "$RUNUSER_BIN" ]] || fail "Missing command: runuser"

        detect_panel
        ok "Panel: ${PANEL}"

        printf '%bHosting username:%b ' "$BOLD" "$RESET"
        read -r HOST_USER
        printf '%bDomain:%b ' "$BOLD" "$RESET"
        read -r DOMAIN

        validate_host_user
        validate_domain
        load_home_dir

        if [[ "$PANEL" == "cpanel" ]]; then
            candidate="$(cpanel_docroot)"
        else
            candidate="$(directadmin_docroot)"
        fi

        [[ -d "$candidate" ]] || fail "Document root not found."

        WP_PATH="$(realpath -e -- "$candidate")"
        safe_home="$(realpath -e -- "$HOME_DIR")"

        case "${WP_PATH}/" in
            "${safe_home}/"*) ;;
            *) fail "Document root is outside the hosting account home." ;;
        esac
    else
        HOST_USER="$(id -un)"
        HOME_DIR="${HOME:-$(getent passwd "$HOST_USER" | cut -d: -f6)}"
        WP_PATH="$(pwd -P)"
    fi
}

find_wp_cli() {
    WP_BIN="$(command -v wp || true)"
    [[ -n "$WP_BIN" ]] || fail "WP-CLI was not found."
    WP_BIN="$(realpath -e -- "$WP_BIN")"
}

wp_run() {
    local -a global_args=(
        "--path=${WP_PATH}"
        "--skip-plugins"
        "--skip-themes"
        "--skip-packages"
        "--no-color"
    )

    if (( EUID == 0 )); then
        "$RUNUSER_BIN" -u "$HOST_USER" -- env \
            "HOME=${HOME_DIR}" \
            "PATH=${PATH}" \
            "WP_CLI_CONFIG_PATH=/dev/null" \
            "WP_CLI_DISABLE_AUTO_CHECK_UPDATE=1" \
            "$WP_BIN" "${global_args[@]}" "$@"
    else
        env \
            "WP_CLI_CONFIG_PATH=/dev/null" \
            "WP_CLI_DISABLE_AUTO_CHECK_UPDATE=1" \
            "$WP_BIN" "${global_args[@]}" "$@"
    fi
}

verify_wordpress() {
    [[ -f "$WP_PATH/wp-config.php" ]] || fail "WordPress was not found."
    [[ -f "$WP_PATH/wp-load.php" ]] || fail "WordPress was not found."
    [[ -d "$WP_PATH/wp-admin" ]] || fail "WordPress was not found."
    [[ -d "$WP_PATH/wp-includes" ]] || fail "WordPress was not found."

    wp_run core is-installed >/dev/null 2>&1 || fail "WordPress was not found."

    if wp_run core is-installed --network >/dev/null 2>&1; then
        fail "WordPress Multisite is not supported."
    fi

    SITE_URL="$(wp_run option get siteurl 2>/dev/null || true)"
    [[ -n "$SITE_URL" ]] || fail "Site URL was not found."
}

# -----------------------------------------------------------------------------
# Safe temporary installation and saved site context
# -----------------------------------------------------------------------------
build_state_paths() {
    local owner_uid
    local site_hash

    need sha256sum

    owner_uid="$(id -u "$HOST_USER")"
    site_hash="$(printf '%s' "$WP_PATH" | sha256sum | awk '{print substr($1,1,12)}')"

    STATE_DIR="/tmp/wp-admin-temp-${owner_uid}-${site_hash}"
    STATE_SCRIPT="${STATE_DIR}/${SCRIPT_NAME}"
    STATE_FILE="${STATE_DIR}/site.env"
}

assert_safe_state_dir() {
    [[ "$STATE_DIR" == /tmp/wp-admin-temp-[0-9]*-[a-f0-9]* ]] \
        || fail "Unsafe temporary path."
    [[ ! -L "$STATE_DIR" ]] || fail "Unsafe temporary path."
}

save_state() {
    assert_safe_state_dir

    mkdir -p -- "$STATE_DIR"
    chmod 700 -- "$STATE_DIR"

    [[ ! -L "$STATE_FILE" ]] || fail "Unsafe state file."

    {
        printf 'HOST_USER=%q\n' "$HOST_USER"
        printf 'DOMAIN=%q\n' "$DOMAIN"
        printf 'PANEL=%q\n' "$PANEL"
        printf 'HOME_DIR=%q\n' "$HOME_DIR"
        printf 'WP_PATH=%q\n' "$WP_PATH"
        printf 'WP_BIN=%q\n' "$WP_BIN"
        printf 'RUNUSER_BIN=%q\n' "$RUNUSER_BIN"
        printf 'SITE_URL=%q\n' "$SITE_URL"
    } > "$STATE_FILE"

    chmod 600 -- "$STATE_FILE"
}

local_script_path() {
    local source_path="${BASH_SOURCE[0]:-}"

    # Process substitution paths are ephemeral. Never call realpath on them.
    case "$source_path" in
        ""|/dev/fd/*|/proc/*/fd/*) return 1 ;;
    esac

    [[ -f "$source_path" ]] || return 1
    realpath -e -- "$source_path" 2>/dev/null
}

install_temp_script() {
    local source_path=""
    local download_url=""

    assert_safe_state_dir
    [[ ! -L "$STATE_SCRIPT" ]] || fail "Unsafe temporary script path."

    source_path="$(local_script_path || true)"

    if [[ -n "$source_path" ]]; then
        cp -- "$source_path" "$STATE_SCRIPT"
    else
        need curl
        download_url="${RAW_URL}?version=${SCRIPT_VERSION}&time=$(date +%s)"
        curl -kfsSL \
            -H 'Cache-Control: no-cache' \
            -H 'Pragma: no-cache' \
            "$download_url" \
            -o "$STATE_SCRIPT" \
            || fail "Could not save the script in /tmp."
    fi

    chmod 700 -- "$STATE_SCRIPT"
    bash -n "$STATE_SCRIPT" || fail "Downloaded script is invalid."

    # Reject an outdated or unrelated copy before execution.
    grep -Fq 'readonly SCRIPT_VERSION="3.0.0"' "$STATE_SCRIPT" \
        || fail "Downloaded script version is outdated."
}

bootstrap() {
    resolve_wp_path
    find_wp_cli
    verify_wordpress
    ok "WordPress: ${DOMAIN:-local site}"

    build_state_paths
    save_state
    install_temp_script

    exec bash "$STATE_SCRIPT" "--${ACTION}"
}

load_saved_state() {
    local source_path=""
    local source_dir=""

    source_path="$(local_script_path || true)"
    [[ -n "$source_path" ]] || return 1

    source_dir="$(dirname -- "$source_path")"
    [[ "$source_dir" == /tmp/wp-admin-temp-* ]] || return 1
    [[ "$(basename -- "$source_path")" == "$SCRIPT_NAME" ]] || return 1
    [[ -f "$source_dir/site.env" ]] || return 1
    [[ ! -L "$source_dir/site.env" ]] || fail "Unsafe state file."

    STATE_DIR="$source_dir"
    STATE_SCRIPT="$source_path"
    STATE_FILE="${source_dir}/site.env"

    # shellcheck disable=SC1090
    source "$STATE_FILE"

    [[ "$WP_PATH" == /* ]] || fail "Invalid saved WordPress path."
    [[ "$WP_BIN" == /* && -x "$WP_BIN" ]] || fail "Invalid saved WP-CLI path."

    verify_wordpress
    return 0
}

remove_state() {
    assert_safe_state_dir
    rm -f -- "$STATE_FILE" "$STATE_SCRIPT"
    rmdir -- "$STATE_DIR" 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# Temporary administrator operations
# -----------------------------------------------------------------------------
generate_password() {
    local pool=""
    local candidate=""

    need openssl
    need tr

    while :; do
        pool="$(openssl rand -base64 96 | tr -dc 'A-Za-z0-9')"
        candidate="${pool:0:15}"

        if [[ ${#candidate} -eq 15 \
            && "$candidate" =~ [A-Z] \
            && "$candidate" =~ [a-z] \
            && "$candidate" =~ [0-9] ]]; then
            PASSWORD="$candidate"
            return 0
        fi
    done
}

mark_user() {
    local user_id="$1"
    wp_run user meta update "$user_id" "$META_KEY" "$META_VALUE" >/dev/null
}

is_managed_user() {
    local user_id="$1"
    local marker=""

    marker="$(wp_run user meta get "$user_id" "$META_KEY" 2>/dev/null || true)"
    [[ "$marker" == "$META_VALUE" ]]
}

show_access() {
    local delete_command
    printf -v delete_command 'bash %q --delete' "$STATE_SCRIPT"

    printf '\n%b╭─ Access%b\n' "$CYAN$BOLD" "$RESET"
    printf '%b│%b %-9s %s\n' "$CYAN" "$RESET" "Login" "${SITE_URL%/}/wp-login.php"
    printf '%b│%b %-9s %b%s%b\n' "$CYAN" "$RESET" "Username" "$BOLD" "$TEMP_USERNAME" "$RESET"
    printf '%b│%b %-9s %b%s%b\n' "$CYAN" "$RESET" "Password" "$GREEN$BOLD" "$PASSWORD" "$RESET"
    printf '%b├─ Remove%b\n' "$CYAN$BOLD" "$RESET"
    printf '%b│%b %s\n' "$CYAN" "$RESET" "$delete_command"
    printf '%b╰──────────────────────────────────────────────╯%b\n\n' "$CYAN$BOLD" "$RESET"
}

create_or_update() {
    local user_id=""
    local email=""

    generate_password

    if wp_run user exists "$TEMP_USERNAME" >/dev/null 2>&1; then
        info "Existing account — updating"
        user_id="$(wp_run user get "$TEMP_USERNAME" --field=ID)"
        printf '%s\n' "$PASSWORD" \
            | wp_run user update "$user_id" --prompt=user_pass >/dev/null
    else
        info "New account — creating"
        email="${TEMP_USERNAME}.$(date -u +%s)@example.invalid"

        printf '%s\n' "$PASSWORD" \
            | wp_run user create "$TEMP_USERNAME" "$email" \
                --role=administrator \
                --display_name="$TEMP_DISPLAY_NAME" \
                --prompt=user_pass >/dev/null

        user_id="$(wp_run user get "$TEMP_USERNAME" --field=ID)"
    fi

    wp_run user set-role "$user_id" administrator >/dev/null
    mark_user "$user_id"
    wp_run user session destroy "$user_id" --all >/dev/null 2>&1 || true

    ok "Account ready"
    show_access
}

find_reassign_admin() {
    local excluded_id="$1"
    local candidate=""
    local admin_ids=""

    admin_ids="$(wp_run user list --role=administrator --field=ID)"

    while IFS= read -r candidate; do
        if [[ -n "$candidate" && "$candidate" != "$excluded_id" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done <<< "$admin_ids"

    return 1
}

delete_account() {
    local user_id=""
    local reassign_id=""

    if ! wp_run user exists "$TEMP_USERNAME" >/dev/null 2>&1; then
        remove_state
        warn "Account not found"
        return 0
    fi

    user_id="$(wp_run user get "$TEMP_USERNAME" --field=ID)"
    is_managed_user "$user_id" || fail "This account is not managed by the script."

    reassign_id="$(find_reassign_admin "$user_id" || true)"
    [[ -n "$reassign_id" ]] || fail "No other administrator exists."

    wp_run user delete "$user_id" --reassign="$reassign_id" --yes >/dev/null
    remove_state

    ok "Account deleted"
    printf '\n'
}

main() {
    parse_args "$@"

    if [[ "${WP_ADMIN_TEMP_BANNER_SHOWN:-0}" != "1" ]]; then
        banner
        export WP_ADMIN_TEMP_BANNER_SHOWN=1
    fi

    if ! load_saved_state; then
        bootstrap
    fi

    case "$ACTION" in
        create) create_or_update ;;
        delete) delete_account ;;
        *) fail "Invalid action." ;;
    esac
}

main "$@"
