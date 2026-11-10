import Foundation
import Testing
import GRDB
@testable import ManagerCore

/// Fresh home folder, store, and queue wired to the fake `claude` (Tests/Fixtures/fake-claude.mjs).
struct Env {
    let home: String
    let store: Store
    let queue: JobQueue
    let log: String

    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("mos-\(UUID().uuidString)").path
        try Knowledge.initHome(home)
        store = try Store(path: "\(home)/data/manager.db")
        log = "\(home)/calls.jsonl"
        setenv("FAKE_CLAUDE_LOG", log, 1)
        let fake = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../Fixtures/fake-claude.mjs").standardizedFileURL.path
        queue = JobQueue(store: store, home: home, runner: ClaudeRunner(binary: fake))
    }

    var calls: [[String: Any]] {
        ((try? String(contentsOfFile: log, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }
}

@Suite(.serialized) struct CoreTests {
    @Test func homeIsInitialized() throws {
        let e = try Env()
        for f in ["CLAUDE.md", "knowledge/me.md"] { #expect(FileManager.default.fileExists(atPath: "\(e.home)/\(f)")) }
    }

    @Test func briefIsAppliedThenResumedWithDelta() async throws {
        let e = try Env()
        let t = try TopicOps.create(e.store, title: "", text: "Incident: ingest errors, decide rollback", requester: "On-call")
        await e.queue.enqueueBrief(t.id, trigger: ("New topic", "新建事项"))
        await e.queue.idle()
        let after = try #require(e.store.topic(t.id))
        #expect(after.titleEn == "Fake title")
        #expect(after.urgency == .P0)
        #expect(after.briefState == "idle")
        #expect(e.store.artifacts(of: t.id).first?.summaryEn.hasPrefix("sum a_") == true)
        #expect(e.calls.last?["resume"] == nil)

        _ = try TopicOps.addContext(e.store, topicId: t.id, title: "", url: "", content: "Hotfix ETA 40 min")
        await e.queue.enqueueBrief(t.id, trigger: ("New context", "新的 context"))
        await e.queue.idle()
        let c = try #require(e.calls.last)
        #expect(c["resume"] as? String == e.store.topic(t.id)?.claudeSessionId)
        #expect((c["prompt"] as? String)?.contains("## New context items") == true)
        #expect((c["prompt"] as? String)?.contains("decide rollback") == false)
        #expect(e.store.topic(t.id)?.titleEn == "Fake title")
    }

    @Test func manualUrgencyIsKept() async throws {
        let e = try Env()
        let t = try TopicOps.create(e.store, title: "x", text: "incident")
        var p = TopicPatch(); p.urgency = .P3
        try TopicOps.patch(e.store, t.id, p)
        await e.queue.enqueueBrief(t.id, trigger: ("r", "r"))
        await e.queue.idle()
        var after = try #require(e.store.topic(t.id))
        #expect(after.urgency == .P3 && after.urgencySource == "manual" && after.aiUrgency == .P0)
        var back = TopicPatch(); back.urgencyAuto = true
        try TopicOps.patch(e.store, t.id, back)
        after = try #require(e.store.topic(t.id))
        #expect(after.urgency == .P0)
    }

    @Test func mergeAndSplit() async throws {
        let e = try Env()
        let a = try TopicOps.create(e.store, title: "A", text: "alpha"), b = try TopicOps.create(e.store, title: "B", text: "beta")
        try TopicOps.merge(e.store, a.id, into: b.id)
        #expect(e.store.topic(a.id)?.mergedInto == b.id)
        #expect(e.store.artifacts(of: b.id).count == 2)
        let art = e.store.artifacts(of: b.id)[0].id
        let n = try TopicOps.split(e.store, b.id, title: "Part", artifactIds: [art], timelineIds: [], asSub: true)
        #expect(e.store.topic(n.id)?.parentId == b.id)
        #expect(e.store.artifacts(of: b.id).count == 1)
        #expect(e.store.artifacts(of: n.id).first?.id == art)
    }

    @Test func moveUnderOwnChildIsRejected() throws {
        let e = try Env()
        let p = try TopicOps.create(e.store, title: "Parent"), k = try TopicOps.create(e.store, title: "Kid", parentId: p.id)
        var patch = TopicPatch(); patch.parentId = .some(k.id)
        #expect(throws: TopicError.cycle) { try TopicOps.patch(e.store, p.id, patch) }
    }

    @Test func chatActionsUndoAndConfirm() async throws {
        let e = try Env()
        let t = try TopicOps.create(e.store, title: "Chat topic", text: "context")
        await e.queue.enqueueChat(t.id, text: "add to timeline: rollback started")
        await e.queue.idle()
        let msg = try #require(e.store.chat(of: t.id).last)
        #expect(msg.decodedStates.first?.state == "applied")
        #expect(e.store.timeline(of: t.id).contains { $0.summaryEn == "rollback started" })
        try e.queue.undo(chatId: msg.id!, index: 0)
        #expect(!e.store.timeline(of: t.id).contains { $0.summaryEn == "rollback started" })

        await e.queue.enqueueChat(t.id, text: "set status please")
        await e.queue.idle()
        let m2 = try #require(e.store.chat(of: t.id).last)
        #expect(m2.decodedStates.first?.state == "pending")
        #expect(e.store.topic(t.id)?.status == .needsMe)
        try await e.queue.confirm(chatId: m2.id!, index: 0, ok: true)
        #expect(e.store.topic(t.id)?.status == .waiting)
    }

    @Test func assistantFollowupNeedsConfirm() async throws {
        let e = try Env()
        let t = try TopicOps.create(e.store, title: "Headcount")
        await e.queue.enqueueAssistant("set a follow up", page: "topics", topicId: nil)
        await e.queue.idle()
        let m = try #require(e.store.chat(of: nil).last)
        #expect(m.decodedActions?.items.first?.topicId == t.id)
        #expect(e.store.topic(t.id)?.remindAt == nil)
        try await e.queue.confirm(chatId: m.id!, index: 0, ok: true)
        let at = try #require(e.store.topic(t.id)?.remindAt.flatMap(parseISO))
        #expect(localDay(at) == "2030-01-01" && Calendar.current.component(.hour, from: at) == 9)
    }

    @Test func missingSessionFallsBackToFresh() async throws {
        let e = try Env()
        let t = try TopicOps.create(e.store, title: "Resume", text: "x")
        await e.queue.enqueueBrief(t.id, trigger: ("a", "a"))
        await e.queue.idle()
        setenv("FAKE_CLAUDE_FAIL_RESUME", "1", 1)
        defer { unsetenv("FAKE_CLAUDE_FAIL_RESUME") }
        await e.queue.enqueueBrief(t.id, trigger: ("b", "b"))
        await e.queue.idle()
        #expect(e.store.jobs(of: t.id).last?.status == "done")
    }

    @Test func scoreAndFollowup() throws {
        let e = try Env()
        try e.store.write { try Person(name: "Director", weight: 3).insert($0) }
        var t = Topic(title: "x", requester: "Director"); t.urgency = .P1; t.status = .waiting
        #expect(TopicOps.score(e.store, t) == 6)
        t.dueAt = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        #expect(TopicOps.score(e.store, t) == 12)
        t.remindAt = "2000-01-01T09:00:00.000Z"; #expect(TopicOps.reminderDue(t))
        t.remindAt = "2999-01-01T09:00:00.000Z"; #expect(!TopicOps.reminderDue(t))
        t.remindAt = "2000-01-01T09:00:00.000Z"; t.status = .done; #expect(!TopicOps.reminderDue(t))
    }

    @Test func tickExpiresPinAndWakesSnoozed() throws {
        let e = try Env()
        var t = Topic(title: "tick"); t.urgency = .P3; t.urgencySource = "manual"; t.urgencyPinnedUntil = "2000-01-01"
        t.aiUrgency = .P1; t.status = .snoozed; t.remindAt = "2000-01-02T09:00:00.000Z"
        try e.store.write { try t.insert($0) }
        let due = TopicOps.tick(e.store)
        let after = try #require(e.store.topic(t.id))
        #expect(after.urgencySource == "auto" && after.urgency == .P1 && after.status == .needsMe)
        #expect(due.contains { $0.topic.id == t.id })
        #expect(!TopicOps.tick(e.store).contains { $0.topic.id == t.id }) // P1 repeats only after 3 h

    }

    @Test func remindersRepeatPerLevelUntilHandled() throws {
        let e = try Env()
        var t = Topic(title: "r"); t.urgency = .P0; t.remindAt = ISO8601DateFormatter.mos.string(from: Date().addingTimeInterval(-60))
        try e.store.write { try t.insert($0) }
        let now = Date()
        #expect(TopicOps.tick(e.store, now: now).first?.repeated == false)
        #expect(TopicOps.tick(e.store, now: now.addingTimeInterval(10 * 60)).isEmpty)          // P0 repeats every 30 min
        #expect(TopicOps.tick(e.store, now: now.addingTimeInterval(31 * 60)).first?.repeated == true)
        var lv = e.store.level(.P0); lv.repeatMinutes = 0
        try e.store.write { try lv.update($0) }
        #expect(TopicOps.tick(e.store, now: now.addingTimeInterval(120 * 60)).isEmpty)         // she turned repeats off
        var p = TopicPatch(); p.status = .done
        try TopicOps.patch(e.store, t.id, p)
        #expect(!TopicOps.reminderDue(e.store.topic(t.id)!))
    }

    @Test func reminderPresetsAndAutoReminders() async throws {
        let e = try Env()
        let base = ISO8601DateFormatter().date(from: "2026-11-11T10:00:00Z")! // a Wednesday
        #expect(parseISO(TopicOps.reminderTime(.oneHour, from: base)) == base.addingTimeInterval(3600))
        let mon = parseISO(TopicOps.reminderTime(.nextMonday, from: base))!
        #expect(Calendar.current.component(.weekday, from: mon) == 2 && Calendar.current.component(.hour, from: mon) == 9)
        // Waiting on others sets a reminder in 2 working days.
        let w = try TopicOps.create(e.store, title: "w")
        var p = TopicPatch(); p.status = .waiting
        try TopicOps.patch(e.store, w.id, p)
        #expect(e.store.topic(w.id)?.remindAt != nil)
        // The first brief sets the level's first reminder (fake claude says P0 → at once).
        let t = try TopicOps.create(e.store, title: "", text: "incident in prod")
        await e.queue.enqueueBrief(t.id, trigger: ("n", "n"))
        await e.queue.idle()
        #expect(TopicOps.reminderDue(e.store.topic(t.id)!))
        // The brief prompt carries her level descriptions.
        #expect(Prompts.briefSystem(e.store.levels()).contains("P0 = Now"))
    }

    @Test func peopleExport() throws {
        let e = try Env()
        var p = Person(name: "VP Eng", relationship: "skip_level", weight: 3); p.notes = "Wants short updates"
        try e.store.write { try p.insert($0) }
        Knowledge.exportPeople(e.store, home: e.home)
        let body = try String(contentsOfFile: "\(e.home)/knowledge/people.md", encoding: .utf8)
        #expect(body.contains("VP Eng — skip_level") && body.contains("Wants short updates"))
    }

    @Test func keywordSearchHandlesChineseAndPrefixes() throws {
        let e = try Env()
        let a = try TopicOps.create(e.store, title: "Ingest incident", text: "SRE 说每个 region 回滚大概 15 分钟。Rollback plan confirmed.")
        let b = try TopicOps.create(e.store, title: "Q1 headcount", text: "招聘一个后端和一个 SRE")
        #expect(try Search.keyword(e.store, "回滚").map(\.topicId) == [a.id])
        #expect(try Search.keyword(e.store, "回滚大概").map(\.topicId) == [a.id])
        #expect(try Search.keyword(e.store, "rollback pla").map(\.topicId) == [a.id])
        #expect(try Search.keyword(e.store, "招聘").map(\.topicId) == [b.id])
        #expect(Set(try Search.keyword(e.store, "SRE").map(\.topicId)) == [a.id, b.id])
        #expect(try Search.keyword(e.store, "回滚").first?.snippet.contains("回滚") == true)
        // Index follows edits.
        _ = try TopicOps.addContext(e.store, topicId: b.id, title: "", url: "", content: "预算 review")
        #expect(try Search.keyword(e.store, "预算").map(\.topicId) == [b.id])
        try TopicOps.merge(e.store, b.id, into: a.id)
        #expect(try Search.keyword(e.store, "招聘").map(\.topicId) == [a.id])
    }

    @Test func dataFromM0IsReadable() throws {
        let e = try Env()
        let t = try TopicOps.create(e.store, title: "Old")
        // Simulate an M0 database: no search index yet, numeric action refs.
        try e.store.write { db in
            try db.execute(sql: "delete from search_index")
            try db.execute(sql: "insert into chat(topic_id, at, role, actions, action_state) values (?, ?, 'assistant', ?, ?)",
                           arguments: [t.id, nowISO(), #"{"items":[{"type":"add_timeline","text_en":"x","text_zh":"x","value":""}]}"#, #"[{"state":"applied","ref":42}]"#])
        }
        _ = e.store.takeDirty()
        #expect(e.store.chat(of: t.id).last?.decodedStates.first == ActionState(state: "applied", ref: "42"))
        #expect(try Search.keyword(e.store, "Old").map(\.topicId) == [t.id])
    }

    @Test func archiveDeleteAndAutoArchive() throws {
        let e = try Env()
        let p = try TopicOps.create(e.store, title: "Parent", text: "shared context")
        let k = try TopicOps.create(e.store, title: "Kid", parentId: p.id)
        try TopicOps.archive(e.store, p.id)
        #expect(e.store.topic(k.id)?.isArchived == true)
        #expect(e.store.activeTopics().isEmpty)
        #expect(!Prompts.assistant(e.store, message: "hi", page: nil, topicId: nil).contains("Parent"))
        #expect(try Search.keyword(e.store, "shared").map(\.topicId) == [p.id]) // archive stays searchable
        try TopicOps.unarchive(e.store, p.id)
        #expect(e.store.activeTopics().count == 2)

        try TopicOps.delete(e.store, p.id)
        #expect(e.store.topic(p.id) == nil)
        #expect(e.store.topic(k.id)?.parentId == nil)
        #expect(try e.store.read { try Int.fetchOne($0, sql: "select count(*) from artifacts") } == 0)
        #expect(try Search.keyword(e.store, "shared").isEmpty)

        var old = Topic(title: "Old done"); old.status = .done; old.lastActivityAt = "2000-01-01T00:00:00.000Z"
        try e.store.write { try old.insert($0) }
        _ = TopicOps.tick(e.store)
        #expect(e.store.topic(old.id)?.isArchived == true)
    }

    @Test func assistantPromptIsCapped() throws {
        let e = try Env()
        try e.store.write { db in for i in 0..<(Prompts.assistantTopicCap + 10) { try Topic(title: "T\(i)").insert(db) } }
        let prompt = Prompts.assistant(e.store, message: "hi", page: nil, topicId: nil)
        #expect(prompt.components(separatedBy: "\n- t_").count - 1 == Prompts.assistantTopicCap)
        #expect(prompt.contains("10 lower-priority open topics not shown"))
    }

    /// Opt-in: MOS_REAL_CLAUDE=1 ./scripts/test.sh --filter realClaude (spends a few cents).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MOS_REAL_CLAUDE"] == "1"))
    func realClaudeEndToEnd() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("mos-real-\(UUID().uuidString)").path
        try Knowledge.initHome(home)
        let store = try Store(path: "\(home)/data/manager.db")
        let queue = JobQueue(store: store, home: home, runner: ClaudeRunner())
        let t = try TopicOps.create(store, title: "", text: "Partner team lead (email): We need a firm sunset date for API v1 by Thursday so we can plan our migration.", requester: "Partner team lead")
        await queue.enqueueBrief(t.id, trigger: ("New topic", "新建事项"))
        await queue.idle()
        let after = try #require(store.topic(t.id))
        #expect(store.jobs(of: t.id).first?.status == "done", "\(store.jobs(of: t.id).first?.error ?? "")")
        #expect(!after.briefEn.isEmpty && !after.briefZh.isEmpty && !after.titleEn.isEmpty)
        await queue.enqueueChat(t.id, text: "add to timeline: asked the Director to approve the date")
        await queue.idle()
        #expect(store.chat(of: t.id).last?.decodedStates.first?.state == "applied")
        #expect(store.jobs(of: t.id).last?.sessionId == after.claudeSessionId)
        let hits = try await queue.aiSearch("API 下线日期")
        #expect(hits.hits.map(\.topicId) == [t.id])
        print("REAL:", after.titleEn, "|", after.urgency.rawValue, "|", store.jobs().map { "\($0.kind) \($0.durationMs ?? 0)ms $\($0.costUsd ?? 0)" })
    }

    @Test func aiSearchReturnsKnownTopicsAndLogsJob() async throws {
        let e = try Env()
        let t = try TopicOps.create(e.store, title: "Partner API sunset date")
        let r = try await e.queue.aiSearch("partner")
        #expect(r.hits.map(\.topicId) == [t.id])
        #expect(e.store.jobs().first?.kind == "search")
        #expect(e.calls.last.flatMap { ($0["args"] as? [String])?.contains("--no-session-persistence") } == true)
    }
}
