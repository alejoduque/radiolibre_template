/**
 * Configuration for the RadioLibre player.
 *
 * Everything the player talks to lives on one origin, declared here so that
 * moving to a different Icecast server is a one-line change.
 */

/**
 * Icecast origin. The status endpoint and every audio mount are read from
 * here.
 *
 * Do NOT point this at https://altred.xyz — that host answers on 443 with a
 * certificate issued only for adj.altred.xyz, so browsers abort the request
 * before it is sent. live.altred.xyz has a certificate that covers it and
 * sends `Access-Control-Allow-Origin: *`, which is what makes the status
 * fetch work from this page at all.
 */
export const ICECAST_ORIGIN = 'https://live.altred.xyz';

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
