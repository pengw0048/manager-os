import Foundation
import GRDB

public enum TopicError: Error, Equatable { case notFound, cycle, badMerge }

public struct TopicPatch: Sendable {
    public var title: String?
    public var status: TopicStatus?
    public var urgency: Urgency?
    public var urgencyAuto = false
    public var urgencyPinnedUntil: String??
    public var nextFollowupAt: String??
    /// ISO datetime, or nil to clear.
    public var remindAt: String??
    public var dueAt: String??
    public var parentId: String??
    public var requester: String?
    public init() {}
}

public struct BriefResult: Codable, Sendable {
    public var titleEn: String; public var titleZh: String
    public var briefEn: String; public var briefZh: String
    public var urgency: Urgency
    public var urgencyReasonEn: String; public var urgencyReasonZh: String
    public var status: TopicStatus?
    public var statusReasonEn: String?; public var statusReasonZh: String?
    public var dueAt: String?
    public var requester: String?
    public var artifactSummaries: [ArtifactSummary]
    public struct ArtifactSummary: Codable, Sendable { public var id: String; public var summaryEn: String; public var summaryZh: String }
}

private let statusLabel: [TopicStatus: (String, String)] = [
    .needsMe: ("Needs me", "待我处理"), .waiting: ("Waiting on others", "等别人"), .snoozed: ("Snoozed", "暂缓"), .done: ("Done", "已完成"),
]

public enum TopicOps {
    /// The person a topic's requester is: by Slack user ID or handle (Settings → People → Slack), else by name.
    /// `slackIds` are the Slack user IDs known for the requester's display name. `people` is sorted by weight.
    public static func person(_ people: [Person], requester: String, slackIds: Set<String> = []) -> Person? {
        let norm = { (s: String) in s.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "@ ")) }
        let r = norm(requester), ids = Set(slackIds.map(norm))
        guard !r.isEmpty || !ids.isEmpty else { return nil }
        if let p = people.first(where: { let h = norm($0.slack); return !h.isEmpty && (h == r || ids.contains(h)) }) { return p }
        return people.first { let n = norm($0.name); return !n.isEmpty && !r.isEmpty && (r == n || r.contains(n)) }
    }

    /// Slack user IDs per lowercased display name, from messages the app has seen.
    public static func slackIdsByName(_ store: Store) -> [String: Set<String>] {
        let rows = (try? store.read { try Row.fetchAll($0, sql: "select id, name from slack_users where name != ''") }) ?? []
        var out: [String: Set<String>] = [:]
        for r in rows { out[(r["name"] as String).lowercased(), default: []].insert(r["id"]) }
        return out
    }

    public static func sender(_ store: Store, _ requester: String) -> Person? {
        person(store.people(), requester: requester, slackIds: slackIdsByName(store)[requester.lowercased()] ?? [])
    }

    public static func senderWeight(_ store: Store, _ requester: String) -> Double { sender(store, requester)?.weight ?? 1 }

    /// score = sender_weight × urgency_weight × deadline_factor × staleness_factor.
    /// `urgency` overrides the topic's own level (a parent counts at least as urgent as its open sub-topics).
    public static func score(_ store: Store, _ t: Topic, now: Date = Date(), weight: Double? = nil, urgency: Urgency? = nil) -> Double {
        var deadline = 1.0
        if let due = t.dueAt.flatMap(parseISO) {
            let hours = due.timeIntervalSince(now) / 3600
            deadline = hours <= 0 ? 3 : hours < 24 ? 2 : hours < 72 ? 1.3 : 1
        }
        var stale = 1.0
        if t.status == .needsMe, let last = parseISO(t.lastActivityAt) { stale = 1 + min(now.timeIntervalSince(last) / 86400, 3) * 0.25 }
        let s = (weight ?? senderWeight(store, t.requester)) * (urgency ?? t.urgency).weight * deadline * stale
        return (s * 100).rounded() / 100
    }

    /// A reminder is due from its time until she handles it (done, new reminder, or cleared).
    public static func reminderDue(_ t: Topic, now: Date = Date()) -> Bool {
        guard let r = t.remindAt, let at = parseISO(r) else { return false }
        return at <= now && t.status != .done && !t.isArchived
    }
    public static func followupDue(_ t: Topic, now: Date = Date()) -> Bool { reminderDue(t, now: now) }

    /// "YYYY-MM-DD" → that day at 09:00 local; a full ISO datetime is kept.
    public static func reminderTime(_ s: String) -> String? {
        if s.count <= 10, let d = parseISO(s), let at = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: d) { return ISO8601DateFormatter.mos.string(from: at) }
        return parseISO(s).map { ISO8601DateFormatter.mos.string(from: $0) }
    }

    public enum ReminderPreset: String, CaseIterable, Sendable { case oneHour, threeHours, tomorrowMorning, nextMonday }
    public static func reminderTime(_ p: ReminderPreset, from now: Date = Date()) -> String {
        let cal = Calendar.current
        let at: Date
        switch p {
        case .oneHour: at = now.addingTimeInterval(3600)
        case .threeHours: at = now.addingTimeInterval(3 * 3600)
        case .tomorrowMorning: at = cal.date(bySettingHour: 9, minute: 0, second: 0, of: cal.date(byAdding: .day, value: 1, to: now)!)!
        case .nextMonday:
            let next = cal.nextDate(after: now, matching: DateComponents(weekday: 2), matchingPolicy: .nextTime)!
            at = cal.date(bySettingHour: 9, minute: 0, second: 0, of: next)!
        }
        return ISO8601DateFormatter.mos.string(from: at)
    }

    /// Parent urgency is at least the highest urgency of its open sub-topics.
    public static func effectiveUrgency(_ t: Topic, children: [Topic]) -> Urgency {
        ([t.urgency] + children.filter { $0.status != .done && !$0.isArchived }.map(\.urgency)).min { $0.rank < $1.rank }!
    }

    public static func addWorkingDays(_ n: Int, from: Date = Date()) -> String {
        var d = from, left = n
        while left > 0 {
            d = Calendar.current.date(byAdding: .day, value: 1, to: d)!
            let wd = Calendar.current.component(.weekday, from: d)
            if wd != 1 && wd != 7 { left -= 1 }
        }
        return localDay(d)
    }

    @discardableResult
    public static func create(_ store: Store, title: String, text: String = "", url: String = "", parentId: String? = nil, requester: String = "", urgency: Urgency? = nil) throws -> Topic {
        var t = Topic(title: title, parentId: parentId, requester: requester, titleSource: title.isEmpty ? "ai" : "me")
        if let urgency { t.urgency = urgency; t.urgencySource = "manual" }
        try store.write(topics: [t.id]) { db in
            try t.insert(db)
            if !text.isEmpty || !url.isEmpty {
                try Store.insertArtifact(db, topicId: t.id, Artifact(type: url.isEmpty ? "note" : "link", title: url.isEmpty ? "Pasted text" : url, url: url.isEmpty ? nil : url, content: text))
            }
            try Store.addTimeline(db, TimelineEntry(topicId: t.id, actor: "me", kind: "structure", en: "Created by you", zh: "你创建的"))
        }
        return t
    }

    /// Fill a link's context item once its page has been read (or record why it could not be).
    public static func fillArtifact(_ store: Store, topicId: String, artifactId: String, title: String?, content: String, ok: Bool, why: (String, String)? = nil) throws {
        try store.write(topics: [topicId]) { db in
            if let title, !title.isEmpty { try db.execute(sql: "update artifacts set title = ? where id = ?", arguments: [title, artifactId]) }
            try db.execute(sql: "update artifacts set content = ?, summary_en = '', summary_zh = '' where id = ?", arguments: [content, artifactId])
            let stored = try String.fetchOne(db, sql: "select title from artifacts where id = ?", arguments: [artifactId])
            let name = title ?? stored ?? ""
            let url = try String.fetchOne(db, sql: "select url from artifacts where id = ?", arguments: [artifactId])
            try Store.addTimeline(db, TimelineEntry(topicId: topicId, actor: "me", kind: "context",
                en: ok ? "Read linked page: \(name)" : "Could not read the linked page (\(why?.0 ?? "sign-in needed?")): \(name)",
                zh: ok ? "已读取链接页面：\(name)" : "无法读取链接页面（\(why?.1 ?? "可能需要登录")）：\(name)",
                sourceUrl: url))
        }
    }

    public static func addContext(_ store: Store, topicId: String, title: String, url: String, content: String) throws -> Artifact {
        let a = Artifact(type: url.isEmpty ? "note" : "link", title: title.isEmpty ? (url.isEmpty ? "Note" : url) : title, url: url.isEmpty ? nil : url, content: content)
        try store.write(topics: [topicId]) { db in
            try Store.insertArtifact(db, topicId: topicId, a)
            try Store.addTimeline(db, TimelineEntry(topicId: topicId, actor: "me", kind: "context", en: "Added context: \(a.title)", zh: "加入 context：\(a.title)", sourceUrl: a.url))
            try db.execute(sql: "update topics set last_activity_at = ?, archived_at = null where id = ?", arguments: [a.createdAt, topicId])
        }
        return a
    }

    public static func patch(_ store: Store, _ id: String, _ p: TopicPatch) throws {
        guard var t = store.topic(id) else { throw TopicError.notFound }
        if case let .some(pid?) = p.parentId, pid == id || isDescendant(store, pid, of: id) { throw TopicError.cycle }
        let names = Dictionary(store.levels().map { ($0.id, ($0.nameEn, $0.nameZh)) }, uniquingKeysWith: { a, _ in a })
        let n = { (u: Urgency) in names[u.rawValue] ?? (u.rawValue, u.rawValue) }
        try store.write(topics: [id]) { db in
            if let title = p.title, title != t.titleEn { t.titleEn = title; t.titleZh = title; t.titleSource = "me" }
            if let r = p.requester { t.requester = r }
            if let s = p.status, s != t.status {
                if s == .waiting && t.remindAt == nil && p.remindAt == nil && p.nextFollowupAt == nil {
                    t.remindAt = reminderTime(addWorkingDays(2)); t.remindNotifiedAt = nil; t.remindCount = 0
                }
                try Store.addTimeline(db, TimelineEntry(topicId: id, actor: "me", kind: "status",
                    en: "Status: \(statusLabel[t.status]!.0) → \(statusLabel[s]!.0)", zh: "状态：\(statusLabel[t.status]!.1) → \(statusLabel[s]!.1)"))
                t.status = s
            }
            if let u = p.urgency, u != t.urgency || t.urgencySource != "manual" {
                if t.urgencySource == "auto" { t.aiUrgency = t.urgency }
                try Store.addTimeline(db, TimelineEntry(topicId: id, actor: "me", kind: "urgency", en: "You set urgency \(n(t.urgency).0) → \(n(u).0)", zh: "你把紧急程度从\(n(t.urgency).1)改为\(n(u).1)"))
                t.urgency = u; t.urgencySource = "manual"; t.urgencyPinnedUntil = p.urgencyPinnedUntil ?? nil
            } else if let pin = p.urgencyPinnedUntil, t.urgencySource == "manual" {
                t.urgencyPinnedUntil = pin
            }
            if p.urgencyAuto && t.urgencySource == "manual" {
                t.urgencySource = "auto"; t.urgencyPinnedUntil = nil; t.urgency = t.aiUrgency ?? t.urgency
                try Store.addTimeline(db, TimelineEntry(topicId: id, actor: "me", kind: "urgency", en: "Urgency back to auto", zh: "紧急程度改回自动"))
            }
            if let f = p.nextFollowupAt { t.remindAt = f.flatMap { $0.isEmpty ? nil : reminderTime($0) }; t.remindNotifiedAt = nil; t.remindCount = 0 }
            if let r = p.remindAt {
                t.remindAt = r.flatMap { $0.isEmpty ? nil : reminderTime($0) }; t.remindNotifiedAt = nil; t.remindCount = 0
                try Store.addTimeline(db, TimelineEntry(topicId: id, actor: "me", kind: "reminder",
                    en: t.remindAt.map { "Reminder set for \(fmtLocal($0))" } ?? "Reminder cleared", zh: t.remindAt.map { "提醒时间设为 \(fmtLocal($0))" } ?? "已取消提醒"))
            }
            if let d = p.dueAt { t.dueAt = (d?.isEmpty ?? true) ? nil : d; t.dueSource = t.dueAt == nil ? nil : "me" }
            if let pid = p.parentId, pid != t.parentId {
                let parent = pid.flatMap { try? Topic.fetchOne(db, key: $0) }
                t.parentId = pid
                try Store.addTimeline(db, TimelineEntry(topicId: id, actor: "me", kind: "structure",
                    en: parent.map { "Moved under \"\($0.titleEn)\"" } ?? "Moved to top level", zh: parent.map { "移到「\($0.titleZh)」下面" } ?? "移到顶层"))
            }
            try t.update(db)
        }
    }

    static func isDescendant(_ store: Store, _ candidate: String, of ancestor: String) -> Bool {
        var cur = store.topic(candidate)
        while let p = cur?.parentId { if p == ancestor { return true }; cur = store.topic(p) }
        return false
    }

    /// Merge `src` into `dst`: context, timeline, chat and sub-topics move; src becomes a redirect.
    public static func merge(_ store: Store, _ srcId: String, into dstId: String) throws {
        guard let src = store.topic(srcId), var dst = store.topic(dstId), srcId != dstId else { throw TopicError.badMerge }
        if isDescendant(store, dstId, of: srcId) { throw TopicError.cycle }
        try store.write(topics: [srcId, dstId]) { db in
            try db.execute(sql: "insert or ignore into topic_artifacts(topic_id, artifact_id) select ?, artifact_id from topic_artifacts where topic_id = ?", arguments: [dstId, srcId])
            try db.execute(sql: "delete from topic_artifacts where topic_id = ?", arguments: [srcId])
            for table in ["timeline", "chat"] { try db.execute(sql: "update \(table) set topic_id = ? where topic_id = ?", arguments: [dstId, srcId]) }
            try db.execute(sql: "update topics set parent_id = ? where parent_id = ?", arguments: [dstId, srcId])
            try db.execute(sql: "update topics set merged_into = ? where id = ?", arguments: [dstId, srcId])
            try Store.addTimeline(db, TimelineEntry(topicId: dstId, actor: "me", kind: "structure", en: "Merged \"\(src.titleEn)\" into this topic", zh: "把「\(src.titleZh)」合并进来"))
            if src.urgency.rank < dst.urgency.rank && dst.urgencySource == "auto" { dst.urgency = src.urgency }
            dst.needsFreshSession = 1; dst.lastActivityAt = nowISO()
            try dst.update(db)
        }
    }

    /// Move the chosen artifacts and timeline entries into a new topic (top level or sub-topic).
    /// Moves one piece of context (e.g. a Slack conversation filed to the wrong topic) to another topic.
    /// Later replies in that Slack thread follow it; the old topic's brief starts a fresh session.
    public static func moveArtifact(_ store: Store, _ artifactId: String, from: String, to: String) throws {
        guard from != to, let src = store.topic(from), let dst = store.topic(to) else { throw TopicError.notFound }
        try store.write(topics: [from, to]) { db in
            try db.execute(sql: "update topic_artifacts set topic_id = ? where topic_id = ? and artifact_id = ?", arguments: [to, from, artifactId])
            guard db.changesCount > 0 else { throw TopicError.notFound }
            try followSlack(db, artifactId: artifactId, to: to)
            let title = try String.fetchOne(db, sql: "select title from artifacts where id = ?", arguments: [artifactId]) ?? ""
            try Store.addTimeline(db, TimelineEntry(topicId: to, actor: "me", kind: "structure", en: "Moved here from \"\(src.titleEn)\": \(title)", zh: "从「\(src.titleZh)」移过来：\(title)"))
            try Store.addTimeline(db, TimelineEntry(topicId: from, actor: "me", kind: "structure", en: "Moved to \"\(dst.titleEn)\": \(title)", zh: "移到了「\(dst.titleZh)」：\(title)"))
            try db.execute(sql: "update topics set needs_fresh_session = 1 where id = ?", arguments: [from])
            try db.execute(sql: "update topics set last_activity_at = ?, archived_at = null where id = ?", arguments: [nowISO(), to])
        }
    }

    static func followSlack(_ db: Database, artifactId: String, to: String) throws {
        try db.execute(sql: "update slack_messages set topic_id = ? where channel || ':' || coalesce(thread_ts, ts) in (select thread_key from slack_threads where artifact_id = ?)", arguments: [to, artifactId])
        try db.execute(sql: "update slack_threads set topic_id = ? where artifact_id = ?", arguments: [to, artifactId])
        try db.execute(sql: "update to_sort set filed_topic_id = ? where artifact_id = ?", arguments: [to, artifactId])
    }

    public static func split(_ store: Store, _ id: String, title: String, artifactIds: [String], timelineIds: [Int64], asSub: Bool) throws -> Topic {
        guard let t = store.topic(id) else { throw TopicError.notFound }
        var n = Topic(title: title, parentId: asSub ? id : t.parentId, requester: t.requester, titleSource: "me")
        n.urgency = t.urgency
        try store.write(topics: [id, n.id]) { db in
            try n.insert(db)
            for a in artifactIds {
                try db.execute(sql: "update topic_artifacts set topic_id = ? where topic_id = ? and artifact_id = ?", arguments: [n.id, id, a])
                try followSlack(db, artifactId: a, to: n.id)
            }
            for e in timelineIds { try db.execute(sql: "update timeline set topic_id = ? where topic_id = ? and id = ?", arguments: [n.id, id, e]) }
            try Store.addTimeline(db, TimelineEntry(topicId: n.id, actor: "me", kind: "structure", en: "Split from \"\(t.titleEn)\"", zh: "从「\(t.titleZh)」拆分出来"))
            try Store.addTimeline(db, TimelineEntry(topicId: id, actor: "me", kind: "structure", en: "Split out \"\(title)\"", zh: "拆分出「\(title)」"))
            try db.execute(sql: "update topics set needs_fresh_session = 1 where id = ?", arguments: [id])
        }
        return n
    }

    /// Slack messages logged in (after, until]: what a brief job saw that the previous brief did not.
    /// Replies in a mapped thread log "event"; a new conversation filed into the topic (e.g. a top-level DM) logs "context".
    public static func hasSlackNews(_ store: Store, _ id: String, after: String?, until: String) -> Bool {
        guard let after else { return false }
        return store.timeline(of: id).contains { $0.actor == "slack" && ($0.kind == "event" || $0.kind == "context") && $0.at > after && $0.at <= until }
    }

    /// Apply a brief from Claude. Manual urgency, her title, and dates she set are never overwritten.
    /// Status follows Claude only when the brief saw new Slack messages (`news`), so a plain refresh keeps hers.
    public static func applyBrief(_ store: Store, _ id: String, _ r: BriefResult, jobId: String, news: Bool = false) throws {
        guard var t = store.topic(id) else { return }
        let names = Dictionary(store.levels().map { ($0.id, ($0.nameEn, $0.nameZh)) }, uniquingKeysWith: { a, _ in a })
        let n = { (u: Urgency) in names[u.rawValue] ?? (u.rawValue, u.rawValue) }
        try store.write(topics: [id]) { db in
            let first = t.briefEn.isEmpty
            t.briefEn = r.briefEn; t.briefZh = r.briefZh; t.briefUpdatedAt = nowISO(); t.lastBriefAt = nowISO()
            t.urgencyReasonEn = r.urgencyReasonEn; t.urgencyReasonZh = r.urgencyReasonZh; t.aiUrgency = r.urgency
            if t.titleEn.isEmpty || (t.titleSource == "ai" && first) { t.titleEn = r.titleEn; t.titleZh = r.titleZh }
            else if t.titleZh == t.titleEn && !r.titleZh.isEmpty && t.titleSource == "ai" { t.titleZh = r.titleZh }
            if t.urgencySource == "auto" && r.urgency != t.urgency {
                try Store.addTimeline(db, TimelineEntry(topicId: id, actor: "claude", kind: "urgency",
                    en: "Urgency \(n(t.urgency).0) → \(n(r.urgency).0): \(r.urgencyReasonEn)", zh: "紧急程度\(n(t.urgency).1) → \(n(r.urgency).1)：\(r.urgencyReasonZh)", jobId: jobId))
                t.urgency = r.urgency
            }
            if let due = r.dueAt, !due.isEmpty, t.dueSource != "me" { t.dueAt = due; t.dueSource = "ai" }
            if news, let s = r.status, s != t.status, s == .needsMe || s == .done || (s == .waiting && (t.status == .needsMe || t.status == .done)) {
                try Store.addTimeline(db, TimelineEntry(topicId: id, actor: "claude", kind: "status",
                    en: "Status: \(statusLabel[t.status]!.0) → \(statusLabel[s]!.0): \(r.statusReasonEn ?? "")",
                    zh: "状态：\(statusLabel[t.status]!.1) → \(statusLabel[s]!.1)：\(r.statusReasonZh ?? "")", jobId: jobId))
                if s == .waiting && t.remindAt == nil { t.remindAt = reminderTime(addWorkingDays(2)); t.remindNotifiedAt = nil; t.remindCount = 0 }
                t.status = s
            }
            if first && t.remindAt == nil && t.status == .needsMe, let mins = try Level.fetchOne(db, key: t.urgency.rawValue)?.firstRemindMinutes {
                t.remindAt = ISO8601DateFormatter.mos.string(from: Date().addingTimeInterval(Double(mins) * 60))
            }
            if t.requester.isEmpty, let req = r.requester { t.requester = req }
            for s in r.artifactSummaries {
                try db.execute(sql: "update artifacts set summary_en = ?, summary_zh = ? where id = ?", arguments: [s.summaryEn, s.summaryZh, s.id])
            }
            try Store.addTimeline(db, TimelineEntry(topicId: id, actor: "claude", kind: "brief",
                en: first ? "Summary written" : "Summary updated", zh: first ? "写好了概要" : "更新了概要", jobId: jobId))
            try t.update(db)
        }
    }

    /// Archive a topic and its sub-topics; archived topics leave the lists and the AI prompts but stay searchable.
    public static func archive(_ store: Store, _ id: String, auto: Bool = false) throws {
        let ids = [id] + store.children(id).map(\.id)
        try store.write(topics: ids) { db in
            for t in ids { try db.execute(sql: "update topics set archived_at = ? where id = ? and archived_at is null", arguments: [nowISO(), t]) }
            try Store.addTimeline(db, TimelineEntry(topicId: id, actor: auto ? "claude" : "me", kind: "structure",
                en: auto ? "Archived automatically (done and quiet)" : "Archived", zh: auto ? "自动归档（已完成且没有新动态）" : "已归档"))
        }
    }

    public static func unarchive(_ store: Store, _ id: String) throws {
        let ids = [id] + store.children(id).map(\.id)
        try store.write(topics: ids) { db in
            for t in ids { try db.execute(sql: "update topics set archived_at = null where id = ?", arguments: [t]) }
            try Store.addTimeline(db, TimelineEntry(topicId: id, actor: "me", kind: "structure", en: "Moved back from the archive", zh: "从归档中恢复"))
        }
    }

    /// Delete a topic for good. Sub-topics move up to its parent; context only it used is removed; job history stays for cost totals.
    public static func delete(_ store: Store, _ id: String) throws {
        guard let t = store.topic(id) else { throw TopicError.notFound }
        try store.write(topics: [id]) { db in
            try db.execute(sql: "update topics set parent_id = ? where parent_id = ?", arguments: [t.parentId, id])
            try db.execute(sql: "update topics set merged_into = null, archived_at = coalesce(archived_at, ?) where merged_into = ?", arguments: [nowISO(), id])
            for table in ["timeline", "chat"] { try db.execute(sql: "delete from \(table) where topic_id = ?", arguments: [id]) }
            try db.execute(sql: "delete from topic_artifacts where topic_id = ?", arguments: [id])
            try db.execute(sql: "delete from artifacts where id not in (select artifact_id from topic_artifacts)")
            try db.execute(sql: "delete from topics where id = ?", arguments: [id])
        }
    }

    /// Done topics with no activity for `days` are archived by `tick`.
    public static let autoArchiveDays = 14

    public struct Reminder: Sendable { public var topic: Topic; public var level: Level; public var repeated: Bool }

    /// Housekeeping: expire manual urgency pins, auto-archive quiet done topics, and return reminders to send now
    /// (first time when due, then again every `repeatMinutes` of the topic's level until she handles it).
    public static func tick(_ store: Store, now: Date = Date()) -> [Reminder] {
        let day = localDay(now)
        var out: [Reminder] = []
        var touched: [String] = []
        let days = Int(store.setting("auto_archive_days") ?? "") ?? autoArchiveDays
        for t in store.activeTopics() where t.status == .done && t.parentId == nil && days > 0 {
            if let last = parseISO(t.lastActivityAt), now.timeIntervalSince(last) > Double(days) * 86400 { try? archive(store, t.id, auto: true) }
        }
        let levels = Dictionary(uniqueKeysWithValues: store.levels().map { ($0.id, $0) })
        for var t in store.activeTopics() {
            var changed = false
            // "Manual until <day>" holds through that day.
            if t.urgencySource == "manual", let pin = t.urgencyPinnedUntil, !pin.isEmpty, pin.prefix(10) < day {
                t.urgencySource = "auto"; t.urgencyPinnedUntil = nil; t.urgency = t.aiUrgency ?? t.urgency; changed = true
            }
            if reminderDue(t, now: now) {
                let level = levels[t.urgency.rawValue] ?? Level.defaults[t.urgency.rank]
                let last = t.remindNotifiedAt.flatMap(parseISO)
                let repeatDue = level.repeatMinutes > 0 && last.map { now.timeIntervalSince($0) >= Double(level.repeatMinutes) * 60 } ?? false
                if last == nil || repeatDue {
                    out.append(Reminder(topic: t, level: level, repeated: last != nil))
                    t.remindNotifiedAt = ISO8601DateFormatter.mos.string(from: now); t.remindCount += 1
                    if t.status == .snoozed { t.status = .needsMe }
                    changed = true
                }
            }
            if changed { try? store.db.write { try t.update($0) }; touched.append(t.id) }
        }
        if !touched.isEmpty { store.changed(topics: touched) }
        return out
    }
}

func fmtLocal(_ iso: String) -> String {
    guard let d = parseISO(iso) else { return iso }
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"
    return f.string(from: d)
}
