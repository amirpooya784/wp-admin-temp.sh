#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# wp-admin-temp.sh
# Safely create, rotate, or delete a temporary WordPress administrator.
#
# Author: Amir Hossein Pouya
# Repository: https://github.com/amirpooya784/wp-admin-temp.sh
#
# Security model:
#   - Uses WP-CLI exclusively for all WordPress data operations.
#   - Never executes SQL or reads database credentials.
#   - Never passes the generated password as a command-line argument.
#   - Refuses to scan arbitrary server paths for WordPress installations.
#   - Refuses to modify an existing unmarked account named "isadmin".
#   - Runs WP-CLI as the hosting account owner when started by root.
# -----------------------------------------------------------------------------

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly SCRIPT_NAME="wp-admin-temp.sh"
readonly SCRIPT_VERSION="1.0.0"
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

# Terminal colors are enabled only for an interactive terminal.
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    readonly C_RESET=$'\033[0m'
    readonly C_BOLD=$'\033[1m'
    readonly C_BLUE=$'\033[38;5;39m'
    readonly C_GREEN=$'\033[38;5;42m'
    readonly C_YELLOW=$'\033[38;5;214m'
    readonly C_RED=$'\033[38;5;196m'
    readonly C_GRAY=$'\033[38;5;245m'
else
    readonly C_RESET=""
    readonly C_BOLD=""
    readonly C_BLUE=""
    readonly C_GREEN=""
    readonly C_YELLOW=""
    readonly C_RED=""
    readonly C_GRAY=""
fi

cleanup() {
    PASSWORD=""
    unset PASSWORD 2>/dev/null || true
}
trap cleanup EXIT

print_banner() {
    printf '\n%b\n' "${C_BLUE}${C_BOLD}╔══════════════════════════════════════════════════════╗${C_RESET}"
    printf '%b\n'   "${C_BLUE}${C_BOLD}║       WordPress Temporary Administrator Tool         ║${C_RESET}"
    printf '%b\n'   "${C_BLUE}${C_BOLD}╚══════════════════════════════════════════════════════╝${C_RESET}"
    printf '%b\n'   "${C_GRAY}Author: Amir Hossein Pouya | Version: ${SCRIPT_VERSION}${C_RESET}"
    printf '%b\n\n' "${C_GRAY}Repository: https://github.com/amirpooya784/wp-admin-temp.sh${C_RESET}"
}

stage() {
    printf '%b\n' "${C_BLUE}${C_BOLD}[$1/5]${C_RESET} ${C_BOLD}$2${C_RESET}"
}

info() {
    printf '  %bℹ%b %s\n' "$C_BLUE" "$C_RESET" "$1"
}

success() {
    printf '  %b✓%b %s\n' "$C_GREEN" "$C_RESET" "$1"
}

warning() {
    printf '  %b!%b %s\n' "$C_YELLOW" "$C_RESET" "$1" >&2
}

die() {
    printf '\n%bError:%b %s\n\n' "${C_RED}${C_BOLD}" "$C_RESET" "$1" >&2
    exit 1
}

usage() {
    cat <<USAGE
Usage:
  ./${SCRIPT_NAME}              Create the managed account or rotate its password
  ./${SCRIPT_NAME} --delete     Delete the managed account and preserve its content
  ./${SCRIPT_NAME} --help       Show this help message
  ./${SCRIPT_NAME} --version    Show the script version

Execution modes:
  Non-root: Run from the exact WordPress document root, usually public_html.
  Root:     The script detects cPanel or DirectAdmin and asks for the hosting
            account username and domain. WP-CLI then runs as that account owner.

Safety behavior:
  - No SQL commands are used.
  - No recursive search for WordPress is performed.
  - WordPress Multisite is not modified automatically.
  - An existing unmarked account named "${TEMP_USERNAME}" is never modified.
USAGE
}

parse_arguments() {
    if (( $# > 1 )); then
        die "Only one option may be supplied. Use --help for usage information."
    fi

    case "${1:-}" in
        ""|--create|create)
            ACTION="create"
            ;;
        --delete|delete)
            ACTION="delete"
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        --version|-v)
            printf '%s %s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"
            exit 0
            ;;
        *)
            die "Unknown option: ${1}. Use --help for usage information."
            ;;
    esac
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

validate_account_username() {
    [[ "$SITE_USER" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$ ]] \
        || die "The hosting account username contains invalid characters."
}

validate_domain() {
    DOMAIN="${DOMAIN,,}"
    DOMAIN="${DOMAIN%.}"

    [[ -n "$DOMAIN" ]] || die "The domain cannot be empty."
    [[ "$DOMAIN" =~ ^[a-z0-9.-]+$ ]] \
        || die "The domain contains invalid characters. Use a DNS-formatted domain."
    [[ "$DOMAIN" != .* && "$DOMAIN" != *. && "$DOMAIN" != *..* ]] \
        || die "The domain format is invalid."
}

detect_control_panel() {
    local cpanel_found=0
    local directadmin_found=0

    [[ -x /usr/local/cpanel/cpanel || -d /var/cpanel/users ]] && cpanel_found=1
    [[ -x /usr/local/directadmin/directadmin || -d /usr/local/directadmin/data/users ]] && directadmin_found=1

    if (( cpanel_found == 1 && directadmin_found == 1 )); then
        die "Both cPanel and DirectAdmin signatures were found. Refusing to guess the active panel."
    elif (( cpanel_found == 1 )); then
        CONTROL_PANEL="cpanel"
    elif (( directadmin_found == 1 )); then
        CONTROL_PANEL="directadmin"
    else
        die "No supported control panel was detected. Supported panels: cPanel and DirectAdmin."
    fi
}

load_account_home() {
    local passwd_entry

    passwd_entry="$(getent passwd "$SITE_USER" || true)"
    [[ -n "$passwd_entry" ]] || die "The hosting account does not exist: $SITE_USER"

    USER_HOME="$(printf '%s' "$passwd_entry" | cut -d: -f6)"
    [[ -n "$USER_HOME" && "$USER_HOME" == /* ]] \
        || die "Could not determine a valid home directory for account: $SITE_USER"
    [[ -d "$USER_HOME" ]] || die "The account home directory does not exist: $USER_HOME"
}

resolve_cpanel_document_root() {
    local metadata_file="/var/cpanel/userdata/${SITE_USER}/${DOMAIN}"
    local document_root=""

    [[ -f "$metadata_file" ]] \
        || die "The domain is not registered to this cPanel account: $DOMAIN"

    document_root="$(
        sed -n '/^[[:space:]]*documentroot:[[:space:]]*/ {
            s/^[[:space:]]*documentroot:[[:space:]]*//
            p
            q
        }' "$metadata_file"
    )"

    document_root="${document_root#\"}"
    document_root="${document_root%\"}"
    document_root="${document_root#\'}"
    document_root="${document_root%\'}"

    [[ -n "$document_root" ]] \
        || die "cPanel metadata does not contain a document root for: $DOMAIN"

    printf '%s\n' "$document_root"
}

resolve_directadmin_document_root() {
    local domain_config="/usr/local/directadmin/data/users/${SITE_USER}/domains/${DOMAIN}.conf"

    [[ -f "$domain_config" ]] \
        || die "The domain is not registered to this DirectAdmin account: $DOMAIN"

    printf '%s/domains/%s/public_html\n' "${USER_HOME%/}" "$DOMAIN"
}

resolve_target_path() {
    local proposed_path=""
    local canonical_home=""

    if (( EUID == 0 )); then
        require_command getent
        require_command runuser
        require_command realpath

        detect_control_panel
        success "Detected control panel: ${CONTROL_PANEL}"

        printf '  Hosting account username: '
        read -r SITE_USER
        printf '  Domain name: '
        read -r DOMAIN

        validate_account_username
        validate_domain
        load_account_home

        case "$CONTROL_PANEL" in
            cpanel)
                proposed_path="$(resolve_cpanel_document_root)"
                ;;
            directadmin)
                proposed_path="$(resolve_directadmin_document_root)"
                ;;
            *)
                die "Internal error: unsupported control panel state."
                ;;
        esac

        [[ -d "$proposed_path" ]] \
            || die "The resolved document root does not exist: $proposed_path"

        TARGET_PATH="$(realpath -e -- "$proposed_path")"
        canonical_home="$(realpath -e -- "$USER_HOME")"

        case "${TARGET_PATH}/" in
            "${canonical_home}/"*) ;;
            *) die "The resolved document root is outside the selected account home. Refusing to continue." ;;
        esac

        runuser -u "$SITE_USER" -- test -r "$TARGET_PATH" \
            || die "The hosting account cannot read the resolved document root."
    else
        SITE_USER="$(id -un)"
        USER_HOME="${HOME:-}"
        TARGET_PATH="$(pwd -P)"
        CONTROL_PANEL="local-directory"
        success "Using the current directory without server-wide discovery."
    fi

    info "Account: $SITE_USER"
    [[ -n "$DOMAIN" ]] && info "Domain: $DOMAIN"
    info "WordPress path: $TARGET_PATH"
}

find_wp_cli() {
    WP_BIN="$(command -v wp || true)"
    [[ -n "$WP_BIN" && -x "$WP_BIN" ]] \
        || die "WP-CLI was not found in PATH. Install WP-CLI before running this script."

    info "WP-CLI binary: $WP_BIN"
}

# All WordPress operations pass through this wrapper. Root never runs WP-CLI
# directly; it switches to the selected hosting account first.
wp_run() {
    local -a global_args=(
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
            "$WP_BIN" "${global_args[@]}" "$@"
    else
        env \
            "WP_CLI_CONFIG_PATH=/dev/null" \
            "WP_CLI_DISABLE_AUTO_CHECK_UPDATE=1" \
            "$WP_BIN" "${global_args[@]}" "$@"
    fi
}

verify_wordpress_installation() {
    [[ -f "$TARGET_PATH/wp-config.php" ]] \
        || die "WordPress was not found at the selected path: wp-config.php is missing."
    [[ -f "$TARGET_PATH/wp-load.php" ]] \
        || die "WordPress was not found at the selected path: wp-load.php is missing."
    [[ -d "$TARGET_PATH/wp-admin" && -d "$TARGET_PATH/wp-includes" ]] \
        || die "WordPress was not found at the selected path: core directories are missing."

    if ! wp_run core is-installed >/dev/null 2>&1; then
        die "WP-CLI could not confirm an installed WordPress site at this exact path. No changes were made."
    fi

    if wp_run core is-installed --network >/dev/null 2>&1; then
        die "WordPress Multisite was detected. Automatic account changes are disabled for multisite installations."
    fi

    SITE_URL="$(wp_run option get siteurl 2>/dev/null)"
    [[ -n "$SITE_URL" ]] || die "WP-CLI could not read the WordPress site URL."

    success "WordPress installation confirmed."
    info "Site URL: $SITE_URL"
    info "WordPress version: $(wp_run core version)"
}

generate_password() {
    local candidate=""
    local random_chunk=""

    require_command openssl
    require_command tr

    while :; do
        # Generate more data than needed, remove non-alphanumeric characters,
        # then take exactly nine characters without exposing the password in argv.
        random_chunk="$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9')"
        candidate="${random_chunk:0:9}"

        if [[ ${#candidate} -eq 9 && "$candidate" =~ [A-Za-z] && "$candidate" =~ [0-9] ]]; then
            PASSWORD="$candidate"
            return 0
        fi
    done
}

managed_marker_matches() {
    local user_id="$1"
    local marker=""

    if ! marker="$(wp_run user meta get "$user_id" "$MANAGED_META_KEY" 2>/dev/null)"; then
        return 1
    fi

    [[ "$marker" == "$MANAGED_META_VALUE" ]]
}

mark_managed_user() {
    local user_id="$1"
    local created_at

    created_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

    if ! wp_run user meta update "$user_id" "$MANAGED_META_KEY" "$MANAGED_META_VALUE" >/dev/null; then
        return 1
    fi

    if ! wp_run user meta update "$user_id" "$CREATED_META_KEY" "$created_at" >/dev/null; then
        return 1
    fi
}

create_or_rotate_user() {
    local user_id=""
    local temp_email=""
    local account_state=""
    local created_now=0

    generate_password

    if wp_run user exists "$TEMP_USERNAME" >/dev/null 2>&1; then
        user_id="$(wp_run user get "$TEMP_USERNAME" --field=ID)"

        if ! managed_marker_matches "$user_id"; then
            die "An existing account named '${TEMP_USERNAME}' is not marked as managed by this script. It was not modified."
        fi

        account_state="Password rotated"
        info "Managed account found. Rotating its password."

        # --prompt keeps the password out of the process argument list.
        printf '%s\n' "$PASSWORD" \
            | wp_run user update "$user_id" --prompt=user_pass >/dev/null
    else
        temp_email="${TEMP_USERNAME}.$(date -u +%s)@temporary.invalid"
        account_state="Account created"
        created_now=1
        info "No managed account exists. Creating a temporary administrator."

        # --prompt keeps the password out of the process argument list.
        printf '%s\n' "$PASSWORD" \
            | wp_run user create "$TEMP_USERNAME" "$temp_email" \
                --role=administrator \
                --display_name="$TEMP_DISPLAY_NAME" \
                --prompt=user_pass >/dev/null

        user_id="$(wp_run user get "$TEMP_USERNAME" --field=ID)"

        if ! mark_managed_user "$user_id"; then
            warning "Could not attach the management marker. Rolling back the new account."
            wp_run user delete "$user_id" --yes >/dev/null 2>&1 || true
            die "The temporary account was rolled back because its safety marker could not be saved."
        fi
    fi

    # Ensure the previously managed account remains an administrator.
    wp_run user set-role "$user_id" administrator >/dev/null

    if (( created_now == 0 )); then
        mark_managed_user "$user_id"
    fi

    # Invalidate any sessions that used the previous password.
    wp_run user session destroy "$user_id" --all >/dev/null 2>&1 || true

    success "$account_state successfully."

    printf '\n%b\n' "${C_GREEN}${C_BOLD}┌──────────────── Temporary Credentials ────────────────┐${C_RESET}"
    printf '%b %-14s %s\n' "$C_BOLD" "Site:" "$SITE_URL${C_RESET}"
    printf '%b %-14s %s\n' "$C_BOLD" "Login URL:" "${SITE_URL%/}/wp-login.php${C_RESET}"
    printf '%b %-14s %s\n' "$C_BOLD" "Username:" "$TEMP_USERNAME${C_RESET}"
    printf '%b %-14s %s\n' "$C_BOLD" "Password:" "$PASSWORD${C_RESET}"
    printf '%b %-14s %s\n' "$C_BOLD" "User ID:" "$user_id${C_RESET}"
    printf '%b\n\n' "${C_GREEN}${C_BOLD}└────────────────────────────────────────────────────────┘${C_RESET}"

    warning "Store the password securely and delete the temporary account immediately after support work."
    info "Deletion command: ./${SCRIPT_NAME} --delete"
}

delete_managed_user() {
    local user_id=""
    local admin_ids=""
    local admin_id=""
    local reassign_id=""
    local reassign_login=""

    if ! wp_run user exists "$TEMP_USERNAME" >/dev/null 2>&1; then
        success "No account named '${TEMP_USERNAME}' exists. Nothing was changed."
        return 0
    fi

    user_id="$(wp_run user get "$TEMP_USERNAME" --field=ID)"

    if ! managed_marker_matches "$user_id"; then
        die "The account '${TEMP_USERNAME}' is not marked as managed by this script. It was not deleted."
    fi

    # Preserve authored content by reassigning it to another administrator.
    admin_ids="$(wp_run user list --role=administrator --field=ID)"
    while IFS= read -r admin_id; do
        if [[ -n "$admin_id" && "$admin_id" != "$user_id" ]]; then
            reassign_id="$admin_id"
            break
        fi
    done <<< "$admin_ids"

    [[ -n "$reassign_id" ]] \
        || die "No other administrator exists. Refusing to delete the only administrator account."

    reassign_login="$(wp_run user get "$reassign_id" --field=user_login)"
    info "Any content owned by '${TEMP_USERNAME}' will be reassigned to '${reassign_login}'."

    wp_run user delete "$user_id" --reassign="$reassign_id" --yes >/dev/null

    success "Managed temporary administrator deleted successfully."
    info "Reassigned content owner: $reassign_login (user ID: $reassign_id)"
}

main() {
    parse_arguments "$@"
    print_banner

    stage 1 "Resolving the target website"
    resolve_target_path

    stage 2 "Checking WP-CLI availability"
    find_wp_cli
    success "WP-CLI is available."

    stage 3 "Confirming the exact WordPress installation"
    verify_wordpress_installation

    stage 4 "Applying the requested account operation"
    case "$ACTION" in
        create)
            create_or_rotate_user
            ;;
        delete)
            delete_managed_user
            ;;
        *)
            die "Internal error: unsupported action."
            ;;
    esac

    stage 5 "Finished"
    success "Operation completed without direct SQL access."
    printf '\n'
}

main "$@"
