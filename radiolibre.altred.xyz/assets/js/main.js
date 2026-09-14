/**
 * Wires the Icecast client, the player and the UI together, and runs the
 * polling loop that keeps the stream list current.
 */

import { POLL_INTERVAL_MS } from './config.js?v=1';
import { fetchStreams } from './icecast.js?v=1';
import { StreamPlayer } from './player.js?v=1';
import { PlayerUI } from './ui.js?v=1';

const el = {
  select: document.getElementById('stream-select'),
  audio: document.getElementById('audio'),
  status: document.getElementById('player-status'),
  meta: document.getElementById('player-meta'),
  nowPlaying: document.getElementById('meta-now-playing'),
  listeners: document.getElementById('meta-listeners'),
  retry: document.getElementById('player-retry'),
};

const ui = new PlayerUI(el);

const player = new StreamPlayer(el.audio, {
  onChange(info) {
    ui.renderStatus(info);
    ui.renderMeta(info.stream);
    ui.renderStreams(streams, info.stream ? info.stream.mount : null);
  },
});

/** @type {import('./icecast.js').Stream[]} */
let streams = [];
let pollTimer = null;
/** Aborts an in-flight status request when a newer one starts. */
let inFlight = null;

function findStream(mount) {
  return streams.find((s) => s.mount === mount) || null;
}

/**
 * Read the status once and push the result through the UI.
 *
 * Keeps playback untouched: a poll only ever refreshes the dropdown and the
 * metadata. Whether the audio is healthy is the player's business.
 */
async function refresh() {
  if (inFlight) inFlight.abort();
  const controller = new AbortController();
  inFlight = controller;

  try {
    streams = await fetchStreams({ signal: controller.signal });
  } catch (err) {
    if (err.name === 'AbortError') return;
    // Leave a playing stream alone: the server being briefly unreachable does
    // not mean the audio connection died.
    if (!player.stream) {
      ui.renderServerError('No se pudo contactar el servidor de transmisión.');
    }
    return;
  } finally {
    // Only clear it if a newer refresh has not already claimed the slot.
    if (inFlight === controller) inFlight = null;
  }

  el.select.disabled = streams.length === 0;
  ui.renderStreams(streams, player.mount);

  if (player.stream) {
    const current = findStream(player.stream.mount);
    if (current) {
      // Refresh listener count and current track for the stream being played.
      player.updateMetadata(current);
    }
  } else if (player.state === 'idle') {
    ui.renderStatus({ state: 'idle', attempt: 0 });
  }
}

/**
 * Poll while the tab is visible. A community radio server does not need
 * traffic from backgrounded tabs, and a listener returning to the tab wants
 * fresh numbers immediately rather than up to a full interval later.
 */
function startPolling() {
  const tick = () => {
    if (document.visibilityState === 'visible') refresh();
  };
  pollTimer = setInterval(tick, POLL_INTERVAL_MS);

  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible') refresh();
  });
}

el.select.addEventListener('change', () => {
  const stream = findStream(el.select.value);
  if (stream) {
    player.select(stream);
  } else {
    player.stop();
  }
});

el.retry.addEventListener('click', () => player.retry());

ui.renderStatus({ state: 'idle', attempt: 0 });
refresh();
startPolling();
