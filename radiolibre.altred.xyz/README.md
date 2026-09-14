# radiolibre.altred.xyz

The RadioLibre site and live player. Static files — no build step, no bundler,
no dependencies. Deploy by copying this directory to the webroot.

```
index.html
assets/
  styles.css        all page styling
  logo.jpeg
  js/
    config.js       endpoints and timings — start here
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

The status endpoint sends `Access-Control-Allow-Origin: *`, so the player works
from localhost against the real server.

## Configuration

Everything environment-specific is in `assets/js/config.js`. Moving to another
Icecast server is a one-line change to `ICECAST_ORIGIN`.

## Things that will bite you

These are not hypothetical — each one was breaking the live site before this
rewrite.

**Use `live.altred.xyz`, never `altred.xyz`.** The bare apex answers on port 443
with a certificate issued only for `adj.altred.xyz`. Browsers reject it before
the request goes out, so any `fetch` or `<img>` pointing there fails silently.
The old page fetched its stream list *and* loaded its logo from that host, which
is why neither worked.

**Icecast 2.4.3 emits invalid JSON.** It leaves a trailing comma before the
closing brace (`…"+0200",}`), and when idle it truncates the document entirely —
the live server really does return 216 bytes containing two `{` and one `}`.
`JSON.parse` rejects all of it, so `response.json()` throws and the player
concludes there are no streams. `repairIcecastJson()` in `icecast.js` fixes the
document before parsing; `test/icecast.test.mjs` pins that behaviour.

**Do not trust `listenurl`.** Icecast reports whatever hostname it was
configured with, often an internal address or plain `http`. Following it gives a
dead link, or mixed content that an https page will block. Only the mount path
is meaningful; URLs are always rebuilt against `ICECAST_ORIGIN`.

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
