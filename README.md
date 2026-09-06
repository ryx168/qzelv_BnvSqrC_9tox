# Static site + on-demand editor

The published site is the HTML in this repository. Every push to `main` syncs it
to object storage, where a Worker serves it. Nothing runs between edits.

## Editing

Just open `/wp-admin` on the site. The editor starts itself — about two minutes —
and then presents the usual login. Work as normal and close the tab when done;
after the idle timeout the session saves, exports the site to static HTML,
commits it here, and the deploy workflow publishes it.

- Database and uploads live in object storage, restored at the start of a
  session and written back **every five minutes**, so a runner that dies loses
  at most five minutes of work.
- Dated database copies are kept, so a bad edit can be rolled back.
- Only one session runs at a time; a second would overwrite the first.
- A session cannot exceed six hours. That is a platform limit, not a setting.

## Two things to keep true

**The database must never be committed here.** This repository is public and the
users table contains password hashes and email addresses. `.gitignore` blocks
the patterns and the workflow unstages them again before committing.

**Editor state does not belong in the site bucket.** The deploy workflow runs
`aws s3 sync --delete` against it, so anything there that is not in this
repository gets deleted. That is why the state has its own bucket.

## Configuration

Everything environment-specific — hostnames, bucket names, credentials — comes
from repository secrets, so nothing identifying is committed:

| Secret | Purpose |
| --- | --- |
| `CF_ACCOUNT_ID`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY` | object storage |
| `SITE_HOST`, `EDIT_HOSTNAME` | public and editor hostnames |
| `SITE_BUCKET`, `STATE_BUCKET` | site files and editor state |
| `CF_TUNNEL_TOKEN` | connector for the editor session |
| `SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASS`, `SMTP_FROM` | outbound mail |

Action logs on a public repository are world-readable, so none of these may be
echoed to the log.
