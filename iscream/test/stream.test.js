'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { FIELD_MAX, sanitizeMeta, iceNames, ffmpegArgs, mountList, mountsInUse, classifyFfmpegError, createPool } = require('../lib/stream');

test('sanitizeMeta keeps only known string fields', () => {
  const meta = sanitizeMeta({ lugar: 'Plaza', quien: 42, evento: ['x'], extra: 'nope' });
  assert.deepEqual(meta, { lugar: 'Plaza', quien: '', evento: '', red: '' });
  assert.deepEqual(sanitizeMeta(null), { lugar: '', quien: '', evento: '', red: '' });
});

test('sanitizeMeta strips control characters that could forge header lines', () => {
  const meta = sanitizeMeta({ evento: 'Marcha\r\nIce-Name: pwned\u0000' });
  assert.equal(meta.evento, 'Marcha Ice-Name: pwned');
  assert.doesNotMatch(meta.evento, /[\r\n\u0000]/);
});

test('sanitizeMeta bounds length and collapses whitespace', () => {
  const meta = sanitizeMeta({ lugar: '  a   b  ', red: 'x'.repeat(500) });
  assert.equal(meta.lugar, 'a b');
  assert.equal(meta.red.length, FIELD_MAX);
});

test('iceNames falls back when nothing was given', () => {
  assert.deepEqual(iceNames(sanitizeMeta({})), { name: 'Reporte en vivo', description: 'iScream' });
  assert.deepEqual(iceNames(sanitizeMeta({ evento: 'Paro', lugar: 'Cali', red: 'RL' })), { name: 'Paro', description: 'Cali · RL' });
});

test('ffmpegArgs with no password is a dry run that never contacts Icecast', () => {
  const args = ffmpegArgs({ password: '' }, sanitizeMeta({}), '/reporta.mp3');
  assert.deepEqual(args.slice(-3), ['-f', 'null', '-']);
  assert.ok(!args.some((a) => a.startsWith('icecast://')));
});

test('ffmpegArgs keeps the password out of the URL and passes metadata as single args', () => {
  const cfg = { password: 's3cret', host: '127.0.0.1', port: 8000, bitrate: '128k' };
  const args = ffmpegArgs(cfg, sanitizeMeta({ evento: 'a; rm -rf /' }), '/reporta3.mp3');
  assert.equal(args[args.length - 1], 'icecast://source@127.0.0.1:8000/reporta3.mp3');
  assert.equal(args[args.indexOf('-password') + 1], 's3cret');
  assert.equal(args[args.indexOf('-ice_name') + 1], 'a; rm -rf /');
  assert.equal(args[args.indexOf('-ice_public') + 1], '0');
});

test('classifyFfmpegError maps the failures the page explains', () => {
  assert.equal(classifyFfmpegError('HTTP error 401 Unauthorized').code, 401);
  assert.equal(classifyFfmpegError('HTTP error 403 Forbidden').code, 409);
  assert.equal(classifyFfmpegError('Failed to resolve hostname x').code, 523);
  assert.equal(classifyFfmpegError('Connection refused').code, 522);
  assert.equal(classifyFfmpegError('some other noise'), null);
});

test('mountList keeps the first mount and numbers the rest from 2', () => {
  assert.deepEqual(mountList('/reporta.mp3', 3), ['/reporta.mp3', '/reporta2.mp3', '/reporta3.mp3']);
  assert.deepEqual(mountList('/reporta.mp3', 1), ['/reporta.mp3']);
  assert.equal(mountList('/reporta.mp3', 8).length, 8);
});

test('mountsInUse finds mounts in status text without confusing /reporta.mp3 with /reporta2.mp3', () => {
  const mounts = mountList('/reporta.mp3', 3);
  // Icecast 2.4 output, trailing comma and all.
  const status = '{"icestats":{"source":[{"listenurl":"http://live.altred.xyz:8000/reporta2.mp3",},{"listenurl":"http://live.altred.xyz:8000/radio.mp3"}]}}';
  assert.deepEqual([...mountsInUse(status, mounts)], ['/reporta2.mp3']);
  assert.deepEqual([...mountsInUse('', mounts)], []);
});

test('the pool hands out free mounts in order, skips busy ones, and refuses when full', () => {
  const pool = createPool(['/a', '/b', '/c']);
  const [x, y, z, w] = [Symbol('x'), Symbol('y'), Symbol('z'), Symbol('w')];
  assert.equal(pool.acquire(x), '/a');
  assert.equal(pool.acquire(y, new Set(['/b'])), '/c');
  assert.equal(pool.acquire(z), '/b');
  assert.equal(pool.acquire(w), null);
  assert.equal(pool.used, 3);
  pool.release(y);
  assert.equal(pool.used, 2);
  assert.equal(pool.acquire(w), '/c');
  pool.release(Symbol('stranger'));
  assert.equal(pool.used, 3);
});
