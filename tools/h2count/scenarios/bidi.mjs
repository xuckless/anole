// Drives a headless Firefox over WebDriver BiDi just far enough to accept the
// proxy's self-signed certificate (capability acceptInsecureCerts) and open
// one URL; the page does the rest. Firefox is killed after <seconds>.
// usage: node bidi.mjs <firefox> <profile-dir> <url> <seconds>
import { spawn } from 'node:child_process';

const [bin, profile, url, seconds] = process.argv.slice(2);
const port = 19200 + Math.floor(Math.random() * 500);
const ff = spawn(bin, ['--headless', '--no-remote', '--profile', profile, '--remote-debugging-port', String(port), 'about:blank'], { stdio: 'ignore' });
const sleep = ms => new Promise(r => setTimeout(r, ms));
let ws;
for (let i = 0; i < 100 && !ws; i++) {
  await sleep(200);
  try {
    ws = await new Promise((res, rej) => { const w = new WebSocket(`ws://127.0.0.1:${port}/session`); w.onopen = () => res(w); w.onerror = rej; });
  } catch { /* not listening yet */ }
}
if (!ws) { console.error('firefox: no BiDi endpoint'); ff.kill(); process.exit(1); }
let id = 0; const pending = new Map();
ws.onmessage = m => { const d = JSON.parse(m.data); pending.get(d.id)?.(d); };
const send = (method, params = {}) => new Promise(r => { pending.set(++id, r); ws.send(JSON.stringify({ id, method, params })); });
const ses = await send('session.new', { capabilities: { alwaysMatch: { acceptInsecureCerts: true } } });
if (ses.error) { console.error('session.new', ses); ff.kill(); process.exit(1); }
const tree = await send('browsingContext.getTree');
const context = tree.result.contexts[0].context;
const nav = await send('browsingContext.navigate', { context, url, wait: 'none' });
if (nav.error) console.error('navigate', nav);
await sleep(Number(seconds) * 1000);
ff.kill('SIGTERM');
await sleep(500);
process.exit(0);
