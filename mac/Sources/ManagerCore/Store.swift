import Foundation
import GRDB

/// SQLite store shared with the M0 web app (same schema), plus the search index.
public final class Store: @unchecked Sendable {
    public let db: DatabaseQueue
    private let lock = NSLock()
    private var _version = 0
    private var observers: [@Sendable () -> Void] = []
    private var dirty = Set<String>()

    public var version: Int { lock.withLock { _version } }

    public init(path: String) throws {
        var config = Configuration()
        config.prepareDatabase { db in try db.execute(sql: "pragma journal_mode = wal") }
        db = try DatabaseQueue(path: path, configuration: config)
        try db.write { db in
            try db.execute(sql: Store.schema)
            let cols = try Set(db.columns(in: "topics").map(\.name))
            if !cols.contains("archived_at") { try db.execute(sql: "alter table topics add column archived_at text") }
            if !cols.contains("remind_at") {
                try db.execute(sql: "alter table topics add column remind_at text")
                try db.execute(sql: "alter table topics add column remind_notified_at text")
                try db.execute(sql: "alter table topics add column remind_count integer not null default 0")
                // M0 follow-up dates become 09:00 local reminders.
                for row in try Row.fetchAll(db, sql: "select id, next_followup_at from topics where next_followup_at is not null") {
                    let day: String = row["next_followup_at"]
                    if let d = parseISO(day), let at = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: d) {
                        try db.execute(sql: "update topics set remind_at = ? where id = ?", arguments: [ISO8601DateFormatter.mos.string(from: at), row["id"] as String])
                    }
                }
            }
            let sortCols = try Set(db.columns(in: "to_sort").map(\.name))
            if !sortCols.contains("filed_topic_id") {
                try db.execute(sql: "alter table to_sort add column filed_topic_id text")
                try db.execute(sql: "alter table to_sort add column artifact_id text")
                try db.execute(sql: "alter table to_sort add column filed_by text")
            }
            try db.execute(sql: "update levels set name_en = 'Now', name_zh = '立即' where id = 'P0' and name_en = 'Incident' and name_zh = '事故'")
            if try Int.fetchOne(db, sql: "select count(*) from levels") == 0 { for l in Level.defaults { try l.insert(db) } }
        }
    }

    /// Register a callback that runs after every write.
    public func onChange(_ f: @escaping @Sendable () -> Void) { lock.withLock { observers.append(f) } }

    public func changed(topics: [String?] = []) {
        let fs: [@Sendable () -> Void] = lock.withLock {
            _version += 1
            for t in topics { if let t { dirty.insert(t) } }
            return observers
        }
        for f in fs { f() }
    }

    func takeDirty() -> Set<String> { lock.withLock { let d = dirty; dirty = []; return d } }

    @discardableResult
    public func write<T>(topics: [String?] = [], _ f: (Database) throws -> T) throws -> T {
        let r = try db.write(f)
        changed(topics: topics)
        return r
    }
    public func read<T>(_ f: (Database) throws -> T) throws -> T { try db.read(f) }

    // MARK: Queries

    public func topic(_ id: String) -> Topic? { try? read { try Topic.fetchOne($0, key: id) } }
    public func topics() -> [Topic] { (try? read { try Topic.filter(Column("merged_into") == nil).fetchAll($0) }) ?? [] }
    /// Topics that are not archived (the working set the AI prompts look at).
    public func activeTopics() -> [Topic] { topics().filter { !$0.isArchived } }
    public func children(_ id: String) -> [Topic] {
        (try? read { try Topic.filter(Column("parent_id") == id && Column("merged_into") == nil).fetchAll($0) }) ?? []
    }
    public func artifacts(of topicId: String) -> [Artifact] {
        (try? read { try Artifact.fetchAll($0, sql: "select a.* from artifacts a join topic_artifacts ta on ta.artifact_id = a.id where ta.topic_id = ? order by a.created_at", arguments: [topicId]) }) ?? []
    }
    public func timeline(of topicId: String) -> [TimelineEntry] {
        (try? read { try TimelineEntry.fetchAll($0, sql: "select * from timeline where topic_id = ? order by at, id", arguments: [topicId]) }) ?? []
    }
    public func chat(of topicId: String?) -> [ChatRow] {
        (try? read { db in
            topicId == nil
                ? try ChatRow.fetchAll(db, sql: "select * from chat where topic_id is null order by id")
                : try ChatRow.fetchAll(db, sql: "select * from chat where topic_id = ? order by id", arguments: [topicId])
        }) ?? []
    }
    public func jobs(limit: Int = 300) -> [Job] { (try? read { try Job.fetchAll($0, sql: "select * from jobs order by created_at desc limit ?", arguments: [limit]) }) ?? [] }
    public func jobs(of topicId: String) -> [Job] { (try? read { try Job.fetchAll($0, sql: "select * from jobs where topic_id = ? order by created_at", arguments: [topicId]) }) ?? [] }
    public func levels() -> [Level] { (try? read { try Level.fetchAll($0, sql: "select * from levels order by id") }) ?? Level.defaults }
    public func level(_ u: Urgency) -> Level { levels().first { $0.id == u.rawValue } ?? Level.defaults[u.rank] }
    public func people() -> [Person] { (try? read { try Person.fetchAll($0, sql: "select * from people order by weight desc, name") }) ?? [] }
    public func setting(_ key: String) -> String? { try? read { try String.fetchOne($0, sql: "select value from settings where key = ?", arguments: [key]) } }
    public func setSetting(_ key: String, _ value: String) {
        try? write { try $0.execute(sql: "insert into settings(key, value) values (?, ?) on conflict(key) do update set value = excluded.value", arguments: [key, value]) }
    }

    // MARK: Inserts used across modules

    public static func insertArtifact(_ db: Database, topicId: String, _ a: Artifact) throws {
        try a.insert(db)
        try db.execute(sql: "insert or ignore into topic_artifacts(topic_id, artifact_id) values (?, ?)", arguments: [topicId, a.id])
    }
    @discardableResult
    public static func addTimeline(_ db: Database, _ e: TimelineEntry) throws -> Int64 {
        var e = e
        try e.insert(db)
        return e.id!
    }
    @discardableResult
    public static func addChat(_ db: Database, _ c: ChatRow) throws -> Int64 {
        var c = c
        try c.insert(db)
        return c.id!
    }

    static let schema = """
    create table if not exists topics(
      id text primary key, parent_id text, merged_into text,
      title_en text not null default '', title_zh text not null default '', title_source text not null default 'ai',
      requester text not null default '', status text not null default 'needs_me',
      urgency text not null default 'P2', urgency_source text not null default 'auto', urgency_pinned_until text,
      ai_urgency text, urgency_reason_en text not null default '', urgency_reason_zh text not null default '',
      due_at text, due_source text, next_followup_at text, followup_notified_at text,
      brief_en text not null default '', brief_zh text not null default '', brief_updated_at text,
      brief_state text not null default 'idle', brief_dirty integer not null default 0, last_brief_at text,
      claude_session_id text, session_tokens integer not null default 0, needs_fresh_session integer not null default 0,
      created_at text not null, last_activity_at text not null
    );
    create table if not exists artifacts(
      id text primary key, type text not null, title text not null default '', url text, content text not null default '',
      summary_en text not null default '', summary_zh text not null default '', added_by text not null default 'me', created_at text not null
    );
    create table if not exists topic_artifacts(topic_id text not null, artifact_id text not null, primary key(topic_id, artifact_id));
    create table if not exists timeline(
      id integer primary key autoincrement, topic_id text not null, at text not null, actor text not null, kind text not null default 'event',
      summary_en text not null default '', summary_zh text not null default '', source_url text, raw text, job_id text
    );
    create table if not exists chat(
      id integer primary key autoincrement, topic_id text, at text not null, role text not null,
      text_en text not null default '', text_zh text not null default '', voice integer not null default 0, job_id text,
      actions text, action_state text
    );
    create table if not exists jobs(
      id text primary key, kind text not null, topic_id text, status text not null,
      trigger_en text not null default '', trigger_zh text not null default '', model text not null default '', session_id text, payload text,
      created_at text not null, started_at text, finished_at text, duration_ms integer,
      input_tokens integer, output_tokens integer, cache_read integer, cache_write integer, cost_usd real, error text
    );
    create table if not exists people(
      id text primary key, name text not null, relationship text not null default 'other', slack text not null default '',
      email text not null default '', zoom text not null default '', weight real not null default 1.0,
      can_interrupt text not null default 'never', notes text not null default ''
    );
    create table if not exists settings(key text primary key, value text not null);
    create table if not exists levels(
      id text primary key, name_en text not null, name_zh text not null, description text not null default '', color text not null,
      notify text not null default 'silent', first_remind_minutes integer, repeat_minutes integer not null default 0, breaks_focus integer not null default 0
    );
    create index if not exists timeline_topic on timeline(topic_id, at);
    create index if not exists chat_topic on chat(topic_id, id);
    create table if not exists slack_messages(
      channel text not null, ts text not null, thread_ts text, user text not null default '', user_name text not null default '',
      channel_name text not null default '', text text not null default '', subtype text, permalink text,
      received_at text not null, topic_id text, to_sort_id text, flushed integer not null default 0, mine integer not null default 0,
      primary key(channel, ts)
    );
    create table if not exists slack_threads(
      thread_key text primary key, topic_id text, state text not null default 'participated', artifact_id text
    );
    create table if not exists to_sort(
      id text primary key, source text not null, channel text not null, channel_name text not null default '', thread_key text not null,
      title text not null default '', permalink text, status text not null default 'pending',
      prefill_topic_id text, prefill_title_en text, prefill_title_zh text, prefill_reason_en text, prefill_reason_zh text, triaged_at text,
      created_at text not null, updated_at text not null
    );
    create virtual table if not exists search_index using fts5(
      topic_id unindexed, kind unindexed, text unindexed, body, tokenize = 'unicode61 remove_diacritics 2'
    );
    """
}
