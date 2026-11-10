import Foundation
import AppKit
import WebKit
import ManagerCore

/// Hosts Slack web in a WKWebView for the app's lifetime and feeds its messages to SlackIngest.
/// The Slack token is used only inside the page; Swift receives message fields and names.
@MainActor @Observable
final class SlackController: NSObject {
    enum Status: Equatable { case off, loading, signedOut, connected }

    let ingest: SlackIngest
    let queue: JobQueue
    var status: Status = .off
    var team = ""
    var lastEventAt: Date?
    var received = 0
    private var webView: WKWebView?
    private var window: NSWindow?
    private var hellos = 0
    private var signedIn = false
    private var shownForSignIn = false
    private var timers: [Timer] = []

    static let dataStoreID = UUID(uuidString: "6D05A1AC-0000-4000-8000-00000000510C")!
    static let safariUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.2 Safari/605.1.15"

    init(ingest: SlackIngest, queue: JobQueue) { self.ingest = ingest; self.queue = queue }

    var enabled: Bool { ingest.store.setting("slack_enabled") == "1" }

    func setEnabled(_ on: Bool) {
        ingest.store.setSetting("slack_enabled", on ? "1" : "0")
        if on { start(); showWindow() } else { stop() }
    }

    func start() {
        guard webView == nil else { return }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore(forIdentifier: SlackController.dataStoreID)
        config.preferences.inactiveSchedulingPolicy = .none // keep the socket alive while the window is hidden
        config.userContentController.addUserScript(WKUserScript(source: SlackController.hookJS, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        config.userContentController.add(WeakScriptHandler(self), contentWorld: .page, name: "mos")
        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 820), configuration: config)
        wv.customUserAgent = SlackController.safariUA
        wv.uiDelegate = self
        wv.navigationDelegate = self
        let w = NSWindow(contentRect: wv.frame, styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "Slack · Manager OS"
        w.isReleasedWhenClosed = false
        w.contentView = wv
        w.center()
        webView = wv; window = w
        status = .loading
        wv.load(URLRequest(url: URL(string: "https://app.slack.com/client")!))
        timers = [
            Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } },
            Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in Task { @MainActor in await self?.triage() } },
            Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in Task { @MainActor in self?.pollTodos() } },
        ]
    }

    func stop() {
        timers.forEach { $0.invalidate() }; timers = []
        window?.close(); webView = nil; window = nil; status = .off; hellos = 0; signedIn = false
    }

    func showWindow() { start(); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }

    private func tick() {
        if !signedIn { checkSignedIn() }
        let briefs = (try? ingest.flush()) ?? []
        for id in briefs { Task { await queue.enqueueBrief(id, trigger: ("New Slack messages", "新的 Slack 消息")) } }
    }

    private func triage() async { _ = try? await queue.triage(ingest) }

    private func checkSignedIn() {
        webView?.callAsyncJavaScript("return await window.__mos?.info();", arguments: [:], in: nil, in: .page) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self else { return }
                SlackController.log("info -> \(result) url=\(self.webView?.url?.absoluteString.prefix(60) ?? "")")
                if case .success(let v) = result, let d = v as? [String: Any], let user = d["user_id"] as? String {
                    self.ingest.selfUserId = user
                    if let dm = d["self_dm"] as? String { self.ingest.selfDM = dm }
                    self.pollTodos()
                    self.team = d["team"] as? String ?? ""
                    self.status = .connected
                    self.signedIn = true
                    if self.shownForSignIn { self.window?.orderOut(nil); self.shownForSignIn = false } // signed in: keep running hidden
                } else if self.status != .signedOut, self.webView?.url?.host?.contains("slack.com") == true, !(self.webView?.url?.path.hasPrefix("/client") ?? false) {
                    self.status = .signedOut
                    self.shownForSignIn = true
                    self.showWindow() // she needs to sign in once
                }
            }
        }
    }

    var isConnected: Bool { signedIn && webView != nil }

    /// Reads a whole thread from inside the page (for a pasted Slack link).
    func fetchThread(channel: String, threadTs: String) async -> [SlackEvent]? {
        guard let wv = webView else { return nil }
        let r = try? await wv.callAsyncJavaScript("return await window.__mos?.thread(channel, ts);", arguments: ["channel": channel, "ts": threadTs], in: nil, contentWorld: .page)
        guard let d = r as? [String: Any], d["ok"] as? Bool == true, let msgs = d["messages"] as? [[String: Any]] else { return nil }
        return msgs.map { b in
            SlackEvent(channel: b["channel"] as? String ?? channel, ts: b["ts"] as? String ?? "", threadTs: (b["thread_ts"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                       user: b["user"] as? String ?? "", userName: b["user_name"] as? String ?? "", channelName: b["channel_name"] as? String ?? "",
                       text: b["text"] as? String ?? "", isBot: b["bot"] as? Bool ?? false, permalink: b["permalink"] as? String)
        }
    }

    /// After a reconnect: fetch what arrived while the socket was down; replayed messages are de-duplicated by (channel, ts).
    private func catchUp() {
        let c = ingest.catchUpTargets()
        let targets = (c.threads + c.dms).map { ["channel": $0.channel, "thread_ts": $0.threadTs ?? "", "oldest": $0.oldest] }
        guard !targets.isEmpty else { return }
        webView?.callAsyncJavaScript("return await window.__mos?.catchUp(targets);", arguments: ["targets": targets], in: nil, in: .page) { _ in }
    }

    /// Slack "Later" to-dos created since the last poll become To-sort items; the first poll only sets the starting point.
    private func pollTodos() {
        guard signedIn, let wv = webView else { return }
        let store = ingest.store
        guard let since = store.setting("slack_todo_since").flatMap(Double.init) else {
            store.setSetting("slack_todo_since", String(Int(Date().timeIntervalSince1970))); return
        }
        wv.callAsyncJavaScript("return await window.__mos?.todos(since);", arguments: ["since": since], in: nil, in: .page) { result in
            MainActor.assumeIsolated {
                SlackController.log("todos -> \(result)")
                if case .success(let v) = result, let n = v as? Double, n > since { store.setSetting("slack_todo_since", String(Int(n))) }
            }
        }
    }

    static let debug = ProcessInfo.processInfo.environment["MOS_DEBUG"] == "1"
    static func log(_ s: @autoclosure () -> String) { if debug { print("[slack] \(s())"); fflush(stdout) } }

    func handle(_ body: [String: Any]) {
        SlackController.log("event \(body["kind"] ?? "?") \(body["subtype"] ?? "") \(body["channel"] ?? "")")
        switch body["kind"] as? String {
        case "hello":
            hellos += 1
            status = .connected
            catchUp() // every (re)connect, including the first after launch
        case "message":
            guard let ch = body["channel"] as? String, let ts = body["ts"] as? String else { return }
            let e = SlackEvent(channel: ch, ts: ts, threadTs: (body["thread_ts"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                               user: body["user"] as? String ?? "", userName: body["user_name"] as? String ?? "", channelName: body["channel_name"] as? String ?? "",
                               text: body["text"] as? String ?? "", subtype: body["subtype"] as? String, isBot: body["bot"] as? Bool ?? false,
                               permalink: body["permalink"] as? String, edited: body["edited"] as? Bool ?? false, todo: body["todo"] as? Bool ?? false)
            if (try? ingest.ingest(e)) != nil { received += 1; lastEventAt = Date() }
        default: break
        }
    }

    // MARK: Page script

    static let hookJS = #"""
    (() => {
      if (window.__mosHooked) return;
      window.__mosHooked = true;
      const post = (o) => { try { window.webkit.messageHandlers.mos.postMessage(o); } catch (_) {} };
      const cfg = () => { const c = JSON.parse(localStorage.getItem('localConfig_v2') || '{}'); const id = c.lastActiveTeamId || Object.keys(c.teams || {})[0]; return c.teams?.[id] || null; };
      async function api(method, params) {
        const team = cfg(); if (!team?.token) return { ok: false, error: 'no_token' };
        const body = new URLSearchParams({ token: team.token, ...params });
        for (const base of ['/api/', `${team.url}api/`]) {
          try { const r = await fetch(`${base}${method}`, { method: 'POST', body, credentials: 'include' }); const j = await r.json(); if (j.ok || j.error) return j; } catch (_) {}
        }
        return { ok: false, error: 'fetch_failed' };
      }
      const users = new Map(), chans = new Map();
      async function userName(id) {
        if (!id) return '';
        if (!users.has(id)) users.set(id, api('users.info', { user: id }).then((j) => j.user?.profile?.display_name || j.user?.real_name || j.user?.name || id));
        return users.get(id);
      }
      async function chanName(id) {
        if (!chans.has(id)) chans.set(id, api('conversations.info', { channel: id }).then(async (j) => j.channel?.is_im ? '' : (j.channel?.name || '')));
        return chans.get(id);
      }
      let last = 0;
      async function emit(m, channel, extra) {
        const now = Date.now(); if (now - last < 50) await new Promise((r) => setTimeout(r, 50)); last = Date.now();
        const team = cfg();
        const thread = m.thread_ts && m.thread_ts !== m.ts ? m.thread_ts : '';
        const permalink = team?.url ? `${team.url}archives/${channel}/p${String(m.ts).replace('.', '')}` + (thread ? `?thread_ts=${thread}&cid=${channel}` : '') : null;
        post({ kind: 'message', channel, ts: m.ts, thread_ts: thread, user: m.user || '', bot: !!m.bot_id || m.subtype === 'bot_message',
               subtype: m.subtype || null, text: m.text || '', user_name: await userName(m.user), channel_name: await chanName(channel), permalink, ...extra });
      }
      const Orig = window.WebSocket;
      if (Orig) window.WebSocket = class extends Orig {
        constructor(url, protocols) {
          super(url, protocols);
          this.addEventListener('message', (e) => {
            if (typeof e.data !== 'string') return;
            let m; try { m = JSON.parse(e.data); } catch { return; }
            if (m.type === 'hello') { post({ kind: 'hello' }); return; }
            if (m.type !== 'message') return;
            if (m.subtype === 'message_changed' && m.message) {
              post({ kind: 'message', edited: true, channel: m.channel, ts: m.message.ts, text: m.message.text || '' }); return;
            }
            if (m.subtype === 'message_replied' || m.subtype === 'message_deleted') return;
            emit(m, m.channel, {}).catch(() => {});
          });
        }
      };
      post({ kind: 'script_loaded', top: window === window.top, url: location.origin + location.pathname });
      window.__mos = {
        async info() {
          const t = cfg(); if (!t?.token) return null;
          const j = await api('auth.test', {});
          if (!j.ok) return null;
          const im = await api('conversations.open', { users: j.user_id, return_im: 'true' });
          return { user_id: j.user_id, team: j.team, url: j.url, self_dm: im.channel?.id || null };
        },
        async thread(channel, ts) {
          const j = await api('conversations.replies', { channel, ts, limit: '200' });
          if (!j.ok) return { ok: false, error: j.error };
          const team = cfg(); const out = [];
          for (const m of (j.messages || [])) {
            if (m.subtype && !['thread_broadcast', 'file_share', 'me_message', 'bot_message'].includes(m.subtype)) continue;
            const thread = m.thread_ts && m.thread_ts !== m.ts ? m.thread_ts : '';
            out.push({ channel, ts: m.ts, thread_ts: thread, user: m.user || '', bot: !!m.bot_id, text: m.text || '',
                       user_name: await userName(m.user), channel_name: await chanName(channel),
                       permalink: team?.url ? `${team.url}archives/${channel}/p${String(m.ts).replace('.', '')}` + (thread ? `?thread_ts=${thread}&cid=${channel}` : '') : null });
          }
          return { ok: true, messages: out };
        },
        async todos(since) {
          const j = await api('saved.list', { limit: '50' });
          let max = since;
          for (const s of (j.saved_items || [])) {
            if (s.item_type !== 'message' || s.todo_state !== 'to_do' || s.state !== 'in_progress' || !(s.date_created > since)) continue;
            const h = await api('conversations.history', { channel: s.item_id, latest: s.ts, oldest: s.ts, inclusive: 'true', limit: '1' });
            let m = (h.messages || []).find((x) => x.ts === s.ts);
            if (!m) { const r = await api('conversations.replies', { channel: s.item_id, ts: s.ts, limit: '200' }); m = (r.messages || []).find((x) => x.ts === s.ts); }
            if (m) await emit(m, s.item_id, { todo: true });
            max = Math.max(max, s.date_created);
          }
          return max;
        },
        async catchUp(targets) {
          let n = 0;
          for (const t of targets) {
            const j = t.thread_ts
              ? await api('conversations.replies', { channel: t.channel, ts: t.thread_ts, oldest: t.oldest, limit: '50' })
              : await api('conversations.history', { channel: t.channel, oldest: t.oldest, limit: '50' });
            for (const m of (j.messages || [])) { if (m.ts === t.oldest) continue; await emit(m, t.channel, { catchup: true }); n++; }
            await new Promise((r) => setTimeout(r, 300));
          }
          return n;
        },
      };
    })();
    """#
}

extension SlackController: WKScriptMessageHandler, WKUIDelegate, WKNavigationDelegate {
    nonisolated func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body as? [String: Any] ?? [:]
        MainActor.assumeIsolated { handle(body) }
    }

    // SSO popups load in the same view.
    nonisolated func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        MainActor.assumeIsolated { _ = webView.load(action.request) }
        return nil
    }

    /// Links with app schemes (Okta Verify / FastPass, slack://) go to macOS so the right app can handle them.
    nonisolated func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let url = action.request.url
        MainActor.assumeIsolated {
            if let url, let scheme = url.scheme?.lowercased(), !["http", "https", "about", "blob", "data"].contains(scheme) {
                SlackController.log("open externally: \(scheme)")
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else { decisionHandler(.allow) }
        }
    }

    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        MainActor.assumeIsolated { _ = webView.reload() }
    }
}

/// Breaks the retain cycle between WKUserContentController and the controller.
final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?
    init(_ target: any WKScriptMessageHandler) { self.target = target }
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(ucc, didReceive: message)
    }
}
