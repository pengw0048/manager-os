import Foundation
import GRDB

/// Keyword search: FTS5 (unicode61) over a bigram-expanded copy of each topic's text.
public enum Search {
    public struct Hit: Hashable, Sendable {
        public var topicId: String
        public var kind: String
        public var snippet: String
    }

    static let cjk = try! NSRegularExpression(pattern: "[\\u3400-\\u9fff\\uf900-\\ufaff\\u3040-\\u30ff]+")

    /// Each CJK run becomes its characters plus overlapping bigrams; other text is left for unicode61.
    public static func expand(_ s: String) -> String {
        let ns = s as NSString
        var out = "", last = 0
        for m in cjk.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let chars = Array(ns.substring(with: m.range)).map(String.init)
            var toks = chars
            if chars.count > 1 { for i in 0..<(chars.count - 1) { toks.append(chars[i] + chars[i + 1]) } }
            out += " " + toks.joined(separator: " ") + " "
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }

    /// Query → FTS5 expression: CJK words as bigram phrases, other words as prefix terms, all ANDed.
    public static func ftsQuery(_ q: String) -> String? {
        let terms = q.split(whereSeparator: { $0.isWhitespace }).compactMap { w -> String? in
            let word = String(w).replacingOccurrences(of: "\"", with: "")
            let ns = word as NSString
            if cjk.firstMatch(in: word, range: NSRange(location: 0, length: ns.length)) != nil {
                var parts: [String] = []
                var last = 0
                for m in cjk.matches(in: word, range: NSRange(location: 0, length: ns.length)) {
                    let before = ns.substring(with: NSRange(location: last, length: m.range.location - last))
                    parts += before.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { "\"\($0)\"*" }
                    let c = Array(ns.substring(with: m.range)).map(String.init)
                    parts.append(c.count == 1 ? "\"\(c[0])\"" : "\"" + (0..<(c.count - 1)).map { c[$0] + c[$0 + 1] }.joined(separator: " ") + "\"")
                    last = m.range.location + m.range.length
                }
                parts += ns.substring(from: last).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { "\"\($0)\"*" }
                return parts.isEmpty ? nil : parts.joined(separator: " AND ")
            }
            let clean = word.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { "\"\($0)\"*" }
            return clean.isEmpty ? nil : clean.joined(separator: " AND ")
        }
        return terms.isEmpty ? nil : terms.joined(separator: " AND ")
    }

    /// Rebuild index rows of topics that changed since the last search.
    public static func refresh(_ store: Store, all: Bool = false) throws {
        let ids: [String] = all ? store.topics().map(\.id) + ((try? store.read { try String.fetchAll($0, sql: "select id from topics where merged_into is not null") }) ?? [])
                                : Array(store.takeDirty())
        guard !ids.isEmpty else { return }
        try store.db.write { db in
            if all { try db.execute(sql: "delete from search_index") }
            for id in ids {
                try db.execute(sql: "delete from search_index where topic_id = ?", arguments: [id])
                guard let t = try Topic.fetchOne(db, key: id), t.mergedInto == nil else { continue }
                var rows: [(String, String)] = [("title", t.titleEn + " " + t.titleZh), ("brief", t.briefEn + "\n" + t.briefZh), ("requester", t.requester)]
                for a in try Artifact.fetchAll(db, sql: "select a.* from artifacts a join topic_artifacts ta on ta.artifact_id = a.id where ta.topic_id = ?", arguments: [id]) {
                    rows.append(("context", [a.title, a.url ?? "", a.summaryEn, a.summaryZh, a.content].joined(separator: "\n")))
                }
                for e in try TimelineEntry.fetchAll(db, sql: "select * from timeline where topic_id = ?", arguments: [id]) { rows.append(("timeline", e.summaryEn + " " + e.summaryZh)) }
                for c in try ChatRow.fetchAll(db, sql: "select * from chat where topic_id = ? and role != 'run'", arguments: [id]) { rows.append(("chat", c.textEn + " " + c.textZh)) }
                for (kind, text) in rows where !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    try db.execute(sql: "insert into search_index(topic_id, kind, text, body) values (?, ?, ?, ?)", arguments: [id, kind, text, expand(text)])
                }
            }
        }
    }

    /// Ranked hits, one per topic (best match first), each with a snippet around the first matching word.
    public static func keyword(_ store: Store, _ q: String, limit: Int = 30) throws -> [Hit] {
        guard let fts = ftsQuery(q) else { return [] }
        // Build the whole index once per database (e.g. data created by M0 or an older version).
        if store.setting("search_index_version") != "1" { try refresh(store, all: true); store.setSetting("search_index_version", "1") }
        try refresh(store)
        let rows = try store.read { try Row.fetchAll($0, sql: "select topic_id, kind, text from search_index where search_index match ? order by bm25(search_index) limit 300", arguments: [fts]) }
        var seen = Set<String>(), out: [Hit] = []
        for r in rows {
            let id: String = r["topic_id"]
            guard seen.insert(id).inserted else { continue }
            out.append(Hit(topicId: id, kind: r["kind"], snippet: snippet(r["text"], q)))
            if out.count >= limit { break }
        }
        return out
    }

    static func snippet(_ text: String, _ q: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        let words = q.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard let r = words.lazy.compactMap({ flat.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) }).first else { return String(flat.prefix(120)) }
        let start = flat.index(r.lowerBound, offsetBy: -40, limitedBy: flat.startIndex) ?? flat.startIndex
        let end = flat.index(r.upperBound, offsetBy: 80, limitedBy: flat.endIndex) ?? flat.endIndex
        return (start > flat.startIndex ? "…" : "") + flat[start..<end] + (end < flat.endIndex ? "…" : "")
    }
}
