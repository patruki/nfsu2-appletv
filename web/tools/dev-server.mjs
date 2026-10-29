// The test tools load the test pages (/test/) and the repo's test scripts
// (/tests/), which the server serves only when started with --dev:
//   out/web/server-rs/nfsu2-server --data "<game folder>" --http-port <http> --dev [--artifacts <dir>]
// requireDev(base) stops a tool early, with that hint, when the server at base
// answers without them.  (A server it cannot reach, or one behind a
// certificate node does not trust, is left to the browser to report.)
export async function requireDev(base) {
  let r;
  try { r = await fetch(new URL('/test/hostcheck.html', base), { method: 'HEAD' }); } catch { return; }
  if (r.status === 404) {
    console.error(`${base} does not serve the test pages: start the server with --dev ` +
      '(out/web/server-rs/nfsu2-server --data "<game folder>" --http-port <http> --dev)');
    process.exit(2);
  }
}

/** The module the server at base sends, in one line for a run's output (a
 *  result counts only for the module that made it): its revision and lift
 *  options (/game.json, web/build.sh's nfsu2.json) and its hash, which the
 *  server adds for /game.wasm?v=.  null when there is no json to read. */
export async function moduleLine(base) {
  let j;
  try { j = await (await fetch(new URL('/game.json', base))).json(); } catch { return null; }
  if (!j || typeof j !== 'object') return null;
  return `module: rev ${j.rev ?? '?'}, lift ${j.lift || '-'}, hash ${j.module ?? '?'}`;
}
