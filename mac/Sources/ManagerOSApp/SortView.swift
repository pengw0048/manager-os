import SwiftUI
import ManagerCore

/// New Slack conversations that are not in a topic yet. Claude pre-fills a target; she decides.
struct SortView: View {
    @Environment(AppModel.self) var m
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(m.L("toSort")).font(.title.weight(.semibold))
                if m.toSort.isEmpty { Text(m.L("toSortDone")).foregroundStyle(.secondary) }
                else { Text(m.L("toSortHint")).font(.callout).foregroundStyle(.secondary) }
                ForEach(m.toSort) { item in SortCard(item: item).id(item.id + (item.triagedAt ?? "")) }
                if !m.autoSorted.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(m.L("autoSorted")).font(.headline)
                        Text(m.L("autoSortedHint")).font(.caption).foregroundStyle(.secondary)
                    }.padding(.top, 12)
                    ForEach(m.autoSorted) { AutoSortedRow(item: $0) }
                }
            }
            .padding(.horizontal, 36).padding(.vertical, 28)
            .frame(maxWidth: 860, alignment: .leading).frame(maxWidth: .infinity)
        }
        .background(Color.canvas)
    }
}

struct SortCard: View {
    @Environment(AppModel.self) var m
    let item: ToSortItem
    @State private var target = "new"
    @State private var title = ""

    var body: some View {
        let msgs = m.slack.messages(of: item.id)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: ["dm": "bubble.left", "mention": "at", "note": "note.text", "todo": "checklist"][item.source] ?? "number").foregroundStyle(.secondary)
                Text(item.title).fontWeight(.semibold)
                Text(m.L("src_" + item.source)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let p = item.permalink, let u = URL(string: p) { Link("\(m.L("openSlack")) ↗", destination: u).font(.caption) }
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(msgs.suffix(6), id: \.ts) { msg in Text(msg.line(m.slackNames)).font(.callout).textSelection(.enabled) }
                if msgs.count > 6 { Text("+\(msgs.count - 6)").font(.caption).foregroundStyle(.secondary) }
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            if item.triagedAt == nil, let err = m.slackCtl.triageError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(m.L("triageFailed") + " " + err).font(.caption).foregroundStyle(.secondary)
                    Button(m.L("retry")) { Task { await m.slackCtl.triage(force: true) } }.buttonStyle(.link).font(.caption)
                }
            } else if item.triagedAt == nil {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text(m.L("triaging")).font(.caption).foregroundStyle(.secondary) }
            } else if let r = item.prefillReasonEn, !r.isEmpty {
                Text(m.pick(r, item.prefillReasonZh ?? "")).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text(m.L("addTo"))
                TopicPickerButton(selection: $target, noneValue: "new", noneLabel: m.L("newTopicOpt")).frame(maxWidth: 320, alignment: .leading)
                if target == "new" { TextField(m.L("title"), text: $title).frame(maxWidth: 260) }
                Spacer()
                Button(m.L("ignore")) { m.ignoreSort(item) }
                Button(m.L("add")) { m.acceptSort(item, topicId: target == "new" ? nil : target, newTitle: title) }.buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
        .draggable("sort|\(item.id)")
        .onAppear {
            target = item.prefillTopicId ?? "new"
            title = m.pick(item.prefillTitleEn ?? "", item.prefillTitleZh ?? "")
        }
    }
}

/// One conversation that was filed or skipped automatically; drag it onto a topic to move it.
struct AutoSortedRow: View {
    @Environment(AppModel.self) var m
    let item: ToSortItem
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: item.status == "skipped" ? "minus.circle" : item.status == "ignored" ? "eye.slash" : "arrow.turn.down.right").foregroundStyle(.secondary).frame(width: 16)
            Text(item.title).lineLimit(1)
            if let id = item.filedTopicId, let t = m.store.topic(id) {
                Text("→").foregroundStyle(.tertiary)
                Button(m.title(t)) { m.select(id) }.buttonStyle(.link).lineLimit(1)
            } else if item.status == "skipped" || item.status == "ignored" {
                Text(m.L(item.status == "skipped" ? "skippedLabel" : "ignoredLabel")).foregroundStyle(.secondary)
            }
            Spacer()
            if item.status == "skipped" || item.status == "ignored" {
                Button(m.L("backToSort")) { m.restoreSort(item) }.controlSize(.small)
            } else if let aid = item.artifactId, let from = item.filedTopicId {
                TopicPickerButton(selection: .constant(""), exclude: from, label: m.L("moveTo")) { m.moveArtifact(aid, from: from, to: $0) }.fixedSize().controlSize(.small)
            }
        }
        .padding(.vertical, 6).padding(.horizontal, 10)
        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
        .draggable("sort|\(item.id)")
    }
}

/// Open topics to move something into.
struct MoveMenu: View {
    @Environment(AppModel.self) var m
    let exclude: String
    let pick: (String) -> Void
    var body: some View {
        let rows = m.rows.filter { !$0.topic.isArchived && $0.topic.status != .done && $0.id != exclude }
        Menu(m.L("moveTo")) {
            ForEach(rows) { r in Button((r.topic.parentId == nil ? "" : "↳ ") + m.title(r.topic)) { pick(r.id) } }
        }
    }
}

/// A button that opens a searchable list of open topics (the full list is too long for a menu).
/// With `onPick`, choosing a topic calls it; otherwise it sets `selection` (`noneValue` = the "none" / "new" option).
struct TopicPickerButton: View {
    @Environment(AppModel.self) var m
    @Binding var selection: String
    var exclude: String? = nil
    var noneValue: String? = nil
    var noneLabel: String? = nil
    var label: String? = nil
    var onPick: ((String) -> Void)? = nil
    @State private var open = false
    @State private var query = ""

    var candidates: [TopicRow] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return m.rows.filter { r in
            !r.topic.isArchived && r.topic.status != .done && r.id != exclude && (exclude == nil || r.topic.parentId != exclude)
                && (q.isEmpty || r.topic.titleEn.lowercased().contains(q) || r.topic.titleZh.lowercased().contains(q) || r.topic.requester.lowercased().contains(q))
        }.sorted { $0.score > $1.score }
    }

    var body: some View {
        let current = m.store.topic(selection).map(m.title) ?? (selection == noneValue ? noneLabel : nil)
        Button { query = ""; open = true } label: {
            HStack(spacing: 4) { Text(label ?? current ?? m.L("pickTopicShort")).lineLimit(1); Image(systemName: "chevron.up.chevron.down").font(.caption2) }
        }
        .popover(isPresented: $open) {
            VStack(alignment: .leading, spacing: 6) {
                TextField(m.L("filterTopics"), text: $query).textFieldStyle(.roundedBorder)
                List {
                    if let nv = noneValue, let nl = noneLabel, query.isEmpty { Button(nl) { choose(nv) }.buttonStyle(.plain) }
                    ForEach(candidates) { r in
                        Button { choose(r.id) } label: {
                            HStack { Circle().fill(r.topic.urgency.color).frame(width: 7, height: 7); Text((r.topic.parentId == nil ? "" : "↳ ") + m.title(r.topic)).lineLimit(1); Spacer() }
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }.listStyle(.plain)
            }.padding(10).frame(width: 380, height: 340)
        }
    }

    func choose(_ id: String) { open = false; if let onPick { onPick(id) } else { selection = id } }
}
