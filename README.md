<div align="center">

# WordPress Temporary Admin

Create, update, and safely remove a temporary WordPress administrator using **WP-CLI only**.

**No direct SQL · 15-character password · cPanel and DirectAdmin support · Automatic cleanup**

**Author:** Amir Hossein Pouya  
**Repository:** https://github.com/amirpooya784/wp-admin-temp.sh

</div>

---

## Overview

`wp-admin-temp.sh` creates a temporary WordPress administrator named `isadmin` for support and maintenance work.

When the account does not exist, the script creates it. When a script-managed `isadmin` account already exists, the script generates a new 15-character password and updates it.

The script is first saved in a private directory under `/tmp`, then executed from that location. After the temporary administrator is successfully deleted, the temporary script file removes itself.

## Main Features

- Uses WP-CLI exclusively for WordPress operations.
- Never runs direct SQL commands.
- Creates a 15-character alphanumeric password.
- Keeps the password out of the process argument list.
- Creates or updates the `isadmin` administrator.
- Invalidates previous login sessions after a password update.
- Detects cPanel or DirectAdmin when executed as root.
- Requests the hosting username and domain in root mode.
- Runs WP-CLI as the hosting account owner, not as root.
- Refuses to search arbitrary server directories.
- Stops immediately when WordPress is not found.
- Refuses to modify an unrelated `isadmin` account.
- Reassigns authored content before deleting the temporary user.
- Deletes its `/tmp` copy after a successful delete operation.

---

## Requirements

- Linux server
- Bash
- WP-CLI available in `PATH`
- `curl`
- `openssl`
- `tr`
- A standard WordPress installation
- cPanel or DirectAdmin when executing as root

WordPress Multisite is intentionally not supported.

---

## Quick Start

Run the following command from the WordPress document root, usually `public_html`:

```bash
bash <(curl -kLs https://raw.githubusercontent.com/amirpooya784/wp-admin-temp.sh/main/wp-admin-temp.sh)
```

The command performs one of these actions:

- Creates a new `isadmin` account when it does not exist.
- Updates the password when a script-managed `isadmin` account already exists.

---

## Explicit Create or Update

The default command and the `--create` option have the same behavior.

```bash
bash <(curl -kLs https://raw.githubusercontent.com/amirpooya784/wp-admin-temp.sh/main/wp-admin-temp.sh) --create
```

The short action name is also accepted:

```bash
bash <(curl -kLs https://raw.githubusercontent.com/amirpooya784/wp-admin-temp.sh/main/wp-admin-temp.sh) create
```

---

## Delete the Temporary Administrator

The online delete command has the same format as the create command:

```bash
bash <(curl -kLs https://raw.githubusercontent.com/amirpooya784/wp-admin-temp.sh/main/wp-admin-temp.sh) --delete
```

The short action name is also accepted:

```bash
bash <(curl -kLs https://raw.githubusercontent.com/amirpooya784/wp-admin-temp.sh/main/wp-admin-temp.sh) delete
```

After creating or updating the account, the script prints an exact local delete command in its final output. You can copy and run that command directly.

Example:

```bash
bash /tmp/wp-admin-temp-0/wp-admin-temp.sh --delete
```

The exact path depends on the effective user ID. Always use the delete command printed by the script.

After a successful delete operation:

1. The `isadmin` account is deleted.
2. Its authored content is reassigned to another administrator.
3. The temporary script is removed from `/tmp`.
4. The private temporary directory is removed when empty.

---

## Run Inside `public_html`

When logged in as the hosting account user, change to the WordPress document root and run the script:

```bash
cd /home/USERNAME/public_html
bash <(curl -kLs https://raw.githubusercontent.com/amirpooya784/wp-admin-temp.sh/main/wp-admin-temp.sh)
```

For an addon domain or a custom document root:

```bash
cd /path/to/domain/document-root
bash <(curl -kLs https://raw.githubusercontent.com/amirpooya784/wp-admin-temp.sh/main/wp-admin-temp.sh)
```

The script only checks the current directory. It does not scan other server paths.

---

## Run as Root

Open a root shell and run the normal command:

```bash
sudo -i
bash <(curl -kLs https://raw.githubusercontent.com/amirpooya784/wp-admin-temp.sh/main/wp-admin-temp.sh)
```

The script detects cPanel or DirectAdmin and requests:

```text
Hosting account username:
Domain name:
```

It then resolves the domain document root and runs WP-CLI as the selected hosting account owner.

To delete the user in root mode, use the delete command printed after creation, or run:

```bash
bash <(curl -kLs https://raw.githubusercontent.com/amirpooya784/wp-admin-temp.sh/main/wp-admin-temp.sh) --delete
```

The hosting username and domain will be requested again.

---

## Local File Execution

Download the script:

```bash
curl -kLs https://raw.githubusercontent.com/amirpooya784/wp-admin-temp.sh/main/wp-admin-temp.sh -o wp-admin-temp.sh
```

Set secure permissions:

```bash
chmod 700 wp-admin-temp.sh
```

Create or update the temporary administrator:

```bash
bash wp-admin-temp.sh
```

Delete the temporary administrator:

```bash
bash wp-admin-temp.sh --delete
```

Even during local execution, the script installs and runs a protected copy from `/tmp`.

---

## Help and Version

Show help online:

```bash
bash <(curl -kLs https://raw.githubusercontent.com/amirpooya784/wp-admin-temp.sh/main/wp-admin-temp.sh) --help
```

Show the version online:

```bash
bash <(curl -kLs https://raw.githubusercontent.com/amirpooya784/wp-admin-temp.sh/main/wp-admin-temp.sh) --version
```

Show help using the temporary copy:

```bash
bash /tmp/wp-admin-temp-0/wp-admin-temp.sh --help
```

Show the version using the temporary copy:

```bash
bash /tmp/wp-admin-temp-0/wp-admin-temp.sh --version
```

Use the actual temporary path printed on your server.

---

## Example Output: New Account

```text
Creating new account...
Account ready.

Credentials
Site: https://example.com
Login: https://example.com/wp-login.php
Username: isadmin
Password: A7k2Lm9Qx4Rt8Wp
User ID: 42
Delete: bash /tmp/wp-admin-temp-1001/wp-admin-temp.sh --delete
```

## Example Output: Existing Managed Account

```text
Existing account found. Updating password...
Account ready.

Credentials
Site: https://example.com
Login: https://example.com/wp-login.php
Username: isadmin
Password: P8m3Xs7Ka2Vn5Qz
User ID: 42
Delete: bash /tmp/wp-admin-temp-1001/wp-admin-temp.sh --delete
```

## Example Output: Delete

```text
Account deleted.
Temporary script removed.
```

---

## Temporary File Behavior

The temporary directory is based on the effective user ID.

Root example:

```text
/tmp/wp-admin-temp-0/wp-admin-temp.sh
```

Hosting user example:

```text
/tmp/wp-admin-temp-1001/wp-admin-temp.sh
```

The directory and script use restrictive permissions. The script refuses unsafe symbolic links or temporary paths owned by another user.

Running the online delete command downloads the latest script into the same private temporary location, performs the delete operation, and removes the temporary copy afterward.

---

## Account Safety Marker

A private WordPress user-meta marker identifies accounts created by this project.

The script updates or deletes `isadmin` only when that marker is present. If an unrelated account already uses the same username, the script stops without modifying it.

This prevents accidental changes to an existing administrator that was not created by this tool.

---

## Delete Safety

Before deleting the temporary administrator, the script finds another administrator and reassigns any content owned by `isadmin`.

If no other administrator exists, deletion is refused:

```text
Error: No other administrator exists. Account was not deleted.
```

The temporary script remains available so the problem can be corrected before trying again.

---

## WordPress Validation

Before making any change, the script verifies all of the following:

- `wp-config.php` exists.
- `wp-load.php` exists.
- `wp-admin` exists.
- `wp-includes` exists.
- WP-CLI confirms the installation with `wp core is-installed`.
- The installation is not WordPress Multisite.

When WordPress is not confirmed, the script exits with:

```text
Error: WordPress not found. No changes were made.
```

---

## WP-CLI Security

All WordPress data operations use WP-CLI commands such as:

```bash
wp user create
```

```bash
wp user update
```

```bash
wp user delete
```

```bash
wp user meta get
```

```bash
wp user meta update
```

```bash
wp user session destroy
```

No MySQL client, direct SQL statement, or database credential parsing is used.

The generated password is supplied through WP-CLI prompt input instead of a command-line password argument. This prevents the password from appearing in normal process listings.

Plugins, themes, and WP-CLI packages are skipped during execution to reduce side effects.

---

## TLS Note

The requested quick command uses `curl -k`, which disables TLS certificate verification:

```bash
bash <(curl -kLs https://raw.githubusercontent.com/amirpooya784/wp-admin-temp.sh/main/wp-admin-temp.sh)
```

When the server has a valid CA certificate store, the safer command is:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/amirpooya784/wp-admin-temp.sh/main/wp-admin-temp.sh)
```

Use `-k` only when certificate validation is unavailable and you understand the security tradeoff.

---

## Common Errors

### WP-CLI is missing

```text
Error: WP-CLI was not found.
```

Install WP-CLI and make sure the `wp` command is available in `PATH`.

### WordPress is not in the current directory

```text
Error: WordPress not found. No changes were made.
```

Change to the exact WordPress document root and run the command again.

### Existing `isadmin` is not managed by this script

```text
Error: Existing 'isadmin' account is not managed by this script.
```

The script intentionally refuses to modify or delete that account.

### Unsupported control panel

```text
Error: Supported control panel not found.
```

Root mode supports cPanel and DirectAdmin only. Run the script as the hosting user from the exact WordPress document root on other server layouts.

### Multisite detected

```text
Error: WordPress Multisite is not supported. No changes were made.
```

Multisite account management is intentionally blocked to prevent unintended network-wide changes.

---

## Recommended Workflow

Create or update the temporary administrator:

```bash
bash <(curl -kLs https://raw.githubusercontent.com/amirpooya784/wp-admin-temp.sh/main/wp-admin-temp.sh)
```

Complete the required support work, then copy the exact delete command printed in the output:

```bash
bash /tmp/wp-admin-temp-USER_ID/wp-admin-temp.sh --delete
```

Alternatively, run the online delete command:

```bash
bash <(curl -kLs https://raw.githubusercontent.com/amirpooya784/wp-admin-temp.sh/main/wp-admin-temp.sh) --delete
```

Do not leave temporary administrator accounts active after maintenance is complete.

---

## License

Add the license of your choice to the repository before public distribution.

