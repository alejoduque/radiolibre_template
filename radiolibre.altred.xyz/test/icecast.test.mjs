/**
 * Regression tests for the Icecast layer.
 *
 * Run with: node --test        (from radiolibre.altred.xyz/)
 *
 * No dependencies and no build step — node's built-in test runner only.
 *
 * These guard the bug that silently broke the player: Icecast 2.4.3 sends
 * JSON that `JSON.parse` refuses, so any change to repairIcecastJson should
 * keep passing these.
 */

import test from 'node:test';
import assert from 'node:assert/strict';

import { repairIcecastJson, parseStatus } from '../assets/js/icecast.js';

/** The literal 216-byte body live.altred.xyz returns when nobody is broadcasting. */
const REAL_IDLE_BODY =
  '{"icestats":{"admin":"alejoduque@gmail.com","host":"live.altred.xyz",' +
  '"location":"Earth","server_id":"Icecast 2.4.3",' +
  '"server_start":"Wed, 09 Jul 2025 16:36:46 +0200",' +
  '"server_start_iso8601":"2025-07-09T16:36:46+0200",}';

test('the real idle response is not valid JSON', () => {
  assert.throws(() => JSON.parse(REAL_IDLE_BODY));
});

test('the real idle response parses after repair', () => {
  const status = parseStatus(REAL_IDLE_BODY);
  assert.equal(status.icestats.host, 'live.altred.xyz');
  assert.equal(status.icestats.source, undefined, 'idle server has no sources');
});

test('drops trailing commas in objects and arrays', () => {
  assert.deepEqual(parseStatus('{"a":1,}'), { a: 1 });
  assert.deepEqual(parseStatus('{"a":[1,2,]}'), { a: [1, 2] });
  assert.deepEqual(parseStatus('{"s":{"x":1,},"l":[{"y":2,},],}'), { s: { x: 1 }, l: [{ y: 2 }] });
});

test('leaves string contents alone', () => {
  // A track title containing a comma, a brace, or an escaped quote must
  // survive the repair untouched.
  assert.deepEqual(parseStatus('{"title":"Rap, hoy","n":1,}'), { title: 'Rap, hoy', n: 1 });
  assert.deepEqual(parseStatus('{"title":"weird,}","n":2,}'), { title: 'weird,}', n: 2 });
  assert.deepEqual(parseStatus('{"title":"say \\"hi\\", ok",}'), { title: 'say "hi", ok' });
});

test('seals a document truncated mid-stream', () => {
  assert.deepEqual(parseStatus('{"icestats":{"a":1,'), { icestats: { a: 1 } });
  assert.deepEqual(parseStatus('{"icestats":{"a":"unter'), { icestats: { a: 'unter' } });
  assert.deepEqual(parseStatus('{"s":[{"m":"/a.mp3"},'), { s: [{ m: '/a.mp3' }] });
});

test('replaces raw control characters inside tags', () => {
  // ID3 tags regularly carry raw newlines, which are illegal inside a JSON
  // string and would otherwise cost us every stream in the list.
  assert.deepEqual(parseStatus('{"title":"bad\ntag"}'), { title: 'bad tag' });
});

test('valid JSON is passed through untouched', () => {
  const valid = '{"a":1,"b":[1,2],"c":"x,y"}';
  assert.equal(repairIcecastJson(valid), valid);
  assert.deepEqual(parseStatus(valid), { a: 1, b: [1, 2], c: 'x,y' });
});
