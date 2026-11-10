# Manager OS (native macOS)

Native macOS app (SwiftUI). An earlier local web version (M0) was removed after this reached parity. Design: [../REQUIREMENTS.md](../REQUIREMENTS.md).

It uses the same home folder (`~/ManagerOS`: `CLAUDE.md`, `knowledge/`, `data/manager.db`) and the
same database schema as M0, so existing data carries over.

## Build and run

Requires full Xcode for the app target (SwiftUI's `@State` macro ships only with Xcode). The core
library and its tests build with Command Line Tools alone.

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer   # once, after installing Xcode
./scripts/test.sh          # core tests, uses Tests/Fixtures/fake-claude.mjs (no tokens spent)
./scripts/bundle.sh        # builds build/ManagerOS.app (ad-hoc signed, no sandbox)
open build/ManagerOS.app
```

Or open `Package.swift` in Xcode and run the `ManagerOS` scheme.

Environment variables (same as M0): `MANAGER_OS_HOME`, `CLAUDE_BIN`, `MOS_MODEL_*`, `MOS_EFFORT_*`
(`BRIEF`, `CHAT`, `ASSISTANT`, `SEARCH`), `MOS_NOTIFY=0`.

## Layout

| Path | What it does |
|------|--------------|
| `Sources/ManagerCore/Models.swift` | Records for topics, artifacts, timeline, chat, jobs, people. |
| `Sources/ManagerCore/Store.swift` | GRDB database, schema, change notifications. |
| `Sources/ManagerCore/TopicOps.swift` | Create, patch, merge, split, archive, delete, score, follow-ups, auto-archive. |
| `Sources/ManagerCore/ClaudeRunner.swift` | One `claude -p` call with a JSON schema (reads pipes concurrently). |
| `Sources/ManagerCore/Prompts.swift` | Schemas, system prompts, full/delta context, capped assistant and search prompts. |
| `Sources/ManagerCore/JobQueue.swift` | Actor: 2 jobs at a time, one per topic; chat actions, undo/confirm, AI search. |
| `Sources/ManagerCore/Search.swift` | Keyword search: FTS5 over bigram-expanded text. |
| `Sources/ManagerCore/Knowledge.swift` | Home folder, knowledge files, `people.md`, session transcripts. |
| `Sources/ManagerOSApp/` | SwiftUI app: window, sidebar + search, topic detail, assistant inspector, knowledge, activity, settings, menu bar. |

The app is not sandboxed: it runs `claude`, reads `~/.claude/projects/…`, and writes `~/ManagerOS`.
