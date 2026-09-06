#!/bin/bash
# Hold the editing session open: autosave to R2 every few minutes, and stop
# once the editor has been idle long enough.
#
# Autosaving is the whole point. A GitHub runner can be cancelled or die with
# no usable shutdown hook, so writing back only at the end would risk losing an
# entire session's work. At 5-minute intervals the worst case is 5 minutes.
set -euo pipefail

STATE_BUCKET="${STATE_BUCKET:?}"
APP_DIR="${APP_DIR:?}"
IDLE_MINUTES="${IDLE_MINUTES:-60}"
SAVE_EVERY=300                       # seconds between autosaves
POLL=30

idle_limit=$(( IDLE_MINUTES * 60 ))
last_count=0
last_activity=$(date +%s)
last_save=$(date +%s)

# php -S logs one line per request, so the line count is a usable activity
# signal. Asset requests count too, which is fine -- a browser sitting on
# wp-admin is a session in use.
# Readiness polls are tagged __probe and must NOT count as activity: the
# waiting page and any bot hitting the admin URL would otherwise hold a
# session open indefinitely, which is exactly what the idle stop exists to
# prevent.
requests() { grep -vc "__probe" /tmp/php.log 2>/dev/null || echo 0; }

autosave() {
  local why="$1"
  mysqldump -uroot -proot --single-transaction --quick wordpress \
    | gzip -9 > /tmp/db-save.sql.gz
  aws s3 cp /tmp/db-save.sql.gz "s3://$STATE_BUCKET/db-latest.sql.gz" \
    --endpoint-url "$ENDPOINT" --no-progress
  # uploads are the only part of wp-content a customer can change from wp-admin
  tar czf /tmp/wp-content-save.tar.gz -C "$APP_DIR" wp-content
  aws s3 cp /tmp/wp-content-save.tar.gz "s3://$STATE_BUCKET/wp-content.tar.gz" \
    --endpoint-url "$ENDPOINT" --no-progress
  if [ -f "$APP_DIR/wp-content/activity.log" ]; then
    aws s3 cp "$APP_DIR/wp-content/activity.log" "s3://$STATE_BUCKET/activity.log"       --endpoint-url "$ENDPOINT" --no-progress >/dev/null
  fi
  echo "$(date -u '+%H:%M:%S') autosaved ($why) db=$(stat -c%s /tmp/db-save.sql.gz)b"
}

echo "session open; idle stop after ${IDLE_MINUTES} min"
last_count=$(requests)

while :; do
  sleep "$POLL"
  now=$(date +%s)

  count=$(requests)
  if [ "$count" -ne "$last_count" ]; then
    last_activity=$now
    last_count=$count
  fi

  # Signed out: stop immediately instead of waiting out the idle timer.
  if [ -f /tmp/session-stop ]; then
    echo "$(date -u '+%H:%M:%S') signed out -- closing the session"
    autosave logout
    break
  fi

  idle=$(( now - last_activity ))
  if [ "$idle" -ge "$idle_limit" ]; then
    echo "idle ${idle}s >= ${idle_limit}s -- ending session"
    break
  fi

  if [ $(( now - last_save )) -ge "$SAVE_EVERY" ]; then
    autosave periodic
    last_save=$now
  fi
done
