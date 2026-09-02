# bodyspiritcentre.com

Static site for The Body Spirit Centre. Exported from WordPress 5.8.15 on
2026-09-02 and now maintained here — WordPress is no longer in the loop.

## How to change the site

Edit the HTML and push to `main`. GitHub Actions syncs the repo to Cloudflare R2
and the site is live, usually in under a minute. Every change is a commit, so
`git revert` is a working undo.

Pages live at `<slug>/index.html`, e.g. `contact/index.html` serves `/contact/`.

## How it is served

```
GitHub (main)  --Actions-->  R2 bucket "bodyspirit"  --> Worker "bodyspirit-static"  --> visitors
```

The Worker resolves directory URLs to `index.html` and refuses to serve
`.php`, `.cgi`, `.sql`, `.zip`, `.bak`, `.ini`, `.log` and `/cgi-bin/`, so no
leftover server-side file can ever be returned as source text.

## Required repository secrets

| Secret | Value |
|---|---|
| `CF_ACCOUNT_ID` | Cloudflare account id |
| `R2_ACCESS_KEY_ID` | R2 access key (Cloudflare API token id) |
| `R2_SECRET_ACCESS_KEY` | R2 secret (SHA-256 of the API token string) |

## What was lost leaving WordPress

These were checked before migrating and none were in use:

- **Comments** — already disabled site-wide by the `disable-comments` plugin
- **Contact form** — `/contact/` had no server-side form, only contact details
- **Search** (`/?s=`) — no longer functional; would need a client-side index
- **GigPress events** — `/events/` is now static and updates by editing HTML
- **wp-json / xmlrpc / RSS feeds** — removed; those endpoints no longer exist

## Archive

The original WordPress database is dumped to
`bodyspir_wordpress_20260902.sql.gz` (16 tables) and kept outside this repo.
The full original `public_html` remains on the old origin server until it is
decommissioned.
