/**
 * Rendering. One card per live mount, each with its own player: play/pause,
 * volume, now playing, listener count. Every DOM write lives here, so the
 * modules that talk to Icecast and drive audio never touch markup.
 */

import { StreamPlayer } from './player.js?v=5';

/** Status line under each card, in the page's language. */
const STATUS_TEXT = {
  connecting: 'Conectando...',
  playing: 'En vivo',
  paused: 'En pausa',
  error: 'No se pudo conectar con la transmisión.',
};

/** Page-level message above the cards. */
const LIST_TEXT = {
  loading: 'Buscando transmisiones...',
  empty: 'No hay transmisiones en vivo ahora.',
};

const DEFAULT_VOLUME = 0.8;
const VOLUME_KEY = 'radiolibre:volume:';

/** Icons are inline so they take currentColor and need no extra request. */
const ICON = {
  play: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M8 5.5v13a1 1 0 0 0 1.5.86l11-6.5a1 1 0 0 0 0-1.72l-11-6.5A1 1 0 0 0 8 5.5z"/></svg>',
  pause: '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="6" y="5" width="4.5" height="14" rx="1"/><rect x="13.5" y="5" width="4.5" height="14" rx="1"/></svg>',
  speaker: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 9.5h3.5L12 5.5v13l-4.5-4H4z"/><path class="wave" d="M15.5 9a4.5 4.5 0 0 1 0 6M18 6.5a8 8 0 0 1 0 11" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/><path class="cross" d="M16 9.5l5 5m0-5l-5 5" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/></svg>',
};

function plural(n, one, many) {
  return n === 1 ? one : many;
}

/**
 * iOS ignores `audio.volume` (the hardware buttons own it) and reads it back
 * as 1. A slider there would move and change nothing, so it is not shown;
 * mute still works everywhere.
 */
const VOLUME_WORKS = (() => {
  const probe = document.createElement('audio');
  probe.volume = 0.5;
  return probe.volume === 0.5;
})();

/** localStorage can be absent or throw (private mode, blocked storage). */
function loadVolume(mount) {
  try {
    const v = parseFloat(localStorage.getItem(VOLUME_KEY + mount));
    return Number.isFinite(v) && v >= 0 && v <= 1 ? v : DEFAULT_VOLUME;
  } catch {
    return DEFAULT_VOLUME;
  }
}

function saveVolume(mount, v) {
  try {
    localStorage.setItem(VOLUME_KEY + mount, String(v));
  } catch {
    // Remembering the level is a convenience; losing it is fine.
  }
}

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

/** "128 kbps · MP3" from what Icecast reports; either half may be missing. */
function formatLabel({ bitrate, format }) {
  const kind = format.split('/').pop().replace(/^mpeg$/, 'mp3').toUpperCase();
  return [bitrate ? `${bitrate} kbps` : '', kind].filter(Boolean).join(' · ');
}

/** One mount: its card, its <audio>, its reconnecting player. */
class StationCard {
  /**
   * @param {import('./icecast.js').Stream} stream
   * @param {{ onActive: (card: StationCard) => void }} hooks
   */
  constructor(stream, { onActive }) {
    this.stream = stream;

    // Never inserted into the page: a detached <audio> plays just the same,
    // and the cards can be reordered without the browser pausing anything.
    this.audio = document.createElement('audio');
    this.audio.preload = 'none';

    this.player = new StreamPlayer(this.audio, {
      onChange: (info) => {
        this.#renderState(info);
        if (info.state === 'connecting' || info.state === 'playing') onActive(this);
      },
    });

    this.#build();
    this.#setVolume(loadVolume(stream.mount), { save: false });
    this.update(stream);
    this.#renderState({ state: 'idle', attempt: 0 });
  }

  /** True while the listener wants this one playing (incl. reconnecting). */
  get active() {
    return ['connecting', 'playing', 'reconnecting'].includes(this.player.state);
  }

  /** A card may be dropped when its mount leaves the status and it is not in use. */
  get disposable() {
    return this.player.state === 'idle' || this.player.state === 'paused' || this.player.state === 'error';
  }

  /** @param {import('./icecast.js').Stream} stream */
  update(stream) {
    this.stream = stream;
    this.player.updateMetadata(stream);

    this.name.textContent = stream.name;
    this.name.title = stream.description || stream.name;
    this.toggle.setAttribute('aria-label', `${this.active ? 'Pausar' : 'Escuchar'} ${stream.name}`);

    this.now.textContent = stream.nowPlaying;
    this.now.title = stream.nowPlaying;
    this.now.hidden = !stream.nowPlaying;

    this.listeners.textContent = String(stream.listeners);
    this.listeners.title = `${stream.listeners} ${plural(stream.listeners, 'persona escuchando', 'personas escuchando')}`;
    this.format.textContent = formatLabel(stream);
  }

  pause() {
    this.player.pause();
  }

  dispose() {
    this.player.stop();
    this.root.remove();
  }

  #build() {
    const root = el('li', 'station');

    this.toggle = el('button', 'station__toggle');
    this.toggle.type = 'button';
    this.toggle.innerHTML = `<span class="station__icon station__icon--play">${ICON.play}</span>`
      + `<span class="station__icon station__icon--pause">${ICON.pause}</span>`
      + '<span class="station__ring" aria-hidden="true"></span>';
    this.toggle.addEventListener('click', () => {
      if (this.active) this.player.pause();
      else this.player.select(this.stream);
    });

    const info = el('div', 'station__info');
    const head = el('div', 'station__head');
    const bars = el('span', 'station__bars');
    bars.setAttribute('aria-hidden', 'true');
    bars.innerHTML = '<i></i><i></i><i></i><i></i>';
    this.name = el('h2', 'station__name');
    head.append(bars, this.name);

    this.now = el('p', 'station__now');
    this.status = el('p', 'station__status');
    this.status.setAttribute('role', 'status');
    this.status.setAttribute('aria-live', 'polite');

    this.retry = el('button', 'station__retry', 'Reintentar');
    this.retry.type = 'button';
    this.retry.hidden = true;
    this.retry.addEventListener('click', () => this.player.retry());
    info.append(head, this.now, this.status, this.retry);

    const side = el('div', 'station__side');
    const facts = el('p', 'station__facts');
    this.listeners = el('span', 'station__listeners');
    this.format = el('span', 'station__format');
    facts.append(this.listeners, this.format);

    const volume = el('div', 'station__volume');
    this.mute = el('button', 'station__mute');
    this.mute.type = 'button';
    this.mute.innerHTML = ICON.speaker;
    this.mute.addEventListener('click', () => {
      // Unmuting at zero would be silent, so lift it to something audible.
      if (this.audio.muted || this.audio.volume === 0) {
        this.audio.muted = false;
        if (this.audio.volume === 0) this.#setVolume(DEFAULT_VOLUME);
      } else {
        this.audio.muted = true;
      }
      this.#renderVolume();
    });

    this.slider = el('input', 'station__slider');
    this.slider.type = 'range';
    this.slider.min = '0';
    this.slider.max = '100';
    this.slider.step = '1';
    this.slider.hidden = !VOLUME_WORKS;
    this.slider.addEventListener('input', () => {
      this.audio.muted = false;
      this.#setVolume(Number(this.slider.value) / 100);
    });
    volume.append(this.mute, this.slider);
    side.append(facts, volume);

    root.append(this.toggle, info, side);
    this.root = root;
  }

  #setVolume(v, { save = true } = {}) {
    this.audio.volume = v;
    if (save) saveVolume(this.stream.mount, v);
    this.#renderVolume();
  }

  #renderVolume() {
    const level = this.audio.muted ? 0 : this.audio.volume;
    const pct = Math.round(level * 100);
    this.slider.value = String(pct);
    this.slider.style.setProperty('--level', `${pct}%`);
    this.slider.setAttribute('aria-label', `Volumen de ${this.stream.name}`);
    this.slider.setAttribute('aria-valuetext', `${pct}%`);
    this.mute.dataset.muted = String(level === 0);
    this.mute.setAttribute('aria-label', level === 0 ? 'Activar sonido' : 'Silenciar');
  }

  #renderState({ state, attempt }) {
    this.root.dataset.state = state;
    this.toggle.setAttribute('aria-label', `${this.active ? 'Pausar' : 'Escuchar'} ${this.stream.name}`);
    this.toggle.setAttribute('aria-pressed', String(this.active));

    if (state === 'reconnecting') {
      this.status.textContent = attempt > 1
        ? `Se perdió la señal. Reconectando (intento ${attempt})...`
        : 'Se perdió la señal. Reconectando...';
    } else {
      this.status.textContent = STATUS_TEXT[state] || '';
    }
    this.status.hidden = !this.status.textContent;
    this.retry.hidden = state !== 'error';
  }
}

export class StationList {
  /**
   * @param {{ list: HTMLElement, message: HTMLElement }} elements
   */
  constructor({ list, message }) {
    this.list = list;
    this.message = message;
    /** @type {Map<string, StationCard>} keyed by mount */
    this.cards = new Map();
    this.#renderMessage(LIST_TEXT.loading);
  }

  /**
   * Bring the cards in line with the latest status. Called on every poll, so
   * it only adds, updates and removes — a card that is playing is never
   * rebuilt, and one whose mount briefly vanished keeps playing (its player
   * reconnects on its own) until the listener stops it.
   *
   * @param {import('./icecast.js').Stream[]} streams already sorted
   */
  render(streams) {
    const live = new Set(streams.map((s) => s.mount));

    for (const [mount, card] of this.cards) {
      if (!live.has(mount) && card.disposable) {
        card.dispose();
        this.cards.delete(mount);
      }
    }

    for (const stream of streams) {
      const card = this.cards.get(stream.mount);
      if (card) {
        card.update(stream);
      } else {
        this.cards.set(stream.mount, new StationCard(stream, {
          onActive: (active) => this.#soloist(active),
        }));
      }
    }

    // Keep DOM order equal to the sorted stream order, moving only what is out
    // of place. Cards kept alive past their mount go last.
    const ordered = [
      ...streams.map((s) => this.cards.get(s.mount)),
      ...[...this.cards.values()].filter((c) => !live.has(c.stream.mount)),
    ];
    ordered.forEach((card, i) => {
      if (this.list.children[i] !== card.root) {
        this.list.insertBefore(card.root, this.list.children[i] || null);
      }
    });

    this.#renderMessage(this.cards.size ? '' : LIST_TEXT.empty);
  }

  /** The server itself could not be reached. Cards in use are left alone. */
  renderServerError(message) {
    if ([...this.cards.values()].some((c) => c.active)) return;
    this.#renderMessage(message, 'error');
  }

  /** One stream at a time: starting a card pauses whichever was playing. */
  #soloist(active) {
    for (const card of this.cards.values()) {
      if (card !== active && card.active) card.pause();
    }
  }

  #renderMessage(text, state = '') {
    this.message.textContent = text;
    this.message.hidden = !text;
    this.message.dataset.state = state;
  }
}
