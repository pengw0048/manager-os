import Foundation

public enum Knowledge {
    static let templates: [(String, String)] = [
        ("CLAUDE.md", """
        # About me
        - Role: Engineering Manager. (Edit: team, size, what you own.)
        - How I like briefs: the ask first, then evidence. Keep it short.

        # Knowledge files
        - @knowledge/me.md
        - @knowledge/people.md
        - @knowledge/where-to-find.md
        - @knowledge/systems.md
        - @knowledge/team.md

        """),
        ("knowledge/me.md", "# What I already know\n## Know well — do not explain\n-\n## Learning — explain in one line\n-\n## New to me — explain fully with an example\n-\n"),
        ("knowledge/where-to-find.md", "# Where to find things\n- Team space:\n- Runbooks:\n- Planning docs:\n"),
        ("knowledge/systems.md", "# Systems we own\n"),
        ("knowledge/team.md", "# Team norms\n"),
    ]

    public static func resolveHome() -> String {
        let raw = ProcessInfo.processInfo.environment["MANAGER_OS_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("ManagerOS").path
        let url = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath).standardizedFileURL
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath().path
    }

    public static func initHome(_ home: String) throws {
        let fm = FileManager.default
        for d in ["knowledge", "data"] { try fm.createDirectory(atPath: "\(home)/\(d)", withIntermediateDirectories: true) }
        for (rel, body) in templates where !fm.fileExists(atPath: "\(home)/\(rel)") { try body.write(toFile: "\(home)/\(rel)", atomically: true, encoding: .utf8) }
    }

    /// people.md is generated from Settings → People so Claude sees the same list.
    public static func exportPeople(_ store: Store, home: String) {
        let lines = store.people().map { p in
            "- \(p.name) — \(p.relationship)" + (p.slack.isEmpty ? "" : ", Slack \(p.slack)") + (p.email.isEmpty ? "" : ", \(p.email)")
                + ". Weight \(p.weight)." + (p.notes.isEmpty ? "" : " \(p.notes)")
        }
        try? ("# People (generated from Settings → People; edit there)\n" + lines.joined(separator: "\n") + "\n")
            .write(toFile: "\(home)/knowledge/people.md", atomically: true, encoding: .utf8)
    }

    public struct File: Hashable, Sendable { public var path: String; public var updatedAt: Date; public var generated: Bool }

    public static func list(_ home: String) -> [File] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: "\(home)/knowledge")) ?? []).filter { $0.hasSuffix(".md") }.sorted()
        return (["CLAUDE.md"] + names.map { "knowledge/\($0)" }).map { rel in
            let attrs = try? FileManager.default.attributesOfItem(atPath: "\(home)/\(rel)")
            return File(path: rel, updatedAt: attrs?[.modificationDate] as? Date ?? .distantPast, generated: rel == "knowledge/people.md")
        }
    }

    static func safe(_ home: String, _ rel: String) throws -> String {
        let f = URL(fileURLWithPath: home).appendingPathComponent(rel).standardizedFileURL.path
        guard f.hasPrefix(home + "/"), f.hasSuffix(".md") else { throw TopicError.notFound }
        return f
    }
    public static func read(_ home: String, _ rel: String) -> String { (try? String(contentsOfFile: safe(home, rel), encoding: .utf8)) ?? "" }
    public static func write(_ home: String, _ rel: String, _ body: String) throws {
        guard rel != "knowledge/people.md" else { return }
        try body.write(toFile: try safe(home, rel), atomically: true, encoding: .utf8)
    }

    /// Where Claude Code stores session transcripts for this home folder.
    public static func sessionFile(home: String, sessionId: String) -> String {
        let dir = home.replacingOccurrences(of: "[^a-zA-Z0-9]", with: "-", options: .regularExpression)
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects/\(dir)/\(sessionId).jsonl").path
    }

    public struct TranscriptEntry: Hashable, Sendable { public var role: String; public var text: String }

    public static func transcript(home: String, sessionId: String) -> [TranscriptEntry] {
        guard let body = try? String(contentsOfFile: sessionFile(home: home, sessionId: sessionId), encoding: .utf8) else { return [] }
        var out: [TranscriptEntry] = []
        for line in body.split(separator: "\n") {
            guard let e = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let type = e["type"] as? String, type == "user" || type == "assistant",
                  let msg = e["message"] as? [String: Any] else { continue }
            var parts: [String] = []
            if let s = msg["content"] as? String { parts = [s] }
            else if let arr = msg["content"] as? [[String: Any]] {
                for c in arr {
                    switch c["type"] as? String {
                    case "text": parts.append(c["text"] as? String ?? "")
                    case "tool_use":
                        let input = (try? JSONSerialization.data(withJSONObject: c["input"] ?? [:])).map { String(decoding: $0, as: UTF8.self) } ?? ""
                        parts.append("[tool] \(c["name"] as? String ?? "") \(input.prefix(2000))")
                    default: break
                    }
                }
            }
            let text = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { out.append(TranscriptEntry(role: type, text: text.count > 4000 ? String(text.prefix(4000)) + " …" : text)) }
        }
        return out
    }
}
