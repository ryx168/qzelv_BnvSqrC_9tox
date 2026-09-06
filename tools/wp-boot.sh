#!/bin/bash
# Bring up WordPress inside the runner from the state restored out of R2.
# Runs as root (the workflow calls it with sudo -E) so it can bind port 80 and
# write /etc/hosts.
set -euo pipefail

WP_DIR="${WP_DIR:-/opt/wp}"
EDIT_HOST="${EDIT_HOST:?}"
LIVE_HOST="${LIVE_HOST:?}"

echo "--- MySQL ---"
systemctl start mysql
for _ in $(seq 1 30); do mysqladmin -uroot -proot ping >/dev/null 2>&1 && break; sleep 1; done
mysql -uroot -proot -e "CREATE DATABASE wordpress DEFAULT CHARACTER SET utf8mb4;"
mysql -uroot -proot -e "CREATE USER 'wp'@'localhost' IDENTIFIED BY 'wp'; GRANT ALL ON wordpress.* TO 'wp'@'localhost';"
gunzip -c /tmp/db.sql.gz | mysql -uroot -proot wordpress
echo "tables: $(mysql -uroot -proot -N -B -e 'SELECT COUNT(*) FROM information_schema.tables WHERE table_schema="wordpress";')"

echo "--- WordPress core ---"
# Latest core, not the origin's ancient 5.8.15 -- that predates PHP 8 and will
# not run on a modern runner. wp-content (theme, plugins, uploads) is the
# site's own, so the look is unchanged; core is disposable and rebuilt each
# session. If a theme or plugin ever breaks on a new core, pin a version here.
mkdir -p "$WP_DIR"
curl -fsSL https://wordpress.org/latest.tar.gz -o /tmp/wp.tar.gz
tar xzf /tmp/wp.tar.gz -C "$WP_DIR" --strip-components=1
rm -rf "$WP_DIR/wp-content"
tar xzf /tmp/wp-content.tar.gz -C "$WP_DIR"
echo "core $(grep -oP "(?<=\\\$wp_version = ')[^']+" "$WP_DIR/wp-includes/version.php")"

# /assets lives at the document root on the old server, OUTSIDE WordPress, and
# the theme's inline CSS points at it. Without it those URLs 404, wget saves
# the 404 pages as "arrow.gif.html", and --convert-links rewrites every page to
# match -- silently stripping the header, backgrounds and nav imagery from the
# whole site. The repository is the authority for these files.
REPO="${GITHUB_WORKSPACE:-$(pwd)}"
for extra in assets; do
  if [ -d "$REPO/$extra" ]; then
    cp -r "$REPO/$extra" "$WP_DIR/"
    echo "seeded /$extra from the repo ($(find "$REPO/$extra" -type f | wc -l) files)"
  fi
done

echo "--- wp-config.php ---"
# WP_HOME/WP_SITEURL as constants beat whatever is stored in the database.
# They are set to the LIVE host because the admin is reached through it -- the
# Worker proxies /wp-admin to the tunnel -- so WordPress must believe it is the
# live site, keeping the login cookie on the right domain and every admin link
# pointing where the browser actually is. The save step flips these to http for
# the local mirror.
cat > "$WP_DIR/wp-config.php" <<PHPEOF
<?php
define('DB_NAME', 'wordpress');
define('DB_USER', 'wp');
define('DB_PASSWORD', 'wp');
define('DB_HOST', 'localhost');
define('DB_CHARSET', 'utf8mb4');
define('DB_COLLATE', '');
define('WP_HOME',    'https://${LIVE_HOST}');
define('WP_SITEURL', 'https://${LIVE_HOST}');
// Behind Cloudflare the connection to PHP is plain HTTP; without this
// WordPress builds http:// URLs and wp-admin redirect-loops.
if (isset(\$_SERVER['HTTP_X_FORWARDED_PROTO']) && \$_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https') {
    \$_SERVER['HTTPS'] = 'on';
}
// SMTP. The runner has no mail server, so without this every wp_mail()
// fails silently -- including "lost your password". These land only in
// wp-config.php, which sits outside wp-content and is therefore never
// written to R2 nor committed anywhere.
define('WP_SMTP_HOST', '${SMTP_HOST:-}');
define('WP_SMTP_PORT', '${SMTP_PORT:-587}');
define('WP_SMTP_USER', '${SMTP_USER:-}');
define('WP_SMTP_PASS', '${SMTP_PASS:-}');
define('WP_SMTP_FROM', '${SMTP_FROM:-}');
define('DISALLOW_FILE_EDIT', true);      // no theme/plugin editor in the browser
define('DISALLOW_FILE_MODS', true);      // no installing anything from wp-admin
define('AUTOMATIC_UPDATER_DISABLED', true);
define('WP_DEBUG', false);
\$table_prefix = 'wp_';
if (!defined('ABSPATH')) define('ABSPATH', __DIR__ . '/');
require_once ABSPATH . 'wp-settings.php';
PHPEOF

chown -R www-data:www-data "$WP_DIR"

echo "--- smtp ---"
mkdir -p "$WP_DIR/wp-content/mu-plugins"
cat > "$WP_DIR/wp-content/mu-plugins/00-smtp.php" <<'PHPEOF'
<?php
// Route wp_mail() through SMTP. There is no MTA on the runner, so without
// this WordPress reports "the email could not be sent" for password resets.
add_action('phpmailer_init', function ($m) {
    if (!defined('WP_SMTP_HOST') || WP_SMTP_HOST === '') return;
    $m->isSMTP();
    $m->Host       = WP_SMTP_HOST;
    $m->Port       = (int) WP_SMTP_PORT;
    $m->SMTPAuth   = true;
    $m->Username   = WP_SMTP_USER;
    $m->Password   = WP_SMTP_PASS;
    $m->SMTPSecure = ((int) WP_SMTP_PORT === 465) ? 'ssl' : 'tls';
});
// The provider only accepts a verified sender, so force the From address.
add_filter('wp_mail_from', function ($e) {
    return (defined('WP_SMTP_FROM') && WP_SMTP_FROM !== '') ? WP_SMTP_FROM : $e;
});
PHPEOF
echo "smtp configured: $([ -n "${SMTP_HOST:-}" ] && echo yes || echo 'no host set')"

echo "--- router + server ---"
# php -S serves files directly and falls back to index.php, which is what
# WordPress pretty permalinks need (there is no .htaccess handling here).
cat > "$WP_DIR/router.php" <<'PHPEOF'
<?php
$p = parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH);
$f = __DIR__ . $p;
if ($p !== '/' && file_exists($f) && !is_dir($f)) return false;
if (is_dir($f) && file_exists(rtrim($f, '/') . '/index.php')) {
    $_SERVER['SCRIPT_NAME'] = rtrim($p, '/') . '/index.php';
    require rtrim($f, '/') . '/index.php';
    return true;
}
require __DIR__ . '/index.php';
PHPEOF

# The live hostname resolves to this runner, so the export step can mirror the
# site by its real URL and produce links identical to the previous export.
grep -q "$LIVE_HOST" /etc/hosts || echo "127.0.0.1 $LIVE_HOST" >> /etc/hosts

# Without workers, php -S is single-threaded and wp-admin deadlocks the moment
# it makes a second request to itself (admin-ajax, cron).
export PHP_CLI_SERVER_WORKERS=6
setsid nohup php -S 0.0.0.0:80 -t "$WP_DIR" "$WP_DIR/router.php" > /tmp/php.log 2>&1 &

# Ask as the live hostname. A bare request to 127.0.0.1 gets a 301, because
# WP_HOME is the live host and WordPress canonicalises to it -- that is correct
# behaviour, not a fault, so the check has to send the right Host. The
# forwarded-proto header stands in for Cloudflare's TLS termination.
probe() {
  curl -s -o /dev/null -w '%{http_code}'     -H "Host: ${LIVE_HOST}" -H "X-Forwarded-Proto: https"     "http://127.0.0.1/${1:-}"
}
for _ in $(seq 1 30); do
  case "$(probe)" in 200|301|302) break ;; esac
  sleep 1
done
code=$(probe)
echo "local WordPress responded: $code"
case "$code" in
  200) ;;
  *) echo "expected 200 from the front page"; tail -30 /tmp/php.log; exit 1 ;;
esac
admin=$(probe "wp-admin/")
echo "wp-admin responded: $admin"   # 302 to wp-login is correct when logged out
