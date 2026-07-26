<div align="center">

# WordPress Temporary Admin

Create, update, and delete a temporary WordPress administrator using **WP-CLI only**.

**cPanel & DirectAdmin**

</div>

## Run

Run inside the WordPress `public_html` directory:

```bash
bash <(curl -kLs https://raw.githubusercontent.com/amirpooya784/wp-admin-temp.sh/main/wp-admin-temp.sh)
```

The script creates `isadmin`, or updates its password when the managed account already exists.


## Delete

Online delete command:

```bash
bash <(curl -kLs https://raw.githubusercontent.com/amirpooya784/wp-admin-temp.sh/main/wp-admin-temp.sh) --delete
```

The create output also prints an exact delete command. That command works from any directory and removes both the temporary user and the saved `/tmp` files.

## Root Mode

Run the same command as root. The script detects cPanel or DirectAdmin and asks for:

```text
Hosting username:
Domain:
```

## Safety

- Uses WP-CLI only; no direct SQL.
- Stops when WordPress is not found.
- Does not modify an unrelated `isadmin` account.
- Reassigns content before deleting the user.
- Does not support WordPress Multisite.

## Author

**Amir Hossein Pouya**  
https://github.com/amirpooya784/wp-admin-temp.sh
