import Foundation
import Testing
import GRDB
@testable import ManagerCore

@Suite(.serialized) struct SlackTests {
    func ev(_ ch: String, _ ts: String, thread: String? = nil, user: String = "U_BOB", text: String = "hello", bot: Bool = false, subtype: String? = nil) -> SlackEvent {
        SlackEvent(channel: ch, ts: ts, threadTs: thread, user: user, userName: user == "U_ME" ? "Me" : "Bob", channelName: ch.hasPrefix("D") ? "" : "eng",
                   text: text, subtype: subtype, isBot: bot, permalink: "https://acme.slack.com/archives/\(ch)/p\(ts.replacingOccurrences(of: ".", with: ""))")
    }

    func setup() throws -> (Env, SlackIngest) {
        let e = try Env()
        let s = SlackIngest(store: e.store)
        s.selfUserId = "U_ME"
        return (e, s)
    }

    @Test func gateKeepsOnlyWhatIsForHer() throws {
        let (_, s) = try setup()
        #expect(try s.ingest(ev("C1", "1.1", bot: true)) == .dropped("bot or system message"))
        #expect(try s.ingest(ev("C1", "1.2", subtype: "channel_join")) == .dropped("bot or system message"))
        #expect(try s.ingest(ev("C1", "1.3")) == .dropped("not for me"))
        if case .toSort = try s.ingest(ev("D1", "1.4")) {} else { Issue.record("DM should go to To sort") }
        if case .toSort = try s.ingest(ev("C1", "1.5", text: "hey <@U_ME> can you look")) {} else { Issue.record("mention should go to To sort") }
        #expect(try s.ingest(ev("C1", "1.5")) == .dropped("duplicate"))
        // Her reply makes the thread "participated": later replies from others are kept.
        #expect(try s.ingest(ev("C2", "2.1", thread: "2.0", user: "U_ME")) == .mine)
        if case .toSort = try s.ingest(ev("C2", "2.2", thread: "2.0")) {} else { Issue.record("participated thread should be kept") }
        // Watched channel by name.
        s.setWatched("#Eng, other")
        if case .toSort = try s.ingest(ev("C9", "9.1")) {} else { Issue.record("watched channel should be kept") }
    }

    @Test func noteToSelfAndTodoCountLikeMentions() throws {
        let (e, s) = try setup()
        s.selfDM = "D_SELF"
        guard case .toSort(let note) = try s.ingest(ev("D_SELF", "3.1", user: "U_ME", text: "follow up with Bob on Q1 plan")) else { Issue.record("note to self should go to To sort"); return }
        #expect(try s.ingest(ev("D_SELF", "3.2", user: "U_ME", text: "also ask SRE")) == .toSort(note))
        #expect(try e.store.read { try ToSortItem.fetchOne($0, key: note) }?.source == "note")
        // Her own DM to someone else is still just her message.
        #expect(try s.ingest(ev("D2", "3.3", user: "U_ME")) == .mine)

        // A to-do on a channel message, a bot alert, and her own earlier reply.
        var todo = ev("C1", "4.1", text: "unrelated chatter"); todo.todo = true
        guard case .toSort(let t1) = try s.ingest(todo) else { Issue.record("to-do should go to To sort"); return }
        #expect(try e.store.read { try ToSortItem.fetchOne($0, key: t1) }?.source == "todo")
        var alert = ev("C1", "4.2", bot: true); alert.todo = true
        if case .toSort = try s.ingest(alert) {} else { Issue.record("to-do on a bot message should be kept") }
        #expect(try s.ingest(ev("C2", "4.3", thread: "4.0", user: "U_ME")) == .mine)
        var mineTodo = ev("C2", "4.3", thread: "4.0", user: "U_ME"); mineTodo.todo = true
        if case .toSort = try s.ingest(mineTodo) {} else { Issue.record("to-do on her own reply should be kept") }
        #expect(try s.ingest(mineTodo) == .dropped("duplicate"))
    }

    @Test func dmBurstGroupsAndAcceptMapsLaterReplies() throws {
        let (e, s) = try setup()
        let now = Date()
        guard case .toSort(let id) = try s.ingest(ev("D1", "1.1", text: "can you review the doc?"), now: now) else { Issue.record("no item"); return }
        #expect(try s.ingest(ev("D1", "1.2", text: "it's the Q1 plan"), now: now.addingTimeInterval(60)) == .toSort(id))
        #expect(try s.ingest(ev("D1", "1.3", text: "next day"), now: now.addingTimeInterval(3 * 3600)) != .toSort(id))
        #expect(s.messages(of: id).count == 2)

        let t = try TopicOps.create(e.store, title: "Q1 plan review")
        try s.accept(id, topicId: t.id)
        #expect(e.store.artifacts(of: t.id).first?.content.contains("Q1 plan") == true)
        #expect(e.store.timeline(of: t.id).contains { $0.actor == "slack" })
        // A reply in the thread of an accepted message lands on the topic.
        #expect(try s.ingest(ev("D1", "1.9", thread: "1.1", text: "any update?")) == .stored(topicId: t.id))
    }

    @Test func flushDebouncesAndUpdatesArtifact() throws {
        let (e, s) = try setup()
        let now = Date()
        guard case .toSort(let id) = try s.ingest(ev("C1", "5.0", text: "<@U_ME> rollback?"), now: now) else { return }
        let t = try s.accept(id, topicId: nil, newTitle: "Rollback")
        #expect(e.store.topic(t)?.titleEn == "Rollback")
        #expect(try s.ingest(ev("C1", "5.1", thread: "5.0", text: "hotfix ETA 40 min"), now: now) == .stored(topicId: t))
        #expect(try s.flush(now: now.addingTimeInterval(30)).isEmpty) // still within the quiet window
        #expect(try s.ingest(ev("C1", "5.2", thread: "5.0", user: "U_ME", text: "roll back now"), now: now.addingTimeInterval(40)) == .mine)
        #expect(try s.flush(now: now.addingTimeInterval(101)) == [t])
        let tl = e.store.timeline(of: t).last!
        #expect(tl.summaryEn == "1 new Slack message in #eng")
        #expect(tl.raw?.contains("roll back now") == true && tl.raw?.contains("hotfix") == true)
        #expect(e.store.artifacts(of: t).first?.content.contains("hotfix ETA") == true)
        #expect(try s.flush(now: now.addingTimeInterval(500)).isEmpty) // nothing left
    }

    @Test func maxWaitFlushesBusyThreads() throws {
        let (e, s) = try setup()
        let now = Date()
        guard case .toSort(let id) = try s.ingest(ev("D2", "6.0"), now: now) else { return }
        let t = try s.accept(id, topicId: nil, newTitle: "Busy")
        for i in 1...10 { _ = try s.ingest(ev("D2", "6.\(i)", thread: "6.0"), now: now.addingTimeInterval(Double(i) * 31)) }
        #expect(try s.flush(now: now.addingTimeInterval(320)).isEmpty) // first reply at +31 s: waited < 5 min, not quiet
        #expect(try s.flush(now: now.addingTimeInterval(340)) == [t]) // never quiet for 60 s, but waited > 5 min
        _ = e
    }

    @Test func ignoreSilencesTheThreadAndMergeFollowsRedirect() throws {
        let (e, s) = try setup()
        guard case .toSort(let a) = try s.ingest(ev("C3", "7.0", text: "<@U_ME> fyi")) else { return }
        try s.ignore(a)
        #expect(try s.ingest(ev("C3", "7.1", thread: "7.0", text: "<@U_ME> more")) == .dropped("ignored thread"))

        guard case .toSort(let b) = try s.ingest(ev("C4", "8.0", text: "<@U_ME> q")) else { return }
        let src = try s.accept(b, topicId: nil, newTitle: "Src")
        let dst = try TopicOps.create(e.store, title: "Dst")
        try TopicOps.merge(e.store, src, into: dst.id)
        #expect(try s.ingest(ev("C4", "8.1", thread: "8.0")) == .stored(topicId: dst.id))
    }

    @Test func archivedTopicWakesUpAndEditsUpdateText() throws {
        let (e, s) = try setup()
        guard case .toSort(let id) = try s.ingest(ev("D5", "9.0")) else { return }
        let t = try s.accept(id, topicId: nil, newTitle: "Old")
        try TopicOps.archive(e.store, t)
        _ = try s.ingest(ev("D5", "9.1", thread: "9.0", text: "typo"))
        #expect(e.store.topic(t)?.isArchived == false)
        var edit = ev("D5", "9.1", text: "fixed"); edit.edited = true
        #expect(try s.ingest(edit) == .updated)
        #expect(try e.store.read { try String.fetchOne($0, sql: "select text from slack_messages where ts = '9.1'") } == "fixed")
    }

    @Test func catchUpTargetsCoverOpenThreadsAndDMs() throws {
        let (_, s) = try setup()
        guard case .toSort(let id) = try s.ingest(ev("C7", "3.0", text: "<@U_ME> x")) else { return }
        try s.accept(id, topicId: nil, newTitle: "T")
        _ = try s.ingest(ev("C7", "3.5", thread: "3.0"))
        _ = try s.ingest(ev("D8", "4.0"))
        let c = s.catchUpTargets()
        #expect(c.threads == [.init(channel: "C7", threadTs: "3.0", oldest: "3.5")])
        #expect(c.dms == [.init(channel: "D8", threadTs: nil, oldest: "4.0")])
    }

    @Test func pastedSlackLinkTracksTheThread() throws {
        let (e, s) = try setup()
        let p = try #require(SlackIngest.parsePermalink("https://acme.slack.com/archives/C42/p1794250680000200?thread_ts=1794250080.000100&cid=C42"))
        #expect(p.channel == "C42" && p.threadTs == "1794250080.000100" && p.ts == "1794250680.000200")
        #expect(SlackIngest.parsePermalink("https://acme.slack.com/archives/C42/p1794250080000100")?.threadTs == "1794250080.000100")
        #expect(SlackIngest.parsePermalink("https://example.com/archives/C42/p1794250080000100") == nil)

        let t = try TopicOps.create(e.store, title: "From link", url: "https://acme.slack.com/archives/C42/p1794250080000100")
        let art = try #require(e.store.artifacts(of: t.id).first)
        try s.attachThread(topicId: t.id, artifactId: art.id, events: [ev("C42", "1794250080.000100", text: "root"), ev("C42", "1794250099.000100", thread: "1794250080.000100", text: "reply")],
                           threadKey: "C42:1794250080.000100")
        #expect(e.store.artifacts(of: t.id).first?.content.contains("reply") == true)
        #expect(try s.ingest(ev("C42", "1794250200.000100", thread: "1794250080.000100", text: "new")) == .stored(topicId: t.id))
    }

    @Test func triagePrefillsTargets() async throws {
        let (e, s) = try setup()
        let t = try TopicOps.create(e.store, title: "Existing")
        _ = try s.ingest(ev("D1", "1.0"), now: Date().addingTimeInterval(-120))
        _ = try s.ingest(ev("C1", "2.0", text: "<@U_ME> new thing"), now: Date().addingTimeInterval(-120))
        #expect(try await e.queue.triage(s) == 2)
        let items = s.pendingItems()
        #expect(items.compactMap(\.prefillTopicId) == [t.id])
        #expect(items.allSatisfy { $0.triagedAt != nil })
        #expect(try await e.queue.triage(s) == 0)
    }
}
