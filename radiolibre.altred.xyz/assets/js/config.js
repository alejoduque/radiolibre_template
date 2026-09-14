/**
 * Configuration for the RadioLibre player.
 */

/**
 * Bump this on every deploy that changes a .js or .css file, in index.html and
 * in every `?v=` import specifier, all together.
 *
 * nginx serves this site's static assets with `Cache-Control: public,
 * immutable; max-age=31536000`. `immutable` means a browser will not even
 * revalidate on a normal reload, so without a changing URL a returning
 * listener keeps running the old player for up to a year. The query string is
 * what makes an update actually reach people.
 *
 * (This constant is documentation — a static `import` cannot interpolate it.
 * It is here so there is one obvious place recording what the number means.)
 */
export const ASSET_VERSION = 1;

/** Hostnames where there is no Icecast behind the page. */
const DEV_HOSTS = new Set(['localhost', '127.0.0.1', '0.0.0.0', '']);

/** Public site, used as the fallback when developing locally. */
const PUBLIC_ORIGIN = 'https://radiolibre.altred.xyz';

/**
 * Where the status document and the audio mounts are read from.
 *
 * In production this is the page's own origin. nginx on radiolibre.altred.xyz
 * already reverse-proxies Icecast: `/status-json.xsl` and every
 * `*.mp3|ogg|aac|opus|m3u|pls` path go to 127.0.0.1:8000 with
 * `proxy_buffering off` and permissive CORS. Staying same-origin means the
 * player uses the page's own valid certificate and makes no cross-origin
 * request at all.
 *
 * Do NOT point this at https://altred.xyz. That host answers on 443 with a
 * certificate issued only for adj.altred.xyz, so browsers abort before the
 * request is sent — which is exactly why the previous player never loaded a
 * stream list, and why the logo was broken too.
 */
function resolveOrigin() {
  const loc = globalThis.location;
  if (!loc || loc.protocol === 'file:' || DEV_HOSTS.has(loc.hostname)) {
    // Local development, or node running the tests. The public host sends
    // Access-Control-Allow-Origin: *, so this works from a local server.
    return PUBLIC_ORIGIN;
  }
  return loc.origin;
}

export const ICECAST_ORIGIN = resolveOrigin();

/** Icecast's machine-readable status document. */
export const STATUS_PATH = '/status-json.xsl';

/** How often to re-read the status while the tab is visible. */
export const POLL_INTERVAL_MS = 20000;

/** Give up on a status request that hangs longer than this. */
export const STATUS_TIMEOUT_MS = 10000;

/** Reconnect backoff: 1s, 2s, 4s … capped, then give up and offer a button. */
export const RECONNECT_BASE_MS = 1000;
export const RECONNECT_MAX_MS = 30000;
export const RECONNECT_MAX_ATTEMPTS = 10;

/**
 * If playback is live but `currentTime` has not advanced for this long, treat
 * the stream as hung. Live streams tend to stall silently rather than fire an
 * `error` event, so this watchdog is what actually catches most dropouts.
 */
export const STALL_TIMEOUT_MS = 15000;
