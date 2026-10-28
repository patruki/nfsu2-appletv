// The app's GameSession (web/src/app/game.ts) with a fake process and fake
// subsystems: the order of attach and exit is controlled, so the late-attach
// rule (app review finding 6) is tested deterministically.
//   node --test web/test/app-session.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import * as esbuild from 'esbuild';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const FAKES = `
export const events = [];
export const ctl = {};
// the process: exits when the test says so; registrations never arrive
export async function startProcess() {
  let exit; const exited = new Promise(r => (exit = r));
  ctl.exit = exit;
  return { memory: new WebAssembly.Memory({ initial: 1, maximum: 2, shared: true }), exited,
    registered: () => new Promise(() => {}), terminate() { events.push('terminate'); exit(-1); } };
}
// subsystems whose attach finishes when the test says so
const later = (name, extra = {}) => (...args) => new Promise((res, rej) => {
  ctl[name] = { attach: () => res({ detach: () => events.push(name + ' detached'), stats: () => ({}), ...extra }), fail: (e) => rej(e) };
});
export const attachRenderer = later('renderer', { imageRect: () => ({ x: 0, y: 0, w: 1, h: 1 }) });
export const attachAudio = later('audio', { state: () => 'running' });
export const attachInput = later('input');
export const attachNet = later('net', { vip: () => null, peers: () => [] });
// the renderer's failure for a page of another build than the module (gpu/index.ts)
export class OtherBuild extends Error {}
`;
const plugin = { name: 'fakes', setup(b) {
  b.onResolve({ filter: /(\/host\/process|\/subsystems|^fakes)$/ }, () => ({ path: 'fakes', namespace: 'fakes' }));
  b.onLoad({ filter: /.*/, namespace: 'fakes' }, () => ({ contents: FAKES, loader: 'js' }));
} };
const entry = `export { GameSession } from ${JSON.stringify(path.join(ROOT, 'web/src/app/game.ts'))}; export { events, ctl, OtherBuild } from 'fakes';`;
const js = (await esbuild.build({ stdin: { contents: entry, resolveDir: ROOT, loader: 'ts' }, bundle: true, format: 'esm', write: false, plugins: [plugin] })).outputFiles[0].text;
const mod = await import('data:text/javascript;base64,' + Buffer.from(js).toString('base64'));
const { GameSession, events, ctl, OtherBuild } = mod;

const tick = () => new Promise(r => setTimeout(r, 10));
async function session(extra = {}) {
  events.length = 0;
  const logs = [], fatal = [];
  let closed = 0;
  const audio = { close: async () => { closed++; } };
  const s = await GameSession.start({ module: null, info: { pages: 0 }, saveDir: 's', env: {}, canvas: { width: 1, height: 1, clientWidth: 1, clientHeight: 1 },
    stage: {}, audio, displayHz: 60, netName: 'Tester', toggleFullscreen() {}, log: l => logs.push(l), onFatal: w => fatal.push(w), ...extra });
  return { s, logs, fatal, closedAudio: () => closed };
}

test('a subsystem attached before the end is detached at the end', async () => {
  const { s } = await session();
  for (const n of ['renderer', 'audio', 'input', 'net']) ctl[n].attach();
  await tick();
  ctl.exit(0); await s.exited; await tick();
  assert.deepEqual(events.sort(), ['audio detached', 'input detached', 'net detached', 'renderer detached']);
});

test('a subsystem that attaches after the game ended is detached at once (renderer, audio, input, net)', async () => {
  const { s, logs, fatal } = await session();
  ctl.exit(1); await s.exited;
  assert.deepEqual(events, []);
  for (const n of ['renderer', 'audio', 'input', 'net']) ctl[n].attach();
  await tick();
  assert.deepEqual(events.sort(), ['audio detached', 'input detached', 'net detached', 'renderer detached']);
  assert.equal(logs.filter(l => /attached after the game ended: detached at once/.test(l)).length, 4);
  assert.deepEqual(fatal, [], 'a late renderer after the end is not a failure to report');
  assert.equal(s.renderer, null);
});

test('audio that fails to attach closes the AudioContext made in the Play click', async () => {
  const { closedAudio, logs } = await session();
  ctl.audio.fail(new Error('no worklet'));
  await tick();
  assert.equal(closedAudio(), 1);
  assert.ok(logs.some(l => /audio could not attach/.test(l)));
});

test('a renderer that fails to attach while the game runs is fatal', async () => {
  const { fatal } = await session();
  ctl.renderer.fail(new Error('no adapter'));
  await tick();
  assert.equal(fatal.length, 1);
});

test('a renderer of another build than the module is not fatal: the page reloads (onOtherBuild)', async () => {
  const other = [];
  const { fatal } = await session({ onOtherBuild: w => other.push(w) });
  ctl.renderer.fail(new OtherBuild('GPU control block mismatch'));
  await tick();
  assert.deepEqual(other, ['GPU control block mismatch']);
  assert.deepEqual(fatal, []);
});

test('no network without free roam (netName null)', async () => {
  delete ctl.net;
  await session({ netName: null });
  assert.equal(ctl.net, undefined);
});
