# Static site + on-demand editor

The published site is the HTML in this repository. Every push to `main` syncs it
to Cloudflare R2, where a Worker serves it. There is no server running anywhere
between edits.

## Editing

`Actions` -> `Edit session` -> `Run workflow`.

About two minutes later WordPress is reachable at the editor hostname. Edit as
normal. When you finish, close the tab; after the idle timeout (default 60
minutes) the session saves, exports the site to static HTML, commits it here,
and the deploy workflow puts it live.

- The database and `wp-content` live in the `bodyspirit-wp` R2 bucket. They are
  restored at the start of a session and written back **every five minutes**,
  so a runner that dies loses at most five minutes of work.
- Dated database copies are kept under `history/` in that bucket, so a bad edit
  can be rolled back.
- Only one session can run at a time; a second would overwrite the first.
- A session cannot exceed six hours. That is a GitHub limit, not a setting.

## Two things to keep true

**The database must never be committed here.** This repository is public and
`wp_users` contains password hashes and email addresses. `.gitignore` blocks the
patterns and the workflow unstages them again before committing.

**WordPress state does not belong in the `bodyspirit` bucket.** The deploy
workflow runs `aws s3 sync --delete` against it, so anything there that is not
in this repository gets deleted. That is why the state has its own bucket.

## Secrets this repository needs

| Secret | What it is |
| --- | --- |
| `CF_ACCOUNT_ID` | Cloudflare account id |
| `R2_ACCESS_KEY_ID` | R2 access key (a Cloudflare API token id) |
| `R2_SECRET_ACCESS_KEY` | SHA-256 of that API token's string |
| `CF_TUNNEL_TOKEN` | token for the `cloudflared` tunnel serving the editor |

Actions logs on a public repository are world-readable, so nothing here may be
echoed to the log.
