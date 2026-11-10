import Foundation
import GRDB

public struct AIConfig: Sendable {
    public var model: [String: String]
    public var effort: [String: String]
    public static func fromEnvironment() -> AIConfig {
        let env = ProcessInfo.processInfo.environment
        func v(_ k: String, _ d: String) -> String { env[k].flatMap { $0.isEmpty ? nil : $0 } ?? d }
        return AIConfig(
            model: ["brief": v("MOS_MODEL_BRIEF", "sonnet"), "chat": v("MOS_MODEL_CHAT", "sonnet"), "assistant": v("MOS_MODEL_ASSISTANT", "sonnet"),
                    "search": v("MOS_MODEL_SEARCH", "haiku"), "triage": v("MOS_MODEL_TRIAGE", "haiku"), "digest": v("MOS_MODEL_DIGEST", "sonnet")],
            effort: ["brief": v("MOS_EFFORT_BRIEF", "low"), "chat": v("MOS_EFFORT_CHAT", "medium"), "assistant": v("MOS_EFFORT_ASSISTANT", "low"),
                     "search": v("MOS_EFFORT_SEARCH", "low"), "triage": v("MOS_EFFORT_TRIAGE", "low"), "digest": v("MOS_EFFORT_DIGEST", "low")])
    }
}

public struct AISearchAnswer: Sendable {
    public struct Hit: Sendable, Hashable { public var topicId: String; public var reasonEn: String; public var reasonZh: String }
    public var answerEn: String
    public var answerZh: String
    public var hits: [Hit]
}

private let additive: Set<String> = ["add_timeline", "add_note", "create_subtopic"]
private let freshAfterTokens = 100_000

func decode<T: Decodable>(_ t: T.Type, _ dict: [String: Any], snake: Bool = true) throws -> T {
    let d = JSONDecoder()
    if snake { d.keyDecodingStrategy = .convertFromSnakeCase }
    return try d.decode(t, from: JSONSerialization.data(withJSONObject: dict))
}

/// Runs Claude jobs: 2 at a time, one per topic, highest priority first.
public actor JobQueue {
    public let store: Store
    public let home: String
    public let runner: ClaudeRunner
    public let config: AIConfig
    let concurrency: Int
    var running = Set<String>()
    var locked = Set<String>()
    var triageRunning = false
    var onAlert: (@Sendable (Topic, BriefAlert) -> Void)?

    public static let kinds = ["brief", "chat", "assistant", "search", "triage", "digest"]
    /// Model and effort per feature: Settings override the defaults (which come from the environment).
    public nonisolated func model(_ kind: String) -> String {
        store.setting("model_\(kind)").flatMap { $0.isEmpty ? nil : $0 } ?? config.model[kind] ?? "sonnet"
    }
    public nonisolated func effort(_ kind: String) -> String? {
        store.setting("effort_\(kind)").flatMap { $0.isEmpty ? nil : $0 } ?? config.effort[kind]
    }

    public init(store: Store, home: String, runner: ClaudeRunner = ClaudeRunner(), config: AIConfig = .fromEnvironment(), concurrency: Int = 2) {
        self.store = store; self.home = home; self.runner = runner; self.config = config; self.concurrency = concurrency
        try? store.db.write { db in
            // Queued kinds resume; one-shot calls (triage, search, digest) are not queued, so a cut-off run is marked as failed.
            try db.execute(sql: "update jobs set status = 'queued', started_at = null where status = 'running' and kind in ('brief','chat','assistant')")
            try db.execute(sql: "update jobs set status = 'error', error = 'interrupted', finished_at = ? where status in ('running','queued') and kind not in ('brief','chat','assistant')", arguments: [nowISO()])
            try db.execute(sql: "update topics set brief_state = 'queued' where brief_state = 'running'")
        }
    }

    public func setOnAlert(_ f: @escaping @Sendable (Topic, BriefAlert) -> Void) { onAlert = f }

    /// Topics left stale by older versions (which refreshed P2/P3 only when opened) refresh now.
    public func refreshStale() {
        let ids = (try? store.read { try String.fetchAll($0, sql: "select id from topics where brief_dirty = 1 and merged_into is null and archived_at is null and brief_state not in ('queued','running')") }) ?? []
        guard !ids.isEmpty else { return }
        try? store.write(topics: ids) { db in for id in ids { try db.execute(sql: "update topics set brief_dirty = 0 where id = ?", arguments: [id]) } }
        for id in ids { enqueueBrief(id, trigger: ("New updates", "有新内容")) }
    }

    public func enqueueBrief(_ topicId: String, trigger: (String, String)) {
        guard store.topic(topicId) != nil else { return }
        let existing = (try? store.read { try Job.fetchAll($0, sql: "select * from jobs where kind = 'brief' and topic_id = ? and status in ('queued','running')", arguments: [topicId]) }) ?? []
        if existing.contains(where: { $0.status == "queued" }) { return }
        if existing.contains(where: { $0.status == "running" }) {
            try? store.write(topics: [topicId]) { try $0.execute(sql: "update topics set brief_dirty = 1 where id = ?", arguments: [topicId]) }
            return
        }
        let m_ = model("brief")
        try? store.write(topics: [topicId]) { db in
            try Job(kind: "brief", topicId: topicId, trigger: trigger, model: m_).insert(db)
            try db.execute(sql: "update topics set brief_state = 'queued' where id = ?", arguments: [topicId])
        }
        pump()
    }

    public func enqueueChat(_ topicId: String, text: String) {
        let m_ = model("chat")
        try? store.write(topics: [topicId]) { db in
            try Store.addChat(db, ChatRow(topicId: topicId, role: "user", en: text))
            try Job(kind: "chat", topicId: topicId, trigger: ("Your question in the Ask tab", "你在“提问”标签页的问题"), model: m_, payload: json(["text": text])).insert(db)
        }
        pump()
    }

    public func enqueueAssistant(_ text: String, page: String?, topicId: String?) {
        let m_ = model("assistant")
        try? store.write { db in
            try Store.addChat(db, ChatRow(topicId: nil, role: "user", en: text))
            try Job(kind: "assistant", topicId: nil, trigger: ("Your message to the assistant", "你发给助理的消息"), model: m_,
                    payload: json(["text": text, "page": page ?? "", "topic_id": topicId ?? ""])).insert(db)
        }
        pump()
    }

    func priority(_ j: Job) -> Int {
        if j.kind != "brief" { return 0 }
        switch j.topicId.flatMap(store.topic)?.urgency { case .P0: return 1; case .P1: return 2; default: return 3 }
    }

    public func pump() {
        guard running.count < concurrency else { return }
        let queued = ((try? store.read { try Job.fetchAll($0, sql: "select * from jobs where status = 'queued' order by created_at") }) ?? [])
            .sorted { priority($0) < priority($1) }
        for j in queued where running.count < concurrency {
            if let t = j.topicId, locked.contains(t) { continue }
            running.insert(j.id)
            if let t = j.topicId { locked.insert(t) }
            Task { await self.execute(j); self.done(j) }
        }
    }

    func done(_ j: Job) {
        running.remove(j.id)
        if let t = j.topicId { locked.remove(t) }
        pump()
    }

    /// Returns when nothing is queued or running (used by tests).
    public func idle() async {
        while true {
            let queued = (try? store.read { try Bool.fetchOne($0, sql: "select exists(select 1 from jobs where status = 'queued')") }) ?? false
            if running.isEmpty && !(queued ?? false) { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func execute(_ j: Job) async {
        let started = nowISO()
        var j = j; j.startedAt = started
        try? store.write(topics: [j.topicId]) { db in
            try db.execute(sql: "update jobs set status = 'running', started_at = ? where id = ?", arguments: [started, j.id])
            if j.kind == "brief" { try db.execute(sql: "update topics set brief_state = 'running' where id = ?", arguments: [j.topicId]) }
        }
        do {
            switch j.kind {
            case "brief": try await runBrief(j)
            case "chat": try await runChat(j)
            case "assistant": try await runAssistant(j)
            default: throw ClaudeError(message: "unknown job kind \(j.kind)")
            }
        } catch {
            let msg = String(String(describing: error).prefix(500))
            try? store.write(topics: [j.topicId]) { db in
                try db.execute(sql: "update jobs set status = 'error', error = ?, finished_at = ? where id = ?", arguments: [msg, nowISO(), j.id])
                if j.kind == "brief" { try db.execute(sql: "update topics set brief_state = 'error' where id = ?", arguments: [j.topicId]) }
                else { try Store.addChat(db, ChatRow(topicId: j.topicId, role: "assistant", en: "Sorry, the request failed: \(msg.prefix(200))", zh: "抱歉，请求失败了：\(msg.prefix(200))", jobId: j.id)) }
            }
        }
    }

    /// Resume the topic session with only new context, or start fresh with the full context.
    func onTopicSession(_ j: Job, _ t: Topic, schema: String, system: String, build: (String?) -> String) async throws -> ClaudeResult {
        let fresh = t.claudeSessionId == nil || t.needsFreshSession != 0 || t.sessionTokens > freshAfterTokens
        let since = fresh ? nil : lastSync(t)
        let req = { (prompt: String, resume: String?) in
            ClaudeRequest(cwd: self.home, prompt: prompt, schema: schema, model: j.model, effort: self.effort(j.kind), systemPrompt: system, resume: resume)
        }
        do { return try await runner.run(req(build(since), fresh ? nil : t.claudeSessionId)) }
        catch let e as ClaudeError where !fresh && e.sessionNotFound { return try await runner.run(req(build(nil), nil)) }
    }

    func lastSync(_ t: Topic) -> String {
        (try? store.read { try String.fetchOne($0, sql: "select started_at from jobs where topic_id = ? and session_id = ? and status = 'done' order by started_at desc limit 1", arguments: [t.id, t.claudeSessionId]) }) ?? t.createdAt
    }

    func finish(_ db: Database, _ j: Job, _ r: ClaudeResult, topicId: String?) throws {
        try db.execute(sql: """
            update jobs set status = 'done', finished_at = ?, duration_ms = ?, session_id = ?, input_tokens = ?, output_tokens = ?, cache_read = ?, cache_write = ?, cost_usd = ? where id = ?
            """, arguments: [nowISO(), r.durationMs, r.sessionId, r.usage.input, r.usage.output, r.usage.cacheRead, r.usage.cacheWrite, r.costUsd, j.id])
        if let topicId {
            let ctx = r.usage.input + r.usage.cacheRead + r.usage.cacheWrite + r.usage.output
            try db.execute(sql: "update topics set claude_session_id = ?, session_tokens = ?, needs_fresh_session = 0 where id = ?", arguments: [r.sessionId, ctx, topicId])
        }
    }

    func runBrief(_ j: Job) async throws {
        guard let t = store.topic(j.topicId!), t.mergedInto == nil else {
            try store.write { try $0.execute(sql: "update jobs set status = 'done', finished_at = ?, error = 'topic gone' where id = ?", arguments: [nowISO(), j.id]) }
            return
        }
        let prev = try? store.read { try String.fetchOne($0, sql: "select max(started_at) from jobs where kind = 'brief' and topic_id = ? and status = 'done' and id != ?", arguments: [t.id, j.id]) }
        let r = try await onTopicSession(j, t, schema: Prompts.briefSchema, system: Prompts.briefSystem(store.levels())) { Prompts.brief(self.store, t, since: $0) }
        let brief = try decode(BriefResult.self, r.structured)
        // News is what this prompt saw that the previous brief did not; messages flushed during the run wait for the next one.
        let news = TopicOps.hasSlackNews(store, t.id, after: prev, until: j.startedAt ?? nowISO())
        let before = store.topic(t.id) ?? t
        try store.write(topics: [t.id]) { try finish($0, j, r, topicId: t.id) }
        try TopicOps.applyBrief(store, t.id, brief, jobId: j.id, news: news)
        try store.write(topics: [t.id]) { db in
            try Store.addChat(db, ChatRow(topicId: t.id, role: "run", en: "Background · \(j.triggerEn)", zh: "后台 · \(j.triggerZh)", jobId: j.id))
            try db.execute(sql: "update topics set brief_state = 'idle' where id = ?", arguments: [t.id])
        }
        let after = store.topic(t.id)!
        if after.briefDirty != 0 {
            try store.write(topics: [t.id]) { try $0.execute(sql: "update topics set brief_dirty = 0 where id = ?", arguments: [t.id]) }
            enqueueBrief(t.id, trigger: ("More updates arrived during the last run", "上次运行期间又有新内容"))
        }
        if after.urgency.rank < before.urgency.rank && after.urgency.rank <= Urgency.P1.rank { onAlert?(after, .raised) }
        else if after.aiUrgency == .P0 && before.aiUrgency != .P0 && after.urgency != .P0 { onAlert?(after, .raised) } // P0 notifies even under a manual level
        else if after.status == .needsMe && before.status != .needsMe { onAlert?(after, .backToHer) }
    }

    func runChat(_ j: Job) async throws {
        guard let t = store.topic(j.topicId!) else { throw ClaudeError(message: "topic gone") }
        let text = (try? JSONSerialization.jsonObject(with: Data((j.payload ?? "{}").utf8)) as? [String: String])?["text"] ?? ""
        let r = try await onTopicSession(j, t, schema: Prompts.chatSchema, system: Prompts.chatSystem) { Prompts.chat(self.store, t, since: $0, message: text) }
        let replyEn = r.structured["reply_en"] as? String ?? "", replyZh = r.structured["reply_zh"] as? String ?? ""
        let items = try decode([String: [ChatAction]].self, ["actions": r.structured["actions"] ?? []], snake: false)["actions"] ?? []
        var subs: [String] = []
        try store.write(topics: [t.id]) { db in
            try finish(db, j, r, topicId: t.id)
            var states: [ActionState] = []
            for a in items {
                if additive.contains(a.type) {
                    let ref = try applyAdditive(db, t.id, a)
                    if a.type == "create_subtopic" { subs.append(ref) }
                    states.append(ActionState(state: "applied", ref: ref))
                } else { states.append(ActionState(state: "pending")) }
            }
            try Store.addChat(db, ChatRow(topicId: t.id, role: "assistant", en: replyEn, zh: replyZh, jobId: j.id, actions: ChatActions(items: items), states: states))
        }
        store.changed(topics: subs)
        for s in subs { enqueueBrief(s, trigger: ("New sub-topic", "新子事项")) }
    }

    func runAssistant(_ j: Job) async throws {
        let p = (try? JSONSerialization.jsonObject(with: Data((j.payload ?? "{}").utf8)) as? [String: String]) ?? [:]
        let key = "assistant_session_\(localDay())"
        let resume = store.setting(key)
        let prompt = Prompts.assistant(store, message: p["text"] ?? "", page: p["page"], topicId: p["topic_id"].flatMap { $0.isEmpty ? nil : $0 })
        let req = { (resume: String?) in ClaudeRequest(cwd: self.home, prompt: prompt, schema: Prompts.assistantSchema, model: j.model, effort: self.effort("assistant"), systemPrompt: Prompts.assistantSystem, resume: resume) }
        let r: ClaudeResult
        do { r = try await runner.run(req(resume)) }
        catch let e as ClaudeError where resume != nil && e.sessionNotFound { r = try await runner.run(req(nil)) }
        store.setSetting(key, r.sessionId)
        let items = try decode([String: [ChatAction]].self, ["actions": r.structured["actions"] ?? []], snake: false)["actions"] ?? []
        let links = (r.structured["topic_links"] as? [String] ?? []).filter { store.topic($0) != nil }
        try store.write { db in
            try finish(db, j, r, topicId: nil)
            try Store.addChat(db, ChatRow(topicId: nil, role: "assistant", en: r.structured["reply_en"] as? String ?? "", zh: r.structured["reply_zh"] as? String,
                                          jobId: j.id, actions: ChatActions(items: items, links: links), states: items.map { _ in ActionState(state: "pending") }))
        }
    }

    func applyAdditive(_ db: Database, _ topicId: String, _ a: ChatAction) throws -> String {
        switch a.type {
        case "add_timeline":
            return String(try Store.addTimeline(db, TimelineEntry(topicId: topicId, actor: "me", kind: "note", en: a.textEn, zh: a.textZh)))
        case "add_note":
            let art = Artifact(type: "note", title: "Note", content: a.textEn, summaryEn: a.textEn, summaryZh: a.textZh, addedBy: "claude")
            try Store.insertArtifact(db, topicId: topicId, art)
            return art.id
        default:
            var sub = Topic(title: a.textEn, parentId: topicId, titleSource: "me")
            sub.titleZh = a.textZh
            try sub.insert(db)
            try Store.addTimeline(db, TimelineEntry(topicId: sub.id, actor: "claude", kind: "structure", en: "Created from the Claude tab of the parent topic", zh: "从父事项的 Claude 标签页创建"))
            return sub.id
        }
    }

    /// Undo an applied additive action.
    public nonisolated func undo(chatId: Int64, index: Int) throws {
        guard var c = try store.read({ try ChatRow.fetchOne($0, key: chatId) }), let items = c.decodedActions?.items else { throw TopicError.notFound }
        var states = c.decodedStates
        guard index < items.count, states[index].state == "applied", let ref = states[index].ref else { throw TopicError.notFound }
        try store.write(topics: [c.topicId]) { db in
            switch items[index].type {
            case "add_timeline": try db.execute(sql: "delete from timeline where id = ?", arguments: [Int64(ref)])
            case "add_note":
                try db.execute(sql: "delete from topic_artifacts where artifact_id = ?", arguments: [ref])
                try db.execute(sql: "delete from artifacts where id = ?", arguments: [ref])
            default: try db.execute(sql: "delete from topics where id = ?", arguments: [ref])
            }
            states[index] = ActionState(state: "undone")
            c.actionState = String(data: try JSONEncoder().encode(states), encoding: .utf8)
            try c.update(db)
        }
    }

    /// Confirm or cancel a pending action (topic chat or assistant).
    public func confirm(chatId: Int64, index: Int, ok: Bool) throws {
        guard var c = try store.read({ try ChatRow.fetchOne($0, key: chatId) }), let items = c.decodedActions?.items else { throw TopicError.notFound }
        var states = c.decodedStates
        guard index < items.count, states[index].state == "pending" else { throw TopicError.notFound }
        let a = items[index]
        let topicId = (a.topicId?.isEmpty == false ? a.topicId : nil) ?? c.topicId ?? ""
        if ok {
            var p = TopicPatch()
            switch a.type {
            case "set_status": p.status = TopicStatus(rawValue: a.value); try TopicOps.patch(store, topicId, p)
            case "set_urgency": p.urgency = Urgency(rawValue: a.value); try TopicOps.patch(store, topicId, p)
            case "set_followup": p.nextFollowupAt = .some(a.value); try TopicOps.patch(store, topicId, p)
            case "add_note":
                try store.write(topics: [topicId]) { try Store.insertArtifact($0, topicId: topicId, Artifact(type: "note", title: "Note", content: a.textEn, summaryEn: a.textEn, summaryZh: a.textZh, addedBy: "claude")) }
            case "create_topic":
                let t = try TopicOps.create(store, title: a.textEn)
                enqueueBrief(t.id, trigger: ("New topic from the assistant", "助理创建的新事项"))
            default: break
            }
        }
        states[index] = ActionState(state: ok ? "confirmed" : "cancelled")
        c.actionState = String(data: try JSONEncoder().encode(states), encoding: .utf8)
        try store.write(topics: [c.topicId]) { try c.update($0) }
    }

    /// Pre-fill a target topic for "To sort" items (one Haiku call for the batch). Accepting stays her decision.
    @discardableResult
    public func triage(_ slack: SlackIngest, now: Date = Date()) async throws -> Int {
        guard !triageRunning else { return 0 }
        let items = Array(slack.untriaged(now: now).prefix(15))
        guard !items.isEmpty else { return 0 }
        triageRunning = true
        defer { triageRunning = false }
        var job = Job(kind: "triage", topicId: nil, trigger: ("\(items.count) Slack conversations to sort", "\(items.count) 个 Slack 对话待归类"), model: model("triage"))
        job.status = "running"; job.startedAt = nowISO()
        try store.write { try job.insert($0) }
        do {
            let prompt = Prompts.triage(store, items: items.map { ($0, slack.messages(of: $0.id)) })
            let r = try await runner.run(ClaudeRequest(cwd: home, prompt: prompt, schema: Prompts.triageSchema, model: job.model,
                                                     effort: effort("triage"), systemPrompt: Prompts.triageSystem, persist: false))
            try store.write { try finish($0, job, r, topicId: nil) }
            let ids = Set(items.map(\.id))
            let auto = store.setting("auto_sort") != "0"
            var briefs: [String] = []
            for a in r.structured["assignments"] as? [[String: Any]] ?? [] {
                guard let id = a["item_id"] as? String, ids.contains(id) else { continue }
                let tid = (a["topic_id"] as? String).flatMap { $0.isEmpty || store.topic($0) == nil ? nil : $0 }
                let en = a["title_en"] as? String ?? "", zh = a["title_zh"] as? String ?? ""
                try slack.savePrefill(id, topicId: tid, titleEn: en, titleZh: zh, reasonEn: a["reason_en"] as? String ?? "", reasonZh: a["reason_zh"] as? String ?? "")
                guard auto else { continue }
                switch a["action"] as? String {
                case "skip": try slack.skip(id)
                case "existing" where tid != nil: briefs.append(try slack.accept(id, topicId: tid, auto: true))
                case "new": briefs.append(try slack.accept(id, topicId: nil, newTitle: en, newTitleZh: zh, auto: true))
                default: break // unsure: stays in To sort with the suggestion filled in
                }
            }
            for t in Set(briefs) { enqueueBrief(t, trigger: ("Slack conversation filed", "归入了 Slack 对话")) }
            for it in items where try store.read({ try String.fetchOne($0, sql: "select triaged_at from to_sort where id = ?", arguments: [it.id]) }) == nil {
                try slack.savePrefill(it.id, topicId: nil, titleEn: it.title, titleZh: it.title, reasonEn: "", reasonZh: "")
            }
            store.changed()
            return items.count
        } catch {
            try? store.write { try $0.execute(sql: "update jobs set status = 'error', error = ?, finished_at = ? where id = ?", arguments: [String(describing: error), nowISO(), job.id]) }
            throw error
        }
    }

    /// The short AI overview at the top of a digest: one call, no session. On failure the digest shows its cards alone.
    public func digestOverview(since: String) async {
        let items = Catchup.changes(store, since: since)
        guard !items.isEmpty else { return }
        var job = Job(kind: "digest", topicId: nil, trigger: ("Digest overview (\(items.count) topics)", "摘要概览（\(items.count) 个事项）"), model: model("digest"))
        job.status = "running"; job.startedAt = nowISO()
        try? store.write { try job.insert($0) }
        do {
            let r = try await runner.run(ClaudeRequest(cwd: home, prompt: Catchup.overviewPrompt(store, items, since: since), schema: Catchup.overviewSchema,
                                                     model: job.model, effort: effort("digest"), systemPrompt: Catchup.overviewSystem, persist: false))
            try store.write { try finish($0, job, r, topicId: nil) }
            store.setSetting("catchup_overview_since", since)
            store.setSetting("catchup_overview", r.structured["overview"] as? String ?? "")
        } catch {
            try? store.write { try $0.execute(sql: "update jobs set status = 'error', error = ?, finished_at = ? where id = ?", arguments: [String(describing: error), nowISO(), job.id]) }
        }
    }

    /// AI search: one call with the topic index as the system prompt and the query as the message.
    public func aiSearch(_ query: String, includeArchived: Bool = false) async throws -> AISearchAnswer {
        var job = Job(kind: "search", topicId: nil, trigger: ("Search: \(query.prefix(60))", "搜索：\(query.prefix(60))"), model: model("search"))
        job.status = "running"; job.startedAt = nowISO()
        try store.write { try job.insert($0) }
        do {
            let r = try await runner.run(ClaudeRequest(cwd: home, prompt: "Query: \(query)", schema: Prompts.searchSchema, model: job.model,
                                                     effort: effort("search"), systemPrompt: Prompts.searchIndex(store, query: query, includeArchived: includeArchived), persist: false))
            try store.write { try finish($0, job, r, topicId: nil) }
            let hits = (r.structured["hits"] as? [[String: Any]] ?? []).compactMap { h -> AISearchAnswer.Hit? in
                guard let id = h["topic_id"] as? String, store.topic(id) != nil else { return nil }
                return .init(topicId: id, reasonEn: h["reason_en"] as? String ?? "", reasonZh: h["reason_zh"] as? String ?? "")
            }
            return AISearchAnswer(answerEn: r.structured["answer_en"] as? String ?? "", answerZh: r.structured["answer_zh"] as? String ?? "", hits: hits)
        } catch {
            try? store.write { try $0.execute(sql: "update jobs set status = 'error', error = ?, finished_at = ? where id = ?", arguments: [String(describing: error), nowISO(), job.id]) }
            throw error
        }
    }
}

/// Why a finished brief asks the app to notify her.
public enum BriefAlert: Sendable { case raised, backToHer }

func json(_ d: [String: String]) -> String { String(data: (try? JSONSerialization.data(withJSONObject: d)) ?? Data(), encoding: .utf8) ?? "{}" }
