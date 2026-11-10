import Foundation
import SwiftUI
import AppKit
import UserNotifications
import ManagerCore

enum Page: String, CaseIterable, Identifiable { case topics, knowledge, activity; var id: String { rawValue } }
enum ListView: String, CaseIterable, Identifiable { case needs, waiting, follow, all, done, archived; var id: String { rawValue } }
enum DetailTab: String, CaseIterable, Identifiable { case brief, ctx, tl, claude; var id: String { rawValue } }

struct TopicRow: Identifiable, Hashable {
    var topic: Topic
    var score: Double
    var followupDue: Bool
    /// The Settings → People entry the requester matched, if any (its weight is in the score).
    var sender: Person? = nil
    /// New Slack messages the summary has not covered yet (pending or failed refresh).
    var hasNews = false
    var id: String { topic.id }
}

struct TopicDetail {
    var topic: Topic
    var parent: Topic?
    var children: [Topic]
    var artifacts: [Artifact]
    var timeline: [TimelineEntry]
    var chat: [ChatRow]
    var jobs: [Job]
    var chatBusy: Bool { jobs.contains { $0.kind == "chat" && ($0.status == "queued" || $0.status == "running") } }
    var currentSession: (id: String, jobs: Int, cost: Double)? {
        guard let sid = topic.claudeSessionId else { return nil }
        let js = jobs.filter { $0.sessionId == sid }
        return (sid, js.count, js.reduce(0) { $0 + ($1.costUsd ?? 0) })
    }
}

@MainActor @Observable
final class AppModel {
    let store: Store
    let queue: JobQueue
    let home: String
    let slack: SlackIngest
    let slackCtl: SlackController
    var toSort: [ToSortItem] = []
    var slackNames: [String: String] = [:]
    var autoSorted: [ToSortItem] = []
    var deleting: String?
    var showingSort = false
    var showingCatchup = false
    var catchup: Catchup.Pending?
    /// Link sources being read right now.
    var readingLinks = Set<String>()
    /// Opens (or brings back) the main window; set by the window's content.
    var openMain: (() -> Void)?

    var lang: String = UserDefaults.standard.string(forKey: "lang") ?? "zh" { didSet { UserDefaults.standard.set(lang, forKey: "lang") } }
    var page: Page = .topics
    var view: ListView = .needs
    var rows: [TopicRow] = []
    var selection: String?
    var detail: TopicDetail?
    var tab: DetailTab = .brief
    var showAssistant = false
    var assistant: [ChatRow] = []
    var assistantBusy = false
    var jobs: [Job] = []
    var people: [Person] = []
    var searchText = "" { didSet { runKeywordSearch() } }
    var keywordHits: [Search.Hit] = []
    var aiAnswer: AISearchAnswer?
    var aiSearching = false
    var aiError: String?
    var expanded = Set<String>()
    var sheet: SheetKind?
    var toast: String?

    enum SheetKind: Identifiable, Equatable {
        case newTopic(parent: String?), merge(String), split(String), move(String), rename(String), transcript(String)
        var id: String { String(describing: self) }
    }

    static weak var shared: AppModel?

    init() throws {
        home = Knowledge.resolveHome()
        try Knowledge.initHome(home)
        store = try Store(path: "\(home)/data/manager.db")
        queue = JobQueue(store: store, home: home)
        slack = SlackIngest(store: store)
        slackCtl = SlackController(ingest: slack, queue: queue)
        Knowledge.exportPeople(store, home: home)
        store.onChange { [weak self] in Task { @MainActor in self?.scheduleReload() } }
        let alert: @Sendable (Topic, BriefAlert) -> Void = { t, kind in Task { @MainActor in AppModel.shared?.alert(t, kind) } }
        Task { await queue.setOnAlert(alert); await queue.refreshStale(); await queue.pump() }
        reload()
        AppModel.shared = self
        if slackCtl.enabled { slackCtl.start() }
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        tick()
    }

    func L(_ k: String) -> String { L10n.s[k].map { lang == "zh" ? $0.1 : $0.0 } ?? k }
    func pick(_ en: String, _ zh: String) -> String { lang == "zh" ? (zh.isEmpty ? en : zh) : (en.isEmpty ? zh : en) }
    func title(_ t: Topic) -> String { let s = pick(t.titleEn, t.titleZh); return s.isEmpty ? "…" : s }

    // MARK: Loading

    private var reloadPending = false
    func scheduleReload() {
        guard !reloadPending else { return }
        reloadPending = true
        Task { @MainActor in try? await Task.sleep(nanoseconds: 80_000_000); reloadPending = false; reload() }
    }

    func reload() {
        let ppl = store.people(), ids = TopicOps.slackIdsByName(store), all = store.topics()
        let kids = Dictionary(grouping: all.filter { $0.parentId != nil }, by: { $0.parentId! })
        let news = Set((try? store.read { try String.fetchAll($0, sql: """
            select distinct t.id from topics t join timeline e on e.topic_id = t.id
            where e.actor = 'slack' and e.kind = 'event' and t.last_brief_at is not null and e.at > t.last_brief_at
            """) }) ?? [])
        rows = all.map { t in
            let p = TopicOps.person(ppl, requester: t.requester, slackIds: ids[t.requester.lowercased()] ?? [])
            let u = TopicOps.effectiveUrgency(t, children: kids[t.id] ?? [])
            return TopicRow(topic: t, score: TopicOps.score(store, t, weight: p?.weight ?? 1, urgency: u), followupDue: TopicOps.followupDue(t),
                            sender: p, hasNews: news.contains(t.id))
        }
        catchup = Catchup.pending(store)
        if catchup == nil { showingCatchup = false }
        if let sel = selection, let t = store.topic(sel) { loadDetail(t.mergedInto ?? sel) }
        else if selection == nil || store.topic(selection!) == nil { selection = listItems().first?.row.id; if let s = selection { loadDetail(s) } else { detail = nil } }
        assistant = store.chat(of: nil)
        jobs = store.jobs()
        assistantBusy = jobs.contains { $0.kind == "assistant" && ($0.status == "queued" || $0.status == "running") }
        people = store.people()
        levels = store.levels()
        toSort = slack.pendingItems()
        slackNames = slack.userNames()
        autoSorted = slack.recentAuto()
        if toSort.isEmpty && autoSorted.isEmpty { showingSort = false }
        if !searchText.isEmpty { runKeywordSearch() }
    }

    func loadDetail(_ id: String) {
        guard let t = store.topic(id) else { detail = nil; return }
        if selection != id { selection = id }
        detail = TopicDetail(topic: t, parent: t.parentId.flatMap(store.topic), children: store.children(t.id), artifacts: store.artifacts(of: t.id),
                             timeline: store.timeline(of: t.id), chat: store.chat(of: t.id), jobs: store.jobs(of: t.id))
    }

    func select(_ id: String) { page = .topics; tab = .brief; showingSort = false; showingCatchup = false; loadDetail(id) }
    func row(_ id: String) -> TopicRow? { rows.first { $0.id == id } }

    func acceptSort(_ item: ToSortItem, topicId: String?, newTitle: String) {
        run {
            let t = try slack.accept(item.id, topicId: topicId, newTitle: newTitle.isEmpty ? nil : newTitle)
            Task { await queue.enqueueBrief(t, trigger: ("Slack conversation added", "加入了 Slack 对话")) }
        }
    }
    func ignoreSort(_ item: ToSortItem) { run { try slack.ignore(item.id) }; reload() }
    func restoreSort(_ item: ToSortItem) { run { try slack.restore(item.id) }; reload() }

    /// Moves a piece of context to another topic; both briefs refresh (the old one from a fresh session).
    func moveArtifact(_ artifactId: String, from: String, to: String) {
        do { try TopicOps.moveArtifact(store, artifactId, from: from, to: to) } catch { flash(describe(error)); return }
        flash(L("moved") + " → " + (store.topic(to).map(title) ?? ""))
        Task {
            await queue.enqueueBrief(to, trigger: ("Context moved here", "移入了资料"))
            await queue.enqueueBrief(from, trigger: ("Context moved away", "移走了资料"))
        }
    }

    /// Drop payloads: "artifact|<id>|<from topic>" (context) or "sort|<to-sort id>".
    func drop(_ payloads: [String], on topicId: String) -> Bool {
        var done = false
        for p in payloads {
            let parts = p.split(separator: "|").map(String.init)
            if parts.count == 3, parts[0] == "artifact" { moveArtifact(parts[1], from: parts[2], to: topicId); done = true }
            else if parts.count == 2, parts[0] == "sort", let it = (toSort + autoSorted).first(where: { $0.id == parts[1] }) {
                if let aid = it.artifactId, let from = it.filedTopicId { moveArtifact(aid, from: from, to: topicId) }
                else {
                    if it.status == "skipped" { run { try slack.restore(it.id) } }
                    acceptSort(it, topicId: topicId, newTitle: "")
                }
                done = true
            }
        }
        return done
    }

    func matches(_ r: TopicRow) -> Bool { matches(r, in: view) }
    func matches(_ r: TopicRow, in view: ListView) -> Bool {
        let t = r.topic
        if view == .archived { return t.isArchived }
        if t.isArchived { return false }
        switch view {
        case .needs: return t.status == .needsMe || r.followupDue // a due reminder stays in the inbox until handled
        case .waiting: return t.status == .waiting
        case .follow: return r.followupDue
        case .all: return t.status != .done
        case .done: return t.status == .done
        case .archived: return true
        }
    }
    func count(_ v: ListView) -> Int { rows.filter { $0.topic.parentId == nil && matches($0, in: v) }.count }

    /// Top-level rows, highest score first.
    func visibleTop() -> [TopicRow] { rows.filter { $0.topic.parentId == nil }.sorted { $0.score > $1.score } }

    var levels: [Level] = []
    func level(_ u: Urgency) -> Level { levels.first { $0.id == u.rawValue } ?? Level.defaults[u.rank] }
    func levelName(_ u: Urgency) -> String { let l = level(u); return pick(l.nameEn, l.nameZh) }
    func setReminder(_ id: String, _ iso: String?) { patch(id) { $0.remindAt = .some(iso) } }
    func saveLevel(_ l: Level) { run { try store.write { try l.save($0) } } }
    /// Due reminders in their own section above the rest, so they do not push urgent new topics down.
    func listSections() -> (due: [(row: TopicRow, child: Bool)], rest: [(row: TopicRow, child: Bool)]) {
        let items = listItems()
        var due: [(row: TopicRow, child: Bool)] = [], rest: [(row: TopicRow, child: Bool)] = [], inDue = false
        for it in items {
            if !it.child { inDue = it.row.followupDue && view != .done && view != .archived }
            if inDue { due.append(it) } else { rest.append(it) }
        }
        return (due, rest)
    }

    /// Top-level rows in view, each followed by its sub-topics.
    func listItems() -> [(row: TopicRow, child: Bool)] {
        var out: [(TopicRow, Bool)] = []
        for r in visibleTop() {
            let kids = rows.filter { $0.topic.parentId == r.id }.sorted { $0.score > $1.score }
            let show = matches(r), kidShow = kids.filter(matches)
            guard show || !kidShow.isEmpty else { continue }
            out.append((r, false))
            for k in (show ? kids.filter { $0.topic.status != .done || view == .done || view == .archived } : kidShow) { out.append((k, true)) }
        }
        return out
    }

    // MARK: Actions

    func run(_ f: () throws -> Void) { do { try f() } catch { flash(describe(error)) } }

    func describe(_ e: Error) -> String {
        switch e as? TopicError {
        case .notFound: return L("e_notFound")
        case .cycle: return L("e_cycle")
        case .badMerge: return L("e_badMerge")
        case nil: return pick(AppModel.explain(e), AppModel.explain(e, zh: true))
        }
    }

    /// A Claude or job error in words she can act on.
    static func explain(_ e: Any, zh: Bool = false) -> String {
        let s = String(describing: e)
        let l = s.lowercased()
        if l.contains("spawn failed") || l.contains("no such file") || l.contains("env: claude") || l.contains("command not found") {
            return zh ? "找不到 Claude Code（claude 命令）。请先安装，或设置 CLAUDE_BIN。" : "Claude Code (the claude command) was not found. Install it or set CLAUDE_BIN."
        }
        if l.contains("login") || l.contains("log in") || l.contains("authenticat") || l.contains("api key") || l.contains("oauth") {
            return zh ? "Claude Code 没有登录。请在终端运行 claude 并登录。" : "Claude Code is not signed in. Run claude in Terminal and sign in."
        }
        if l.contains("timed out") { return zh ? "Claude 太久没有回应（超时）。" : "Claude took too long and was stopped (timeout)." }
        if l.contains("unparseable") || l.contains("structured_output") { return zh ? "读不懂 Claude 的回答。" : "Claude's answer could not be read." }
        return String(s.prefix(160))
    }
    func flash(_ s: String) { toast = s; Task { try? await Task.sleep(nanoseconds: 3_500_000_000); if toast == s { toast = nil } } }

    func patch(_ id: String, _ build: (inout TopicPatch) -> Void) { var p = TopicPatch(); build(&p); run { try TopicOps.patch(store, id, p) } }

    func createTopic(title: String, text: String, url: String, requester: String, parent: String?) {
        run {
            let link = url.trimmingCharacters(in: .whitespacesAndNewlines)
            let t = try TopicOps.create(store, title: title, text: text, url: link, parentId: parent, requester: requester)
            if !link.isEmpty && text.isEmpty, let a = store.artifacts(of: t.id).first { readLink(topicId: t.id, artifactId: a.id, url: link, trigger: ("New topic from a link", "从链接新建事项")) }
            else { Task { await queue.enqueueBrief(t.id, trigger: ("New topic", "新建事项")) } }
            if view != .all && view != .needs { view = .needs }
            select(t.id)
        }
    }
    func addContext(_ id: String, title: String, url: String, content: String) {
        run {
            let link = url.trimmingCharacters(in: .whitespacesAndNewlines)
            let a = try TopicOps.addContext(store, topicId: id, title: title, url: link, content: content)
            if !link.isEmpty && content.isEmpty { readLink(topicId: id, artifactId: a.id, url: link, trigger: ("New link in context", "context 里加了新链接")) }
            else { Task { await queue.enqueueBrief(id, trigger: ("New context item", "新的 context")) } }
        }
    }

    let linkReader = LinkReader()

    /// Fill a link's context item, then refresh the brief: Slack links fetch and track the thread; other links are read as pages.
    /// Slack links are only read through the Slack connection, never in the link reader (which would show Slack's sign-in).
    func readLink(topicId: String, artifactId: String, url: String, trigger: (String, String)) {
        readingLinks.insert(artifactId)
        Task {
            defer { readingLinks.remove(artifactId) }
            let slackLink = SlackIngest.parsePermalink(url)
            if slackLink != nil && slackCtl.enabled {
                for _ in 0..<45 where !slackCtl.isConnected { try? await Task.sleep(nanoseconds: 1_000_000_000) } // Slack may still be starting
            }
            if let p = slackLink {
                if slackCtl.isConnected, let events = await slackCtl.fetchThread(channel: p.channel, threadTs: p.threadTs), !events.isEmpty {
                    run { try slack.attachThread(topicId: topicId, artifactId: artifactId, events: events, threadKey: "\(p.channel):\(p.threadTs)") }
                    let place = events.first.map { $0.isDM ? "DM" : "#\($0.channelName)" } ?? "Slack"
                    run { try TopicOps.fillArtifact(store, topicId: topicId, artifactId: artifactId, title: "Slack thread · \(place)",
                                                    content: (store.artifacts(of: topicId).first { $0.id == artifactId }?.content) ?? "", ok: true) }
                } else {
                    let why = slackCtl.enabled ? ("Slack could not read the thread", "Slack 没能读取这个 thread") : ("Connect Slack in Settings to read Slack links", "请先在设置里连接 Slack，才能读取 Slack 链接")
                    run { try TopicOps.fillArtifact(store, topicId: topicId, artifactId: artifactId, title: nil, content: "", ok: false, why: why) }
                }
            } else if let u = URL(string: url), u.scheme?.hasPrefix("http") == true {
                let r = await linkReader.read(u)
                run { try TopicOps.fillArtifact(store, topicId: topicId, artifactId: artifactId, title: r.title, content: r.text, ok: r.ok) }
            }
            await queue.enqueueBrief(topicId, trigger: trigger)
        }
    }

    /// ⌘⇧V: a link or text on the clipboard becomes a new topic.
    func pasteAsTopic() {
        let s = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !s.isEmpty else { flash(L("clipboardEmpty")); return }
        let isLink = !s.contains(" ") && !s.contains("\n") && (URL(string: s)?.scheme?.hasPrefix("http") ?? false)
        createTopic(title: "", text: isLink ? "" : s, url: isLink ? s : "", requester: "", parent: nil)
    }
    func retryLink(_ topicId: String, _ a: Artifact) {
        guard let u = a.url else { return }
        readLink(topicId: topicId, artifactId: a.id, url: u, trigger: ("You asked to read the link again", "你要求重新读取链接"))
    }
    func refreshBrief(_ id: String) { Task { await queue.enqueueBrief(id, trigger: ("You asked to refresh the brief", "你要求刷新简报")) } }
    func merge(_ id: String, into: String) { run { try TopicOps.merge(store, id, into: into) }; select(into); Task { await queue.enqueueBrief(into, trigger: ("Topics merged", "事项合并")) } }
    func split(_ id: String, title: String, artifacts: [String], timeline: [Int64], asSub: Bool) {
        run {
            let n = try TopicOps.split(store, id, title: title, artifactIds: artifacts, timelineIds: timeline, asSub: asSub)
            Task { await queue.enqueueBrief(n.id, trigger: ("Split from another topic", "从其他事项拆分")); await queue.enqueueBrief(id, trigger: ("Part of the topic was split out", "部分内容被拆分出去")) }
            select(n.id)
        }
    }
    func archive(_ id: String) { run { try TopicOps.archive(store, id) }; flash(L("archived")) }
    func unarchive(_ id: String) { run { try TopicOps.unarchive(store, id) } }
    func delete(_ id: String) { run { try TopicOps.delete(store, id) }; selection = nil; reload() }
    func sendChat(_ id: String, _ text: String) { let t = text.trimmingCharacters(in: .whitespacesAndNewlines); guard !t.isEmpty else { return }; Task { await queue.enqueueChat(id, text: t) } }
    func sendAssistant(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines); guard !t.isEmpty else { return }
        let page = self.page.rawValue, sel = self.page == .topics ? selection : nil
        Task { await queue.enqueueAssistant(t, page: page, topicId: sel) }
    }
    func undo(_ chat: ChatRow, _ i: Int) { run { try queue.undo(chatId: chat.id!, index: i) } }
    func confirm(_ chat: ChatRow, _ i: Int, _ ok: Bool) { Task { do { try await queue.confirm(chatId: chat.id!, index: i, ok: ok) } catch { flash(describe(error)) } } }

    func runKeywordSearch() {
        aiAnswer = nil; aiError = nil
        keywordHits = searchText.trimmingCharacters(in: .whitespaces).isEmpty ? [] : ((try? Search.keyword(store, searchText)) ?? [])
    }
    func runAISearch(includeArchived: Bool = true) {
        let q = searchText.trimmingCharacters(in: .whitespaces); guard !q.isEmpty else { return }
        aiSearching = true; aiError = nil
        Task {
            do { aiAnswer = try await queue.aiSearch(q, includeArchived: includeArchived) } catch { aiError = describe(error) }
            aiSearching = false
        }
    }

    func savePerson(_ p: Person) { run { try store.write { try p.save($0) } }; Knowledge.exportPeople(store, home: home) }
    func addPerson() { savePerson(Person(name: "")) }
    func deletePerson(_ id: String) { run { try store.write { try $0.execute(sql: "delete from people where id = ?", arguments: [id]) } }; Knowledge.exportPeople(store, home: home) }

    func openInTerminal(_ sessionId: String) {
        let cmd = "cd '\(home.replacingOccurrences(of: "'", with: ""))' && claude --resume \(sessionId)"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "tell application \"Terminal\" to do script \"\(cmd)\"", "-e", "tell application \"Terminal\" to activate"]
        try? p.run()
    }

    func tick() {
        let due = TopicOps.tick(store).filter { $0.level.notify != "none" || canInterrupt($0.topic) }
        if due.count > 3 {
            // After sleep many reminders come due at once: one notification with the count instead of one each.
            AppModel.notify(L("remindersN").replacingOccurrences(of: "{n}", with: "\(due.count)"),
                            due.prefix(4).map { title($0.topic) }.joined(separator: " · "), sound: due.contains { $0.level.notify == "interrupt" })
        } else {
            for r in due {
                let name = pick(r.level.nameEn, r.level.nameZh), vip = canInterrupt(r.topic)
                AppModel.notify("\(name) · \(L(r.repeated ? "stillOpen" : "reminder"))", title(r.topic), sound: r.level.notify == "interrupt" || vip,
                                topicId: r.topic.id, timeSensitive: vip)
            }
        }
        if let kind = Catchup.tick(store), let p = Catchup.pending(store) {
            let c = Catchup.counts(store, Catchup.changes(store, since: p.since))
            AppModel.notify(L("cu_" + kind.rawValue), countsLine(c), sound: false, catchup: true)
            Task { await queue.digestOverview(since: p.since) }
        }
        catchup = Catchup.pending(store)
    }

    func countsLine(_ c: Catchup.Counts) -> String {
        [("cu_changed", c.topics), ("cu_needs", c.needsMe), ("cu_reminders", c.remindersDue), ("cu_dueToday", c.dueToday)]
            .map { L($0.0).replacingOccurrences(of: "{n}", with: "\($0.1)") }.joined(separator: " · ")
    }

    /// The requester may interrupt her (Settings → People → Can interrupt): always, or when the topic is due today.
    func canInterrupt(_ t: Topic) -> Bool {
        guard let p = row(t.id)?.sender ?? TopicOps.sender(store, t.requester) else { return false }
        let dueToday = t.dueAt.flatMap(parseISO).map { Calendar.current.isDateInToday($0) } ?? false
        return p.canInterrupt == "always" || (p.canInterrupt == "if_due_today" && dueToday)
    }

    /// A finished brief raised urgency to Now/Today, or new messages put the topic back on her.
    func alert(_ t: Topic, _ kind: BriefAlert) {
        if NSApp.isActive && selection == t.id { return } // she is looking at it
        let u = t.aiUrgency == .P0 ? Urgency.P0 : t.urgency // escalation to P0 notifies even under a lower manual level
        let l = level(u), vip = canInterrupt(t)
        guard l.notify != "none" || vip else { return }
        let head = kind == .backToHer ? L("n_backToHer") : L("n_raised").replacingOccurrences(of: "{level}", with: pick(l.nameEn, l.nameZh))
        AppModel.notify(head, title(t), sound: l.notify == "interrupt" || vip, topicId: t.id, timeSensitive: vip || u == .P0)
    }

    func openFromNotification(topic: String?, catchup: Bool) {
        if let topic, store.topic(topic) != nil { select(topic) }
        else if catchup, self.catchup != nil { page = .topics; showingSort = false; showingCatchup = true }
        openMain?()
        NSApp.activate(ignoringOtherApps: true)
    }

    static func notify(_ title: String, _ body: String, sound: Bool = true, topicId: String? = nil, timeSensitive: Bool = false, catchup: Bool = false) {
        guard Bundle.main.bundleIdentifier != nil, ProcessInfo.processInfo.environment["MOS_NOTIFY"] != "0" else { return }
        let c = UNMutableNotificationContent(); c.title = title; c.body = String(body.prefix(200)); c.sound = sound ? .default : nil
        var info: [String: Any] = [:]
        if let topicId { info["topic"] = topicId }
        if catchup { info["catchup"] = true }
        c.userInfo = info
        if timeSensitive { c.interruptionLevel = .timeSensitive }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    /// Starts macOS Dictation in the focused text field.
    static func dictate() { NSApp.sendAction(Selector(("startDictation:")), to: nil, from: nil) }
}

/// Shows banners while the app is in front, and opens the topic (or the digest) when she clicks a notification.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()
    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification, withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound, .list])
    }
    func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse, withCompletionHandler done: @escaping () -> Void) {
        let info = r.notification.request.content.userInfo
        let topic = info["topic"] as? String, catchup = info["catchup"] as? Bool ?? false
        DispatchQueue.main.async { MainActor.assumeIsolated { AppModel.shared?.openFromNotification(topic: topic, catchup: catchup) } }
        done()
    }
}

extension Urgency { @MainActor var color: Color { Color(hex: AppModel.shared?.level(self).color ?? Level.defaults[rank].color) } }

extension Color {
    init(hex: String) {
        let v = UInt64(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x888888
        self.init(red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }
    var hex: String {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .gray
        return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}

/// "in 2 h" / "2 h overdue" style label for a reminder time.
func reminderLabel(_ iso: String, zh: Bool, now: Date = Date()) -> (String, Bool) {
    guard let d = parseISO(iso) else { return (iso, false) }
    let mins = Int(d.timeIntervalSince(now) / 60), overdue = mins < 0, a = abs(mins)
    let span = a < 60 ? (zh ? "\(a) 分钟" : "\(a) min") : a < 1440 ? (zh ? "\(a / 60) 小时" : "\(a / 60) h") : (zh ? "\(a / 1440) 天" : "\(a / 1440) d")
    let f = DateFormatter(); f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : "MM-dd HH:mm"
    if overdue { return (zh ? "已过 \(span)" : "\(span) overdue", true) }
    return ("\(f.string(from: d)) (\(zh ? "\(span)后" : "in \(span)"))", false)
}

func fmtTime(_ iso: String?) -> String {
    guard let iso, let d = parseISO(iso) else { return "" }
    let f = DateFormatter()
    f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : "MM-dd HH:mm"
    return f.string(from: d)
}
func fmtN(_ n: Int?) -> String { let n = n ?? 0; return n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1e6) : n >= 1000 ? "\(n / 1000)k" : "\(n)" }
