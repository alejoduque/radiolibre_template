/**
 * Rendering. Every DOM write for the player lives here, so the modules that
 * talk to Icecast and drive the <audio> element never touch markup.
 */

/** Status text for each player state, in the page's language. */
const STATUS_TEXT = {
  idle: 'Selecciona una transmisión para escuchar.',
  connecting: 'Conectando...',
  playing: 'En vivo',
  paused: 'En pausa',
  error: 'No se pudo conectar con la transmisión.',
};

function plural(n, one, many) {
  return n === 1 ? one : many;
}

export class PlayerUI {
  /**
   * @param {{ select: HTMLSelectElement, status: HTMLElement, meta: HTMLElement,
   *           nowPlaying: HTMLElement, listeners: HTMLElement,
   *           retry: HTMLButtonElement, audio: HTMLAudioElement }} elements
   */
  constructor(elements) {
    this.el = elements;
    /**
     * Mounts currently in the <select>, to avoid rebuilding it on every poll.
     * Starts as null rather than '' because '' is the legitimate signature of
     * an empty stream list, which would otherwise look already-rendered and
     * leave the markup's initial placeholder on screen.
     */
    this.renderedMounts = null;
  }

  /**
   * Fill the stream dropdown, preserving the listener's current choice.
   *
   * Called on every poll, so it rebuilds only when the set of mounts actually
   * changed - otherwise an open dropdown would snap shut every 20 seconds.
   *
   * @param {import('./icecast.js').Stream[]} streams
   * @param {string | null} selectedMount
   */
  renderStreams(streams, selectedMount) {
    const signature = streams.map((s) => `${s.mount}|${s.name}`).join(' ');
    if (signature === this.renderedMounts) {
      this.#syncSelection(selectedMount);
      return;
    }
    this.renderedMounts = signature;

    const select = this.el.select;
    select.replaceChildren();

    const placeholder = document.createElement('option');
    placeholder.value = '';
    placeholder.textContent = streams.length
      ? 'Selecciona una transmisión'
      : 'No hay transmisiones ahora';
    select.append(placeholder);

    for (const stream of streams) {
      const option = document.createElement('option');
      option.value = stream.mount;
      option.textContent = stream.name;
      select.append(option);
    }

    select.disabled = streams.length === 0;
    this.#syncSelection(selectedMount);
  }

  #syncSelection(selectedMount) {
    const value = selectedMount || '';
    if (this.el.select.value !== value) this.el.select.value = value;
  }

  /**
   * @param {{ state: string, attempt: number }} info
   */
  renderStatus({ state, attempt }) {
    const { status, retry } = this.el;

    if (state === 'reconnecting') {
      status.textContent = attempt > 1
        ? `Se perdió la señal. Reconectando (intento ${attempt})...`
        : 'Se perdió la señal. Reconectando...';
    } else {
      status.textContent = STATUS_TEXT[state] || '';
    }

    status.dataset.state = state;
    retry.hidden = state !== 'error';
  }

  /**
   * Now playing and listener count for the selected stream.
   * @param {import('./icecast.js').Stream | null} stream
   */
  renderMeta(stream) {
    const { meta, nowPlaying, listeners } = this.el;

    if (!stream) {
      meta.hidden = true;
      return;
    }

    meta.hidden = false;

    nowPlaying.textContent = stream.nowPlaying;
    nowPlaying.closest('.player__meta-item').hidden = !stream.nowPlaying;

    listeners.textContent = `${stream.listeners} ${plural(stream.listeners, 'persona', 'personas')}`;
  }

  /** Message shown when the Icecast server itself could not be reached. */
  renderServerError(message) {
    this.el.status.textContent = message;
    this.el.status.dataset.state = 'error';
    this.el.select.disabled = true;
    this.el.meta.hidden = true;
  }
}
