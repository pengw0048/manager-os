import Foundation

public enum Prompts {
    public static let briefSchema = #"""
    {"type":"object","properties":{
      "title_en":{"type":"string"},"title_zh":{"type":"string"},"brief":{"type":"string"},
      "urgency":{"type":"string","enum":["P0","P1","P2","P3"]},"urgency_reason":{"type":"string"},
      "status":{"type":"string","enum":["needs_me","waiting","done"]},"status_reason":{"type":"string"},
      "due_at":{"type":["string","null"],"description":"ISO date or datetime if a deadline is stated or clearly implied, else null"},
      "requester":{"type":["string","null"],"description":"Name of the person asking, if known"},
      "artifact_summaries":{"type":"array","items":{"type":"object","properties":{"id":{"type":"string"},"summary":{"type":"string"}},"required":["id","summary"]}}},
     "required":["title_en","title_zh","brief","urgency","urgency_reason","status","status_reason","due_at","requester","artifact_summaries"]}
    """#

    public static let chatSchema = #"""
    {"type":"object","properties":{"reply":{"type":"string"},
      "actions":{"type":"array","items":{"type":"object","properties":{
        "type":{"type":"string","enum":["add_timeline","add_note","create_subtopic","set_status","set_urgency","set_followup"]},
        "text_en":{"type":"string"},"text_zh":{"type":"string"},
        "value":{"type":"string","description":"set_status: needs_me|waiting|snoozed|done; set_urgency: P0-P3; set_followup: YYYY-MM-DD or YYYY-MM-DDTHH:MM local time"}},
        "required":["type","text_en","text_zh","value"]}}},
     "required":["reply","actions"]}
    """#

    public static let assistantSchema = #"""
    {"type":"object","properties":{"reply":{"type":"string"},
      "topic_links":{"type":"array","items":{"type":"string"},"description":"ids of topics the reply refers to"},
      "actions":{"type":"array","items":{"type":"object","properties":{
        "type":{"type":"string","enum":["create_topic","set_status","set_urgency","set_followup","add_note"]},
        "topic_id":{"type":"string"},"text_en":{"type":"string"},"text_zh":{"type":"string"},"value":{"type":"string"}},
        "required":["type","topic_id","text_en","text_zh","value"]}}},
     "required":["reply","topic_links","actions"]}
    """#

    public static let searchSchema = #"""
    {"type":"object","properties":{"answer":{"type":"string"},
      "hits":{"type":"array","items":{"type":"object","properties":{"topic_id":{"type":"string"},"reason":{"type":"string"}},
        "required":["topic_id","reason"]}}},
     "required":["answer","hits"]}
    """#

    public static let triageSchema = #"""
    {"type":"object","properties":{"assignments":{"type":"array","items":{"type":"object","properties":{
      "item_id":{"type":"string"},"action":{"type":"string","enum":["existing","new","skip"]},
      "topic_id":{"type":"string","description":"id of the existing topic this belongs to, or \"\" for a new topic"},
      "title_en":{"type":"string","description":"short title for a new topic (also fill when topic_id is set)"},"title_zh":{"type":"string"},
      "reason":{"type":"string"}},
      "required":["item_id","action","topic_id","title_en","title_zh","reason"]}}},
     "required":["assignments"]}
    """#

    public static let triageSystem = """
    You sort new Slack conversations for an Engineering Manager into her topics in "Manager OS".
    For each item choose an action:
    - "existing": it is clearly the same matter as an open topic; set topic_id. Be conservative.
    - "new": it asks something of her or needs her attention later; topic_id "".
    - "skip": nothing to do (thanks, acknowledgements, FYI chatter, already resolved); topic_id "".
    Write a short title (en + zh) a new topic would get, and a one-line reason in Simplified Chinese. Use topic ids from the list exactly.
    """

    public static func triage(_ store: Store, items: [(ToSortItem, [SlackMessage])]) -> String {
        let topics = store.activeTopics().filter { $0.status != .done }.sorted { $0.lastActivityAt > $1.lastActivityAt }.prefix(assistantTopicCap)
        let names = SlackIngest.names(nil, store)
        let itemText = items.map { it, msgs in
            "### Item \(it.id) (\(it.source), \(it.title))\n" + clip(msgs.map { $0.line(names) }.joined(separator: "\n"), 1500)
        }.joined(separator: "\n\n")
        return "Today: \(localDay())\n\n## Open topics\n" + (topics.isEmpty ? "(none)" : topics.map { topicLine(store, $0) }.joined(separator: "\n"))
            + "\n\n## New Slack conversations\n" + itemText
    }

    /// Always first in the system prompt.
    public static let base = """
    You work inside "Manager OS", a local macOS app that helps an Engineering Manager track topics. You have no tools;
    answer only with the structured output requested.
    """

    static let langRules = """
    Language: write what she reads in Simplified Chinese (brief, reply, answer, summary, reason). Keep code identifiers,
    product names, and established English engineering terms in English. Anything meant to be sent to other people
    (a draft reply or message) is in English. Fields ending in _en / _zh: write both, English and Chinese.
    Use plain words. Never claim a message was sent: the app never sends messages.
    Refer to topics by their title in text; ids belong only in id fields. Titles name the matter, not its status (no "overdue", "urgent").
    CLAUDE.md and the knowledge files describe the user (an Engineering Manager), the people around her, and what she already knows; use them.
    """

    public static func briefSystem(_ levels: [Level]) -> String {
        let rubric = levels.map { "\($0.id) = \($0.nameEn): \($0.description)" }.joined(separator: "\n")
        return """
    You are the background analyst of "Manager OS", a local app that tracks topics for an Engineering Manager.
    You keep the brief of ONE topic current so she can act without re-reading every thread.
    \(langRules)
    Brief format (Markdown, short; at most about 180 words ; do not repeat the ask in the facts):
    ## 请求 — one or two sentences: what is asked of her, by whom.
    ## 已知信息 — at most 6 bullets with facts from the context; name the source.
    ## 待确认的问题 — only if something important is unknown.
    ## 建议的下一步 — one concrete step.
    ## 回复草稿 — only if a reply from her is expected; in English, ready to paste.
    Urgency levels (she defined these; pick the one that fits and give a one-line reason):
    \(rubric)
    status (judge from the latest messages, with a one-line reason):
    needs_me = the next move is hers (a question or request to her, a decision, a reply she owes).
    waiting = she has done her part and the next move is someone else's.
    done = the matter is resolved and nothing more is expected from her.
    A bare "thanks" or acknowledgement does not change who has the next move.
    artifact_summaries: one or two sentences for each context item listed as needing a summary; return [] if none.
    If the context is thin, say what is missing instead of guessing.
    """
    }

    public static let chatSystem = """
    You are Claude inside "Manager OS", talking with an Engineering Manager in the Claude tab of ONE topic.
    This session also holds the background runs that wrote the topic's brief.
    \(langRules)
    Answer from the topic's context. Propose actions only when she asks for a change:
    - add_timeline (text = the entry), add_note (text = note added to the topic's context), create_subtopic (text = title):
      the app applies these at once and offers undo.
    - set_status, set_urgency, set_followup (a reminder time): the app asks her to confirm first; text = a one-line description of the change.
    Use value "" when not needed. Return actions: [] when no change was asked for.
    """

    public static let assistantSystem = """
    You are the assistant of "Manager OS", an app that tracks topics for an Engineering Manager.
    You answer questions across all her topics and can propose changes; every change needs her confirmation in the app.
    \(langRules)
    Use topic ids from the list exactly. For create_topic use topic_id "" and text = title. Put ids of topics you mention in topic_links.
    Refer to topics by title in the reply text; never write topic ids there (the app shows links). Keep replies short.
    """

    static let searchRules = """
    You are the search of "Manager OS". The index below lists all of the user's topics, including done ones.
    Find the topics that match her query by meaning, not only by words; the query may be English or Chinese.
    Return up to 8 hits, best first, each with a one-line reason in Simplified Chinese. If the query is a question the index answers, put a short answer (Simplified Chinese) in answer; else leave answer empty.
    Use topic ids from the index exactly. Return hits: [] if nothing matches.
    """

    static func clip(_ s: String, _ n: Int) -> String { s.count > n ? String(s.prefix(n)) + " …[truncated]" : s }

    static func header(_ store: Store, _ t: Topic) -> String {
        let parent = t.parentId.flatMap(store.topic)
        let kids = store.children(t.id)
        return [
            "Topic id: \(t.id)", "Title: \(t.titleEn)", "Status: \(t.status.rawValue)", "Requester: \(t.requester.isEmpty ? "unknown" : t.requester)",
            "Urgency: \(t.urgency.rawValue) (\(t.urgencySource == "manual" ? "set by her manually; still give your own assessment" : "auto"))",
            "Due: \(t.dueAt ?? "none")\(t.dueSource == "me" ? " (set by her)" : "")", "Reminder: \(t.remindAt.map(fmtLocal) ?? "none")",
            parent.map { "Parent topic: \($0.titleEn)" } ?? "",
            kids.isEmpty ? "" : "Sub-topics: " + kids.map { "\($0.titleEn) [\($0.status.rawValue), \($0.urgency.rawValue)]" }.joined(separator: "; "),
        ].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    static func fmt(_ a: Artifact) -> String {
        let by = a.addedBy == "claude" ? ", added by Claude" : ""
        var s = "### Context item \(a.id) (\(a.type)\(by))\nTitle: \(a.title)"
        if let u = a.url { s += "\nURL: \(u)" }
        if !a.summaryEn.isEmpty { s += "\nExisting summary: \(a.summaryEn)" }
        return s + "\n" + clip(a.content, 20_000)
    }
    static func fmt(_ e: TimelineEntry) -> String { "- \(e.at.prefix(16).replacingOccurrences(of: "T", with: " ")) [\(e.actor)] \(e.summaryEn)" }

    /// Full context of a topic, used when a session starts fresh.
    public static func fullContext(_ store: Store, _ t: Topic) -> String {
        let arts = store.artifacts(of: t.id)
        let parentArts = t.parentId.map { store.artifacts(of: $0) } ?? []
        let tl = store.timeline(of: t.id).suffix(60)
        let chat = store.chat(of: t.id).filter { $0.role != "run" }.suffix(10)
        var parts: [String] = ["Today: \(localDay())", "## Topic", header(store, t)]
        if !t.briefEn.isEmpty { parts.append("## Current brief\n\(t.briefEn)") }
        parts.append("## Context items")
        parts.append(arts.isEmpty ? "(none)" : arts.map { fmt($0) }.joined(separator: "\n\n"))
        if !parentArts.isEmpty { parts.append("## Parent topic context\n" + parentArts.map { fmt($0) }.joined(separator: "\n\n")) }
        parts.append("## Timeline")
        parts.append(tl.isEmpty ? "(empty)" : tl.map { fmt($0) }.joined(separator: "\n"))
        if !chat.isEmpty {
            let lines = chat.map { c -> String in "- \(c.role == "user" ? "She" : "Claude"): \(clip(c.textEn, 1000))" }
            parts.append("## Recent chat\n" + lines.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }

    /// Only what changed since `since`, used when the topic session is resumed.
    public static func deltaContext(_ store: Store, _ t: Topic, since: String) -> String {
        let arts = store.artifacts(of: t.id).filter { $0.createdAt > since }
        let tl = store.timeline(of: t.id).filter { $0.at > since && $0.actor != "claude" }
        var parts: [String] = ["Today: \(localDay())", "## Topic now", header(store, t)]
        if !arts.isEmpty { parts.append("## New context items\n" + arts.map { fmt($0) }.joined(separator: "\n\n")) }
        // Slack entries carry the new messages themselves; the thread's context item was sent earlier and only grew.
        if !tl.isEmpty { parts.append("## New timeline entries\n" + tl.map { e in fmt(e) + (e.actor == "slack" ? (e.raw.map { "\n" + clip($0, 8000) } ?? "") : "") }.joined(separator: "\n")) }
        if arts.isEmpty && tl.isEmpty { parts.append("(No new context since your last turn.)") }
        return parts.joined(separator: "\n\n")
    }

    public static func brief(_ store: Store, _ t: Topic, since: String?) -> String {
        let need = store.artifacts(of: t.id).filter { $0.summaryEn.isEmpty }.map(\.id)
        return (since.map { deltaContext(store, t, since: $0) } ?? fullContext(store, t))
            + "\n\n## Task\nWrite the complete, updated brief for this topic." + (need.isEmpty ? "" : "\nContext items needing a summary: \(need.joined(separator: ", "))")
    }

    public static func chat(_ store: Store, _ t: Topic, since: String?, message: String) -> String {
        (since.map { deltaContext(store, t, since: $0) } ?? fullContext(store, t)) + "\n\n## Her message\n\(message)"
    }

    static func topicLine(_ store: Store, _ t: Topic) -> String {
        let ask = t.briefEn.split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("#") }.map { String($0.prefix(160)) } ?? ""
        return "- \(t.id)\(t.parentId.map { " (sub-topic of \($0))" } ?? ""): \"\(t.titleEn)\" [\(t.urgency.rawValue), \(t.status.rawValue)\(t.dueAt.map { ", due \($0)" } ?? "")\(t.remindAt.map { ", reminder \(fmtLocal($0))" } ?? "")] \(ask)"
    }

    /// Prompt sizes stay bounded as topics pile up: archived topics are left out and long lists are capped.
    public static let assistantTopicCap = 40
    public static let searchTopicCap = 150

    public static func assistant(_ store: Store, message: String, page: String?, topicId: String?) -> String {
        let all = store.activeTopics().filter { $0.status != .done }.map { ($0, TopicOps.score(store, $0)) }.sorted { $0.1 > $1.1 }.map(\.0)
        var rows = Array(all.prefix(assistantTopicCap))
        let open = topicId.flatMap(store.topic)
        if let open, !rows.contains(where: { $0.id == open.id }) { rows.insert(open, at: 0) }
        let more = all.count - rows.count
        return [
            "Today: \(localDay())",
            "She is looking at: \(page ?? "topics")" + (open.map { ", topic \($0.id) \"\($0.titleEn)\"" } ?? ""),
            "## Open topics (highest score first)\n" + (rows.isEmpty ? "(none)" : rows.map { topicLine(store, $0) }.joined(separator: "\n"))
                + (more > 0 ? "\n(\(more) lower-priority open topics not shown; suggest using search for them.)" : ""),
            "## Her message\n\(message)",
        ].joined(separator: "\n\n")
    }

    /// Compact topic index for AI search, sent as the system prompt so repeated searches can reuse the cache.
    /// Archived topics are included only on request; beyond the cap, keyword matches come first, then the most recent.
    public static func searchIndex(_ store: Store, query: String = "", includeArchived: Bool = false) -> String {
        var pool = includeArchived ? store.topics() : store.activeTopics()
        if pool.count > searchTopicCap {
            let kw = Set(((try? Search.keyword(store, query, limit: searchTopicCap)) ?? []).map(\.topicId))
            pool.sort { (kw.contains($0.id) ? 0 : 1, $1.lastActivityAt) < (kw.contains($1.id) ? 0 : 1, $0.lastActivityAt) }
            pool = Array(pool.prefix(searchTopicCap))
        }
        let lines = pool.map { t -> String in
            let sums = store.artifacts(of: t.id).map(\.summaryEn).filter { !$0.isEmpty }.prefix(5).joined(separator: " | ")
            return topicLine(store, t) + " (zh: \(t.titleZh); created \(t.createdAt.prefix(10)); last activity \(t.lastActivityAt.prefix(10)))" + (sums.isEmpty ? "" : "\n  context: \(clip(sums, 600))")
        }
        return searchRules + "\n\n## Index\n" + lines.joined(separator: "\n")
    }
}
