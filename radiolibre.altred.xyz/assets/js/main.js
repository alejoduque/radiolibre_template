/**
 * Wires the Icecast client to the station list, and runs the polling loop
 * that keeps it current. Each card owns its own player; see ui.js.
 */

import { POLL_INTERVAL_MS } from './config.js?v=5';
import { fetchStreams } from './icecast.js?v=5';
import { StationList } from './ui.js?v=5';

const stations = new StationList({
  list: document.getElementById('stations'),
  message: document.getElementById('stations-message'),
});

/** Aborts an in-flight status request when a newer one starts. */
let inFlight = null;

/**
 * Read the status once and push the result through the UI.
 *
 * Keeps playback untouched: a poll only ever adds, refreshes or retires cards.
 * Whether the audio is healthy is each player's business.
 */
async function refresh() {
  if (inFlight) inFlight.abort();
  const controller = new AbortController();
  inFlight = controller;

  let streams;
  try {
    streams = await fetchStreams({ signal: controller.signal });
  } catch (err) {
    if (err.name === 'AbortError') return;
    // A playing stream is left alone: the server being briefly unreachable
    // does not mean the audio connection died.
    stations.renderServerError('No se pudo contactar el servidor de transmisión.');
    return;
  } finally {
    // Only clear it if a newer refresh has not already claimed the slot.
    if (inFlight === controller) inFlight = null;
  }

  stations.render(streams);
}

/**
 * Poll while the tab is visible. A community radio server does not need
 * traffic from backgrounded tabs, and a listener returning to the tab wants
 * fresh numbers immediately rather than up to a full interval later.
 */
function startPolling() {
  setInterval(() => {
    if (document.visibilityState === 'visible') refresh();
  }, POLL_INTERVAL_MS);

  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible') refresh();
  });
}

refresh();
startPolling();
