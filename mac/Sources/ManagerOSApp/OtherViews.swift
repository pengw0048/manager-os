import SwiftUI
import AppKit
import ManagerCore

struct SheetHost: View {
    @Environment(AppModel.self) var m
    @Environment(\.dismiss) var dismiss
    let kind: AppModel.SheetKind
    @State private var title = ""
    @State private var text = ""
    @State private var url = ""
    @State private var requester = ""
    @State private var target = ""
    @State private var asSub = false
    @State private var pickedArtifacts = Set<String>()
    @State private var pickedTimeline = Set<Int64>()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(20).frame(width: 560)
    }

    func topicPicker(_ label: String, exclude: String?, allowNone: Bool) -> some View {
        HStack {
            Text(label)
            TopicPickerButton(selection: $target, exclude: exclude, noneValue: allowNone ? "" : nil, noneLabel: allowNone ? m.L("none") : nil)
            Spacer()
        }
    }

    func buttons(_ okLabel: String, disabled: Bool = false, role: ButtonRole? = nil, _ ok: @escaping () -> Void) -> some View {
        HStack { Spacer(); Button(m.L("cancel")) { dismiss() }.keyboardShortcut(.cancelAction); Button(okLabel, role: role) { ok(); dismiss() }.keyboardShortcut(.defaultAction).disabled(disabled) }
    }

    @ViewBuilder var content: some View {
        switch kind {
        case .newTopic(let p):
            Text(m.L("newTopic")).font(.headline)
            TextField(m.L("title"), text: $title, prompt: Text(m.L("titleHint")))
            Text(m.L("source")).font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $text).frame(height: 120).overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
            TextField(m.L("link"), text: $url)
            TextField(m.L("requester"), text: $requester)
            topicPicker(m.L("parent"), exclude: nil, allowNone: true).onAppear { target = p ?? "" }
            buttons(m.L("create"), disabled: title.isEmpty && text.isEmpty && url.isEmpty) {
                m.createTopic(title: title, text: text, url: url, requester: requester, parent: target.isEmpty ? nil : target)
            }
        case .merge(let id):
            Text(m.L("merge")).font(.headline)
            Text(m.L("mergeHint")).font(.caption).foregroundStyle(.secondary)
            topicPicker(m.L("mergeTarget"), exclude: id, allowNone: false)
            buttons(m.L("ok"), disabled: target.isEmpty) { m.merge(id, into: target) }
        case .move(let id):
            Text(m.L("moveUnder")).font(.headline)
            topicPicker(m.L("parent"), exclude: id, allowNone: true)
            buttons(m.L("ok")) { let p = target; m.patch(id) { $0.parentId = .some(p.isEmpty ? nil : p) } }
        case .rename(let id):
            Text(m.L("rename")).font(.headline)
            TextField(m.L("title"), text: $title).onAppear { title = m.store.topic(id).map(m.title) ?? "" }
            buttons(m.L("ok"), disabled: title.isEmpty) { let v = title; m.patch(id) { $0.title = v } }
        case .split(let id):
            let d = m.detail
            Text(m.L("split")).font(.headline)
            ScrollView {
                VStack(alignment: .leading) {
                    Text(m.L("ctxItems")).font(.caption).foregroundStyle(.secondary)
                    ForEach(d?.artifacts ?? []) { a in
                        Toggle(a.title.isEmpty ? (a.url ?? "Note") : a.title, isOn: Binding(get: { pickedArtifacts.contains(a.id) }, set: { if $0 { pickedArtifacts.insert(a.id) } else { pickedArtifacts.remove(a.id) } }))
                    }
                    Text(m.L("tlEntries")).font(.caption).foregroundStyle(.secondary).padding(.top, 6)
                    ForEach((d?.timeline ?? []).filter { $0.kind != "structure" }) { e in
                        Toggle("\(fmtTime(e.at)) · \(m.pick(e.summaryEn, e.summaryZh))", isOn: Binding(get: { pickedTimeline.contains(e.id ?? -1) }, set: { if $0 { pickedTimeline.insert(e.id ?? -1) } else { pickedTimeline.remove(e.id ?? -1) } }))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 280)
            TextField(m.L("splitTitle"), text: $title)
            Toggle(m.L("asSub"), isOn: $asSub)
            buttons(m.L("ok"), disabled: title.isEmpty) { m.split(id, title: title, artifacts: Array(pickedArtifacts), timeline: Array(pickedTimeline), asSub: asSub) }
        case .transcript(let sid):
            Text("\(m.L("viewT")) · \(sid.prefix(8))").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(Knowledge.transcript(home: m.home, sessionId: sid).enumerated()), id: \.offset) { _, e in
                        VStack(alignment: .leading, spacing: 2) { Text(e.role).font(.caption.bold()).foregroundStyle(.secondary); Text(e.text).font(.caption.monospaced()).textSelection(.enabled) }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 420)
            HStack { Button(m.L("openTerm")) { m.openInTerminal(sid) }; Spacer(); Button(m.L("close")) { dismiss() }.keyboardShortcut(.defaultAction) }
        }
    }
}

struct AssistantView: View {
    @Environment(AppModel.self) var m
    @State private var text = ""
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(m.L("a_ctx")): \(m.page == .topics ? (m.detail.map { m.title($0.topic) } ?? "") : m.L(m.page.rawValue))")
                .font(.caption).foregroundStyle(.secondary).padding(10)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if m.assistant.isEmpty { Text(m.L("a_empty")).foregroundStyle(.secondary) }
                        ForEach(m.assistant) { c in
                            if c.role == "user" {
                                HStack { Spacer(minLength: 40); Text(c.textEn).padding(8).background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10)) }
                            } else {
                                VStack(alignment: .leading, spacing: 6) {
                                    MarkdownText(text: m.pick(c.textEn, c.textZh))
                                    ForEach(c.decodedActions?.links ?? [], id: \.self) { id in
                                        if let t = m.store.topic(id) { Button("→ \(m.title(t))") { m.select(id) }.buttonStyle(.link) }
                                    }
                                    ActionList(row: c)
                                }.padding(8).background(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
                            }
                        }
                        if m.assistantBusy { HStack { ProgressView().controlSize(.small); Text(m.L("thinking")).foregroundStyle(.secondary) } }
                        Color.clear.frame(height: 1).id("end")
                    }.padding(10)
                }
                .onChange(of: m.assistant.count) { proxy.scrollTo("end") }
                .onAppear { proxy.scrollTo("end") }
            }
            Divider()
            HStack {
                Button { focused = true; AppModel.dictate() } label: { Image(systemName: "mic") }.help(m.L("dictate"))
                TextField(m.L("a_ph"), text: $text).textFieldStyle(.roundedBorder).focused($focused).onSubmit { m.sendAssistant(text); text = "" }
                Button(m.L("send")) { m.sendAssistant(text); text = "" }
            }.padding(10)
        }
    }
}

struct KnowledgeView: View {
    @Environment(AppModel.self) var m
    @State private var files: [Knowledge.File] = []
    @State private var selected = "CLAUDE.md"
    @State private var body_ = ""
    @State private var saveTask: Task<Void, Never>?
    var body: some View {
        HSplitView {
            List(files, id: \.path, selection: Binding(get: { selected }, set: { if let s = $0 { load(s) } })) { f in
                VStack(alignment: .leading) { Text(f.path).font(.callout.weight(.medium)); Text(fmtTime(ISO8601DateFormatter().string(from: f.updatedAt))).font(.caption).foregroundStyle(.secondary) }.tag(f.path)
            }.frame(minWidth: 220, maxWidth: 300)
            VStack(alignment: .leading, spacing: 8) {
                Text(m.L("kn_note")).font(.caption).foregroundStyle(.secondary)
                Text("\(m.home)/\(selected)").font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                let generated = files.first { $0.path == selected }?.generated ?? false
                if generated { Text(m.L("kn_gen")).font(.caption).foregroundStyle(.orange) }
                TextEditor(text: $body_).font(.body.monospaced()).disabled(generated)
                    .onChange(of: body_) {
                        saveTask?.cancel()
                        let path = selected, text = body_
                        guard text != Knowledge.read(m.home, path) else { return }
                        saveTask = Task { try? await Task.sleep(nanoseconds: 600_000_000); if !Task.isCancelled { try? Knowledge.write(m.home, path, text) } }
                    }
                    .scrollContentBackground(.hidden).padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
            }.padding(20).background(Color.canvas)
        }
        .onAppear { files = Knowledge.list(m.home); load(selected) }
        .onDisappear { flush() }
    }
    /// Saves typing that is still waiting for the 0.6 s pause, before switching files or closing.
    func flush() {
        guard saveTask != nil else { return }
        saveTask?.cancel(); saveTask = nil
        if body_ != Knowledge.read(m.home, selected) { try? Knowledge.write(m.home, selected, body_) }
    }
    func load(_ path: String) { flush(); selected = path; body_ = Knowledge.read(m.home, path); files = Knowledge.list(m.home) }
}

struct ActivityView: View {
    @Environment(AppModel.self) var m
    @State private var filter = "all"
    @State private var days = 1
    struct Usage: Identifiable { var id: String { kind + model }; var kind: String; var model: String; var runs = 0; var input = 0; var output = 0; var cacheRead = 0; var cacheWrite = 0; var cost = 0.0 }
    var usage: [Usage] {
        let since = Calendar.current.date(byAdding: .day, value: -(days - 1), to: Calendar.current.startOfDay(for: Date()))!
        var by: [String: Usage] = [:]
        for j in m.jobs where j.status == "done" && (parseISO(j.createdAt) ?? .distantPast) >= since {
            var u = by[j.kind + "|" + j.model] ?? Usage(kind: j.kind, model: j.model)
            u.runs += 1; u.input += j.inputTokens ?? 0; u.output += j.outputTokens ?? 0; u.cacheRead += j.cacheRead ?? 0; u.cacheWrite += j.cacheWrite ?? 0; u.cost += j.costUsd ?? 0
            by[j.kind + "|" + j.model] = u
        }
        return by.values.sorted { $0.cost > $1.cost }
    }
    var body: some View {
        let rows = usage
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(m.L("usageBy")).font(.headline)
                    Spacer()
                    Picker("", selection: $days) { Text(m.L("p_today")).tag(1); Text(m.L("p_7")).tag(7); Text(m.L("p_30")).tag(30) }.pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                Grid(alignment: .trailing, horizontalSpacing: 18, verticalSpacing: 6) {
                    GridRow {
                        Text(m.L("c_feature")).gridColumnAlignment(.leading); Text(m.L("c_model")).gridColumnAlignment(.leading)
                        Text(m.L("c_runs")); Text(m.L("ac_in")); Text(m.L("ac_out")); Text(m.L("ac_cache")); Text(m.L("ac_cost"))
                    }.font(.caption).foregroundStyle(.secondary)
                    Divider()
                    ForEach(rows) { u in
                        GridRow {
                            Text(m.L("k_" + u.kind)); Text(u.model)
                            Text("\(u.runs)"); Text(fmtN(u.input)); Text(fmtN(u.output)); Text("\(fmtN(u.cacheRead)) / \(fmtN(u.cacheWrite))"); Text(String(format: "$%.2f", u.cost))
                        }.font(.callout.monospacedDigit())
                    }
                    Divider()
                    GridRow {
                        Text("").gridCellColumns(2); Text("\(rows.reduce(0) { $0 + $1.runs })"); Text(fmtN(rows.reduce(0) { $0 + $1.input })); Text(fmtN(rows.reduce(0) { $0 + $1.output }))
                        Text("\(fmtN(rows.reduce(0) { $0 + $1.cacheRead })) / \(fmtN(rows.reduce(0) { $0 + $1.cacheWrite }))"); Text(String(format: "$%.2f", rows.reduce(0) { $0 + $1.cost }))
                    }.font(.callout.monospacedDigit().weight(.semibold))
                }
                Text(m.L("ac_costNote")).font(.caption).foregroundStyle(.secondary)
                Text(m.L("recentRuns")).font(.headline).padding(.top, 8)
                Picker("", selection: $filter) {
                    Text(m.L("allJobs")).tag("all"); ForEach(JobQueue.kinds, id: \.self) { Text(m.L("k_" + $0)).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().fixedSize()
                Table(m.jobs.filter { filter == "all" || $0.kind == filter }.prefix(150).map { $0 }) {
                    TableColumn(m.L("c_time")) { Text(fmtTime($0.createdAt)) }.width(90)
                    TableColumn(m.L("c_kind")) { Text(m.L("k_" + $0.kind)) }.width(80)
                    TableColumn(m.L("c_topic")) { j in Text(j.topicId.flatMap(m.store.topic).map(m.title) ?? "—").lineLimit(1) }
                    TableColumn(m.L("c_trigger")) { j in Text(j.error ?? m.pick(j.triggerEn, j.triggerZh)).foregroundStyle(j.error == nil ? Color.primary : Color.red).lineLimit(2) }
                    TableColumn(m.L("c_dur")) { j in Text(j.durationMs.map { "\($0 / 1000) s" } ?? "—") }.width(60)
                    TableColumn(m.L("c_tok")) { j in Text(j.inputTokens == nil ? "—" : "\(fmtN(j.inputTokens)) / \(fmtN(j.outputTokens)) / \(fmtN((j.cacheRead ?? 0) + (j.cacheWrite ?? 0)))") }.width(130)
                    TableColumn(m.L("c_cost")) { j in Text(j.costUsd.map { String(format: "$%.2f", $0) } ?? "—") }.width(60)
                    TableColumn(m.L("c_status")) { j in Text(m.L("js_" + j.status)) }.width(60)
                }.frame(height: 300)
                Text(m.L("ac_sessions")).font(.headline)
                Text(m.L("ac_sessionsD")).font(.caption).foregroundStyle(.secondary)
                ForEach(sessions(), id: \.id) { s in
                    HStack {
                        Text(String(s.id.prefix(8))).font(.callout.monospaced())
                        Text(m.L("k_" + s.kind)).foregroundStyle(.secondary)
                        Text(s.topic).lineLimit(1)
                        Spacer()
                        Text("\(s.jobs) · \(fmtN(s.tokens)) · \(String(format: "$%.2f", s.cost)) · \(fmtTime(s.last))").font(.caption).foregroundStyle(.secondary)
                        Button(m.L("viewT")) { m.sheet = .transcript(s.id) }
                        Button(m.L("openTerm")) { m.openInTerminal(s.id) }
                    }
                    Divider()
                }
            }.padding(24)
        }
        .background(Color.canvas)
    }

    struct SessionRow { var id: String; var kind: String; var topic: String; var jobs: Int; var tokens: Int; var cost: Double; var last: String }
    func sessions() -> [SessionRow] {
        var by: [String: SessionRow] = [:]
        for j in m.jobs { guard let sid = j.sessionId, j.kind != "search" else { continue }
            var s = by[sid] ?? SessionRow(id: sid, kind: j.kind, topic: j.topicId.flatMap(m.store.topic).map(m.title) ?? "—", jobs: 0, tokens: 0, cost: 0, last: j.createdAt)
            s.jobs += 1; s.tokens += (j.inputTokens ?? 0) + (j.outputTokens ?? 0) + (j.cacheRead ?? 0) + (j.cacheWrite ?? 0); s.cost += j.costUsd ?? 0
            if j.createdAt > s.last { s.last = j.createdAt }
            by[sid] = s
        }
        return by.values.sorted { $0.last > $1.last }
    }


}
