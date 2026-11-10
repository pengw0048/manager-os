# Manager OS — Requirements & Design (v0 draft)

A local macOS app that helps an Engineering Manager triage incoming requests, keep track of
follow-ups, and get AI-prepared context before she opens an topic. AI runs through the local
Claude CLI on her own subscription.

## 1. Problems to solve

| # | Problem | What the app must do |
|---|---------|----------------------|
| P1 | High-priority work (leadership asks, incidents) gets delayed because lower-priority messages grab attention first | Score every topic and show the highest-score topic first; only interrupt for high scores |
| P2 | Threads that need a follow-up are forgotten | Every topic has an owner state and a `next_followup_at`; the app resurfaces it |
| P3 | Context switching is expensive | When an topic arrives, AI starts investigating at once and writes a brief; opening the topic shows everything needed |
| P4 | Response time matters, but a human is slow | AI pre-work (brief, draft reply, open questions) is ready before she looks |
| P5 | Meetings create commitments that get lost | Zoom transcripts are parsed into new topics and updates to existing topics |

## 2. Core entity: Topic

Everything in the app is a view or a background job over two entities: **Topic** (one thing to
handle; 中文 UI label: 事项) and **Artifact** (a piece of context). An Topic works like a project in
Claude: it is a space that holds its artifacts, and every AI job on the Topic gets them as context.

```
Topic
  id
  parent_id             # null for a top-level topic; set for a sub-topic
  title                 # AI-written, editable
  kind                  # request | incident | follow_up | decision | fyi
  requester             # person who asked
  people[]              # everyone involved
  status                # new | investigating | needs_me | waiting_on_others | snoozed | done
  urgency               # P0..P3
  urgency_source        # auto | manual
  urgency_pinned_until  # manual urgency holds until this time (null = until changed)
  urgency_history[]     # {from, to, by: ai|me, reason, at}
  score                 # number used for sorting (see §4)
  due_at                # explicit or AI-inferred deadline
  next_followup_at      # when the app resurfaces this topic
  ai_brief              # {en, zh} markdown: summary, context, findings, next step, draft reply
  ai_brief_updated_at
  claude_session_id     # session reused by background jobs and the "Ask Claude" box
  timeline[]            # TimelineEntry: every new message / transcript mention / status change / merge / split
  created_at, last_activity_at, last_touched_by_me_at

Artifact
  id
  type                  # slack_thread | email_thread | transcript | doc | file | link | note | ai_output
  title
  url_or_path
  content_snapshot      # cached text, so AI jobs work without re-fetching
  ai_summary            # {en, zh} short summary, regenerated when the content changes
  added_by              # me | ai | ingest
  topic_ids[]            # many-to-many: one transcript can belong to several topics
```

Rules:

- One real-world "thing" = one Topic, even when it spans Slack, email, and a meeting.
  New messages are matched to an existing Topic first (same thread → same Topic; otherwise AI
  proposes a match and she confirms).
- An incoming Slack thread or email becomes an Artifact attached to the Topic. Its link and
  `ai_summary` show on the Topic.
- She can attach anything as context: a link, a file, a note, a transcript, an AI answer from
  "Ask Claude". AI jobs on the Topic read all attached artifacts, so she never re-pastes context.
- A sub-topic sees its own artifacts plus its parent's artifacts.
- `status` drives follow-up:
  - `needs_me` → stays in the inbox until she acts.
  - `waiting_on_others` → app sets `next_followup_at` (default +2 working days) and resurfaces it
    if nobody replied.
  - `snoozed` → hidden until `next_followup_at`.

### Topic operations (user-driven)

The user owns the structure. The AI never merges, splits, or moves topics on its own, and the UI
does not show unsolicited merge/split suggestions.

| Operation | What happens |
|-----------|--------------|
| New topic | She creates a topic from a title, or from a pasted link / text / file. The AI then writes the brief. |
| Merge A into B | B keeps its id. A's artifacts, timeline, and sub-topics move to B. A becomes a redirect so later messages from A's threads land in B. B's brief is regenerated. |
| Split | She selects timeline entries and artifacts from a topic and moves them to a new topic (or an existing one). Both briefs are regenerated. |
| Make sub-topic / promote | Move a topic under another topic, or promote a sub-topic to the top level. |
| Move artifact | Move or copy an artifact to another topic. |
| Undo | Every operation is logged in the timeline and can be undone. |

### Incoming items without a topic ("To sort")

A new Slack thread, email, or transcript that does not belong to a known thread goes to a
"To sort" list. The AI pre-fills a target topic for each one (one structured-output call); she
confirms, changes the target, creates a new topic, or ignores it.

## 3. Inputs

| Source | v1 approach | Later option | Notes |
|--------|-------------|--------------|-------|
| Slack | Slack user token: DMs, mentions, threads she replied in, selected channels | Slack app with events API | Needs Slack workspace admin approval — see open questions |
| Email | Gmail / Outlook API, filtered to inbox + starred | — | Same approval question |
| Zoom transcript | Watch the local folder where transcripts are saved (`.vtt`), or paste | Zoom API (cloud recordings) | Folder watch needs no API approval |
| Calendar | Read today's meetings to attach transcripts and prep briefs | — | |
| Manual | Global hotkey: paste a link or text, or forward to the app | Share extension | Always available; the fallback for every source |
| Incident tools | Read-only links that she can open (incident page, dashboards, runbooks) | — | No write access, no prod access |

## 4. Prioritization

Use explicit rules for the score so she can understand and tune it. Use the LLM only to fill
the fields the rules need.

```
score = sender_weight × urgency_weight × deadline_factor × staleness_factor
```

| Factor | Source | Example |
|--------|--------|---------|
| `sender_weight` | People list she edits (see below) | Her manager / skip-level = 3.0, peer EMs = 1.5, her reports = 1.5, unknown = 1.0, bots = 0.3 |
| `urgency_weight` | LLM classifies P0..P3 with a one-line reason | P0 (active incident, exec ask with today deadline) = 5, P3 = 0.5 |
| `deadline_factor` | `due_at` explicit or inferred | Grows as the deadline gets closer |
| `staleness_factor` | Time since the requester last heard from her | Grows after 1 working day without reply |

Overrides: channel or keyword rules (e.g. `#incident-*` → P0, "FYI" → P3).

### People

She maintains the list herself; the app does not need an org-chart integration.

```
Person
  name
  relationship        # manager | skip_level | peer | report | partner | other
  slack_handle, email, zoom_display_name   # used to match messages and transcript speakers
  weight              # sender_weight
  can_interrupt       # never | if_due_today | always
  notes               # free text, given to the AI as context ("cares about cost", "prefers short updates")
```

### Manual and automatic urgency

- **Auto**: the AI re-evaluates urgency whenever the Topic gets new activity (new message,
  deadline moved, transcript mention). Every change is logged with a reason in
  `urgency_history` and shown on the Topic.
- **Manual**: she can set urgency at any time, optionally with an expiry ("P3 until Monday").
  While a manual value holds, the AI does not change it. If the AI thinks it should change, it
  writes one line under the urgency control on that topic ("AI would set P1: director asked
  again"); no popup. One exception: escalation to P0 always notifies her, even when a lower
  manual value is set.
- Her manual corrections are stored and fed back into the classifier prompt as examples.
- A parent Topic's urgency is at least the highest urgency of its open sub-topics.

## 5. Notification tiers

| Tier | Trigger | How the app notifies |
|------|---------|----------------------|
| Interrupt | P0, or VIP with a deadline today | macOS notification with sound, menu-bar icon turns red, stays until acknowledged |
| Next break | P1 | Silent notification; batched and shown when her calendar shows a gap between meetings |
| Digest | P2/P3 | Morning digest and end-of-day digest |
| Follow-up | `next_followup_at` reached | Appears in the "Follow-ups due" section; one daily notification with the count |

Focus mode: during a meeting or a focus block, only the Interrupt tier gets through.

## 6. AI pre-work

When a new Topic appears (or an existing one gets new activity), the app runs a job:

1. Summarize the thread and state the actual ask in one sentence.
2. Gather context she can access: linked docs, PRs, tickets, earlier related Topics, meeting
   mentions.
3. For incidents: build a timeline, list what is known and unknown, and list hypotheses for the
   root cause with evidence links. The AI does not run commands against production.
4. Suggest a next step and draft a reply (never sent automatically).
5. Write the result into `ai_brief`, update `urgency` / `due_at` if the new information changes
   them.

The brief must be self-contained so she never has to paste context into a separate Claude
session. The topic's Claude tab (§6a) continues the same session with the brief loaded.

### Meeting processing

After a meeting ends and its transcript appears:

1. Store the transcript as an Artifact with an AI summary.
2. Split the transcript into segments. For each segment, pre-fill a target topic (existing or
   new) and attach the transcript with the segment's time range.
3. Extract action items with owner. Owned by her → `needs_me`. Owned by others →
   `waiting_on_others` with a follow-up date.
4. The transcript appears in "To sort"; she confirms or changes each segment in one screen.

### AI tools and permissions

Background jobs run `claude -p` with a local MCP server that exposes only these tools. Each
write tool can be turned off in Settings.

| Tool | Kind | Default |
|------|------|---------|
| `get_topic`, `search_topics`, `read_artifact`, `get_person` | read | on |
| `fetch_url` (links she attached; read-only) | read | on |
| `write_brief(topic_id, brief_en, brief_zh)` | write, own field | on |
| `summarize_artifact(artifact_id, summary_en, summary_zh)` | write, own field | on |
| `set_auto_urgency(topic_id, level, reason)` | write; ignored while urgency is manual | on |
| `set_due_date(topic_id, due_at, reason)` | write; ignored if she set the date | on |
| `prefill_sort_target(incoming_id, topic_id \| new_title)` | write, suggestion only | on |
| `add_related_artifact(topic_id, url, reason)` | write, marked "added by AI" | off |

| `propose_knowledge(file, line, source_topic_id)` | write, suggestion only | on |

Background jobs have no tools for merge, split, status changes, or sending messages. The
assistant (§6c) has more tools, but only acts after she confirms each write.

## 6a. UI

- Layout: topic list on the left, selected topic on the right (mail-client style). A view
  selector at the top of the list (Needs me / Waiting / Follow-up due / All / Done) and a
  "To sort" entry with a count.
- Topic page: header (title, urgency control, status, follow-up date), sub-topics, then tabs:
  Brief / Context / Timeline / Claude. Merge, split, and move live in a "⋯" menu.

### Timeline: every entry opens its source

```
TimelineEntry
  at, actor             # slack | email | zoom | incident | claude | me
  summary               # {en, zh}, one line: "3 new messages: hotfix ETA 40 min"
  source_url            # where the event happened
  raw_refs[]            # the underlying messages / transcript range, shown when expanded
```

- Click the chevron → the entry expands in place and shows the raw content: the actual Slack
  messages (author, time, text), the email, or the transcript lines.
- Click "Open ↗" → the source opens in its own app:
  - Slack: the message permalink (`https://<workspace>.slack.com/archives/<channel>/p<ts>`); Slack
    opens it in the desktop app at that message.
  - Incident: the incident page in the incident-management tool.
  - Transcript: the app's transcript viewer, scrolled to the time range.
  - Email: the message in the mail client.
  - Claude: the matching run in the Claude tab.
- Context items work the same way: expand to see the cached snapshot, or open the source.

### Claude tab (per topic)

One place for every conversation Claude had about this topic.

- Shows the topic's sessions (topic session, investigation forks) with a filter chip per session.
- Background runs appear as collapsed cards ("14:33 · update after 3 new messages · 38 s ·
  $0.21"); expanding one shows what Claude read and which tools it called.
- Her own messages and Claude's replies sit in the same stream; she writes or speaks here.
- Claude can act on the topic from the chat:
  - Read: brief, context items, timeline, transcripts.
  - Additive changes she asks for (add a timeline entry, add a context item or note, update the
    brief) run immediately and show "Undo".
  - Structural changes (merge, split, move, status, urgency) show a confirmation card first.
- The global assistant drawer (§6c) is for questions across topics; it uses its own session.
- No banners or popups inside the app. Interrupt-tier alerts use macOS notifications only.
- Top bar: Topics, Knowledge, Assistant (⌘K), New topic, EN / 中文, Settings.
- Settings: People, Rules, Notifications, AI permissions, Language.

## 6b. Knowledge

General work knowledge (where things live in Confluence, who owns what, team norms, unwritten
knowledge) is not stored in the app DB. It lives as Markdown in a Claude Code project folder,
so Claude Code loads it with no extra retrieval system.

- Folder `~/ManagerOS/`: `CLAUDE.md` (role, team, preferences, links to the files below) and
  `knowledge/*.md` (`where-to-find.md`, `systems.md`, `team.md`, ...).
- Every `claude -p` job runs with this folder as cwd. One `@import` line in her user-level
  `~/.claude/CLAUDE.md` makes the same knowledge available in her own Claude Code sessions.
- Settings → People is exported to `knowledge/people.md` (read-only in the editor).
- Background jobs do not edit knowledge files on their own. Turn off Claude Code auto memory
  for app jobs (confirm the setting name in the installed CLI) and use `propose_knowledge`
  instead.

### What she already knows

`knowledge/me.md` records her background so Claude explains the right amount:

```
## Know well — do not explain
- Incident process, on-call, SLOs
## Learning — explain in one line
- Kubernetes autoscaling
## New to me — explain fully with an example
- Storage engine internals of the query service
```

Each brief marks terms it explained. She can click a term → "I know this" or "Explain more";
the click becomes a proposed line for `me.md`. A glossary file (`knowledge/glossary.md`) keeps
explanations Claude already gave, so it reuses them.

This stays plain Markdown. Claude Code loads `CLAUDE.md` and reads other files on demand with
its own search tools. A retrieval system (embeddings, an agent-memory service) is only worth it
if the knowledge grows far beyond what fits in a few files; revisit then.

Knowledge page: file list, a plain editor, and helpers that she starts herself:

| Helper | What it does |
|--------|--------------|
| Interview me | Claude finds gaps and asks short questions, one at a time. Each answer is written to the right file and can be undone. |
| Tidy up this file | Removes duplicates, groups related lines, shortens wording. Shown as a list of changes; she applies each one. |
| Check what is outdated | Compares facts with recent topics and with how long ago each line was confirmed. Each finding: Still true / Update / Remove. |
| Learned from recent topics | Facts Claude noticed while working on topics. Nothing is saved until she adds it. Shown only on this page. |

## 6c. Assistant

A chat drawer available on every page (button or ⌘K), so she can work by talking instead of
clicking, without opening a separate Claude app.

- Knows the current page and topic. Answers from topics and knowledge.
- Acts on the UI through tools: `navigate`, `create_topic`, `update_topic` (urgency, status,
  follow-up), `merge_topics`, `split_topic`, `move_topic`, `attach_artifact`, `edit_knowledge`.
- Every write shows a confirmation card in the chat; nothing changes until she taps Confirm.
  Implementation: `claude -p --permission-prompts host --permission-prompt-tool <app tool>`, so
  the app renders each permission request as the card.
- Never sends messages; it writes drafts with a Copy button.
- "Interview me" on the Knowledge page uses the same drawer.

Voice input (Chinese and English mixed):

| Option | Pros | Cons |
|--------|------|------|
| macOS Dictation | Built in, no work; works in any text field | Needs a key press; weaker on mixed zh/en |
| Web Speech API | Easy in a browser UI | Chrome sends audio to Google; not available in every webview |
| Local whisper.cpp, push-to-talk | Offline; handles mixed zh/en well | Model download (0.5–1.5 GB); uses CPU/GPU |

Recommendation: macOS Dictation in M0, local whisper.cpp in a later milestone.

### Language

- The UI has an EN / 中文 switch. All UI strings exist in both languages.
- Every AI-written text (brief, summaries, urgency reasons, draft replies) is generated in both
  English and Chinese in the same call and stored as `{en, zh}`. The switch changes the display
  only; no re-generation.
- Draft replies default to the language of the source thread; the other language is shown for
  reference.

## 7. Claude integration

| Option | How | Pros | Cons |
|--------|-----|------|------|
| A. `claude -p` subprocess (recommended for v1) | `claude -p --output-format json --resume <session>` per job, with an MCP config for the app's own tools | Uses the existing CLI login and subscription; simple; each Topic can keep its own session id | Process start overhead per job; concurrency limited by subscription rate limits |
| B. Claude Agent SDK (TypeScript/Python) | Long-running agent in the app process | Better control of tools, streaming, cancellation | Need to confirm subscription auth is allowed for a background app |
| C. Anthropic API key | Direct API | Most control, predictable | Separate billing; not the subscription the user wants to use |

The app exposes its data to Claude as a small local MCP server (`get_topic`, `search_topics`,
`update_brief`, `propose_topic`), so the same tools work in the background jobs and in the
interactive "Ask Claude" box.

Budget: a job queue with a concurrency limit (e.g. 2) and a per-day job cap, so background work
does not use up the subscription quota she needs for interactive use.

### M0 implementation (first built as a web app, now in `mac/`)

M0 uses structured output instead of an MCP server; MCP is deferred.

- Every job is `claude -p --output-format json --json-schema <schema> --tools "" --strict-mcp-config
  --setting-sources project --effort <level>`, run in the home folder, with the prompt on stdin.
  - `--setting-sources project` loads the home folder's `CLAUDE.md` (and its `@knowledge/…`
    imports) but not her user-level `~/.claude/CLAUDE.md`. Verified on this machine.
  - The app sends the context in the prompt and applies the JSON result itself.
- Tradeoff: Claude cannot read more on demand (no tools); the app must put the right context in
  the prompt. In exchange there is no MCP server and no permission-prompt plumbing.
- The behavior contract stays: the chat schema returns `actions[]`. Additive actions
  (`add_timeline`, `add_note`, `create_subtopic`) apply at once with undo. Structural actions
  (`set_status`, `set_urgency`, `set_followup`) and every assistant action wait for Confirm.
- Measured (Sonnet, one incident topic): effort `high` (default) took 129 s, 14.8k output tokens,
  $0.27; effort `low` took 19 s, 2.3k output tokens, $0.08 with similar brief quality. Defaults:
  brief `low`, chat `medium`, assistant `low` (env `MOS_EFFORT_*`).
- Prompt cache: brief → brief on the same session read 12.6k cached tokens and wrote 2.2k. Brief
  and chat use different system prompts and schemas, so a chat turn after a brief does not hit
  the cache. Possible later fix: one system prompt and one union schema for the topic session.

## 7a. Ingestion and AI runtime

### Getting new data (no AI involved)

| Source | Option | Notes |
|--------|--------|-------|
| Slack | See "Slack without installing an app" below | Installing a Slack app in her workspace is not possible. |
| Zoom (A) | Watch the local Zoom folder for saved captions (`~/Documents/Zoom/<meeting>/…closed_caption.txt`) | Works only if "save captions" is enabled for her meetings. |
| Zoom (B) | Zoom API: download the cloud-recording transcript (`.vtt`) after the meeting ends | Needs a Zoom OAuth app; transcripts exist only for cloud-recorded meetings. |
| Zoom (C) | Drop a transcript file onto the app | Always works. |

### Slack without installing an app

| Option | How | Pros | Cons |
|--------|-----|------|------|
| A. Browser as the Slack client (recommended) | Playwright drives real Chrome with a persistent profile; she signs in to Slack web once (SSO). The app listens to the page's real-time websocket frames (`page.on('websocket')`) for new messages, and calls Slack's API from inside the page (same calls the web client makes) to read full threads. | Real time; sees exactly what she sees; no app install; no token handling in our code | Unofficial: Slack can change the web client at any time; one Chrome process (~300–500 MB); SSO may expire and need a re-login; automation may be visible to the company's security tools |
| B. Session token from the browser (xoxc + `d` cookie) | Call the Web API directly with the web client's credentials (approach used by tools like slackdump) | Simple; no browser running | Handles a live credential; looks like an unusual client to security monitoring; against the spirit of Slack's terms. Not recommended. |
| C. macOS notifications | Read Slack's notifications from Notification Center | No access to Slack itself | Only DMs/mentions, truncated text; the notification store location and access rules change across macOS versions (unverified on the current version) |
| D. Slack email notifications | Turn on email notifications for DMs and mentions; ingest from email | Official; no automation | Delayed (Slack batches emails); only DMs/mentions |
| E. Manual | Paste a Slack link or text, or use Slack's "Copy link" + global hotkey | Always works | Manual |

Decision: A is the Slack source; E is always available. Spike done on 2026-11-09: websocket
frames are plain JSON with `thread_ts`, and in-page `conversations.replies` works
(see `spikes/slack-browser/FINDINGS.md`). A separate Chrome profile is required (Chrome blocks
automation on the default profile); she signs in once.
Update (same day): the native app hosts Slack in its own `WKWebView` instead (see
`spikes/slack-webkit/FINDINGS.md`): the websocket lives in the page, `message` frames with
`thread_ts` arrive, in-page `conversations.replies` worked 5/5, and the sign-in survives restarts.
No Chrome or Node sidecar is needed.

The ingest layer stores raw messages in SQLite and maps them to topics without AI:
same Slack thread / email thread → same topic. Rules (§4) run here too, so an `#incident-*`
mention notifies her within seconds, before any AI runs.

### What Slack messages are kept

A message is kept (mapped thread → topic, otherwise → "To sort") when it is one of:
- a DM to her, or a message that mentions her;
- a reply in a thread she has posted in, or a message in a watched channel;
- a note to self: anything in her DM with herself (found with `conversations.open users=<self>`);
- a Slack to-do: a message she marks as a to-do in "Later". The app polls `saved.list` every 60 s
  and takes items with `todo_state = to_do` created after the last poll. The first poll only sets
  the starting point, so older to-dos are not imported. A to-do is kept even on her own message or
  a bot message.

### When AI runs: debounce and batching

Calling Claude per message would be slow and wasteful. Measured on this machine: a minimal
`claude -p` call with no tools already sends about 9.5k tokens of system context; with the
default tool set, about 31k (mostly cache reads after the first call). So the app batches.

| Event | What runs | When |
|-------|-----------|------|
| New messages on a known topic | Topic job with all new messages since the last job | After 60 s with no new message on that topic, or at most 5 min after the first new message (P0 topics: 20 s / 2 min) |
| Messages that match no topic | One triage call for the whole batch | Every 5 min, if the batch is not empty |
| Bots, muted channels, her own messages | No AI; her own reply only updates `last_touched_by_me_at` and may clear `needs_me` | — |
| P2/P3 topics | Brief updates are batched | Hourly, or when she opens the topic |
| Transcript | Meeting job | Once, when the file appears |

### Session types

Each AI purpose has its own kind of session. All run as `claude -p` with `--output-format json`,
in the `~/ManagerOS/` folder, through one job queue (concurrency 2, priority: assistant > P0 >
P1 > rest).

| Session | Model | Lifetime | Tools | Output |
|---------|-------|----------|-------|--------|
| Triage | Haiku | One call per batch, no persistence (`--no-session-persistence`) | none (`--tools ""`), `--json-schema` | target topic / new / ignore, urgency, is-it-for-me |
| Topic | Sonnet | One session per topic, resumed with `--resume` | read tools, `write_brief`, `set_auto_urgency`, `fetch_url` | brief, urgency, due date |
| Investigation | Opus | Forked from the topic session (`--resume <id> --fork-session`), started when she clicks "Investigate" or the topic is P0 | adds Confluence / code / dashboard MCP servers she configured | findings appended to the brief |
| Meeting | Sonnet | One per transcript | read tools, `prefill_sort_target` | segments, action items |
| Knowledge | Sonnet | Daily, plus when she runs a helper | read tools, `propose_knowledge` | learned facts, outdated lines |
| Assistant | Sonnet | One session per day, resumed | all assistant tools; writes need confirmation | chat |

### New replies on a known thread

Debounce decides *when* to call Claude; resuming decides *how*:

1. Skip with a rule, no AI: emoji-only replies, "thanks", "+1", her own messages.
2. Otherwise resume the topic's session (`--resume <session_id>`) and send only the new
   messages since the last job. Earlier messages, artifacts, and the previous brief are already
   in the session, so Claude gets more context while the app sends fewer new tokens.
3. Claude answers in one structured result: `changed: false` (only timeline updated) or an
   updated brief / urgency / due date.

Cost: resumed context is served from the prompt cache. Measured on this machine, `claude -p`
writes the cache with a 1-hour TTL (`ephemeral_1h_input_tokens` in `usage`), so a reply within an
hour of the last job mostly costs cache reads. After the cache expires, the whole session is
written to the cache again.

A topic session is not resumed forever. The brief is the topic's real memory: when a topic
session passes ~100k tokens, or the cache has expired and the session is large, the next job
starts a new session seeded with the brief and the artifact summaries.

### Sleep and wake

Everything runs on her Mac, so nothing is ingested while it sleeps. The app is designed to
tolerate sleep, not to prevent it:

- While AI jobs are running, the app holds `caffeinate -i -w <app pid>` so an idle sleep does
  not cut a job in half. Closing the lid still sleeps the Mac.
- Keeping the Mac awake all the time (Amphetamine, or a "stay awake" switch in Settings) is
  optional: it lets overnight messages be processed so the morning view is ready, at the cost
  of battery and subscription quota.
- On wake (detected by a gap in a 10 s heartbeat timer, or the websocket `hello` after a
  reconnect):
  1. Catch up from the last seen `ts`: `conversations.history` for watched channels and DMs,
     `search.messages` for mentions, run in-page.
  2. Feed the backlog through the normal pipeline (rules → topic mapping → batched AI jobs).
  3. Re-run jobs that were interrupted by sleep (the job queue lives in SQLite).
  4. Show a "While you were away" summary at the top of the topic list.
- Urgent pages while the Mac sleeps still reach her through Slack mobile and the paging tool;
  the app is not the alerting system of record.

### Visibility ("AI activity" page)

Every job is logged from the `claude -p` JSON result, which includes `session_id`,
`duration_ms`, `num_turns`, `usage` (input, output, cache read, cache write tokens), and
`total_cost_usd` (list-price estimate; the subscription is not billed per call).

- Totals for today / 7 days: tokens by type, estimated cost, jobs by session type.
- Job list: time, session type, topic, model, trigger, duration, tokens, cost, status.
- Session list: one row per session with its purpose and topic.
  - "View transcript": the app reads `~/.claude/projects/<folder>/<session_id>.jsonl`.
  - "Open in terminal": runs `claude --resume <session_id>` in Terminal, in `~/ManagerOS/`,
    so she can continue the same session interactively.
- Daily budget and the job queue (running / waiting) are shown on the same page.

## 7c. Archive, delete, and keeping prompts small

Topics pile up over months. The working set stays small; history stays searchable.

| Action | Where | What happens |
|--------|-------|--------------|
| Rename | Topic "⋯" menu and right-click on a row | Sets the title; Claude no longer renames it. |
| Archive | Same menu | The topic and its sub-topics leave every list except "Archived" and every AI prompt; keyword and AI search still find them (marked "Archived"). New context or activity on an archived topic moves it back. |
| Auto-archive | Background check every minute | Done top-level topics with no activity for 14 days (setting `auto_archive_days`; 0 turns it off). Logged on the topic's timeline. |
| Delete | Same menu, with a confirmation that offers Archive instead | Removes the topic, its timeline, chat, and context only it used. Sub-topics move up a level. Job history stays so cost totals remain correct. |

Prompt size limits, so nothing grows with the number of topics:

| Prompt | Bound |
|--------|-------|
| Topic brief / chat | One session per topic; only that topic's context. Restarts from the brief after ~100k tokens. |
| Assistant | Open, non-archived topics only, top 40 by score (plus the open topic); the prompt says how many were left out. |
| AI search index | Non-archived by default; at most 150 topics, keyword matches first. |
| Triage (future Slack / transcript sorting) | Same rule as the assistant: titles of open topics, capped. |

## 7d. Reminders, urgency levels, and pasted links (built 2026-11-09)

Reminders replace follow-up dates:
- "Remind me" quick picks: in 1 hour, in 3 hours, tomorrow 9:00, next Monday 9:00, or any date and time.
- A reminder is only the first nudge. From its time until she handles it (Done, a new time, or Clear) the
  topic stays at the top of the inbox with "N h overdue", whatever its status.
- While unhandled, it repeats at its level's interval. Setting "Waiting on others" adds a reminder in two
  working days at 9:00. A new topic gets its level's first reminder automatically.

Urgency levels: the four slots P0–P3 stay (sorting and the AI schema rely on a fixed set), but she
names each one and sets its rules in Settings → Urgency levels:

| Field | Default (P0 / P1 / P2 / P3) |
|-------|-----------------------------|
| Name (en / zh) | Incident 事故 / Today 今天 / This week 本周 / FYI 仅供参考 |
| Description for Claude (used in the brief prompt to pick a level) | incident or manager within hours / due today or blocking / this week / no deadline |
| Notify | sound + banner / banner / banner / none |
| First reminder | at once / 2 h / 1 day / none |
| Repeat while open | 30 min / 3 h / 1 day / none |
| Breaks focus | yes / no / no / no |

Pasted links (New topic, Context, or ⌘⇧V "New topic from clipboard"):
- Slack permalink: the whole thread is fetched inside the Slack page and stored; the thread is mapped to the
  topic, so later replies land there through the normal Slack pipeline.
- Confluence, Jira, any page: read in a separate hidden web view with its own saved sign-ins. If the page
  asks for sign-in (by URL or by its text), the window opens; reading continues once she is through.
- Google Docs / Sheets / Slides: read through their plain-text / CSV export (the editor draws on a canvas).
- Sign-in notes: Okta FastPass links are handed to macOS so Okta Verify can answer. Passkeys do not work in
  an embedded web view (Apple limits WebAuthn to browsers and the site's own apps); use OTP or a push
  instead. Sign-in is needed once per session lifetime of each service.

## 7b. Search

One search box at the top of the topic list (⌘F). Two modes:

| Mode | How | When |
|------|-----|------|
| Keyword (instant, no AI) | SQLite FTS5 (`unicode61`) over a bigram-expanded copy of topic titles and briefs (en + zh), context items (title, content, summaries), timeline summaries, and chat text. Before indexing, each run of CJK characters is expanded into its single characters plus overlapping bigrams (`回滚计划` → `回 滚 计 划 回滚 滚计 计划`); Latin text stays as words. The query is expanded the same way and matched as a phrase, so `回滚` and `rollback pla*` both work. Results are ranked with BM25 and grouped by topic with a snippet. | As you type |
| AI search | One Haiku call (`--effort low`, no tools, `--json-schema`) with the query plus a compact index of all topics, done ones included: id, titles, status, urgency, dates, first lines of the brief, context summaries. Returns ranked topic ids, a one-line reason each (en + zh), and an optional short answer. The index is sent as the system prompt and the query as the message, so repeated searches can read the index from the cache. Archived topics are included only when asked; above 150 topics, keyword matches and the most recent topics are sent first. | Press Enter on "Ask AI", or when keyword search finds nothing |

Examples AI search handles and keyword search does not: "the thing about the partner team's
API date", "上个月和 SRE 讨论容量的那个", "what did I promise the Director last week". The
assistant drawer uses the same search to find topics.

Why bigrams instead of `trigram` or `LIKE` (measured on this Mac, 20k documents, 33 MB of
mixed Chinese/English text — far more than she will have):

| Approach | `回滚大概` | 2-character query | Ranking |
|----------|-----------|-------------------|---------|
| `LIKE '%…%'` | 50 ms (full scan) | works | none |
| FTS5 `trigram` | fast | does not match (needs ≥ 3 characters) | BM25 |
| FTS5 `unicode61` + bigram expansion | 0.1 ms | 0.0 ms | BM25 |

No extra search engine is needed: the bigram trick runs on plain SQLite with no custom
tokenizer. Core Spotlight or a separate engine (Tantivy, Meilisearch) would add a dependency
without a clear gain at this size.

If the index grows past ~150k tokens, pre-filter with FTS on the query terms before calling
Claude. No embeddings in v1: there is no local embedding model, and Claude reranking is enough at
this scale.

## 8. Platform options

Decision 2026-11-09: native SwiftUI app (N1). M0 was first built as a local web app (option A); the native app in `mac/` reached parity the same day (plus search and archive) and the web app was removed. Slack moves from Playwright to a
`WKWebView` inside the app (needs a spike).

| Option | What changes | Pros | Cons |
|--------|--------------|------|------|
| N1. SwiftUI (native) | Rewrite M0 in Swift: SQLite (GRDB or `sqlite3`), `Process` for `claude -p`, SwiftUI UI. Slack in a `WKWebView` with a page script that taps the WebSocket, replacing Playwright and Chrome. | Real Mac app: menu bar, notifications, global hotkey, Dictation, small and fast; no Node, no Chrome | Full rewrite (~3k lines); full Xcode needed for a smooth build (this Mac has only Command Line Tools); UI iteration is slower; Slack in WKWebView is unverified (needs a spike) |
| N2. Electron | Keep the TypeScript core and the current UI; replace HTTP with IPC; Slack in a hidden Electron window instead of Playwright | Little rewrite; ships in days; same web UI | Still web tech inside; large app (~200 MB); one more runtime to keep updated |
| N3. Tauri | Rust core + current web UI in the system WebView | Small app; no HTTP server | Rewrite the core in Rust; same web UI |

| Option | Pros | Cons |
|--------|------|------|
| A. Local web app (Python/Node server + browser UI) + small menu-bar helper | Fastest to build; easy to iterate on the UI | Notifications and hotkeys need the helper |
| B. Tauri / Electron desktop app | One package: tray icon, notifications, hotkey, UI | More setup; Electron is heavy |
| C. Native SwiftUI menu-bar app | Best macOS integration | Slowest to iterate; UI changes cost more |

Recommendation: start with A (SQLite + local server + browser UI + `terminal-notifier` or a tiny
menu-bar helper). Move to B only if the workflow proves useful.

## 9. Privacy and safety

- All data stays on her machine (SQLite). No cloud sync in v1.
- The app never sends a message on her behalf. Drafts only.
- Read-only access to every source.
- AI investigation uses only sources she can already open; no production access.

## 10. Open questions (need her answers)

1. ~~Company policy~~ — resolved: the app runs locally like a personal script; acceptable.
2. ~~Slack access~~ — resolved: no app install possible; use the browser-based option (§7a).
   Open: does her Slack sign-in use SSO, and how often does the web session expire?
3. **Email**: Gmail or Outlook?
4. **Zoom**: Are transcripts saved locally, in Zoom cloud, or only shown in the meeting?
5. **Other systems**: Which tools hold her work topics (Jira, Confluence, Google Docs, incident
   tool)? Which of those should the AI read?
6. **VIP list**: Who are the top senders, and what weights feel right?
7. **Interrupt rules**: What should break through focus mode? Phone push (e.g. via ntfy/Pushover)
   or Mac only?
8. **Volume**: Roughly how many Slack threads / emails per day? This sets the AI job budget.

## 11. Milestones

| Milestone | Scope |
|-----------|-------|
| M0 | Manual capture (paste link/text) → Topic → AI brief. Artifacts with AI summaries. Merge / split / sub-topics. Manual + auto urgency. Inbox sorted by score. Follow-up timer. Knowledge folder + editor. Assistant drawer (text; voice via macOS Dictation). |
| M0.5 | Knowledge helpers (interview, tidy, outdated check, learned facts). |
| M1 | Zoom transcript folder watch + meeting review screen. Calendar-aware notifications. |
| M2 | Slack and email ingestion (if policy allows). Thread-to-Topic matching. |
| M3 | Feedback loop on urgency, digests, tuning of weights. |

M0 is useful on day one before any source integration exists.

## 7e. Auto-sorting, moving context, and token use (built 2026-11-10)

- **Auto-sorting.** Triage (Haiku) picks an action per Slack conversation: `existing` (file into an open topic),
  `new` (create a topic), or `skip` (thanks / FYI). The app applies it at once; unsure items stay in To sort.
  To sort lists everything sorted or skipped automatically in the last 24 hours. Settings → Slack turns this off.
- **Moving context.** Drag a source (Sources tab) or an auto-sorted conversation onto a topic in the sidebar,
  or use "Move to". Later replies in that Slack thread follow it; the old topic's summary starts a fresh session.
- **Token use** (measured on the dev data before these changes: a brief was ~$0.10, of which ~60% output):
  - The CLI's default coding system prompt (~8.5k tokens per call) is replaced with a short one (`--system-prompt`).
  - Summaries are capped at about 180 words per language.
  - New messages on P2/P3 topics only mark the summary stale; it refreshes when she opens the topic.
    P0/P1 topics and new topics refresh at once.
  - What she reads (summary, replies, answers, reasons) is written once, in Chinese; anything meant for other
    people (draft replies) is in English. Titles stay in both languages. A real brief after this: 702 output
    tokens, $0.014, 7.7 s.
- **Models.** Settings → AI models sets the model and effort per feature (summary, ask, assistant, search, sorting).
  The Activity window (⌥⌘A) shows runs, tokens, and cost by feature and model.
