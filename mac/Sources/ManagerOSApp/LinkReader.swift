import Foundation
import AppKit
import WebKit

/// Reads the text of a pasted link (Confluence, Jira, Google Docs, any page) in a hidden web view that keeps
/// its own sign-ins. If the page asks her to sign in, the window opens; reading continues once she is through.
@MainActor
final class LinkReader: NSObject, WKNavigationDelegate, WKUIDelegate {
    struct Result { var title: String?; var text: String; var ok: Bool }

    static let dataStoreID = UUID(uuidString: "6D05A1AC-0000-4000-8000-0000000AEAD0")!
    private var webView: WKWebView?
    private var window: NSWindow?
    private var busy = false

    private func setup() -> WKWebView {
        if let wv = webView { return wv }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore(forIdentifier: LinkReader.dataStoreID)
        config.preferences.inactiveSchedulingPolicy = .none
        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 800), configuration: config)
        wv.customUserAgent = SlackController.safariUA
        wv.navigationDelegate = self
        wv.uiDelegate = self
        let w = NSWindow(contentRect: wv.frame, styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "Sign in to read the link · Manager OS"
        w.isReleasedWhenClosed = false
        w.contentView = wv
        w.center()
        webView = wv; window = w
        return wv
    }

    /// Opens the reader window, e.g. to sign in to Okta / Atlassian / Google ahead of time.
    func showForSignIn(_ url: URL? = nil) {
        let wv = setup()
        if let url { wv.load(URLRequest(url: url)) } else if wv.url == nil { wv.load(URLRequest(url: URL(string: "https://www.google.com")!)) }
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }

    func read(_ url: URL, timeout: TimeInterval = 300) async -> Result {
        while busy { try? await Task.sleep(nanoseconds: 300_000_000) }
        busy = true
        defer { busy = false }
        let wv = setup()
        wv.load(URLRequest(url: url))
        let deadline = Date().addingTimeInterval(timeout)
        var shown = false, polls = 0
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            polls += 1
            guard !wv.isLoading, let cur = wv.url else { continue }
            if LinkReader.isSignInPage(cur) {
                if !shown { window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); shown = true }
                continue
            }
            guard let r = await extract(wv, original: url) else { continue }
            if LinkReader.looksLikeSignIn(r.text) {
                if !shown { window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); shown = true }
                continue
            }
            if r.text.count >= 80 || polls >= 6 {
                if shown { window?.orderOut(nil) }
                return Result(title: r.title, text: r.text, ok: r.text.count >= 80)
            }
        }
        if shown { window?.orderOut(nil) }
        return Result(title: nil, text: "", ok: false)
    }

    static func isSignInPage(_ u: URL) -> Bool {
        let host = u.host?.lowercased() ?? "", path = u.path.lowercased()
        return host.contains("okta") || host.hasPrefix("login.") || host.hasPrefix("accounts.google.") || host == "id.atlassian.com"
            || host.hasPrefix("sso.") || path.contains("/login") || path.contains("/signin") || path.contains("/saml")
    }

    /// Short pages that mostly ask to sign in (any language the page may use).
    static func looksLikeSignIn(_ text: String) -> Bool {
        guard text.count < 1500 else { return false }
        let t = text.lowercased()
        return ["sign in", "log in", "signin", "サインイン", "ログイン", "登录", "登入"].contains { t.contains($0) }
    }

    /// Google Docs/Sheets/Slides draw on a canvas, so use their plain-text export; other pages use the main content's text.
    private func extract(_ wv: WKWebView, original: URL) async -> (title: String?, text: String)? {
        let js = """
        const m = location.pathname.match(/^\\/(document|spreadsheets|presentation)\\/d\\/([^/]+)/);
        if (location.hostname === 'docs.google.com' && m) {
          const exp = { document: 'export?format=txt', spreadsheets: 'export?format=csv', presentation: 'export/txt' }[m[1]];
          try { const r = await fetch(`/${m[1]}/d/${m[2]}/${exp}`, { credentials: 'include' }); if (r.ok) return { title: document.title.replace(/ - Google (Docs|Sheets|Slides)$/, ''), text: (await r.text()).slice(0, 60000) }; } catch (_) {}
        }
        const main = document.querySelector('#main-content, [data-testid="issue.views.issue-details.issue-layout.container-left"], main, article, [role=main]') || document.body;
        return { title: document.title, text: (main.innerText || '').replace(/\\n{3,}/g, '\\n\\n').slice(0, 60000) };
        """
        guard let r = try? await wv.callAsyncJavaScript(js, arguments: [:], in: nil, contentWorld: .page) as? [String: Any] else { return nil }
        return (r["title"] as? String, r["text"] as? String ?? "")
    }

    // App links (Okta Verify FastPass) go to macOS.
    nonisolated func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let url = action.request.url
        MainActor.assumeIsolated {
            if let url, let scheme = url.scheme?.lowercased(), !["http", "https", "about", "blob", "data"].contains(scheme) {
                NSWorkspace.shared.open(url); decisionHandler(.cancel)
            } else { decisionHandler(.allow) }
        }
    }

    nonisolated func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        MainActor.assumeIsolated { _ = webView.load(action.request) }
        return nil
    }
}
