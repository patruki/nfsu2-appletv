// web/tools/run-suite.mjs names the module it ran against (a result counts only for the module that made it),
// checked against a stand-in server, without a browser or the game:
//   node --test web/test/suite-module.test.mjs
// 1. moduleLine (web/tools/dev-server.mjs): the server's /game.json in one line, its revision, lift options and the
//    hash the server adds (/game.wasm?v=); nothing without a json or a server.
// 2. run-suite prints that line before anything else, and writes it into summary.txt and summary.json.
// Port: NFSU2_TEST_SUITE_PORT (8541), the stand-in's.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const LIFT = 'FLAGABI X87OPT JTSWITCH LREGS FTOL2INL INLINE_LIST';
const PORT = +(process.env.NFSU2_TEST_SUITE_PORT || 8541);

/** a stand-in for the server with --dev: the test page, and /game.json while `json()` gives one */
async function standIn(t, json) {
  const server = http.createServer((q, s) => {
    if (q.url === '/test/hostcheck.html') { s.end('<!doctype html>'); return; }
    if (q.url === '/game.json' && json()) { s.end(json()); return; }
    s.statusCode = 404; s.end();
  });
  await new Promise((r, j) => { server.once('error', j); server.listen(PORT, '127.0.0.1', r); });
  t.after(() => server.close());
  return `http://127.0.0.1:${server.address().port}`;
}

/** a node process: its exit code and what it printed */
const node = (args, env = process.env) => new Promise(res => {
  const c = spawn(process.execPath, args, { cwd: REPO, env });
  let out = '', err = '';
  c.stdout.on('data', d => { out += d; }); c.stderr.on('data', d => { err += d; });
  c.on('exit', code => res({ code, out, err }));
});

test('moduleLine: the module the server sends, in one line', async t => {
  let json = '';
  const base = await standIn(t, () => json);
  const line = async b => JSON.parse((await node(['--input-type=module', '-e',
    `import { moduleLine } from ${JSON.stringify(path.join(REPO, 'web/tools/dev-server.mjs'))}; ` +
    `console.log(JSON.stringify(await moduleLine(${JSON.stringify(b)})));`])).out);
  // nfsu2.json as web/build.sh writes it, with the hash the server adds
  json = JSON.stringify({ pages: 16384, maxPages: 65536, rev: '4eda10d+', size: 35657931, opt: '-O3', lift: LIFT, module: 'AbC-12_x' });
  assert.equal(await line(base), `module: rev 4eda10d+, lift ${LIFT}, hash AbC-12_x`);
  // a lift without options, a json without a revision or a hash
  json = JSON.stringify({ rev: 'unknown', lift: '', module: 'h' });
  assert.equal(await line(base), 'module: rev unknown, lift -, hash h');
  json = JSON.stringify({ pages: 16384 });
  assert.equal(await line(base), 'module: rev ?, lift -, hash ?');
  // no json, or no server: nothing to say
  json = '';
  assert.equal(await line(base), null);
  assert.equal(await line('http://127.0.0.1:9'), null);
});

test('run-suite: the module line first, and in both summaries', async t => {
  const json = JSON.stringify({ rev: '4eda10d+', lift: LIFT, module: 'AbC-12_x' });
  const base = await standIn(t, () => json);
  const want = `module: rev 4eda10d+, lift ${LIFT}, hash AbC-12_x`;
  // before anything else (here it stops at the unknown scenario, before a browser starts)
  let r = await node([path.join(REPO, 'web/tools/run-suite.mjs'), '--base', base, 'nosuchscenario']);
  assert.equal(r.code, 2);
  assert.equal(r.out, `${want}\n`);
  assert.match(r.err, /unknown scenario nosuchscenario/);
  // a run of a scenario that is not runnable yet (outrun without a save seed): nothing to start, the summaries written
  const run = `suite-module-test-${process.pid}`, out = path.join(REPO, 'out/web/runs', run);
  t.after(() => fs.rmSync(out, { recursive: true, force: true }));
  const env = { ...process.env }; delete env.NFSU2_SAVE_SEED;
  r = await node([path.join(REPO, 'web/tools/run-suite.mjs'), '--base', base, '--run', run, 'outrun'], env);
  assert.equal(r.code, 0, r.err);
  assert.ok(r.out.startsWith(`${want}\n`), r.out);
  const sum = fs.readFileSync(path.join(out, 'summary.txt'), 'utf8').split('\n');
  assert.equal(sum[0], `web suite ${run}: 0 passed, 0 failed, 1 not runnable yet`);
  assert.equal(sum[1], want);
  const j = JSON.parse(fs.readFileSync(path.join(out, 'summary.json'), 'utf8'));
  assert.equal(j.module, want);
  assert.deepEqual(j.skipped.map(s => s.name), ['outrun']);
});
