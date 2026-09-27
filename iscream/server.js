'use strict';
/**
 * iScream — Sistema de Alerta Temprana de Radiolibre.
 *
 * Serves the page in www/ and bridges a phone's microphone to Icecast:
 *
 *   browser MediaRecorder --ws /ws/stream--> this process --stdin--> ffmpeg --icecast://--> /reporta[N].mp3
 *
 * Up to ICECAST_SLOTS people broadcast at once, each on the first free mount.
 *
 * Nothing is written to disk: the audio only passes through ffmpeg on its way
 * to Icecast, and the chat lives in Ergo (deploy/ergo/), not here.
 *
 * Configuration comes from the environment (see iscream.env.example). With no
 * ICECAST_SOURCE_PASSWORD the bridge runs dry: ffmpeg decodes and discards.
 */

const fs = require('fs');
const http = require('http');
const path = require('path');
const { spawn } = require('child_process');
const { WebSocket, WebSocketServer } = require('ws');
const { sanitizeMeta, ffmpegArgs, mountList, mountsInUse, classifyFfmpegError, createPool } = require('./lib/stream');

const cfg = {
  listen: Number(process.env.PORT || 3000),
  bind: process.env.BIND || '127.0.0.1',
  host: process.env.ICECAST_HOST || '127.0.0.1',
  port: Number(process.env.ICECAST_PORT || 8000),
  mount: process.env.ICECAST_MOUNT || '/reporta.mp3',
  // How many people can be on air at once, each on their own mount:
  // /reporta.mp3, /reporta2.mp3 … Icecast needs a <mount> block for each
  // (same password as the first), see README.
  slots: Math.max(1, Number(process.env.ICECAST_SLOTS || 8)),
  password: process.env.ICECAST_SOURCE_PASSWORD || '',
  bitrate: process.env.MP3_BITRATE || '128k',
  ffmpeg: process.env.FFMPEG || 'ffmpeg',
  debug: process.env.DEBUG === '1',
  // Set when matterbridge links the chat to Libera/Telegram, so the page can
  // say that messages leave this server.
  bridged: process.env.CHAT_BRIDGED === '1',
  // Local development only: forward /irc to Ergo's websocket. In production
  // nginx sends /irc straight to Ergo and this stays unset.
  chatProxy: process.env.CHAT_PROXY || '',
};

const WWW = path.join(__dirname, 'www');

/** A phone that stops sending for this long is treated as gone. */
const SILENCE_LIMIT_MS = 20000;
const PING_EVERY_MS = 10000;

const TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.gif': 'image/gif',
  '.png': 'image/png',
  '.ico': 'image/x-icon',
  '.svg': 'image/svg+xml',
  '.txt': 'text/plain; charset=utf-8',
};

// connect-src 'self' covers ws(s):// to this same host (the chat socket at
// /irc and the stream at /ws/stream) in current browsers.
const CSP = [
  "default-src 'self'",
  "connect-src 'self'",
  "img-src 'self' data:",
  "media-src 'self' https://radiolibre.altred.xyz",
  "font-src https://zkm.de",
  "style-src 'self'",
  "script-src 'self'",
  "base-uri 'none'",
  "form-action 'none'",
  "frame-ancestors 'none'",
].join('; ');

const mounts = mountList(cfg.mount, cfg.slots);
const pool = createPool(mounts);

/**
 * Mounts some other source client (butt, a studio…) is already feeding, so we
 * don't hand them out. Best effort: if Icecast can't be asked, assume none.
 */
function busyOnIcecast() {
  return new Promise((resolve) => {
    const req = http.get({ host: cfg.host, port: cfg.port, path: '/status-json.xsl', timeout: 2000 }, (res) => {
      let body = '';
      res.setEncoding('utf8');
      res.on('data', (c) => { body += c; });
      res.on('end', () => resolve(mountsInUse(body, mounts)));
    });
    req.on('timeout', () => req.destroy());
    req.on('error', () => resolve(new Set()));
  });
}

function log(...args) {
  console.log(new Date().toISOString(), ...args);
}

// ---------------------------------------------------------------- static files

function serveStatic(req, res) {
  if (req.method !== 'GET' && req.method !== 'HEAD') {
    res.writeHead(405, { Allow: 'GET, HEAD' }).end();
    return;
  }
  const url = new URL(req.url, 'http://x');

  if (url.pathname === '/api/estado') {
    const body = JSON.stringify({ alAire: pool.used, libres: pool.total - pool.used, total: pool.total, puente: cfg.bridged });
    res.writeHead(200, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
    res.end(req.method === 'HEAD' ? undefined : body);
    return;
  }

  let rel;
  try {
    rel = decodeURIComponent(url.pathname);
  } catch {
    res.writeHead(400).end();
    return;
  }
  if (rel.endsWith('/')) rel += 'index.html';
  const file = path.join(WWW, path.normalize(rel));
  if (!file.startsWith(WWW + path.sep)) {
    res.writeHead(403).end();
    return;
  }

  fs.stat(file, (err, st) => {
    if (err || !st.isFile()) {
      res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' }).end('No encontrado\n');
      return;
    }
    res.writeHead(200, {
      'Content-Type': TYPES[path.extname(file)] || 'application/octet-stream',
      'Content-Length': st.size,
      'Cache-Control': file.endsWith('.html') ? 'no-cache' : 'public, max-age=300',
      'Content-Security-Policy': CSP,
      'X-Content-Type-Options': 'nosniff',
      'Referrer-Policy': 'no-referrer',
      'Permissions-Policy': 'microphone=(self), camera=(), geolocation=()',
    });
    if (req.method === 'HEAD') res.end();
    else fs.createReadStream(file).pipe(res);
  });
}

// ---------------------------------------------------------------- broadcast

function send(ws, msg) {
  if (ws.readyState === ws.OPEN) ws.send(JSON.stringify(msg));
}

/**
 * One broadcast. The first frame must be a JSON text frame
 * {type: 'hola', meta: {...}}; after the server answers {type: 'listo'} every
 * binary frame is a MediaRecorder chunk for ffmpeg's stdin.
 */
function handleBroadcast(ws) {
  let ffmpeg = null;
  let lastData = Date.now();
  let alive = true;
  let starting = false;
  let closed = false;
  const who = Symbol('broadcaster');

  const heartbeat = setInterval(() => {
    if (!alive || (ffmpeg && Date.now() - lastData > SILENCE_LIMIT_MS)) {
      log('stream: connection went quiet, dropping it');
      ws.terminate();
      return;
    }
    alive = false;
    ws.ping();
  }, PING_EVERY_MS);
  ws.on('pong', () => { alive = true; });

  function stop() {
    clearInterval(heartbeat);
    closed = true;
    pool.release(who);
    if (ffmpeg) {
      ffmpeg.stdin.end();
      const proc = ffmpeg;
      setTimeout(() => proc.kill('SIGKILL'), 3000).unref();
      ffmpeg = null;
    }
  }

  ws.on('close', () => {
    log('stream: closed');
    stop();
  });
  ws.on('error', (e) => log('stream: socket error', e.message));

  async function begin(msg) {
    const skip = await busyOnIcecast();
    if (closed) return;
    const mount = pool.acquire(who, skip);
    if (!mount) {
      send(ws, { type: 'error', code: 409, text: `Los ${pool.total} lugares para transmitir están ocupados. Intenta en un rato.` });
      ws.close(1000);
      return;
    }
    const meta = sanitizeMeta(msg.meta);
    ffmpeg = spawn(cfg.ffmpeg, ffmpegArgs(cfg, meta, mount), { stdio: ['pipe', 'ignore', 'pipe'] });
    log(`stream: start ${mount}${cfg.password ? '' : ' (dry run, no Icecast password set)'} ${JSON.stringify(meta)}`);

    ffmpeg.stdin.on('error', (e) => log('stream: ffmpeg stdin', e.code || e.message));
    ffmpeg.stderr.on('data', (chunk) => {
      const text = chunk.toString();
      // ffmpeg can echo the icecast URL; never let the password reach a log.
      if (cfg.debug) log('ffmpeg:', cfg.password ? text.split(cfg.password).join('***') : text);
      const status = classifyFfmpegError(text);
      if (status) send(ws, { type: 'error', ...status });
    });
    ffmpeg.on('error', (e) => {
      log('stream: could not run ffmpeg', e.message);
      send(ws, { type: 'error', code: 500, text: 'El servidor no pudo iniciar la transmisión.' });
      ws.close(1011);
    });
    ffmpeg.on('close', (code, signal) => {
      log(`stream: ${mount} ffmpeg exited code=${code} signal=${signal}`);
      ffmpeg = null;
      ws.close(1000);
    });

    send(ws, { type: 'listo', mount, dryRun: !cfg.password });
  }

  ws.on('message', (data, isBinary) => {
    if (!isBinary) {
      if (starting) return; // only one hello per connection
      let msg;
      try {
        msg = JSON.parse(data.toString());
      } catch {
        ws.close(1003, 'mensaje inválido');
        return;
      }
      if (msg.type !== 'hola') {
        ws.close(1003, 'mensaje inválido');
        return;
      }
      starting = true;
      begin(msg);
      return;
    }

    if (!ffmpeg) return;
    lastData = Date.now();
    ffmpeg.stdin.write(data);
  });
}

// ---------------------------------------------------------------- wiring

const server = http.createServer(serveStatic);
const wss = new WebSocketServer({ noServer: true, maxPayload: 1024 * 1024 });

const chatWss = new WebSocketServer({
  noServer: true,
  maxPayload: 8 * 1024,
  handleProtocols: (protocols) => (protocols.has('text.ircv3.net') ? 'text.ircv3.net' : false),
});

function proxyChat(client, req) {
  const upstream = new WebSocket(cfg.chatProxy, 'text.ircv3.net', {
    headers: { Origin: req.headers.origin || '', 'X-Forwarded-For': req.socket.remoteAddress },
  });
  const pending = [];
  upstream.on('open', () => pending.splice(0).forEach((m) => upstream.send(m)));
  upstream.on('message', (m) => client.readyState === client.OPEN && client.send(m.toString()));
  client.on('message', (m) => (upstream.readyState === upstream.OPEN ? upstream.send(m.toString()) : pending.push(m.toString())));
  upstream.on('close', () => client.close());
  upstream.on('error', () => client.close());
  client.on('close', () => upstream.close());
}

server.on('upgrade', (req, socket, head) => {
  const { pathname } = new URL(req.url, 'http://x');
  if (pathname === '/ws/stream') {
    wss.handleUpgrade(req, socket, head, (ws) => handleBroadcast(ws));
  } else if (pathname === '/irc' && cfg.chatProxy) {
    chatWss.handleUpgrade(req, socket, head, (ws) => proxyChat(ws, req));
  } else {
    socket.destroy();
  }
});

server.listen(cfg.listen, cfg.bind, () => {
  log(`iScream on http://${cfg.bind}:${cfg.listen}/ → icecast ${cfg.host}:${cfg.port}${cfg.mount}${cfg.password ? '' : ' (DRY RUN)'}`);
});

function shutdown() {
  for (const ws of wss.clients) ws.close(1001);
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(0), 2000).unref();
}
process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);
