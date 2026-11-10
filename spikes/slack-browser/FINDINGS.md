# Slack browser spike — findings (2026-11-09)

Goal: confirm that Slack web, driven by Playwright in real Chrome, can be the app's Slack source
without installing a Slack app (REQUIREMENTS.md §7a, option A).

Setup: `spike.mjs`, Playwright 1.64.1, `channel: 'chrome'` (Chrome 157), persistent profile in
`.profile/`. Tested for ~2.5 minutes on a test workspace.

## Results

| Question | Result |
|----------|--------|
| Sign in once, keep it | Works. SSO + email code in the spike window; session is stored in `.profile/`. |
| Default Chrome profile | Not possible: Chrome 136+ blocks remote debugging on the default profile, and the profile must not be in use. A separate profile is required. |
| Real-time messages from the websocket | Works. `page.on('websocket')` sees `wss://wss-primary.slack.com/`; frames are plain JSON. 14 `message` events in ~2 min, from channels (`C…`) and DMs (`D…`). |
| Thread replies | Each reply arrives as a `message` with `thread_ts`, plus a `message_replied` event on the parent. Enough to map replies to a topic without AI. |
| Read a full thread | Works. `conversations.replies` called from inside the page (`fetch('/api/…')`, token read from `localStorage` inside the page) returned `ok: true` 3/3. The credential never left the page. |
| Other frame types seen | `reaction_added`, `user_typing`, `presence_change`, `channel_marked`, `im_marked`, `badge_counts_updated`, `subscription_update`, `reconnect_url`, `hello`, `pong`. `channel_marked` / `im_marked` show when she reads something in Slack — useful to clear "needs me". |
| Websocket reconnects | The client reconnected twice in ~2 min (close + new socket within 1 s). `page.on('websocket')` picks up each new socket. |

## Implications for the design

- Option A is viable. Keep it.
- Filter bots early: most traffic in a busy workspace is bot messages (job notifications here).
- Message `text` uses Slack markup (`&lt;@U…&gt;`, `:emoji:`). Resolve user IDs to names with
  `users.info` (in-page, cached) before showing text or sending it to Claude.
- Reconnect gap: after each `hello`, catch up with `conversations.history` for watched channels
  since the last seen `ts`, so nothing is lost between sockets.
- Use `channel_marked` / `im_marked` to learn what she already read in Slack.
- Throttle in-page API calls (the spike used one call per 20 s) to stay within normal client rates.

## Not tested yet

- Long runs (hours/days): SSO expiry, memory use of the Chrome process.
- Behavior when the window is minimized or the Mac sleeps.
- Enterprise Grid workspaces (her company's Slack may be Grid; `localConfig_v2` layout may differ).
- Message edits/deletes (`message_changed`, `message_deleted` subtypes).

## Local data

`events.jsonl` and `spike.log` contain clipped real message text; both are git-ignored. Delete
them when no longer needed.
