// Tests for nodejswebapp. HERMETIC: an ephemeral port on loopback — no fixed port, no machine
// state, so they behave identically on a dev box, in the Tekton task, and on a cold CI runner.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { writeFileSync } from 'node:fs';
import { newApp, render } from './server.js';

const listen = (app) => new Promise((r) => { const s = app.listen(0, '127.0.0.1', () => r(s)); });
const url = (s, p) => `http://127.0.0.1:${s.address().port}${p}`;

test('healthz answers 200 with the shared JSON body', async () => {
  const s = await listen(newApp({}));
  const res = await fetch(url(s, '/healthz'));
  assert.equal(res.status, 200);
  assert.equal((await res.text()).trim(), '{"status":"UP"}');
  s.close();
});

// The deployed page MUST render the message: `make verify` proves the whole GitOps loop by pushing
// a unique marker into it and asserting the marker appears on the live page. If the message stopped
// rendering, that check would be measuring nothing.
test('index renders the message, version and commit', async () => {
  const p = { appName: 'nodejswebapp', message: 'marker-4711-hello', version: '1.2.3', commit: 'abc1234' };
  const s = await listen(newApp(p));
  const body = await (await fetch(url(s, '/'))).text();
  for (const want of [p.message, p.version, p.commit, p.appName]) assert.ok(body.includes(want), `missing ${want}`);
  s.close();
});

test('html-significant characters are escaped', () => {
  assert.ok(render({ appName: 'a', message: '<script>x</script>', version: 'v', commit: 'c' }).includes('&lt;script&gt;'));
});

// --- THE SHARED-UI CONTRACT PRODUCER (see scripts/check-ui-contract.sh) ------------------------
// Renders through the REAL handler and writes the page to $UI_CONTRACT_OUT. Skipped when unset, so
// a normal `npm test` is unaffected. The literals must be IDENTICAL across all six apps AND
// MUTUALLY DISTINCT — distinctness is the only reason a field SWAP (appName rendered where version
// belongs) is caught by the diff.
test('ui contract producer', { skip: !process.env.UI_CONTRACT_OUT }, async () => {
  const s = await listen(newApp({ appName: 'APPNAME', message: 'MESSAGE', appVersion: 'APPVERSION', version: 'VERSION', commit: 'COMMIT' }));
  writeFileSync(process.env.UI_CONTRACT_OUT, await (await fetch(url(s, '/'))).text());
  s.close();
});
