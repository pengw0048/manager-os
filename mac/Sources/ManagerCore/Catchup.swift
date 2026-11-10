import Foundation
import GRDB

/// "What changed since X": the away summary and the morning / evening digests, built from the timeline without AI.
public enum Catchup {
    public enum Kind: String, Sendable { case away, morning, evening }

    public struct Item: Sendable, Identifiable {
        public var topic: Topic
        public var entries: [TimelineEntry]
        public var isNew: Bool
        public var id: String { topic.id }
    }

    public struct Counts: Sendable, Equatable {
        public var topics = 0, needsMe = 0, remindersDue = 0, dueToday = 0
    }

    /// An open summary page: since when, and why it opened.
    public struct Pending: Sendable, Equatable { public var since: String; public var kind: Kind }

    public static let awayGap: TimeInterval = 30 * 60
    public static let defaultMorning = "09:00", defaultEvening = "17:30"

    /// Non-archived topics with entries after `since` that she did not write (Slack messages, automatic status and
    /// urgency changes, conversations filed automatically), each with those entries; highest score first.
    public static func changes(_ store: Store, since: String) -> [Item] {
        let rows = (try? store.read { try TimelineEntry.fetchAll($0, sql: "select * from timeline where at > ? and actor != 'me' and kind != 'brief' order by at, id", arguments: [since]) }) ?? []
        let byTopic = Dictionary(grouping: rows, by: \.topicId)
        let items = byTopic.compactMap { id, entries -> Item? in
            guard let t = store.topic(id), t.mergedInto == nil, !t.isArchived else { return nil }
            return Item(topic: t, entries: entries, isNew: t.createdAt > since)
        }
        return items.sorted { TopicOps.score(store, $0.topic) > TopicOps.score(store, $1.topic) }
    }

    public static func counts(_ store: Store, _ items: [Item], now: Date = Date()) -> Counts {
        let open = store.activeTopics().filter { $0.status != .done }
        let today = localDay(now)
        return Counts(topics: items.count, needsMe: items.filter { $0.topic.status == .needsMe }.count,
                      remindersDue: open.filter { TopicOps.reminderDue($0, now: now) }.count,
                      dueToday: open.filter { ($0.dueAt.flatMap(parseISO)).map { localDay($0) == today } ?? false }.count)
    }

    public static func pending(_ store: Store) -> Pending? {
        guard let s = store.setting("catchup_since"), !s.isEmpty else { return nil }
        return Pending(since: s, kind: Kind(rawValue: store.setting("catchup_kind") ?? "") ?? .away)
    }

    public static func markRead(_ store: Store) {
        for k in ["catchup_since", "catchup_kind", "catchup_overview", "catchup_overview_since"] { store.setSetting(k, "") }
    }

    /// Runs at launch and every minute. Opens the away summary after a gap of 30 min, and fires a digest once its
    /// time has passed on a weekday (only the latest one when both are pending). Returns the digest that fired.
    @discardableResult
    public static func tick(_ store: Store, now: Date = Date()) -> Kind? {
        let iso = ISO8601DateFormatter.mos.string(from: now)
        defer { store.setSetting("last_seen", iso, quiet: true) }
        if let seen = store.setting("last_seen").flatMap(parseISO), now.timeIntervalSince(seen) > awayGap, pending(store) == nil {
            store.setSetting("catchup_kind", Kind.away.rawValue)
            store.setSetting("catchup_since", ISO8601DateFormatter.mos.string(from: seen))
        }
        guard store.setting("digest_enabled") != "0" else { return nil }
        guard let lastRaw = store.setting("digest_last"), let last = parseISO(lastRaw) else {
            store.setSetting("digest_last", iso, quiet: true); return nil // first run: start counting from now
        }
        let cal = Calendar.current
        guard !cal.isDateInWeekend(now) else { return nil }
        let times: [(Kind, Date)] = [(.morning, store.setting("digest_morning") ?? defaultMorning), (.evening, store.setting("digest_evening") ?? defaultEvening)]
            .compactMap { k, hm in at(hm, on: now).map { (k, $0) } }
        guard let fire = times.filter({ $0.1 <= now && $0.1 > last }).max(by: { $0.1 < $1.1 }) else { return nil }
        if pending(store) == nil { store.setSetting("catchup_since", lastRaw) } // an unread earlier summary keeps its start
        store.setSetting("catchup_kind", fire.0.rawValue)
        store.setSetting("digest_last", iso, quiet: true)
        return fire.0
    }

    /// "HH:mm" on the day of `d`, local time.
    public static func at(_ hm: String, on d: Date) -> Date? {
        let p = hm.split(separator: ":").compactMap { Int($0) }
        guard p.count == 2 else { return nil }
        return Calendar.current.date(bySettingHour: p[0], minute: p[1], second: 0, of: d)
    }

    public static let overviewSchema = #"{"type":"object","properties":{"overview":{"type":"string"}},"required":["overview"]}"#

    public static let overviewSystem = """
    You write the opening of a digest for an Engineering Manager in "Manager OS". Below are the topics that changed and
    what changed. Write 3 to 6 short lines in Simplified Chinese (Markdown bullets): what needs her first, what moved, what
    can wait. Keep code identifiers and established English engineering terms in English. Refer to topics by title. Do not invent facts.
    """

    public static func overviewPrompt(_ store: Store, _ items: [Item], since: String) -> String {
        let body = items.prefix(30).map { it in
            "### \(it.topic.titleEn) [\(it.topic.urgency.rawValue), \(it.topic.status.rawValue)\(it.isNew ? ", new" : "")]\n"
                + it.entries.suffix(8).map { "- \($0.summaryEn)" + ($0.raw.map { "\n  " + Prompts.clip($0, 600).replacingOccurrences(of: "\n", with: "\n  ") } ?? "") }.joined(separator: "\n")
        }.joined(separator: "\n\n")
        return "Since: \(fmtLocal(since))\nToday: \(localDay())\n\n" + (body.isEmpty ? "(nothing changed)" : body)
    }
}
