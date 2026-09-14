/**
 * Playback for a live Icecast mount.
 *
 * A live stream is not a file: there is nothing to seek, the "duration" is
 * meaningless, and the connection drops regularly — a broadcaster's laptop
 * closes, the wifi dies, the server restarts. This wrapper keeps a single
 * <audio> element pointed at whichever mount is selected and puts the
 * connection back when it breaks, as long as the listener still wants it.
 *
 * Two behaviours are specific to live audio and worth knowing about:
 *
 *  - Pausing detaches the source instead of just pausing. A paused <audio>
 *    keeps pulling the stream down in the background, which wastes the
 *    listener's data and holds a listener slot on the server. Pressing play
 *    afterwards reconnects to the live edge, which is what "resume" means for
 *    a live broadcast anyway.
 *
 *  - A stall watchdog runs alongside the `error` handler, because streams far
 *    more often go quiet than they fire an error: the element stays in a
 *    "playing" state while `currentTime` silently stops advancing.
 */

import {
  RECONNECT_BASE_MS,
  RECONNECT_MAX_MS,
  RECONNECT_MAX_ATTEMPTS,
  STALL_TIMEOUT_MS,
} from './config.js';

/**
 * @typedef {'idle'|'connecting'|'playing'|'paused'|'reconnecting'|'error'} PlayerState
 */

export class StreamPlayer {
  #audio;
  #onChange;
  /** @type {import('./icecast.js').Stream | null} */
  #stream = null;
  /** @type {PlayerState} */
  #state = 'idle';
  #attempt = 0;
  #retryTimer = null;
  #watchdog = null;
  #lastTime = 0;
  #lastProgressAt = 0;
  /** True while the listener wants audio; the only thing that authorises a reconnect. */
  #wantsToPlay = false;
  /** Suppresses events caused by our own src juggling. */
  #internal = false;

  /**
   * @param {HTMLAudioElement} audio
   * @param {{ onChange?: (info: { state: PlayerState, stream: object|null, attempt: number }) => void }} [options]
   */
  constructor(audio, { onChange } = {}) {
    this.#audio = audio;
    this.#onChange = onChange || (() => {});
    this.#bindEvents();
  }

  get state() {
    return this.#state;
  }

  get stream() {
    return this.#stream;
  }

  /** Mount of the current stream, or null. Used to keep the <select> in sync. */
  get mount() {
    return this.#stream ? this.#stream.mount : null;
  }

  /**
   * Switch to a stream and start playing it.
   * @param {import('./icecast.js').Stream} stream
   */
  select(stream) {
    this.#stream = stream;
    this.#wantsToPlay = true;
    this.#attempt = 0;
    this.#connect();
  }

  /** Stop, release the connection, and forget the stream. */
  stop() {
    this.#wantsToPlay = false;
    this.#stream = null;
    this.#clearRetry();
    this.#stopWatchdog();
    this.#detach();
    this.#setState('idle');
  }

  /** Retry now, after the automatic attempts gave up. */
  retry() {
    if (!this.#stream) return;
    this.#wantsToPlay = true;
    this.#attempt = 0;
    this.#connect();
  }

  /**
   * Refresh metadata for the stream being played, without touching playback.
   * @param {import('./icecast.js').Stream} stream
   */
  updateMetadata(stream) {
    if (!this.#stream || stream.mount !== this.#stream.mount) return;
    this.#stream = { ...stream };
    this.#emit();
  }

  // ---------------------------------------------------------------- internals

  #connect() {
    if (!this.#stream) return;
    this.#clearRetry();
    this.#setState(this.#attempt > 0 ? 'reconnecting' : 'connecting');

    // A cache-buster forces a genuinely new connection. Without it a browser
    // may re-use the dead response it already has buffered and "reconnect"
    // into silence.
    const url = new URL(this.#stream.url);
    url.searchParams.set('_', Date.now().toString(36));

    this.#internal = true;
    this.#audio.src = url.toString();
    this.#audio.load();
    this.#internal = false;

    this.#audio.play().then(
      () => this.#startWatchdog(),
      (err) => {
        // Autoplay policy: the browser wants a user gesture. That is not a
        // failure to retry against — it needs the listener to press play.
        if (err && err.name === 'NotAllowedError') {
          this.#wantsToPlay = false;
          this.#setState('paused');
          return;
        }
        this.#scheduleReconnect();
      },
    );
  }

  #scheduleReconnect() {
    if (!this.#wantsToPlay || !this.#stream) return;
    this.#stopWatchdog();

    if (this.#attempt >= RECONNECT_MAX_ATTEMPTS) {
      this.#setState('error');
      return;
    }

    const delay = Math.min(RECONNECT_BASE_MS * 2 ** this.#attempt, RECONNECT_MAX_MS);
    this.#attempt += 1;
    this.#setState('reconnecting');
    this.#retryTimer = setTimeout(() => this.#connect(), delay);
  }

  #clearRetry() {
    if (this.#retryTimer) {
      clearTimeout(this.#retryTimer);
      this.#retryTimer = null;
    }
  }

  /** Release the network connection without losing track of the stream. */
  #detach() {
    this.#internal = true;
    this.#audio.pause();
    // removeAttribute rather than src = '': an empty src makes browsers fire a
    // spurious MEDIA_ERR_SRC_NOT_SUPPORTED error.
    this.#audio.removeAttribute('src');
    this.#audio.load();
    this.#internal = false;
  }

  #startWatchdog() {
    this.#stopWatchdog();
    this.#lastTime = this.#audio.currentTime;
    this.#lastProgressAt = Date.now();

    this.#watchdog = setInterval(() => {
      if (!this.#wantsToPlay || this.#audio.paused) return;

      if (this.#audio.currentTime > this.#lastTime) {
        this.#lastTime = this.#audio.currentTime;
        this.#lastProgressAt = Date.now();
        return;
      }

      if (Date.now() - this.#lastProgressAt > STALL_TIMEOUT_MS) {
        // Playing in name only — the stream went quiet. Treat it as a drop.
        this.#scheduleReconnect();
      }
    }, 1000);
  }

  #stopWatchdog() {
    if (this.#watchdog) {
      clearInterval(this.#watchdog);
      this.#watchdog = null;
    }
  }

  #bindEvents() {
    const audio = this.#audio;

    audio.addEventListener('playing', () => {
      if (this.#internal) return;
      this.#attempt = 0;
      this.#clearRetry();
      this.#setState('playing');
      this.#startWatchdog();
    });

    // Buffering mid-stream. Report it, but let the watchdog decide when the
    // gap has gone on long enough to be a dropout.
    audio.addEventListener('waiting', () => {
      if (this.#internal || !this.#wantsToPlay) return;
      if (this.#state === 'playing') this.#setState('connecting');
    });

    audio.addEventListener('error', () => {
      if (this.#internal || !this.#wantsToPlay) return;
      this.#scheduleReconnect();
    });

    // A live stream should never end; if it does, the broadcaster went away.
    audio.addEventListener('ended', () => {
      if (this.#internal || !this.#wantsToPlay) return;
      this.#scheduleReconnect();
    });

    // The listener pressed pause on the native controls.
    audio.addEventListener('pause', () => {
      if (this.#internal || !this.#wantsToPlay || !this.#stream) return;
      this.#wantsToPlay = false;
      this.#clearRetry();
      this.#stopWatchdog();
      this.#detach();
      this.#setState('paused');
    });

    // The listener pressed play again after we detached the source.
    audio.addEventListener('play', () => {
      if (this.#internal || this.#wantsToPlay || !this.#stream) return;
      this.#wantsToPlay = true;
      this.#attempt = 0;
      this.#connect();
    });
  }

  /** @param {PlayerState} state */
  #setState(state) {
    this.#state = state;
    this.#emit();
  }

  #emit() {
    this.#onChange({
      state: this.#state,
      stream: this.#stream,
      attempt: this.#attempt,
    });
  }
}
