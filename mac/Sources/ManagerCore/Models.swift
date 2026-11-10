import Foundation
import GRDB

public enum Urgency: String, Codable, CaseIterable, Sendable {
    case P0, P1, P2, P3
    public var weight: Double { [.P0: 5, .P1: 2, .P2: 1, .P3: 0.5][self]! }
    public var rank: Int { Urgency.allCases.firstIndex(of: self)! }
}

public enum TopicStatus: String, Codable, CaseIterable, Sendable {
    case needsMe = "needs_me", waiting, snoozed, done
}

/// Columns match the M0 schema so the same database file works in both apps.
public struct Topic: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "topics"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    public var id: String
    public var parentId: String?
    public var mergedInto: String?
    public var titleEn: String
    public var titleZh: String
    public var titleSource: String
    public var requester: String
    public var status: TopicStatus
    public var urgency: Urgency
    public var urgencySource: String
    public var urgencyPinnedUntil: String?
    public var aiUrgency: Urgency?
    public var urgencyReasonEn: String
    public var urgencyReasonZh: String
    public var dueAt: String?
    public var dueSource: String?
    public var nextFollowupAt: String?
    public var followupNotifiedAt: String?
    public var briefEn: String
    public var briefZh: String
    public var briefUpdatedAt: String?
    public var briefState: String
    public var briefDirty: Int
    public var lastBriefAt: String?
    public var claudeSessionId: String?
    public var sessionTokens: Int
    public var needsFreshSession: Int
    public var createdAt: String
    public var lastActivityAt: String
    public var archivedAt: String?
    /// When to remind her (ISO datetime). Stays due until she handles it; repeats per the level's rule.
    public var remindAt: String?
    public var remindNotifiedAt: String?
    public var remindCount: Int

    public var isArchived: Bool { archivedAt != nil }

    public init(id: String = newId("t"), title: String, parentId: String? = nil, requester: String = "", titleSource: String = "ai") {
        let ts = nowISO()
        self.id = id; self.parentId = parentId; self.mergedInto = nil
        self.titleEn = title; self.titleZh = title; self.titleSource = titleSource
        self.requester = requester; self.status = .needsMe; self.urgency = .P2; self.urgencySource = "auto"
        self.urgencyPinnedUntil = nil; self.aiUrgency = nil; self.urgencyReasonEn = ""; self.urgencyReasonZh = ""
        self.dueAt = nil; self.dueSource = nil; self.nextFollowupAt = nil; self.followupNotifiedAt = nil
        self.briefEn = ""; self.briefZh = ""; self.briefUpdatedAt = nil; self.briefState = "idle"; self.briefDirty = 0
        self.lastBriefAt = nil; self.claudeSessionId = nil; self.sessionTokens = 0; self.needsFreshSession = 0
        self.createdAt = ts; self.lastActivityAt = ts; self.archivedAt = nil
        self.remindAt = nil; self.remindNotifiedAt = nil; self.remindCount = 0
    }
}

/// One of the four urgency levels (ids P0–P3). She can rename them and change their rules.
public struct Level: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord, Identifiable {
    public static let databaseTableName = "levels"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase
    public var id: String          // P0 | P1 | P2 | P3
    public var nameEn: String
    public var nameZh: String
    public var description: String // what belongs here; Claude reads it when it picks a level
    public var color: String       // hex
    public var notify: String      // interrupt | silent | none
    public var firstRemindMinutes: Int? // automatic first reminder after a topic gets this level; nil = none
    public var repeatMinutes: Int  // re-remind interval while unhandled; 0 = no repeat
    public var breaksFocus: Int

    public static let defaults: [Level] = [
        Level(id: "P0", nameEn: "Now", nameZh: "立即", description: "Active incident or customer impact, or her manager needs it within hours.",
              color: "#E8436C", notify: "interrupt", firstRemindMinutes: 0, repeatMinutes: 30, breaksFocus: 1),
        Level(id: "P1", nameEn: "Today", nameZh: "今天", description: "Due today or tomorrow, or blocking other people.",
              color: "#E8890C", notify: "silent", firstRemindMinutes: 120, repeatMinutes: 180, breaksFocus: 0),
        Level(id: "P2", nameEn: "This week", nameZh: "本周", description: "Should be handled this week.",
              color: "#4C6EF5", notify: "silent", firstRemindMinutes: 1440, repeatMinutes: 1440, breaksFocus: 0),
        Level(id: "P3", nameEn: "FYI", nameZh: "仅供参考", description: "No deadline; for awareness.",
              color: "#9AA0A6", notify: "none", firstRemindMinutes: nil, repeatMinutes: 0, breaksFocus: 0),
    ]
}

public struct Artifact: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord, Identifiable {
    public static let databaseTableName = "artifacts"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase
    public var id: String
    public var type: String
    public var title: String
    public var url: String?
    public var content: String
    public var summaryEn: String
    public var summaryZh: String
    public var addedBy: String
    public var createdAt: String

    public init(type: String, title: String, url: String? = nil, content: String = "", summaryEn: String = "", summaryZh: String = "", addedBy: String = "me") {
        self.id = newId("a"); self.type = type; self.title = title; self.url = url; self.content = content
        self.summaryEn = summaryEn; self.summaryZh = summaryZh; self.addedBy = addedBy; self.createdAt = nowISO()
    }
}

public struct TimelineEntry: Codable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord, Identifiable {
    public static let databaseTableName = "timeline"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase
    public var id: Int64?
    public var topicId: String
    public var at: String
    public var actor: String
    public var kind: String
    public var summaryEn: String
    public var summaryZh: String
    public var sourceUrl: String?
    public var raw: String?
    public var jobId: String?

    public init(topicId: String, actor: String, kind: String = "event", en: String, zh: String? = nil, sourceUrl: String? = nil, raw: String? = nil, jobId: String? = nil) {
        self.id = nil; self.topicId = topicId; self.at = nowISO(); self.actor = actor; self.kind = kind
        self.summaryEn = en; self.summaryZh = zh ?? en; self.sourceUrl = sourceUrl; self.raw = raw; self.jobId = jobId
    }
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct ChatAction: Codable, Hashable, Sendable {
    public var type: String
    public var topicId: String?
    public var textEn: String
    public var textZh: String
    public var value: String
    enum CodingKeys: String, CodingKey { case type, topicId = "topic_id", textEn = "text_en", textZh = "text_zh", value }
}

public struct ActionState: Codable, Hashable, Sendable {
    public var state: String // applied | pending | confirmed | cancelled | undone
    public var ref: String?
    public init(state: String, ref: String? = nil) { self.state = state; self.ref = ref }
    enum CodingKeys: String, CodingKey { case state, ref }
    /// M0 stored timeline refs as numbers; accept both.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = try c.decode(String.self, forKey: .state)
        if let s = try? c.decodeIfPresent(String.self, forKey: .ref) { ref = s }
        else if let n = try? c.decodeIfPresent(Int64.self, forKey: .ref) { ref = String(n) }
        else { ref = nil }
    }
}

public struct ChatActions: Codable, Hashable, Sendable {
    public var items: [ChatAction]
    public var links: [String]?
}

public struct ChatRow: Codable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord, Identifiable {
    public static let databaseTableName = "chat"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase
    public var id: Int64?
    public var topicId: String?
    public var at: String
    public var role: String // user | assistant | run
    public var textEn: String
    public var textZh: String
    public var voice: Int
    public var jobId: String?
    public var actions: String?
    public var actionState: String?

    public init(topicId: String?, role: String, en: String, zh: String? = nil, jobId: String? = nil, actions: ChatActions? = nil, states: [ActionState]? = nil) {
        self.id = nil; self.topicId = topicId; self.at = nowISO(); self.role = role
        self.textEn = en; self.textZh = zh ?? en; self.voice = 0; self.jobId = jobId
        self.actions = actions.flatMap { try? String(data: JSONEncoder().encode($0), encoding: .utf8) }
        self.actionState = states.flatMap { try? String(data: JSONEncoder().encode($0), encoding: .utf8) }
    }
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    public var decodedActions: ChatActions? { actions.flatMap { try? JSONDecoder().decode(ChatActions.self, from: Data($0.utf8)) } }
    public var decodedStates: [ActionState] { actionState.flatMap { try? JSONDecoder().decode([ActionState].self, from: Data($0.utf8)) } ?? [] }
}

public struct Job: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord, Identifiable {
    public static let databaseTableName = "jobs"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase
    public var id: String
    public var kind: String // brief | chat | assistant | search
    public var topicId: String?
    public var status: String // queued | running | done | error
    public var triggerEn: String
    public var triggerZh: String
    public var model: String
    public var sessionId: String?
    public var payload: String?
    public var createdAt: String
    public var startedAt: String?
    public var finishedAt: String?
    public var durationMs: Int?
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var cacheRead: Int?
    public var cacheWrite: Int?
    public var costUsd: Double?
    public var error: String?

    public init(kind: String, topicId: String?, trigger: (String, String), model: String, payload: String? = nil) {
        self.id = newId("j"); self.kind = kind; self.topicId = topicId; self.status = "queued"
        self.triggerEn = trigger.0; self.triggerZh = trigger.1; self.model = model; self.sessionId = nil; self.payload = payload
        self.createdAt = nowISO(); self.startedAt = nil; self.finishedAt = nil; self.durationMs = nil
        self.inputTokens = nil; self.outputTokens = nil; self.cacheRead = nil; self.cacheWrite = nil; self.costUsd = nil; self.error = nil
    }
}

public struct Person: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord, Identifiable {
    public static let databaseTableName = "people"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase
    public var id: String
    public var name: String
    public var relationship: String
    public var slack: String
    public var email: String
    public var zoom: String
    public var weight: Double
    public var canInterrupt: String
    public var notes: String

    public init(name: String, relationship: String = "other", weight: Double = 1) {
        self.id = newId("p"); self.name = name; self.relationship = relationship; self.slack = ""; self.email = ""
        self.zoom = ""; self.weight = weight; self.canInterrupt = "never"; self.notes = ""
    }
}

public func newId(_ prefix: String) -> String {
    prefix + "_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(10)
}

private let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
public func nowISO() -> String { isoFormatter.string(from: Date()) }
public func parseISO(_ s: String) -> Date? {
    isoFormatter.date(from: s) ?? ISO8601DateFormatter().date(from: s) ?? {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] { f.dateFormat = fmt; if let d = f.date(from: s) { return d } }
        return nil
    }()
}
/// Local calendar date as YYYY-MM-DD.
public func localDay(_ d: Date = Date()) -> String {
    let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
    return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
}
