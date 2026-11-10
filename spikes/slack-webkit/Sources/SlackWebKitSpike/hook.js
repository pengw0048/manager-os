// Injected at document start in every frame (page content world).
// Wraps WebSocket to report Slack RTM frames, and reports workers so we can tell where the socket lives.
(() => {
  if (window.__slackSpikeHooked) return;
  window.__slackSpikeHooked = true;
  const post = (obj) => { try { window.webkit.messageHandlers.slackSpike.postMessage(obj); } catch (_) {} };
  const where = location.origin + location.pathname;
  const clip = (s, n) => (typeof s === 'string' ? s.slice(0, n) : s);

  const OrigWS = window.WebSocket;
  if (OrigWS) {
    window.WebSocket = class extends OrigWS {
      constructor(url, protocols) {
        super(url, protocols);
        const u = String(url).split('?')[0];
        post({ kind: 'ws_open', url: u, frame: where });
        this.addEventListener('close', (e) => post({ kind: 'ws_close', url: u, code: e.code }));
        this.addEventListener('message', (e) => {
          if (typeof e.data !== 'string') { post({ kind: 'frame', type: '<binary>' }); return; }
          let m;
          try { m = JSON.parse(e.data); } catch { post({ kind: 'frame', type: '<non-json>' }); return; }
          const type = m.type ?? '<no-type>';
          if (type !== 'message') { post({ kind: 'frame', type }); return; }
          post({
            kind: 'message', subtype: m.subtype, channel: m.channel, ts: m.ts,
            thread_ts: m.thread_ts ?? m.message?.thread_ts, user: m.user, text: clip(m.text, 120),
          });
        });
      }
    };
  }

  for (const name of ['Worker', 'SharedWorker']) {
    const Orig = window[name];
    if (!Orig) continue;
    window[name] = class extends Orig {
      constructor(url, opts) {
        super(url, opts);
        post({ kind: 'worker_created', which: name, url: String(url).split('?')[0].slice(0, 200), frame: where });
      }
    };
  }

  post({ kind: 'script_loaded', frame: where, top: window === window.top });
  navigator.serviceWorker?.ready
    .then((r) => post({ kind: 'service_worker', scope: r.scope, script: r.active?.scriptURL?.split('?')[0] }))
    .catch(() => {});
})();
