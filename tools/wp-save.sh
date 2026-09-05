#!/bin/bash
# Final write-back, then export WordPress to the static site that actually gets
# served. Runs even when the session was cancelled or failed (if: always()), so
# every branch here has to tolerate a half-built environment.
set -uo pipefail

STATE_BUCKET="${STATE_BUCKET:-bodyspirit-wp}"
WP_DIR="${WP_DIR:-/opt/wp}"
LIVE_HOST="${LIVE_HOST:-www.bodyspiritcentre.com}"
PUBLISH="${PUBLISH:-true}"
REPO_DIR="$(pwd)"

if ! mysqladmin -uroot -proot ping >/dev/null 2>&1; then
  echo "MySQL never came up -- nothing to save"
  exit 0
fi

echo "--- final save to R2 ---"
mysqldump -uroot -proot --single-transaction --quick wordpress | gzip -9 > /tmp/db-final.sql.gz
aws s3 cp /tmp/db-final.sql.gz "s3://$STATE_BUCKET/db-latest.sql.gz" --endpoint-url "$ENDPOINT" --no-progress
tar czf /tmp/wp-content-final.tar.gz -C "$WP_DIR" wp-content
aws s3 cp /tmp/wp-content-final.tar.gz "s3://$STATE_BUCKET/wp-content.tar.gz" --endpoint-url "$ENDPOINT" --no-progress
# A dated copy, so a bad edit can be rolled back to any previous session.
aws s3 cp /tmp/db-final.sql.gz "s3://$STATE_BUCKET/history/db-$(date -u '+%Y%m%d-%H%M').sql.gz" \
  --endpoint-url "$ENDPOINT" --no-progress
echo "saved $(stat -c%s /tmp/db-final.sql.gz) bytes"

if [ "$PUBLISH" != "true" ]; then
  echo "publish not requested -- state saved, site untouched"
  exit 0
fi

echo "--- export to static ---"
# Flip the site URL to the live host so generated links are the real ones, then
# mirror over /etc/hosts (which points the live host at this runner).
sed -i "s#https://[a-z.]*bodyspiritcentre.com'#https://${LIVE_HOST}'#g" "$WP_DIR/wp-config.php"
grep -n "WP_HOME\|WP_SITEURL" "$WP_DIR/wp-config.php"
sleep 2

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
# and the WordPress discovery <link> tags for dead endpoints go away.
find "$OUT" -name '*.html' -print0 | xargs -0 perl -pi -e "
  s#https?://${LIVE_HOST}/#/#g;
  s#<link[^>]+rel=[\"'](?:pingback|EditURI|wlwmanifest|alternate|https://api\.w\.org/)[\"'][^>]*>##g;
"

pages=$(find "$OUT" -name '*.html' | wc -l)
echo "exported $pages html files"
if [ "$pages" -lt 10 ]; then
  echo "REFUSING to publish: only $pages pages, expected ~12. Leaving the live site alone."
  exit 1
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
