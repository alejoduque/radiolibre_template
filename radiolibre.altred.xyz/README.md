# radiolibre.altred.xyz

The RadioLibre site and live player. Static files — no build step, no bundler,
no dependencies. Deploy by copying `index.html` and `assets/` into the webroot.

```
index.html
assets/
  styles.css        all page styling
  logo.jpeg
  js/
    config.js       endpoints, timings, asset version — start here
    icecast.js      reads the Icecast status, normalises it into a stream list
    player.js       drives the <audio> element, reconnects when streams drop
    ui.js           all DOM writes
    main.js         wiring plus the polling loop
test/
  icecast.test.mjs  regression tests for the status parsing
```

## Running locally

```sh
python3 -m http.server 8777    # then open http://127.0.0.1:8777/
node --test                    # run the tests
```

There is no Icecast behind a local server, so on `localhost` the player falls
back to reading the public host, which sends `Access-Control-Allow-Origin: *`.
See `resolveOrigin()` in `config.js`.

## How it talks to Icecast

**Everything is same-origin in production.** nginx on this host already reverse
-proxies Icecast at `127.0.0.1:8000`:

- `location /status-json.xsl` — the stream list.
- `location ~ ^/(.*\.(mp3|ogg|aac|opus|m3u|pls))$` — the audio mounts, with
  `proxy_buffering off` and Range support, which is what streaming needs.

So the player reads `/status-json.xsl` and plays `/rap.mp3` straight off this
domain, using the page's own certificate and making no cross-origin request at
all. `ICECAST_ORIGIN` in `config.js` resolves to `location.origin`.

One consequence: a mount whose file extension is **not** in that nginx regex
will 404. If a broadcaster ever uses `.oga` or `.webm`, add it to the regex in
`/etc/nginx/sites-enabled/radiolibre.altred.xyz.conf`.

## Deploying

The webroot is `/var/www/altred.xyz` (shared with the `altred.xyz` vhost).
Upload `assets/` first and `index.html` last — the old page does not reference
the new assets, so the final file swap is the switch. `package.json`, `test/`
and `README.md` are development-only; leave them out of the webroot.

**Bump `?v=` on every deploy that changes a `.js` or `.css` file.** nginx serves
static assets here as `Cache-Control: public, immutable; max-age=31536000`.
`immutable` means browsers will not revalidate even on a normal reload, so
without a changed URL a returning listener keeps the old player for up to a
year. The version appears in `index.html` (stylesheet + module entry) and in
every intra-module `import ... from './x.js?v=N'`. Change them together:

```sh
grep -rn '?v=' index.html assets/js/
```

`ASSET_VERSION` in `config.js` records the current number.

## Things that will bite you

These are not hypothetical — each one was breaking the live site before this
rewrite.

**Never point anything at `altred.xyz`.** The bare apex answers on port 443 with
a certificate issued only for `adj.altred.xyz`. Browsers reject it before the
request goes out, so any `fetch` or `<img>` there fails silently. The old page
fetched its stream list *and* loaded its logo from that host, which is why
neither worked.

**Icecast 2.4.3 emits invalid JSON.** It leaves a trailing comma before the
closing brace (`…"+0200",}`), and when idle it truncates the document entirely —
the live server really does return 216 bytes containing two `{` and one `}`.
`JSON.parse` rejects all of it, so `response.json()` throws and the player
concludes there are no streams. `repairIcecastJson()` in `icecast.js` fixes the
document before parsing; `test/icecast.test.mjs` pins that behaviour.

**Do not trust `listenurl`.** Icecast reports whatever hostname it was
configured with — here it says `live.altred.xyz` regardless of who asked.
Following it gives a cross-origin request at best. Only the mount path is
meaningful; URLs are always rebuilt against `ICECAST_ORIGIN`.

**There is no XML fallback.** Icecast only exposes `<source>` elements at
`/admin/stats.xml`, which requires authentication. The previous player carried a
`parseXmlData()` path that could never have run.

**Zero live streams is normal.** Broadcasts here are intermittent. An empty
stream list is an expected state with its own message, not an error.

## How the player behaves

- Polls the status every 20s, and only while the tab is visible.
- Rebuilds the dropdown only when the set of mounts actually changes, so it does
  not snap shut under someone mid-selection.
- Reconnects with exponential backoff (1s, 2s, 4s… capped at 30s, 10 attempts)
  when a stream drops, then offers a manual retry button.
- Watches `currentTime` for stalls. Live streams usually go quiet rather than
  firing an `error` event, so the watchdog catches most real dropouts.
- Detaches the source on pause. A paused `<audio>` keeps pulling the stream down,
  wasting the listener's data and holding a slot on the server. Pressing play
  reconnects to the live edge, which is what resuming a live broadcast means.
