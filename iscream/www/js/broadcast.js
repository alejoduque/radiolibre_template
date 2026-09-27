/*
 * iScream — the broadcast button.
 *
 * mic → MediaRecorder (webm/opus, or mp4/aac on Safari) → WebSocket
 * /ws/stream → server.js → ffmpeg → Icecast, on the first free mount
 * (/reporta.mp3, /reporta2.mp3 … up to 8 people at once).
 *
 * Protocol: after the socket opens we send {type:'hola', meta}; the server
 * answers {type:'listo'} (or {type:'error'}), and from then on every
 * MediaRecorder chunk goes up as a binary frame, in order.
 */
(function () {
  'use strict';

  // Chrome/Firefox record webm/opus; Safari (iOS 14.5+) only mp4/aac.
  var MIME_TYPES = ['audio/webm;codecs=opus', 'audio/webm', 'audio/mp4;codecs=mp4a.40.2', 'audio/mp4', 'audio/ogg;codecs=opus'];
  var AUDIO_BPS = 96000;
  var CHUNK_MS = 500;
  // If the uplink can't keep up, stop queueing rather than build minutes of lag.
  var MAX_BUFFERED = 2 * 1024 * 1024;

  var $ = function (id) { return document.getElementById(id); };
  var box = $('onair');
  var button = $('onair-button');
  var label = $('onair-label');
  var statusEl = $('onair-status');
  var timerEl = $('onair-timer');
  var meterBar = $('meter-bar');
  var form = $('meta-form');

  var session = null; // everything belonging to the current broadcast

  function setState(state, text) {
    box.dataset.state = state;
    statusEl.textContent = text;
    button.disabled = state === 'connecting';
    label.textContent = state === 'live' ? 'Terminar' : state === 'connecting' ? 'Conectando…' : 'Salir al aire';
    button.setAttribute('aria-pressed', state === 'live' ? 'true' : 'false');
  }

  function pickMime() {
    if (typeof MediaRecorder !== 'function') return null;
    for (var i = 0; i < MIME_TYPES.length; i++) {
      if (MediaRecorder.isTypeSupported(MIME_TYPES[i])) return MIME_TYPES[i];
    }
    return '';
  }

  function readMeta() {
    var data = {};
    ['evento', 'lugar', 'quien', 'red'].forEach(function (k) { data[k] = form.elements[k].value.trim(); });
    return data;
  }

  function fmt(ms) {
    var s = Math.floor(ms / 1000);
    var h = Math.floor(s / 3600);
    var mm = String(Math.floor(s / 60) % 60).padStart(2, '0');
    var ss = String(s % 60).padStart(2, '0');
    return (h ? h + ':' : '') + mm + ':' + ss;
  }

  // ------------------------------------------------------------ extras

  function startMeter(s) {
    var Ctx = window.AudioContext || window.webkitAudioContext;
    if (!Ctx) return;
    s.audio = new Ctx();
    var analyser = s.audio.createAnalyser();
    analyser.fftSize = 512;
    s.audio.createMediaStreamSource(s.stream).connect(analyser);
    var buf = new Float32Array(analyser.fftSize);
    (function tick() {
      if (session !== s) return;
      analyser.getFloatTimeDomainData(buf);
      var sum = 0;
      for (var i = 0; i < buf.length; i++) sum += buf[i] * buf[i];
      var rms = Math.sqrt(sum / buf.length);
      // ~-50 dBFS .. 0 dBFS onto 0..100%
      var pct = Math.max(0, Math.min(100, (20 * Math.log10(rms || 1e-6) + 50) * 2));
      meterBar.style.width = pct + '%';
      s.raf = requestAnimationFrame(tick);
    })();
  }

  function keepAwake(s) {
    if (!('wakeLock' in navigator)) return;
    navigator.wakeLock.request('screen').then(function (lock) { s.wakeLock = lock; }, function () {});
  }

  document.addEventListener('visibilitychange', function () {
    // The browser drops the wake lock whenever the page is hidden.
    if (session && session.live && document.visibilityState === 'visible') keepAwake(session);
  });

  window.addEventListener('beforeunload', function (e) {
    if (session && session.live) {
      e.preventDefault();
      e.returnValue = '';
    }
  });

  // ------------------------------------------------------------ lifecycle

  function teardown(s) {
    if (s.recorder && s.recorder.state !== 'inactive') {
      try { s.recorder.stop(); } catch (e) { /* already stopped */ }
    }
    if (s.stream) s.stream.getTracks().forEach(function (t) { t.stop(); });
    if (s.ws && s.ws.readyState <= 1) s.ws.close(1000);
    if (s.audio) s.audio.close();
    if (s.raf) cancelAnimationFrame(s.raf);
    if (s.timer) clearInterval(s.timer);
    if (s.wakeLock) s.wakeLock.release().catch(function () {});
    meterBar.style.width = '0';
    if (session === s) session = null;
  }

  function fail(s, text) {
    s.failed = true;
    teardown(s);
    setState('error', text);
  }

  function start() {
    var mime = pickMime();
    if (mime === null || !navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
      setState('error', 'Este navegador no puede transmitir. Usa Chrome o Firefox, o Safari en iOS 14.5 o más.');
      return;
    }
    if (!window.isSecureContext) {
      setState('error', 'El micrófono solo funciona por https.');
      return;
    }

    var s = { live: false };
    session = s;
    setState('connecting', 'Pidiendo el micrófono…');

    navigator.mediaDevices.getUserMedia({ audio: true, video: false }).then(function (stream) {
      if (session !== s) { stream.getTracks().forEach(function (t) { t.stop(); }); return; }
      s.stream = stream;
      startMeter(s); // inside the tap, so iOS lets the AudioContext run
      setState('connecting', 'Conectando con el servidor…');

      var proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
      s.ws = new WebSocket(proto + '//' + location.host + '/ws/stream');
      s.ws.binaryType = 'arraybuffer';

      s.ws.onopen = function () {
        s.ws.send(JSON.stringify({ type: 'hola', meta: readMeta(), mime: mime }));
      };

      s.ws.onmessage = function (ev) {
        var msg;
        try { msg = JSON.parse(ev.data); } catch (e) { return; }
        if (msg.type === 'listo') goLive(s, mime, msg);
        else if (msg.type === 'error') fail(s, msg.text || 'Error del servidor.');
      };

      s.ws.onclose = function () {
        if (session !== s || s.failed) return;
        if (s.live) fail(s, 'Se cortó la transmisión (' + fmt(Date.now() - s.t0) + '). Revisa tu conexión e intenta de nuevo.');
        else fail(s, 'No se pudo conectar con el servidor.');
      };
    }, function (err) {
      if (session !== s) return;
      fail(s, err && err.name === 'NotAllowedError'
        ? 'Sin permiso para el micrófono. Actívalo en los ajustes del navegador para este sitio.'
        : 'No se encontró un micrófono.');
    });
  }

  function goLive(s, mime, msg) {
    var opts = { audioBitsPerSecond: AUDIO_BPS };
    if (mime) opts.mimeType = mime;
    try {
      s.recorder = new MediaRecorder(s.stream, opts);
    } catch (e) {
      fail(s, 'El navegador no pudo codificar el audio.');
      return;
    }
    s.recorder.ondataavailable = function (e) {
      if (!e.data || !e.data.size || s.ws.readyState !== 1) return;
      if (s.ws.bufferedAmount > MAX_BUFFERED) {
        statusEl.textContent = 'Al aire · la conexión está lenta';
        return;
      }
      s.ws.send(e.data);
    };
    s.recorder.start(CHUNK_MS);
    s.live = true;
    s.t0 = Date.now();
    s.timer = setInterval(function () { timerEl.textContent = fmt(Date.now() - s.t0); }, 500);
    timerEl.textContent = '00:00';
    keepAwake(s);
    setState('live', msg.dryRun ? 'Al aire (prueba local: no sale a Icecast)' : 'Al aire en ' + msg.mount);
  }

  function stop() {
    var s = session;
    if (!s) return;
    var took = s.t0 ? fmt(Date.now() - s.t0) : null;
    s.failed = true; // a close we asked for is not an error
    teardown(s);
    setState('idle', took ? 'Transmisión terminada (' + took + ').' : 'Listo para transmitir.');
  }

  button.addEventListener('click', function () {
    if (session && session.live) stop();
    else if (!session) start();
  });

  // ------------------------------------------------------------ server state

  function poll() {
    if (session) return;
    fetch('/api/estado', { cache: 'no-store' }).then(function (r) { return r.json(); }).then(function (st) {
      if (!session && box.dataset.state !== 'error') {
        statusEl.textContent = !st.libres
          ? 'Los ' + st.total + ' lugares están ocupados. Espera a que alguien termine.'
          : st.alAire
            ? (st.alAire === 1 ? '1 persona' : st.alAire + ' personas') + ' al aire · quedan ' + st.libres + ' de ' + st.total + ' lugares.'
            : 'Listo para transmitir.';
      }
      var note = document.getElementById('bridge-note');
      if (note) note.hidden = !st.puente;
    }).catch(function () {});
  }
  poll();
  setInterval(poll, 15000);

  // ------------------------------------------------------------ share link

  var copy = $('copy-link');
  copy.addEventListener('click', function () {
    var url = copy.dataset.copy;
    if (navigator.share) {
      navigator.share({ title: 'Radiolibre en vivo', url: url }).catch(function () {});
      return;
    }
    if (navigator.clipboard) {
      navigator.clipboard.writeText(url).then(function () {
        copy.textContent = 'Copiado';
        setTimeout(function () { copy.textContent = 'Copiar enlace'; }, 1500);
      });
    }
  });
  if (navigator.share) copy.textContent = 'Compartir';
})();
