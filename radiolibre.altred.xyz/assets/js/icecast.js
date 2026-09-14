/**
 * Reads the Icecast status document and turns it into a stable list of
 * streams the UI can render.
 *
 * Two quirks of the server drive most of the code in this file:
 *
 *  1. Icecast 2.4.3 emits invalid JSON. It leaves a trailing comma before the
 *     closing brace of `icestats` (`…"+0200",}`) and before the closing
 *     bracket of the `source` array, and when the server is idle it truncates
 *     the document before the final closing brace — the live server really
 *     does send 216 bytes containing two `{` and one `}`. `JSON.parse`
 *     rejects all of that, so a naive `response.json()` sees an exception and
 *     reports a dead server even while Icecast is healthy.
 *
 *  2. `listenurl` is whatever hostname Icecast was configured with, which is
 *     often an internal name or plain http. Following it produces a dead link
 *     or mixed content on an https page. Only the mount path is trustworthy,
 *     so URLs are always rebuilt against ICECAST_ORIGIN.
 */

import { ICECAST_ORIGIN, STATUS_PATH, STATUS_TIMEOUT_MS } from './config.js';

/**
 * Repair the ways Icecast produces text that `JSON.parse` refuses: trailing
 * commas before `}` / `]`, raw control characters inside string literals
 * (track metadata copied straight out of ID3 tags), and a document truncated
 * before its closing braces.
 *
 * The scanner tracks whether it is inside a string literal so that a comma or
 * a brace in a track title is copied through untouched.
 *
 * @param {string} text
 * @returns {string}
 */
export function repairIcecastJson(text) {
  let out = '';
  let inString = false;
  let escaped = false;
  /** Open `{` / `[` still awaiting a closer, so a truncated tail can be sealed. */
  const open = [];

  for (let i = 0; i < text.length; i++) {
    const ch = text[i];

    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (ch === '\\') {
        escaped = true;
      } else if (ch === '"') {
        inString = false;
      } else if (ch < ' ') {
        // A raw newline or 0x01 inside a string is illegal JSON. Keep the
        // document parseable rather than losing every stream to one bad tag.
        out += ' ';
        continue;
      }
      out += ch;
      continue;
    }

    if (ch === '"') {
      inString = true;
      out += ch;
      continue;
    }

    if (ch === '{' || ch === '[') {
      open.push(ch === '{' ? '}' : ']');
      out += ch;
      continue;
    }

    if (ch === '}' || ch === ']') {
      if (open[open.length - 1] === ch) open.pop();
      out += ch;
      continue;
    }

    if (ch === ',') {
      // Drop a comma that closes nothing: one before `}` / `]`, and one left
      // dangling at a truncated end of document.
      let j = i + 1;
      while (j < text.length && /\s/.test(text[j])) j++;
      if (j >= text.length || text[j] === '}' || text[j] === ']') continue;
    }

    out += ch;
  }

  // Seal a document the server cut short.
  if (inString) out += '"';
  while (open.length) out += open.pop();

  return out;
}

/**
 * Parse a status document, repairing it only if the server sent something
 * `JSON.parse` rejects.
 *
 * @param {string} text
 * @returns {object}
 */
export function parseStatus(text) {
  try {
    return JSON.parse(text);
  } catch {
    return JSON.parse(repairIcecastJson(text));
  }
}

/** Icecast omits `source` entirely when idle, and unwraps it when there is exactly one. */
function toSourceArray(source) {
  if (!source) return [];
  return Array.isArray(source) ? source : [source];
}

function clean(value) {
  return typeof value === 'string' ? value.trim() : '';
}

/** Only the path of `listenurl` is trustworthy; see the note at the top. */
function mountOf(source) {
  const mount = clean(source.mount);
  if (mount) return mount;

  const listenurl = clean(source.listenurl);
  if (!listenurl) return '';
  try {
    return new URL(listenurl).pathname;
  } catch {
    return listenurl.startsWith('/') ? listenurl : '';
  }
}

/** Icecast's placeholder when a broadcaster did not set a name. */
function nameOf(source, mount) {
  const name = clean(source.server_name);
  if (name && name.toLowerCase() !== 'unspecified name') return name;

  const fromMount = mount.replace(/^\//, '').replace(/\.(mp3|ogg|oga|opus|aac|webm)$/i, '');
  return fromMount || 'RadioLibre';
}

/**
 * `title` carries the current track, updated live by the broadcaster. The old
 * player used it as a fallback for the station name, which made the dropdown
 * label change every time a song changed.
 */
function nowPlayingOf(source) {
  const artist = clean(source.artist);
  const title = clean(source.title) || clean(source.yp_currently_playing);
  if (artist && title) return `${artist} — ${title}`;
  return title || artist;
}

function toInt(value) {
  const n = Number.parseInt(value, 10);
  return Number.isFinite(n) ? n : 0;
}

/**
 * @typedef {object} Stream
 * @property {string} mount      Mount path, e.g. "/rap.mp3". Stable identity.
 * @property {string} name       Human-readable station name.
 * @property {string} description
 * @property {string} url        Absolute https URL to play.
 * @property {number} listeners
 * @property {number} bitrate
 * @property {string} format     Content type reported by Icecast.
 * @property {string} nowPlaying Current track, may be empty.
 */

/** @returns {Stream | null} */
function normalizeSource(source) {
  const mount = mountOf(source);
  if (!mount) return null;

  return {
    mount,
    name: nameOf(source, mount),
    description: clean(source.server_description),
    url: new URL(mount, ICECAST_ORIGIN).toString(),
    listeners: toInt(source.listeners),
    bitrate: toInt(source.bitrate),
    format: clean(source.server_type),
    nowPlaying: nowPlayingOf(source),
  };
}

/** Abort signal that trips on either the caller's signal or a timeout. */
function withTimeout(externalSignal, ms) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(new DOMException('Timeout', 'TimeoutError')), ms);

  const onAbort = () => controller.abort(externalSignal.reason);
  if (externalSignal) {
    if (externalSignal.aborted) controller.abort(externalSignal.reason);
    else externalSignal.addEventListener('abort', onAbort, { once: true });
  }

  return {
    signal: controller.signal,
    cleanup() {
      clearTimeout(timer);
      if (externalSignal) externalSignal.removeEventListener('abort', onAbort);
    },
  };
}

/**
 * Fetch the live stream list.
 *
 * Resolves with an empty array when the server is up but nobody is
 * broadcasting — a normal state here, not an error. Rejects only when the
 * server could not be reached or understood.
 *
 * @param {{ signal?: AbortSignal }} [options]
 * @returns {Promise<Stream[]>}
 */
export async function fetchStreams({ signal } = {}) {
  const url = new URL(STATUS_PATH, ICECAST_ORIGIN);
  // Icecast and any proxy in front of it will happily serve a cached status;
  // a unique query string keeps each poll honest.
  url.searchParams.set('_', Date.now().toString(36));

  const timeout = withTimeout(signal, STATUS_TIMEOUT_MS);
  let response;
  try {
    response = await fetch(url, { signal: timeout.signal, cache: 'no-store' });
  } finally {
    timeout.cleanup();
  }

  if (!response.ok) {
    throw new Error(`Icecast respondió ${response.status}`);
  }

  // Read as text, not .json(): the document usually needs repair first.
  const status = parseStatus(await response.text());

  const streams = toSourceArray(status?.icestats?.source)
    .map(normalizeSource)
    .filter(Boolean);

  // Sort by name so the dropdown keeps a stable order across polls; sorting
  // by listener count would make entries jump around while someone is
  // choosing one.
  streams.sort((a, b) => a.name.localeCompare(b.name, 'es'));
  return streams;
}
