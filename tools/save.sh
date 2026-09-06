#!/bin/bash
# Final write-back, then export the site to the static site that actually gets
# served. Runs even when the session was cancelled or failed (if: always()), so
# every branch here has to tolerate a half-built environment.
set -uo pipefail

STATE_BUCKET="${STATE_BUCKET:?}"
APP_DIR="${APP_DIR:?}"
LIVE_HOST="${LIVE_HOST:?}"
PUBLISH="${PUBLISH:-true}"
EXPORT_ONLY="${EXPORT_ONLY:-false}"
REPO_DIR="$(pwd)"

if ! mysqladmin -uroot -proot ping >/dev/null 2>&1; then
  echo "MySQL never came up -- nothing to save"
  exit 0
fi

echo "--- final save to R2 ---"
mysqldump -uroot -proot --single-transaction --quick wordpress | gzip -9 > /tmp/db-final.sql.gz
aws s3 cp /tmp/db-final.sql.gz "s3://$STATE_BUCKET/db-latest.sql.gz" --endpoint-url "$ENDPOINT" --no-progress
tar czf /tmp/wp-content-final.tar.gz -C "$APP_DIR" wp-content
aws s3 cp /tmp/wp-content-final.tar.gz "s3://$STATE_BUCKET/wp-content.tar.gz" --endpoint-url "$ENDPOINT" --no-progress
# A dated copy, so a bad edit can be rolled back to any previous session.
aws s3 cp /tmp/db-final.sql.gz "s3://$STATE_BUCKET/history/db-$(date -u '+%Y%m%d-%H%M').sql.gz" \
  --endpoint-url "$ENDPOINT" --no-progress
echo "saved $(stat -c%s /tmp/db-final.sql.gz) bytes"

# The activity log, readable without waiting for a run to finish.
if [ -f "$APP_DIR/wp-content/activity.log" ]; then
  aws s3 cp "$APP_DIR/wp-content/activity.log" "s3://$STATE_BUCKET/activity.log"     --endpoint-url "$ENDPOINT" --no-progress
  echo "activity: $(wc -l < "$APP_DIR/wp-content/activity.log") entries"
  echo "--- this session ---"
  tail -20 "$APP_DIR/wp-content/activity.log" || true
fi

if [ "$PUBLISH" != "true" ] && [ "$EXPORT_ONLY" != "true" ]; then
  echo "publish not requested -- state saved, site untouched"
  exit 0
fi

echo "--- export to static ---"
# Flip the site URL to the live host so generated links are the real ones, then
# mirror over /etc/hosts (which points the live host at this runner).
# http, not https: the mirror is fetched over plain HTTP from 127.0.0.1, and an
# https WP_HOME makes the application redirect to a port nothing is listening on. The
# rewrite pass below matches either scheme, so the output is identical.
sed -i -E "s#(define\('WP_(HOME|SITEURL)', *)'[^']*'#\1'http://${LIVE_HOST}'#" "$APP_DIR/wp-config.php"
grep -n "WP_HOME\|WP_SITEURL" "$APP_DIR/wp-config.php"

# Each workflow step gets its own sudo session, and the PHP server started in
# the boot step does not reliably survive into this one. Rather than depend on
# that, make this step self-sufficient: start the server if nothing answers.
if ! curl -s -o /dev/null --max-time 5 "http://127.0.0.1/"; then
  echo "php server is not up -- starting one for the export"
  export PHP_CLI_SERVER_WORKERS=6
  setsid nohup php -S 0.0.0.0:80 -t "$APP_DIR" "$APP_DIR/router.php" > /tmp/php-export.log 2>&1 &
fi
for _ in $(seq 1 30); do
  code=$(curl -s -o /dev/null -w '%{http_code}' -H "Host: ${LIVE_HOST}" http://127.0.0.1/)
  [ "$code" = "200" ] && break
  sleep 1
done
echo "serving as ${LIVE_HOST}: $code"
if [ "$code" != "200" ]; then
  echo "cannot serve the site locally -- aborting before the export"
  tail -20 /tmp/php-export.log /tmp/php.log 2>/dev/null
  exit 1
fi

OUT=/tmp/mirror
rm -rf "$OUT"; mkdir -p "$OUT"
cd "$OUT"

wget --mirror --page-requisites --convert-links --adjust-extension \
     --no-host-directories --no-verbose \
     --reject-regex '(wp-admin|wp-login|xmlrpc|/feed/|wp-json|\?)' \
     "http://${LIVE_HOST}/" 2>&1 | tail -5

# wget only follows links, so pages that nothing links to are missed. The
# sitemap is the authority -- fetch anything the crawl did not reach.
# (Count with grep -o: the XML is one line, so grep -c would report 1.)
curl -fsS "http://${LIVE_HOST}/wp-sitemap-posts-page-1.xml" -o /tmp/sm.xml 2>/dev/null || true
curl -fsS "http://${LIVE_HOST}/wp-sitemap-posts-post-1.xml" -o /tmp/sm2.xml 2>/dev/null || true
cat /tmp/sm.xml /tmp/sm2.xml 2>/dev/null \
  | grep -o '<loc>[^<]*' | sed 's/<loc>//' | sort -u > /tmp/sitemap-urls.txt || true
echo "sitemap lists $(wc -l < /tmp/sitemap-urls.txt) urls"
while read -r u; do
  [ -n "$u" ] || continue
  p="${u#*://*/}"; p="${p%/}"
  [ -n "$p" ] || continue
  if [ ! -f "$OUT/$p/index.html" ] && [ ! -f "$OUT/$p.html" ]; then
    echo "  orphan, fetching: /$p/"
    wget --page-requisites --convert-links --adjust-extension \
         --no-host-directories --no-verbose "$u" 2>&1 | tail -2
  fi
done < /tmp/sitemap-urls.txt

# Make the mirror portable: absolute links to the live host become root paths,
# and the discovery <link> tags for dead endpoints go away.
find "$OUT" -name '*.html' -print0 | xargs -0 perl -pi -e "
  s#https?://${LIVE_HOST}/#/#g;
  s#<link[^>]+rel=[\"'](?:pingback|EditURI|wlwmanifest|alternate|https://api\.w\.org/)[\"'][^>]*>##g;
"

# An asset URL that returns HTML gets saved as "arrow.gif.html", and every page
# is rewritten to point at it. That always means a file is missing from the
# runner, never a real page, and publishing it would strip the site's imagery.
bogus=$(find "$OUT" -regextype posix-extended -regex '.*\.(jpg|jpeg|png|gif|css|js)\.html' | head -20)
if [ -n "$bogus" ]; then
  echo "REFUSING to publish: these asset URLs returned HTML, so files are missing:"
  echo "$bogus" | sed "s#^${OUT}#  #"
  exit 1
fi

# The mirror is fetched over http, so any absolute URL that survives outside
# the HTML rewrite above (robots.txt, sitemaps) still says http. Put those
# back to https, or robots.txt advertises an insecure sitemap URL.
find "$OUT" -maxdepth 1 -name 'robots.txt' -o -name '*.xml' | while read -r f; do
  [ -f "$f" ] && sed -i "s#http://${LIVE_HOST}#https://${LIVE_HOST}#g" "$f"
done

pages=$(find "$OUT" -name '*.html' | wc -l)
echo "exported $pages html files"
if [ "$pages" -lt 10 ]; then
  echo "REFUSING to publish: only $pages pages, expected ~12. Leaving the live site alone."
  exit 1
fi

if [ "$EXPORT_ONLY" = "true" ]; then
  echo "export_only -- mirror left at $OUT for inspection, repo and live site untouched"
  exit 0
fi

echo "--- stage into the repo ---"
cd "$REPO_DIR"
# Replace only content; never touch git, workflows or the tooling.
find . -mindepth 1 -maxdepth 1 \
     ! -name .git ! -name .github ! -name tools ! -name README.md ! -name .gitignore \
     -exec rm -rf {} +
cp -r "$OUT"/. .
rm -f ./*.sql ./*.sql.gz ./*.tar.gz
echo "staged $(find . -name '*.html' -not -path './.git/*' | wc -l) html files"
