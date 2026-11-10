// Spike: use Slack web in real Chrome as the client; capture new messages from its websocket
// and read a thread through an in-page API call.
import { chromium } from 'playwright';
import { appendFileSync, mkdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const here = path.dirname(fileURLToPath(import.meta.url));
const profileDir = path.join(here, '.profile');
const eventsFile = path.join(here, 'events.jsonl');
mkdirSync(profileDir, { recursive: true });

const log = (tag, obj = {}) => console.log(`[${new Date().toISOString().slice(11, 19)}] ${tag} ${JSON.stringify(obj)}`);
const record = (obj) => appendFileSync(eventsFile, JSON.stringify({ at: new Date().toISOString(), ...obj }) + '\n');
const clip = (s, n = 120) => (typeof s === 'string' ? s.slice(0, n) : s);

const frameTypes = new Map();
const apiCalls = new Map();
let lastFetch = 0;

const context = await chromium.launchPersistentContext(profileDir, {
  channel: 'chrome',
  headless: false,
  viewport: null,
});
const page = context.pages()[0] ?? (await context.newPage());

page.on('websocket', (ws) => {
  log('WS_OPEN', { url: ws.url().split('?')[0] });
  ws.on('close', () => log('WS_CLOSE', { url: ws.url().split('?')[0] }));
  ws.on('framereceived', ({ payload }) => {
    const text = typeof payload === 'string' ? payload : null;
    if (!text) { frameTypes.set('<binary>', (frameTypes.get('<binary>') ?? 0) + 1); return; }
    let msg;
    try { msg = JSON.parse(text); } catch { frameTypes.set('<non-json>', (frameTypes.get('<non-json>') ?? 0) + 1); return; }
    const type = msg.type ?? '<no-type>';
    frameTypes.set(type, (frameTypes.get(type) ?? 0) + 1);
    if (type === 'message') {
      const ev = {
        kind: 'message', subtype: msg.subtype, channel: msg.channel, ts: msg.ts,
        thread_ts: msg.thread_ts, user: msg.user, text: clip(msg.text),
      };
      record(ev);
      log('MESSAGE', ev);
      maybeFetchThread(msg.channel, msg.thread_ts ?? msg.ts);
    }
  });
});

// Passive: which API methods the web client itself calls (names only, no bodies).
page.on('response', (res) => {
  const m = res.url().match(/\/api\/([a-zA-Z0-9_.]+)/);
  if (m) apiCalls.set(m[1], (apiCalls.get(m[1]) ?? 0) + 1);
});

// Active: read a thread from inside the page, the same way the web client does.
// The credential is read and used inside the page only; it is never returned to this process.
async function maybeFetchThread(channel, ts) {
  if (!channel || !ts || Date.now() - lastFetch < 20_000) return;
  lastFetch = Date.now();
  const result = await page.evaluate(async ({ channel, ts }) => {
    const cfg = JSON.parse(localStorage.getItem('localConfig_v2') || '{}');
    const teamId = cfg.lastActiveTeamId || Object.keys(cfg.teams || {})[0];
    const team = cfg.teams?.[teamId];
    if (!team?.token) return { ok: false, error: 'no_local_config' };
    const body = new URLSearchParams({ token: team.token, channel, ts, limit: '20' });
    const bases = ['/api/', `${team.url}api/`];
    for (const base of bases) {
      try {
        const r = await fetch(`${base}conversations.replies`, { method: 'POST', body, credentials: 'include' });
        const j = await r.json();
        if (j.ok || base === bases.at(-1)) {
          return {
            ok: j.ok, error: j.error, base,
            count: j.messages?.length ?? 0,
            messages: (j.messages || []).map((m) => ({ ts: m.ts, user: m.user, text: (m.text || '').slice(0, 80) })),
          };
        }
      } catch (e) { if (base === bases.at(-1)) return { ok: false, error: String(e), base }; }
    }
  }, { channel, ts }).catch((e) => ({ ok: false, error: String(e) }));
  record({ kind: 'thread_fetch', channel, ts, ...result });
  log('THREAD_FETCH', { channel, ts, ok: result.ok, error: result.error, base: result.base, count: result.count });
}

setInterval(() => {
  log('SUMMARY', {
    frames: Object.fromEntries(frameTypes),
    api: Object.fromEntries([...apiCalls].sort((a, b) => b[1] - a[1]).slice(0, 15)),
  });
}, 60_000);

let signedIn = false;
setInterval(async () => {
  if (signedIn) return;
  const team = await page.evaluate(() => {
    const cfg = JSON.parse(localStorage.getItem('localConfig_v2') || '{}');
    const id = cfg.lastActiveTeamId;
    return id ? { id, name: cfg.teams?.[id]?.name, url: cfg.teams?.[id]?.url } : null;
  }).catch(() => null);
  if (team) { signedIn = true; log('SIGNED_IN', team); }
}, 5_000);

context.on('close', () => { log('BROWSER_CLOSED'); process.exit(0); });
await page.goto('https://app.slack.com/client');
log('READY', { note: 'Sign in to Slack in the Chrome window, then send yourself a DM or reply in a thread.' });
