# Build and install Manager OS on this Mac (instructions for Claude Code)

You are setting up Manager OS, a native macOS app, on the user's own Mac. Build it from source here; do not
download a prebuilt app. Explain each step to the user in Simplified Chinese. Stop and ask her when a step needs
her password, her sign-in, or a decision.

What the app does on this Mac, so you can answer her questions:
- Keeps its data in `~/ManagerOS` (SQLite database, `CLAUDE.md`, `knowledge/`).
- Runs `claude -p` in `~/ManagerOS` with her Claude subscription, with no tools; the app sends the context and applies the result.
- Reads Slack through Slack's own web page inside the app, after she signs in. It never sends messages.
- Is not sandboxed and is signed ad hoc (local build only).

## 1. Check the Mac

```bash
sw_vers -productVersion        # needs 14 or later
xcode-select -p                # where the Swift toolchain comes from
swift --version
claude --version               # Claude Code must be installed and signed in
```

- If `xcode-select -p` fails, ask her to run `xcode-select --install` (a system dialog) and wait for it to finish.
- If `claude` is missing or not signed in, stop: the app needs it for every summary.

## 2. Get the source

```bash
git clone https://github.com/pengw0048/manager-os.git ~/manager-os
```

If `~/manager-os` already exists, update it instead: `git -C ~/manager-os pull --ff-only`.
If she cannot use git or GitHub, she may have a zip of the source; unzip it to `~/manager-os` and continue.

## 3. Build

```bash
cd ~/manager-os/mac
./scripts/bundle.sh
```

This runs a release build and creates `build/ManagerOS.app` (about one to three minutes the first time; it downloads
the GRDB package).

If the build fails with an error about a macro plugin (for example `@Observable` or `@State` "external macro
implementation … could not be found"), the Command Line Tools on this Mac do not include the SwiftUI macros.
Then full Xcode is needed:
1. Ask her to install Xcode from the App Store and open it once to accept the license.
2. Ask her to run `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` (needs her password).
3. Run `./scripts/bundle.sh` again.

Optional: if `node` is installed, `./scripts/test.sh` runs the core tests with a fake `claude` (no tokens).

## 4. Install and open

```bash
pkill -x ManagerOS 2>/dev/null; sleep 1
mkdir -p ~/Applications
rm -rf ~/Applications/ManagerOS.app
ditto build/ManagerOS.app ~/Applications/ManagerOS.app
open ~/Applications/ManagerOS.app
```

`~/Applications` needs no administrator rights. If her company blocks apps outside `/Applications`, ask before
copying it there instead.

## 5. First run (she does these in the app; guide her)

1. Allow notifications when macOS asks.
2. Settings (⌘,) → General → turn on "Open at login", so Slack keeps being read after a restart.
3. Settings → Slack → turn on "Connect Slack". A Slack window opens; she signs in once, then it hides itself.
4. Settings → People → "+": add her manager and other key people with "Choose from Slack…", and set a weight.
5. Optional: Settings → General → digest times; Settings → AI models.

## 6. Quick check that it works (about 15 minutes)

1. Ask a colleague to send her a Slack DM. Within about a minute it appears under "To sort" or is filed into a topic,
   and the topic gets a summary.
2. She replies in the DM. After about a minute the topic moves to "Waiting on others".
3. The colleague replies again. The topic comes back to "Needs me" and a notification appears.
4. Copy a Confluence, Jira, or Google Docs link, press ⌃⌥⌘V in any app: a new topic is created from it.
5. Put the Mac to sleep for a few minutes with a message sent meanwhile; after wake the message arrives and
   "While you were away" appears in the sidebar.

Activity (⌥⌘A) lists every Claude run with its cost. If something fails, the topic page says why.

## Updating later

```bash
cd ~/manager-os && git pull --ff-only && cd mac && ./scripts/bundle.sh
pkill -x ManagerOS 2>/dev/null; sleep 1
rm -rf ~/Applications/ManagerOS.app && ditto build/ManagerOS.app ~/Applications/ManagerOS.app && open ~/Applications/ManagerOS.app
```

Her data in `~/ManagerOS` stays; the app updates the database itself on the next launch.

## Do not

- Do not edit `~/ManagerOS/data/manager.db` or delete `~/ManagerOS`.
- Do not change Slack, Okta, or company settings; do not send anything on her behalf.
