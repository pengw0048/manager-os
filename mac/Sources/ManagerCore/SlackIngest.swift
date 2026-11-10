import Foundation
import GRDB

/// One Slack message as reported by the in-page hook (already enriched with names and a permalink).
public struct SlackEvent: Sendable, Equatable {
    public var channel: String
    public var ts: String
    public var threadTs: String?
    public var user: String
    public var userName: String
    public var channelName: String
    public var text: String
    public var subtype: String?
    public var isBot: Bool
    public var permalink: String?
    /// `message_changed`: `ts`/`text` are the edited message's.
    public var edited: Bool
    /// She marked this message as a to-do in Slack ("Later"); kept like a mention, even if hers or a bot's.
    public var todo: Bool

    public init(channel: String, ts: String, threadTs: String? = nil, user: String, userName: String = "", channelName: String = "",
                text: String, subtype: String? = nil, isBot: Bool = false, permalink: String? = nil, edited: Bool = false, todo: Bool = false) {
        self.channel = channel; self.ts = ts; self.threadTs = threadTs == ts ? nil : threadTs; self.user = user; self.userName = userName
        self.channelName = channelName; self.text = text; self.subtype = subtype; self.isBot = isBot; self.permalink = permalink; self.edited = edited
        self.todo = todo
    }
    public var threadKey: String { "\(channel):\(threadTs ?? ts)" }
}

public struct ToSortItem: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord, Identifiable {
    public static let databaseTableName = "to_sort"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase
    public var id: String
    public var source: String // dm | note | todo | mention | thread | watched
    public var channel: String
    public var channelName: String
    public var threadKey: String
    public var title: String
    public var permalink: String?
    public var status: String // pending | accepted | ignored | skipped
    public var prefillTopicId: String?
    public var prefillTitleEn: String?
    public var prefillTitleZh: String?
    public var prefillReasonEn: String?
    public var prefillReasonZh: String?
    public var triagedAt: String?
    public var createdAt: String
    public var updatedAt: String
    /// Where it was filed, and by whom ("me" | "auto").
    public var filedTopicId: String? = nil
    public var artifactId: String? = nil
    public var filedBy: String? = nil
}

public struct SlackMessage: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "slack_messages"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase
    public var channel: String
    public var ts: String
    public var threadTs: String?
    public var user: String
    public var userName: String
    public var channelName: String
    public var text: String
    public var subtype: String?
    public var permalink: String?
    public var receivedAt: String
    public var topicId: String?
    public var toSortId: String?
    public var flushed: Int
    public var mine: Int
    public var threadKey: String { "\(channel):\(threadTs ?? ts)" }
    /// "HH:mm Name: text" in local time, from the Slack ts.
    public var line: String {
        let d = Date(timeIntervalSince1970: Double(ts) ?? 0)
        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"
        return "\(f.string(from: d)) \(userName.isEmpty ? user : userName): \(text)"
    }
}

/// Turns Slack events into topic updates without AI: filter, map threads to topics, group the rest into "To sort",
/// and flush mapped messages to topics after a quiet period (debounce).
public final class SlackIngest: @unchecked Sendable {
    public let store: Store
    private let lock = NSLock()
    private var _selfUserId: String?
    private var _watched: Set<String> = []
    private var _selfDM: String?

    public static let keptSubtypes: Set<String?> = [nil, "thread_broadcast", "file_share", "me_message"]
    public static let dmGroupWindow: TimeInterval = 30 * 60

    public init(store: Store) {
        self.store = store
        _selfUserId = store.setting("slack_self_user_id")
        _watched = SlackIngest.parseWatched(store.setting("slack_watched") ?? "")
        _selfDM = store.setting("slack_self_dm")
    }

    public var selfUserId: String? {
        get { lock.withLock { _selfUserId } }
        set { lock.withLock { _selfUserId = newValue }; if let v = newValue { store.setSetting("slack_self_user_id", v) } }
    }
    /// Her DM with herself; messages there are notes to self and count like mentions.
    public var selfDM: String? {
        get { lock.withLock { _selfDM } }
        set { lock.withLock { _selfDM = newValue }; if let v = newValue { store.setSetting("slack_self_dm", v) } }
    }
    public var watched: Set<String> { lock.withLock { _watched } }
    public func setWatched(_ raw: String) { store.setSetting("slack_watched", raw); lock.withLock { _watched = SlackIngest.parseWatched(raw) } }
    static func parseWatched(_ raw: String) -> Set<String> {
        Set(raw.split(whereSeparator: { $0 == "," || $0.isNewline }).map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#")).lowercased() }.filter { !$0.isEmpty })
    }

    public enum Outcome: Equatable { case dropped(String), stored(topicId: String), toSort(String), mine, updated }

    /// Follows merges; nil if the topic is gone.
    func liveTopic(_ db: Database, _ id: String?) throws -> Topic? {
        var cur = try id.flatMap { try Topic.fetchOne(db, key: $0) }
        var hops = 0
        while let m = cur?.mergedInto, hops < 10 { cur = try Topic.fetchOne(db, key: m); hops += 1 }
        return cur
    }

    @discardableResult
    public func ingest(_ e: SlackEvent, now: Date = Date()) throws -> Outcome {
        let me = selfUserId, watched = self.watched
        let note = selfDM.map { e.channel == $0 } ?? false
        let isoNow = ISO8601DateFormatter.mos.string(from: now)
        var touched: [String?] = []
        let out: Outcome = try store.db.write { db in
            if e.edited {
                try db.execute(sql: "update slack_messages set text = ? where channel = ? and ts = ?", arguments: [e.text, e.channel, e.ts])
                return db.changesCount > 0 ? .updated : .dropped("unknown edit")
            }
            if let old = try SlackMessage.fetchOne(db, key: ["channel": e.channel, "ts": e.ts]) {
                // A to-do on a message stored only as her own reply still needs a place.
                guard e.todo, old.topicId == nil, old.toSortId == nil else { return .dropped("duplicate") }
                try old.delete(db)
            }
            if !e.todo && (e.isBot || !SlackIngest.keptSubtypes.contains(e.subtype)) { return .dropped("bot or system message") }

            let thread = try Row.fetchOne(db, sql: "select * from slack_threads where thread_key = ?", arguments: [e.threadKey])
            let state: String? = thread?["state"]
            if state == "ignored" && !e.todo { return .dropped("ignored thread") }
            let mapped = state == "mapped" ? try liveTopic(db, thread?["topic_id"]) : nil
            let mine = me != nil && e.user == me && !note && !e.todo

            var msg = SlackMessage(channel: e.channel, ts: e.ts, threadTs: e.threadTs, user: e.user, userName: e.userName, channelName: e.channelName,
                                   text: e.text, subtype: e.subtype, permalink: e.permalink, receivedAt: isoNow, topicId: mapped?.id, toSortId: nil,
                                   flushed: 0, mine: mine ? 1 : 0)
            if var t = mapped {
                try msg.insert(db)
                t.lastActivityAt = isoNow; t.archivedAt = nil
                try t.update(db)
                touched.append(t.id)
                return mine ? .mine : .stored(topicId: t.id)
            }
            if mine {
                msg.flushed = 1
                try msg.insert(db)
                if thread == nil { try db.execute(sql: "insert into slack_threads(thread_key, state) values (?, 'participated')", arguments: [e.threadKey]) }
                return .mine
            }

            let isDM = e.channel.hasPrefix("D") || note
            let mention = me.map { e.text.contains("<@\($0)>") } ?? false
            let participated = state == "participated"
            let isWatched = watched.contains(e.channel.lowercased()) || (!e.channelName.isEmpty && watched.contains(e.channelName.lowercased()))
            guard e.todo || isDM || mention || participated || isWatched else { return .dropped("not for me") }
            let source = e.todo ? "todo" : note ? "note" : isDM ? "dm" : mention ? "mention" : participated ? "thread" : "watched"

            // Join an open "To sort" item: same thread, or (for top-level DMs) the same DM within 30 minutes.
            var item = try ToSortItem.fetchOne(db, sql: "select * from to_sort where status = 'pending' and thread_key = ?", arguments: [e.threadKey])
            if item == nil && isDM && !e.todo && e.threadTs == nil {
                let since = ISO8601DateFormatter.mos.string(from: now.addingTimeInterval(-SlackIngest.dmGroupWindow))
                item = try ToSortItem.fetchOne(db, sql: "select * from to_sort where status = 'pending' and channel = ? and source = ? and updated_at >= ? order by updated_at desc", arguments: [e.channel, source, since])
            }
            if var it = item {
                it.updatedAt = isoNow
                try it.update(db)
                msg.toSortId = it.id
            } else {
                let who = e.userName.isEmpty ? e.user : e.userName
                let place = note ? "Note to self" : isDM ? "DM" : "#\(e.channelName.isEmpty ? e.channel : e.channelName)"
                let it = ToSortItem(id: newId("s"), source: source, channel: e.channel, channelName: e.channelName, threadKey: e.threadKey,
                                    title: "\(who) · \(place)", permalink: e.permalink, status: "pending", prefillTopicId: nil, prefillTitleEn: nil,
                                    prefillTitleZh: nil, prefillReasonEn: nil, prefillReasonZh: nil, triagedAt: nil, createdAt: isoNow, updatedAt: isoNow)
                try it.insert(db)
                msg.toSortId = it.id
            }
            try msg.insert(db)
            return .toSort(msg.toSortId!)
        }
        if out != .dropped("duplicate") && !(out.isDropped) { store.changed(topics: touched) }
        return out
    }

    /// Writes mapped messages to their topics once a thread is quiet (60 s, P0: 20 s) or has waited too long (5 min, P0: 2 min).
    /// Returns the topics that got messages from other people, so the caller can refresh their briefs.
    @discardableResult
    public func flush(now: Date = Date()) throws -> [String] {
        let groups = try store.read { db in
            try Row.fetchAll(db, sql: "select topic_id, min(received_at) as first, max(received_at) as last from slack_messages where flushed = 0 and topic_id is not null group by topic_id")
        }
        var briefs: [String] = []
        for g in groups {
            let topicId: String = g["topic_id"]
            guard let first = parseISO(g["first"]), let last = parseISO(g["last"]) else { continue }
            let urgency = store.topic(topicId)?.urgency
            let (quiet, maxWait): (TimeInterval, TimeInterval) = urgency == .P0 ? (20, 120) : (60, 300)
            guard now.timeIntervalSince(last) >= quiet || now.timeIntervalSince(first) >= maxWait else { continue }
            let others = try store.write(topics: [topicId]) { db -> Bool in
                let msgs = try SlackMessage.fetchAll(db, sql: "select * from slack_messages where flushed = 0 and topic_id = ? order by ts", arguments: [topicId])
                guard let target = try liveTopic(db, topicId), !msgs.isEmpty else {
                    try db.execute(sql: "update slack_messages set flushed = 1 where topic_id = ?", arguments: [topicId]); return false
                }
                let fromOthers = msgs.filter { $0.mine == 0 }
                let place = msgs.first.map { $0.channel.hasPrefix("D") ? "DM" : "#\($0.channelName.isEmpty ? $0.channel : $0.channelName)" } ?? "Slack"
                let (en, zh) = fromOthers.isEmpty
                    ? ("You replied in \(place)", "你在 \(place) 回复了")
                    : ("\(fromOthers.count) new Slack message\(fromOthers.count == 1 ? "" : "s") in \(place)", "\(place) 有 \(fromOthers.count) 条新 Slack 消息")
                try Store.addTimeline(db, TimelineEntry(topicId: target.id, actor: "slack", kind: "event", en: en, zh: zh,
                                                        sourceUrl: msgs.last?.permalink, raw: msgs.map(\.line).joined(separator: "\n")))
                for key in Set(msgs.map(\.threadKey)) {
                    let lines = msgs.filter { $0.threadKey == key }.map(\.line).joined(separator: "\n")
                    if let aid = try String.fetchOne(db, sql: "select artifact_id from slack_threads where thread_key = ?", arguments: [key]) {
                        try db.execute(sql: "update artifacts set content = content || char(10) || ?, summary_en = '', summary_zh = '' where id = ?", arguments: [lines, aid])
                    }
                }
                try db.execute(sql: "update slack_messages set flushed = 1, topic_id = ? where flushed = 0 and topic_id = ?", arguments: [target.id, topicId])
                return !fromOthers.isEmpty
            }
            if others { briefs.append(topicId) }
        }
        return briefs
    }

    public func pendingItems() -> [ToSortItem] {
        (try? store.read { try ToSortItem.fetchAll($0, sql: "select * from to_sort where status = 'pending' order by updated_at desc") }) ?? []
    }
    public func messages(of itemId: String) -> [SlackMessage] {
        (try? store.read { try SlackMessage.fetchAll($0, sql: "select * from slack_messages where to_sort_id = ? order by ts", arguments: [itemId]) }) ?? []
    }

    /// File a "To sort" item into an existing topic or a new one. Later messages in its threads go to that topic.
    @discardableResult
    public func accept(_ itemId: String, topicId: String?, newTitle: String? = nil, newTitleZh: String? = nil, auto: Bool = false) throws -> String {
        guard let item = try store.read({ try ToSortItem.fetchOne($0, key: itemId) }), item.status == "pending" else { throw TopicError.notFound }
        let msgs = messages(of: itemId)
        let requester = msgs.first { $0.mine == 0 }.map { $0.userName.isEmpty ? $0.user : $0.userName } ?? ""
        let target: String
        if let topicId, let t = try store.read({ try liveTopic($0, topicId) }) { target = t.id }
        else {
            var t = try TopicOps.create(store, title: newTitle ?? item.prefillTitleEn ?? "", requester: requester)
            if auto, let zh = newTitleZh, !zh.isEmpty { t.titleZh = zh; try store.write(topics: [t.id]) { try t.update($0) } }
            target = t.id
        }
        let place = item.channel.hasPrefix("D") ? "DM" : "#\(item.channelName.isEmpty ? item.channel : item.channelName)"
        let lines = msgs.map(\.line).joined(separator: "\n")
        try store.write(topics: [target]) { db in
            let art = Artifact(type: "slack_thread", title: "Slack · \(item.title)", url: item.permalink, content: lines)
            try Store.insertArtifact(db, topicId: target, art)
            for key in Set(msgs.map(\.threadKey) + [item.threadKey]) {
                try db.execute(sql: """
                    insert into slack_threads(thread_key, topic_id, state, artifact_id) values (?, ?, 'mapped', ?)
                    on conflict(thread_key) do update set topic_id = excluded.topic_id, state = 'mapped', artifact_id = excluded.artifact_id
                    """, arguments: [key, target, art.id])
            }
            try db.execute(sql: "update slack_messages set topic_id = ?, flushed = 1 where to_sort_id = ?", arguments: [target, itemId])
            try Store.addTimeline(db, TimelineEntry(topicId: target, actor: "slack", kind: "context",
                en: auto ? "Slack conversation from \(place) filed here automatically (\(msgs.count) messages)" : "Slack conversation added from \(place) (\(msgs.count) messages)",
                zh: auto ? "\(place) 的 Slack 对话被自动归到这里（\(msgs.count) 条消息）" : "加入了 \(place) 的 Slack 对话（\(msgs.count) 条消息）",
                sourceUrl: item.permalink, raw: lines))
            try db.execute(sql: "update topics set last_activity_at = ?, archived_at = null where id = ?", arguments: [nowISO(), target])
            try db.execute(sql: "update to_sort set status = 'accepted', updated_at = ?, filed_topic_id = ?, artifact_id = ?, filed_by = ? where id = ?",
                           arguments: [nowISO(), target, art.id, auto ? "auto" : "me", itemId])
        }
        return target
    }

    /// Not worth a topic (thanks, FYI): set aside without silencing the thread, so she can still add it.
    public func skip(_ itemId: String) throws {
        try store.write { try $0.execute(sql: "update to_sort set status = 'skipped', updated_at = ? where id = ? and status = 'pending'", arguments: [nowISO(), itemId]) }
    }

    /// A skipped item goes back to "To sort".
    public func restore(_ itemId: String) throws {
        try store.write { try $0.execute(sql: "update to_sort set status = 'pending', updated_at = ? where id = ? and status = 'skipped'", arguments: [nowISO(), itemId]) }
    }

    /// Items filed or skipped automatically in the last `hours`, newest first, so she can check them.
    public func recentAuto(hours: Double = 24, now: Date = Date()) -> [ToSortItem] {
        let since = ISO8601DateFormatter.mos.string(from: now.addingTimeInterval(-hours * 3600))
        return (try? store.read { try ToSortItem.fetchAll($0, sql: "select * from to_sort where (filed_by = 'auto' or status = 'skipped') and updated_at >= ? order by updated_at desc", arguments: [since]) }) ?? []
    }

    /// Dismiss an item; later replies in its threads are ignored too.
    public func ignore(_ itemId: String) throws {
        let keys = Set(messages(of: itemId).map(\.threadKey))
        try store.write { db in
            for key in keys {
                try db.execute(sql: "insert into slack_threads(thread_key, state) values (?, 'ignored') on conflict(thread_key) do update set state = 'ignored', topic_id = null", arguments: [key])
            }
            try db.execute(sql: "update to_sort set status = 'ignored', updated_at = ? where id = ?", arguments: [nowISO(), itemId])
        }
    }

    public func savePrefill(_ itemId: String, topicId: String?, titleEn: String, titleZh: String, reasonEn: String, reasonZh: String) throws {
        try store.write { db in
            try db.execute(sql: "update to_sort set prefill_topic_id = ?, prefill_title_en = ?, prefill_title_zh = ?, prefill_reason_en = ?, prefill_reason_zh = ?, triaged_at = ? where id = ?",
                           arguments: [topicId, titleEn, titleZh, reasonEn, reasonZh, nowISO(), itemId])
        }
    }

    /// Items that still need a triage suggestion and have been quiet for `quiet` seconds.
    public func untriaged(now: Date = Date(), quiet: TimeInterval = 30) -> [ToSortItem] {
        let cutoff = ISO8601DateFormatter.mos.string(from: now.addingTimeInterval(-quiet))
        return (try? store.read { try ToSortItem.fetchAll($0, sql: "select * from to_sort where status = 'pending' and triaged_at is null and updated_at <= ? order by created_at", arguments: [cutoff]) }) ?? []
    }

    /// `https://x.slack.com/archives/C123/p1700000000123456?thread_ts=1700000000.000100` → (C123, thread ts, message ts).
    public static func parsePermalink(_ s: String) -> (channel: String, threadTs: String, ts: String)? {
        guard let u = URLComponents(string: s.trimmingCharacters(in: .whitespacesAndNewlines)), u.host?.hasSuffix("slack.com") == true else { return nil }
        let parts = u.path.split(separator: "/").map(String.init)
        guard let i = parts.firstIndex(of: "archives"), parts.count > i + 2, parts[i + 2].hasPrefix("p"), parts[i + 2].count == 17 else { return nil }
        let digits = parts[i + 2].dropFirst()
        let ts = "\(digits.prefix(10)).\(digits.suffix(6))"
        let thread = u.queryItems?.first { $0.name == "thread_ts" }?.value ?? ts
        return (parts[i + 1], thread, ts)
    }

    /// A Slack thread she pasted: store its messages on the topic and track later replies there.
    @discardableResult
    public func attachThread(topicId: String, artifactId: String, events: [SlackEvent], threadKey: String) throws -> Int {
        let me = selfUserId
        let isoNow = nowISO()
        try store.write(topics: [topicId]) { db in
            for e in events {
                let m = SlackMessage(channel: e.channel, ts: e.ts, threadTs: e.threadTs, user: e.user, userName: e.userName, channelName: e.channelName,
                                     text: e.text, subtype: e.subtype, permalink: e.permalink, receivedAt: isoNow, topicId: topicId, toSortId: nil,
                                     flushed: 1, mine: me != nil && e.user == me ? 1 : 0)
                try m.insert(db, onConflict: .ignore)
            }
            let lines = events.map { SlackMessage(channel: $0.channel, ts: $0.ts, threadTs: nil, user: $0.user, userName: $0.userName, channelName: "", text: $0.text,
                                                  subtype: nil, permalink: nil, receivedAt: isoNow, topicId: nil, toSortId: nil, flushed: 1, mine: 0).line }
            try db.execute(sql: "update artifacts set content = ?, summary_en = '', summary_zh = '' where id = ?", arguments: [lines.joined(separator: "\n"), artifactId])
            try db.execute(sql: """
                insert into slack_threads(thread_key, topic_id, state, artifact_id) values (?, ?, 'mapped', ?)
                on conflict(thread_key) do update set topic_id = excluded.topic_id, state = 'mapped', artifact_id = excluded.artifact_id
                """, arguments: [threadKey, topicId, artifactId])
        }
        return events.count
    }

    public struct CatchUp: Sendable, Equatable {
        public var threads: [Target]
        public var dms: [Target]
        public struct Target: Sendable, Equatable { public var channel: String; public var threadTs: String?; public var oldest: String }
    }

    /// After a reconnect: replies since the last seen ts for threads of open topics, and history for DM channels seen before.
    public func catchUpTargets() -> CatchUp {
        let rows = (try? store.read { db in
            try Row.fetchAll(db, sql: """
                select st.thread_key, (select max(ts) from slack_messages m where m.channel || ':' || coalesce(m.thread_ts, m.ts) = st.thread_key) as last
                from slack_threads st join topics t on t.id = st.topic_id
                where st.state = 'mapped' and t.archived_at is null and t.status != 'done'
                """)
        }) ?? []
        let threads = rows.compactMap { r -> CatchUp.Target? in
            let key: String = r["thread_key"]
            let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            return .init(channel: parts[0], threadTs: parts[1], oldest: (r["last"] as String?) ?? parts[1])
        }
        let dms = ((try? store.read { try Row.fetchAll($0, sql: "select channel, max(ts) as last from slack_messages where channel like 'D%' group by channel") }) ?? [])
            .map { CatchUp.Target(channel: $0["channel"], threadTs: nil, oldest: $0["last"]) }
        return CatchUp(threads: threads, dms: dms)
    }
}

extension SlackIngest.Outcome { var isDropped: Bool { if case .dropped = self { return true }; return false } }

extension ISO8601DateFormatter {
    static let mos: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
}
