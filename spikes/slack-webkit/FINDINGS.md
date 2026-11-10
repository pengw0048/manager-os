# Slack WebKit spike — findings (2026-11-09)

Goal: confirm that Slack web can run inside a `WKWebView` in a native macOS app, and that the app
can read new messages from it, so the native app does not need to drive Chrome. The Playwright
spike (`../slack-browser/FINDINGS.md`) already showed the same flow works in Chrome.

Setup: `Sources/SlackWebKitSpike/main.swift` + `hook.js`, a SwiftPM executable (Swift 6.4.2,
macOS 27.2, Xcode 27.2). `WKWebView` with `WKWebsiteDataStore(forIdentifier:)` (fixed UUID),
`customUserAgent` set to a Safari 26.2 UA, Web Inspector on. `hook.js` is a `WKUserScript` at
document start, all frames, `.page` content world; it subclasses `window.WebSocket` and posts frames to
a `WKScriptMessageHandler`. Tested for ~3.5 minutes on a test workspace, including one restart.

Run: `swift build && ./.build/debug/SlackWebKitSpike` (from this folder).

## Results

| Question | Result |
|----------|--------|
| Slack web runs in `WKWebView` | Works. `app.slack.com/client` loaded with the Safari UA; no "unsupported browser" page. |
| Sign in once, keep it | Works. The user signed in in the spike window (no `window.open` popup was needed). After killing and restarting the process, the client opened signed in, with no prompt, 5 s after launch. |
| Where the websocket lives | In the page, not a worker. `wss://wss-primary.slack.com/` is created by the main frame (`app.slack.com/client`), so the page-level `WebSocket` wrap sees it. The only `Worker` created was reCAPTCHA's on the sign-in page. Slack also registers `service-worker.js`, but it does not own the socket. |
| Real-time messages from the websocket | Works. Frames are plain JSON strings (no binary, no non-JSON). 21 `message` events in ~2.5 min signed in, from channels (`C…`) and DMs (`D…`). |
| Thread replies | Same as Chrome: each reply is a `message` with `thread_ts`, plus a `message_replied` event for the parent. |
| Read a full thread | Works. `conversations.replies` through `callAsyncJavaScript` in the page (`fetch('/api/…')`, token read from `localStorage` inside the page) returned `ok: true` 5/5, including full channel threads of 6 and 4 messages. The token never reached Swift. |
| Other frame types seen | `hello`, `pong`, `presence_change`, `subscription_update`, `reconnect_url`, `im_marked`, `update_global_thread_state`, `thread_subscribed`, `badge_counts_updated`, `activity`, `visits_changed`, `user_typing`. Same family as Chrome. |
| Websocket reconnects | One socket per run here; no reconnect seen in ~1 min per run (Chrome saw two in ~2 min). The wrap is on the constructor, so any new socket is also caught. |

## What failed or needed a fix

- `message_changed` and `message_replied` carry `thread_ts` inside `m.message`, not at the top level.
  The first version missed it and fetched a single message (`count: 1`) instead of the parent thread.
  `hook.js` now reads `m.thread_ts ?? m.message?.thread_ts`.
- Nothing else failed: no navigation errors, no web content process crash, no blocked schemes.

## Implications for the design

- Host Slack in the app's own `WKWebView`. The Node + Playwright sidecar is not needed.
- Use a fixed `WKWebsiteDataStore(forIdentifier:)` so the sign-in survives restarts; a bare
  executable has no bundle, and in the real app the bundle id gives a stable store too.
- The message handler lives in the `.page` world, so Slack's own scripts could see
  `window.webkit.messageHandlers.slackSpike`. Accept this for now, or move the frame parsing into an
  isolated world later if it matters.
- Keep the in-page API calls in the page and return only the fields we need; this matches the
  Playwright spike and keeps the token out of the app.
- All earlier notes still apply: filter bots early, resolve `<@U…>` with `users.info`, catch up with
  `conversations.history` after each `hello`, use `im_marked` / `channel_marked` for "already read",
  throttle in-page API calls.

## Not tested yet

- Google / Okta SSO popups (`window.open`): the spike loads them in the same view, but this sign-in
  did not use one.
- Long runs (hours/days): SSO expiry, memory use of the WebKit content process.
- Window hidden, minimized or off-screen, and Mac sleep: WebKit may throttle timers and the socket.
- Enterprise Grid workspaces (`localConfig_v2` layout may differ).
- Message deletes (`message_deleted`).

## Local data

`events.jsonl`, `spike.log` and `spike.run1.log` contain clipped real message text; all are
git-ignored. Delete them when no longer needed. The WebKit data store (cookies, sign-in) is under
`~/Library/WebKit/SlackWebKitSpike/`.
