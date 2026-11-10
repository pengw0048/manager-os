// Spike: host Slack web in a WKWebView; capture new messages from its websocket
// and read a thread through an in-page API call.
import AppKit
import WebKit

let spikeDir = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let eventsFile = spikeDir.appendingPathComponent("events.jsonl")
let hookSource = try! String(contentsOf: URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().appendingPathComponent("hook.js"), encoding: .utf8)

// Fixed id so the sign-in survives restarts (stored under ~/Library/WebKit/<process>/WebsiteDataStore/<id>).
let dataStoreID = UUID(uuidString: "5A1C7E00-0000-4000-8000-00000000510C")!
let safariUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.2 Safari/605.1.15"

func stamp() -> String {
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f.string(from: Date())
}

func jsonString(_ obj: Any) -> String {
    guard JSONSerialization.isValidJSONObject(obj),
          let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return "\(obj)" }
    return String(decoding: d, as: UTF8.self)
}

func log(_ tag: String, _ obj: [String: Any] = [:]) {
    print("[\(stamp())] \(tag) \(jsonString(obj))")
    fflush(stdout)
}

func record(_ obj: [String: Any]) {
    var o = obj
    o["at"] = ISO8601DateFormatter().string(from: Date())
    let line = Data((jsonString(o) + "\n").utf8)
    if let h = try? FileHandle(forWritingTo: eventsFile) {
        h.seekToEndOfFile(); h.write(line); try? h.close()
    } else {
        try? line.write(to: eventsFile)
    }
}

// Reads a thread from inside the page. The token is read and used in the page only; it never reaches Swift.
let threadFetchJS = """
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
        ok: j.ok, error: j.error ?? null, base, count: j.messages?.length ?? 0,
        messages: (j.messages || []).map((m) => ({ ts: m.ts, user: m.user ?? null, text: (m.text || '').slice(0, 80) })),
      };
    }
  } catch (e) { if (base === bases.at(-1)) return { ok: false, error: String(e), base }; }
}
"""

let signedInJS = """
const cfg = JSON.parse(localStorage.getItem('localConfig_v2') || '{}');
const id = cfg.lastActiveTeamId;
return id ? { id, name: cfg.teams?.[id]?.name ?? null, url: cfg.teams?.[id]?.url ?? null } : null;
"""

final class Spike: NSObject, WKScriptMessageHandler, WKUIDelegate, WKNavigationDelegate {
    var window: NSWindow!
    var webView: WKWebView!
    var frameTypes: [String: Int] = [:]
    var lastFetch = Date.distantPast
    var signedIn = false

    func start() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore(forIdentifier: dataStoreID)
        let ucc = config.userContentController
        ucc.addUserScript(WKUserScript(source: hookSource, injectionTime: .atDocumentStart,
                                       forMainFrameOnly: false, in: .page))
        ucc.add(self, contentWorld: .page, name: "slackSpike")

        webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = safariUA
        webView.isInspectable = true
        webView.uiDelegate = self
        webView.navigationDelegate = self

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 860),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "Slack WebKit spike"
        window.contentView = webView
        window.center()
        window.makeKeyAndOrderFront(nil)

        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            log("SUMMARY", ["frames": self.frameTypes])
        }
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.checkSignedIn() }

        webView.load(URLRequest(url: URL(string: "https://app.slack.com/client")!))
        log("READY", ["note": "Sign in to Slack in the window, then send yourself a DM or reply in a thread.",
                      "events": eventsFile.path])
    }

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard var body = message.body as? [String: Any], let kind = body["kind"] as? String else { return }
        switch kind {
        case "frame":
            let t = body["type"] as? String ?? "?"
            frameTypes[t, default: 0] += 1
        case "message":
            frameTypes["message", default: 0] += 1
            body["main_frame"] = message.frameInfo.isMainFrame
            record(body)
            log("MESSAGE", body)
            let channel = body["channel"] as? String
            let ts = (body["thread_ts"] as? String) ?? (body["ts"] as? String)
            if let channel, let ts { maybeFetchThread(channel: channel, ts: ts) }
        default:
            body["main_frame"] = message.frameInfo.isMainFrame
            record(body)
            log(kind.uppercased(), body)
        }
    }

    func maybeFetchThread(channel: String, ts: String) {
        guard Date().timeIntervalSince(lastFetch) > 20 else { return }
        lastFetch = Date()
        webView.callAsyncJavaScript(threadFetchJS, arguments: ["channel": channel, "ts": ts],
                                    in: nil, in: .page) { result in
            var ev: [String: Any] = ["kind": "thread_fetch", "channel": channel, "ts": ts]
            switch result {
            case .success(let v):
                if let d = v as? [String: Any] { ev.merge(d) { a, _ in a } } else { ev["ok"] = false; ev["error"] = "no_result" }
            case .failure(let e):
                ev["ok"] = false; ev["error"] = e.localizedDescription
            }
            record(ev)
            log("THREAD_FETCH", ev.filter { $0.key != "messages" })
        }
    }

    func checkSignedIn() {
        guard !signedIn else { return }
        webView.callAsyncJavaScript(signedInJS, arguments: [:], in: nil, in: .page) { [weak self] result in
            if case .success(let v) = result, let team = v as? [String: Any] {
                self?.signedIn = true
                log("SIGNED_IN", team)
                record(["kind": "signed_in", "team_name": team["name"] ?? NSNull()])
            }
        }
    }

    // window.open (SSO popups): load in the same web view.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        log("POPUP", ["url": navigationAction.request.url?.absoluteString.components(separatedBy: "?").first ?? ""])
        webView.load(navigationAction.request)
        return nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let scheme = navigationAction.request.url?.scheme ?? ""
        if !["http", "https", "about", "blob", "data"].contains(scheme) {
            log("BLOCKED_SCHEME", ["url": navigationAction.request.url?.absoluteString.prefix(80).description ?? ""])
            decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        log("LOADED", ["url": webView.url?.absoluteString.components(separatedBy: "?").first ?? ""])
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        log("NAV_FAIL", ["error": error.localizedDescription])
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        log("NAV_FAIL", ["error": error.localizedDescription])
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        log("WEB_PROCESS_TERMINATED")
        webView.reload()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let spike = Spike()
    func applicationDidFinishLaunching(_ n: Notification) {
        spike.start()
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool {
        log("WINDOW_CLOSED"); return true
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
