'use strict';
/**
 * The pure parts of the broadcast bridge, kept apart from server.js so that
 * node --test can reach them without sockets or ffmpeg.
 */

/** Longest value accepted for any metadata field, in characters. */
const FIELD_MAX = 80;

const FIELDS = ['lugar', 'quien', 'evento', 'red'];

/**
 * Metadata arrives from an anonymous browser and ends up in the Icecast
 * stream title that every listener sees, so: strings only, no control
 * characters (they would let someone forge extra header lines), collapsed
 * whitespace, bounded length.
 */
function sanitizeMeta(raw) {
  const out = {};
  const src = raw && typeof raw === 'object' ? raw : {};
  for (const key of FIELDS) {
    const value = typeof src[key] === 'string' ? src[key] : '';
    out[key] = value
      .replace(/[\u0000-\u001f\u007f-\u009f]/g, ' ')
      .replace(/\s+/g, ' ')
      .trim()
      .slice(0, FIELD_MAX);
  }
  return out;
}

/** "evento" names the stream; the rest becomes its description. */
function iceNames(meta) {
  const name = meta.evento || 'Reporte en vivo';
  const description = [meta.lugar, meta.quien, meta.red].filter(Boolean).join(' · ') || 'iScream';
  return { name, description };
}

/**
 * ffmpeg arguments for one broadcast to `mount`. The browser sends webm/opus
 * or, from Safari, mp4/aac; ffmpeg sniffs either on stdin and re-encodes to
 * the mp3 that every player on radiolibre.altred.xyz can open.
 *
 * With no Icecast password configured this is a dry run: the audio is decoded
 * and discarded, which is what local development uses.
 */
function ffmpegArgs(cfg, meta, mount) {
  const { name, description } = iceNames(meta);
  const input = ['-hide_banner', '-nostats', '-loglevel', 'error', '-i', 'pipe:0', '-vn'];
  if (!cfg.password) {
    return [...input, '-f', 'null', '-'];
  }
  return [
    ...input,
    '-c:a', 'libmp3lame', '-b:a', cfg.bitrate, '-ar', '44100',
    '-content_type', 'audio/mpeg',
    '-ice_name', name,
    '-ice_description', description,
    '-ice_public', '0',
    '-password', cfg.password,
    '-f', 'mp3',
    `icecast://source@${cfg.host}:${cfg.port}${mount}`,
  ];
}

/**
 * The mounts broadcasters are spread over: the first keeps the historical
 * /reporta.mp3, the rest are numbered from 2 (/reporta2.mp3 …).
 */
function mountList(first, slots) {
  const m = /^(.*?)(\.[a-z0-9]+)?$/i.exec(first);
  const out = [first];
  for (let i = 2; i <= slots; i++) out.push(`${m[1]}${i}${m[2] || ''}`);
  return out;
}

/**
 * Mounts that already have a source on Icecast, read from the raw text of
 * status-json.xsl. Icecast 2.4 sometimes emits invalid JSON there, so this
 * looks for each mount's listenurl instead of parsing.
 */
function mountsInUse(statusText, mounts) {
  return new Set(mounts.filter((mount) => statusText.includes(`${mount}"`)));
}

/**
 * Map ffmpeg's stderr to a status the page can explain. Codes follow the old
 * icecream client (and Cloudflare's 52x for "could not reach the origin").
 */
function classifyFfmpegError(text) {
  if (/401 Unauthorized/i.test(text)) return { code: 401, text: 'El servidor rechazó la clave de transmisión.' };
  if (/403 Forbidden|Mountpoint in use|already in use/i.test(text)) return { code: 409, text: 'Ese punto de transmisión ya está ocupado. Intenta de nuevo.' };
  if (/Failed to resolve hostname/i.test(text)) return { code: 523, text: 'No se encontró el servidor Icecast.' };
  if (/Connection (timed out|refused)/i.test(text)) return { code: 522, text: 'El servidor Icecast no responde.' };
  return null;
}

/**
 * A pool of mounts. Each broadcaster holds one; when all are taken the next
 * person is told so instead of fighting over a mount.
 */
function createPool(mounts) {
  const owners = new Map(); // mount -> owner
  return {
    acquire(who, skip = new Set()) {
      const mount = mounts.find((m) => !owners.has(m) && !skip.has(m));
      if (!mount) return null;
      owners.set(mount, who);
      return mount;
    },
    release(who) {
      for (const [mount, owner] of owners) if (owner === who) owners.delete(mount);
    },
    get used() {
      return owners.size;
    },
    get total() {
      return mounts.length;
    },
  };
}

module.exports = { FIELD_MAX, sanitizeMeta, iceNames, ffmpegArgs, mountList, mountsInUse, classifyFfmpegError, createPool };
