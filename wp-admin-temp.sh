#!/usr/bin/env bash
# wp-admin-temp.sh
# Temporary WordPress administrator manager using WP-CLI only.
# Author: Amir Hossein Pouya
# Repository: https://github.com/amirpooya784/wp-admin-temp.sh

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly SCRIPT_NAME="wp-admin-temp.sh"
readonly SCRIPT_VERSION="2.0.0"
readonly RAW_URL="https://raw.githubusercontent.com/amirpooya784/wp-admin-temp.sh/main/wp-admin-temp.sh"
readonly TEMP_USERNAME="isadmin"
readonly TEMP_DISPLAY_NAME="Temporary Support Administrator"
readonly MANAGED_META_KEY="_wp_admin_temp_managed_by"
readonly MANAGED_META_VALUE="amirpooya784/wp-admin-temp.sh"
readonly CREATED_META_KEY="_wp_admin_temp_created_at"

ACTION="create"
SITE_USER=""
DOMAIN=""
CONTROL_PANEL=""
TARGET_PATH=""
USER_HOME=""
WP_BIN=""
SITE_URL=""
PASSWORD=""
STATE_DIR=""
STATE_SCRIPT=""
STATE_CONTEXT=""

cleanup_secret() {
    PASSWORD=""
    unset PASSWORD 2>/dev/null || true
}
trap cleanup_secret EXIT

fail() {
    printf 'Error: %s\n' "$1" >&2
    exit 1
}

usage() {
    cat <<EOF_USAGE
Usage:
  bash ${SCRIPT_NAME}
  bash ${SCRIPT_NAME} --delete
  bash ${SCRIPT_NAME} --version
EOF_USAGE
}

parse_arguments() {
    (( $# <= 1 )) || fail "Only one option is allowed."

    case "${1:-}" in
        ""|create|--create) ACTION="create" ;;
        delete|--delete) ACTION="delete" ;;
        -h|--help) usage; exit 0 ;;
        -v|--version) printf '%s %s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"; exit 0 ;;
        *) fail "Unknown option: ${1}" ;;
    esac
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

validate_account_username() {
    [[ "$SITE_USER" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$ ]] \
        || fail "Invalid hosting username."
}

validate_domain() {
    DOMAIN="${DOMAIN,,}"
    DOMAIN="${DOMAIN%.}"

    [[ "$DOMAIN" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] \
        || fail "Invalid domain."
    [[ "$DOMAIN" != *..* ]] || fail "Invalid domain."
}

detect_control_panel() {
    local cpanel=0
    local directadmin=0

    [[ -x /usr/local/cpanel/cpanel || -d /var/cpanel/users ]] && cpanel=1
    [[ -x /usr/local/directadmin/directadmin || -d /usr/local/directadmin/data/users ]] && directadmin=1

    if (( cpanel == 1 && directadmin == 1 )); then
        fail "Both cPanel and DirectAdmin were detected."
    elif (( cpanel == 1 )); then
        CONTROL_PANEL="cpanel"
    elif (( directadmin == 1 )); then
        CONTROL_PANEL="directadmin"
    else
        fail "cPanel or DirectAdmin was not detected."
    fi
}

load_account_home() {
    local entry

    entry="$(getent passwd "$SITE_USER" || true)"
    [[ -n "$entry" ]] || fail "Hosting account not found."

    USER_HOME="$(printf '%s' "$entry" | cut -d: -f6)"
    [[ -d "$USER_HOME" ]] || fail "Hosting home directory not found."
}

resolve_cpanel_document_root() {
    local metadata="/var/cpanel/userdata/${SITE_USER}/${DOMAIN}"
    local document_root

    [[ -f "$metadata" ]] || fail "Domain is not assigned to this cPanel account."

    document_root="$(
        sed -n '/^[[:space:]]*documentroot:[[:space:]]*/ {
            s/^[[:space:]]*documentroot:[[:space:]]*//
            p
            q
        }' "$metadata"
    )"

    document_root="${document_root#\"}"
    document_root="${document_root%\"}"
    document_root="${document_root#\'}"
    document_root="${document_root%\'}"

    [[ -n "$document_root" ]] || fail "Document root was not found."
    printf '%s\n' "$document_root"
}

resolve_directadmin_document_root() {
    local config="/usr/local/directadmin/data/users/${SITE_USER}/domains/${DOMAIN}.conf"

    [[ -f "$config" ]] || fail "Domain is not assigned to this DirectAdmin account."
    printf '%s/domains/%s/public_html\n' "${USER_HOME%/}" "$DOMAIN"
}

resolve_target_path() {
    local proposed
    local canonical_home

    require_command realpath

    if (( EUID == 0 )); then
        require_command getent
        require_command runuser

        detect_control_panel

        printf 'Hosting username: '
        read -r SITE_USER
        printf 'Domain: '
        read -r DOMAIN

        validate_account_username
        validate_domain
        load_account_home

        if [[ "$CONTROL_PANEL" == "cpanel" ]]; then
            proposed="$(resolve_cpanel_document_root)"
        else
            proposed="$(resolve_directadmin_document_root)"
        fi

        [[ -d "$proposed" ]] || fail "Document root not found."

        TARGET_PATH="$(realpath -e -- "$proposed")"
        canonical_home="$(realpath -e -- "$USER_HOME")"

        case "${TARGET_PATH}/" in
            "${canonical_home}/"*) ;;
            *) fail "Document root is outside the hosting account home." ;;
        esac
    else
        SITE_USER="$(id -un)"
        USER_HOME="${HOME:-$(getent passwd "$SITE_USER" | cut -d: -f6)}"
        TARGET_PATH="$(pwd -P)"
        CONTROL_PANEL="local"
    fi
}

find_wp_cli() {
    WP_BIN="$(command -v wp || true)"
    [[ -n "$WP_BIN" && -x "$WP_BIN" ]] || fail "WP-CLI was not found."
    WP_BIN="$(realpath -e -- "$WP_BIN")"
}

wp_run() {
    local -a args=(
        "--path=${TARGET_PATH}"
        "--skip-plugins"
        "--skip-themes"
        "--skip-packages"
        "--no-color"
    )

    if (( EUID == 0 )); then
        runuser -u "$SITE_USER" -- env \
            "HOME=${USER_HOME}" \
            "PATH=${PATH}" \
            "WP_CLI_CONFIG_PATH=/dev/null" \
            "WP_CLI_DISABLE_AUTO_CHECK_UPDATE=1" \
            "$WP_BIN" "${args[@]}" "$@"
    else
        env \
            "WP_CLI_CONFIG_PATH=/dev/null" \
            "WP_CLI_DISABLE_AUTO_CHECK_UPDATE=1" \
            "$WP_BIN" "${args[@]}" "$@"
    fi
}

verify_wordpress() {
    [[ -f "$TARGET_PATH/wp-config.php" ]] || fail "WordPress was not found."
    [[ -f "$TARGET_PATH/wp-load.php" ]] || fail "WordPress was not found."
    [[ -d "$TARGET_PATH/wp-admin" ]] || fail "WordPress was not found."
    [[ -d "$TARGET_PATH/wp-includes" ]] || fail "WordPress was not found."

    wp_run core is-installed >/dev/null 2>&1 \
        || fail "WordPress was not found."

    if wp_run core is-installed --network >/dev/null 2>&1; then
        fail "WordPress Multisite is not supported."
    fi

    SITE_URL="$(wp_run option get siteurl 2>/dev/null)"
    [[ -n "$SITE_URL" ]] || fail "WordPress site URL was not found."
}

state_path_for_site() {
    local owner_uid
    local site_hash

    require_command sha256sum

    owner_uid="$(id -u "$SITE_USER")"
    site_hash="$(printf '%s' "$TARGET_PATH" | sha256sum | awk '{print substr($1,1,12)}')"

    STATE_DIR="/tmp/wp-admin-temp-${owner_uid}-${site_hash}"
    STATE_SCRIPT="${STATE_DIR}/${SCRIPT_NAME}"
    STATE_CONTEXT="${STATE_DIR}/site.context"
}

save_context() {
    mkdir -p -- "$STATE_DIR"
    chmod 700 -- "$STATE_DIR"

    {
        printf 'SITE_USER=%q\n' "$SITE_USER"
        printf 'DOMAIN=%q\n' "$DOMAIN"
        printf 'CONTROL_PANEL=%q\n' "$CONTROL_PANEL"
        printf 'TARGET_PATH=%q\n' "$TARGET_PATH"
        printf 'USER_HOME=%q\n' "$USER_HOME"
        printf 'WP_BIN=%q\n' "$WP_BIN"
        printf 'SITE_URL=%q\n' "$SITE_URL"
    } > "$STATE_CONTEXT"

    chmod 600 -- "$STATE_CONTEXT"
}

install_temp_copy() {
    local source_path="${BASH_SOURCE[0]}"

    if [[ -f "$source_path" && "$source_path" != /dev/fd/* && "$source_path" != /proc/*/fd/* ]]; then
        cp -- "$source_path" "$STATE_SCRIPT"
    else
        require_command curl
        curl -kfsSL "$RAW_URL" -o "$STATE_SCRIPT" \
            || fail "Could not save the script in /tmp."
    fi

    chmod 700 -- "$STATE_SCRIPT"
    bash -n "$STATE_SCRIPT" || fail "The saved script is invalid."
}

bootstrap_to_temp() {
    resolve_target_path
    find_wp_cli
    verify_wordpress
    state_path_for_site
    save_context
    install_temp_copy

    exec bash "$STATE_SCRIPT" "$([[ "$ACTION" == "delete" ]] && printf '%s' '--delete' || printf '%s' '--create')"
}

load_temp_context() {
    local script_path
    local script_dir

    script_path="$(realpath -e -- "${BASH_SOURCE[0]}")"
    script_dir="$(dirname -- "$script_path")"

    [[ "$script_dir" == /tmp/wp-admin-temp-* ]] || return 1
    [[ "$(basename -- "$script_path")" == "$SCRIPT_NAME" ]] || return 1
    [[ -f "$script_dir/site.context" ]] || return 1

    STATE_DIR="$script_dir"
    STATE_SCRIPT="$script_path"
    STATE_CONTEXT="$script_dir/site.context"

    # The file is private to the invoking account and contains only shell-escaped declarations.
    # shellcheck disable=SC1090
    source "$STATE_CONTEXT"

    [[ "$TARGET_PATH" == /* ]] || fail "Invalid saved WordPress path."
    [[ "$WP_BIN" == /* && -x "$WP_BIN" ]] || fail "Saved WP-CLI path is invalid."

    verify_wordpress
    return 0
}

generate_password() {
    local random_data
    local candidate

    require_command openssl
    require_command tr

    while :; do
        random_data="$(openssl rand -base64 96 | tr -dc 'A-Za-z0-9')"
        candidate="${random_data:0:15}"

        if [[ ${#candidate} -eq 15 \
            && "$candidate" =~ [A-Z] \
            && "$candidate" =~ [a-z] \
            && "$candidate" =~ [0-9] ]]; then
            PASSWORD="$candidate"
            return 0
        fi
    done
}

mark_managed_user() {
    local user_id="$1"
    local created_at

    created_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    wp_run user meta update "$user_id" "$MANAGED_META_KEY" "$MANAGED_META_VALUE" >/dev/null
    wp_run user meta update "$user_id" "$CREATED_META_KEY" "$created_at" >/dev/null
}

is_managed_user() {
    local user_id="$1"
    local marker

    marker="$(wp_run user meta get "$user_id" "$MANAGED_META_KEY" 2>/dev/null || true)"
    [[ "$marker" == "$MANAGED_META_VALUE" ]]
}

create_or_update_user() {
    local user_id
    local email

    generate_password

    if wp_run user exists "$TEMP_USERNAME" >/dev/null 2>&1; then
        printf 'Existing account found. Updating password...\n'
        user_id="$(wp_run user get "$TEMP_USERNAME" --field=ID)"

        printf '%s\n' "$PASSWORD" \
            | wp_run user update "$user_id" --prompt=user_pass >/dev/null
    else
        printf 'Creating new account...\n'
        email="${TEMP_USERNAME}.$(date -u +%s)@example.invalid"

        printf '%s\n' "$PASSWORD" \
            | wp_run user create "$TEMP_USERNAME" "$email" \
                --role=administrator \
                --display_name="$TEMP_DISPLAY_NAME" \
                --prompt=user_pass >/dev/null

        user_id="$(wp_run user get "$TEMP_USERNAME" --field=ID)"
    fi

    wp_run user set-role "$user_id" administrator >/dev/null
    mark_managed_user "$user_id"
    wp_run user session destroy "$user_id" --all >/dev/null 2>&1 || true

    printf 'Login: %s/wp-login.php\n' "${SITE_URL%/}"
    printf 'Username: %s\n' "$TEMP_USERNAME"
    printf 'Password: %s\n' "$PASSWORD"
    printf 'Delete: bash %q --delete\n' "$STATE_SCRIPT"
}

find_reassign_admin() {
    local excluded_id="$1"
    local candidate

    while IFS= read -r candidate; do
        if [[ -n "$candidate" && "$candidate" != "$excluded_id" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done < <(wp_run user list --role=administrator --field=ID)

    return 1
}

remove_state_files() {
    local expected_prefix="/tmp/wp-admin-temp-"

    [[ "$STATE_DIR" == "${expected_prefix}"* ]] \
        || fail "Unsafe temporary path."

    rm -f -- "$STATE_CONTEXT" "$STATE_SCRIPT"
    rmdir -- "$STATE_DIR" 2>/dev/null || true
}

delete_user() {
    local user_id
    local reassign_id

    if ! wp_run user exists "$TEMP_USERNAME" >/dev/null 2>&1; then
        remove_state_files
        printf 'Account not found. Temporary files removed.\n'
        return 0
    fi

    user_id="$(wp_run user get "$TEMP_USERNAME" --field=ID)"

    if ! is_managed_user "$user_id"; then
        fail "The account is not managed by this script."
    fi

    reassign_id="$(find_reassign_admin "$user_id" || true)"
    [[ -n "$reassign_id" ]] || fail "No other administrator exists."

    wp_run user delete "$user_id" --reassign="$reassign_id" --yes >/dev/null
    remove_state_files

    printf 'Account deleted.\n'
}

main() {
    parse_arguments "$@"

    if ! load_temp_context; then
        bootstrap_to_temp
    fi

    case "$ACTION" in
        create) create_or_update_user ;;
        delete) delete_user ;;
        *) fail "Invalid action." ;;
    esac
}

main "$@"
