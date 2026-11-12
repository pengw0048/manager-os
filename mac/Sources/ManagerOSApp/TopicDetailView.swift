import SwiftUI
import AppKit
import ManagerCore

struct TopicDetailView: View {
    @Environment(AppModel.self) var m
    let d: TopicDetail
    @State private var requester = ""
    @State private var chatText = ""
    @State private var ctxTitle = ""
    @State private var ctxUrl = ""
    @State private var ctxBody = ""
    @State private var addingCtx = false
    @FocusState private var chatFocused: Bool
    @FocusState private var fromFocused: Bool

    var t: Topic { d.topic }

    var body: some View {
        @Bindable var m = m
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let p = d.parent {
                        Button("↑ \(m.title(p))") { m.select(p.id) }.buttonStyle(.link).font(.caption)
                    }
                    HStack(alignment: .firstTextBaseline) {
                        Text(m.title(t)).font(.title.weight(.semibold)).textSelection(.enabled)
                        if t.isArchived { Text(m.L("archived")).font(.caption).padding(.horizontal, 6).padding(.vertical, 2).background(.quaternary, in: Capsule()) }
                        Spacer()
                        Menu { TopicMenuItems(id: t.id) } label: { Image(systemName: "ellipsis.circle").imageScale(.large) }.menuStyle(.borderlessButton).fixedSize()
                    }
                    if TopicOps.reminderDue(t) { dueBanner }
                    props.padding(.top, 2)
                    reasonLine
                    aiLine
                    if t.parentId == nil { subtopics }
                    TabBar(selection: $m.tab, items: [
                        (.brief, m.L("tabBrief")), (.ctx, "\(m.L("tabCtx")) \(d.artifacts.count)"),
                        (.tl, "\(m.L("tabTl")) \(d.timeline.count)"), (.claude, m.L("tabClaude")),
                    ]).padding(.top, 10)
                    Group {
                        switch m.tab {
                        case .brief: brief
                        case .ctx: context
                        case .tl: timeline
                        case .claude: claude(proxy)
                        }
                    }.padding(.top, 4)
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, 36).padding(.vertical, 28)
                .frame(maxWidth: 860, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(Color.canvas)
            // The Ask input stays at the bottom of the window, and new replies scroll into view.
            .safeAreaInset(edge: .bottom) { if m.tab == .claude { chatInput } }
            .onChange(of: d.chat.count) { if m.tab == .claude { withAnimation { proxy.scrollTo("end", anchor: .bottom) } } }
            .onChange(of: d.chatBusy) { if m.tab == .claude { withAnimation { proxy.scrollTo("end", anchor: .bottom) } } }
            .onChange(of: m.tab) { if m.tab == .claude { DispatchQueue.main.async { proxy.scrollTo("end", anchor: .bottom) } } }
        }
        .onAppear { requester = t.requester }
        .onChange(of: t.requester) { requester = t.requester }
        .onChange(of: fromFocused) { if !fromFocused { saveRequester() } }
        .onDisappear { saveRequester() }
    }

    func saveRequester() { if requester != t.requester { let r = requester; m.patch(t.id) { $0.requester = r } } }

    // MARK: Header

    /// One row when the detail column is wide; urgency on its own row when the assistant panel makes it narrow.
    var props: some View {
        ViewThatFits(in: .horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 4) {
                GridRow { caption("urgency"); caption("status"); caption("followUp"); caption("from") }
                GridRow { urgencyCell; statusCell; RemindControl(topic: t, quiet: TopicOps.reminderDue(t)); fromCell }
            }
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) { caption("urgency"); urgencyCell }
                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 4) {
                    GridRow { caption("status"); caption("followUp"); caption("from") }
                    GridRow { statusCell; RemindControl(topic: t, quiet: TopicOps.reminderDue(t)); fromCell }
                }
            }
        }
    }

    func caption(_ key: String) -> some View { Text(m.L(key)).font(.caption).foregroundStyle(.secondary) }

    var urgencyCell: some View {
        HStack(spacing: 3) {
            ForEach(Urgency.allCases, id: \.self) { u in
                Button { m.patch(t.id) { $0.urgency = u } } label: { Text(m.levelName(u)).fixedSize() }
                    .help(t.urgency == u && t.urgencySource == "auto" && !m.pick(t.urgencyReasonEn, t.urgencyReasonZh).isEmpty ? m.pick(t.urgencyReasonEn, t.urgencyReasonZh) : m.level(u).description)
                    .buttonStyle(.plain).font(.caption.weight(.bold)).padding(.horizontal, 7).padding(.vertical, 3)
                    .background(t.urgency == u ? u.color : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                    .foregroundStyle(t.urgency == u ? Color.white : Color.secondary)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
            }
            if t.urgencySource == "auto" { Text(m.L("auto")).font(.caption).foregroundStyle(.secondary).fixedSize().padding(.leading, 4) }
            else {
                Text(m.L("manualUntil")).font(.caption).foregroundStyle(.secondary).padding(.leading, 4)
                OptionalDate(value: t.urgencyPinnedUntil) { v in m.patch(t.id) { $0.urgencyPinnedUntil = .some(v) } }
                Button(m.L("backAuto")) { m.patch(t.id) { $0.urgencyAuto = true } }.buttonStyle(.link).font(.caption)
            }
        }
    }

    var statusCell: some View {
        Picker("", selection: Binding(get: { t.status }, set: { s in m.patch(t.id) { $0.status = s } })) {
            ForEach(TopicStatus.allCases, id: \.self) { Text(m.L("st_" + $0.rawValue)).tag($0) }
        }.labelsHidden().frame(width: 150)
    }

    var fromCell: some View {
        TextField("", text: $requester).frame(width: 150).focused($fromFocused).onSubmit { saveRequester() }
    }

    /// A due reminder stays here (and in the inbox) until she handles it.
    var dueBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "bell.badge.fill").foregroundStyle(.orange)
            Text("\(m.L("reminderDue")) · \(reminderLabel(t.remindAt ?? "", zh: m.lang == "zh").0)").fontWeight(.medium)
            Spacer()
            Button(m.L("markDone")) { m.patch(t.id) { $0.status = .done } }
            RemindMenu(topic: t, label: m.L("snooze"))
            Button(m.L("remindClear")) { m.setReminder(t.id, nil) }
        }
        .padding(10).background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }

    /// The due date (she can change it), the sender weight in effect, and a different suggested level when she set urgency by hand.
    var reasonLine: some View {
        let suggest = t.urgencySource != "auto" ? t.aiUrgency.flatMap { $0 != t.urgency ? $0 : nil } : nil
        let sender = m.row(t.id)?.sender
        return HStack(spacing: 14) {
            DueControl(topic: t)
            if let p = sender, p.weight != 1 {
                Label("\(m.L("c_weight")) \(p.weight.formatted()) (\(p.name))", systemImage: "person.crop.circle").help(m.L("weightHelp"))
            }
            if let ai = suggest {
                Text("\(m.L("aiWould")): \(m.levelName(ai))").help(m.pick(t.urgencyReasonEn, t.urgencyReasonZh))
            }
        }.font(.caption).foregroundStyle(.secondary)
    }

    @Environment(\.openWindow) var openWindow

    var aiLine: some View {
        HStack(spacing: 10) {
            switch t.briefState {
            case "running": ProgressView().controlSize(.small); Text(m.L("writing"))
            case "queued": ProgressView().controlSize(.small); Text(m.L("queued"))
            case "error":
                let err = d.jobs.last { $0.kind == "brief" && $0.status == "error" }?.error ?? ""
                Text(m.L("briefError") + (err.isEmpty ? "" : " " + m.pick(AppModel.explain(err), AppModel.explain(err, zh: true)))).foregroundStyle(.red)
                Button(m.L("retry")) { m.refreshBrief(t.id) }.buttonStyle(.link)
                Button(m.L("details")) { openWindow(id: "activity") }.buttonStyle(.link)
            default: EmptyView()
            }
        }.font(.caption).foregroundStyle(.secondary)
    }

    /// Folded to one line by default so the summary starts higher.
    @ViewBuilder var subtopics: some View {
        if !d.children.isEmpty {
            let key = "subs:" + t.id
            DisclosureGroup(isExpanded: Binding(get: { m.expanded.contains(key) }, set: { if $0 { m.expanded.insert(key) } else { m.expanded.remove(key) } })) {
                subtopicList.padding(.top, 4)
            } label: {
                HStack(spacing: 6) {
                    Text("\(m.L("subtopics")) \(d.children.count)").font(.callout.weight(.medium))
                    ForEach(d.children.prefix(8), id: \.id) { Circle().fill($0.urgency.color).frame(width: 6, height: 6).opacity($0.status == .done ? 0.3 : 1) }
                }
            }
        }
    }

    var subtopicList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(d.children, id: \.id) { k in
                Button { m.select(k.id) } label: {
                    HStack { Circle().fill(k.urgency.color).frame(width: 8, height: 8); Text(m.title(k)); Spacer(); Text(m.L("st_" + k.status.rawValue)).font(.caption).foregroundStyle(.secondary) }
                        .contentShape(Rectangle()).padding(.vertical, 6).padding(.horizontal, 10)
                }.buttonStyle(.plain)
                Divider()
            }
            Button { m.sheet = .newTopic(parent: t.id) } label: { Label(m.L("addSub"), systemImage: "plus").padding(.vertical, 6).padding(.horizontal, 10) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .background(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
    }

    // MARK: Tabs

    @ViewBuilder var brief: some View {
        let b = m.pick(t.briefEn, t.briefZh)
        if !b.isEmpty { BriefView(text: b) }
        else if t.briefState == "idle" || t.briefState == "error" { Text(m.L("noBrief")).foregroundStyle(.secondary) }
        else { HStack { ProgressView().controlSize(.small); Text(m.L("writing")).foregroundStyle(.secondary) } }
    }

    @ViewBuilder var context: some View {
        ForEach(d.artifacts) { a in
            Group {
                if a.type == "link" && a.content.isEmpty { LinkPendingRow(topicId: t.id, artifact: a) }
                else {
                    EntryRow(key: "a:" + a.id, icon: a.type == "link" ? "link" : "note.text",
                             title: a.title.isEmpty || a.title == a.url ? (a.url.flatMap { URL(string: $0)?.host } ?? a.url ?? "Note") : a.title,
                             subtitle: m.pick(a.summaryEn, a.summaryZh).isEmpty ? String(a.content.prefix(160)) : m.pick(a.summaryEn, a.summaryZh),
                             raw: a.content.isEmpty ? nil : a.content, url: a.url, when: nil)
                }
            }
            .draggable("artifact|\(a.id)|\(t.id)")
            .contextMenu { MoveMenu(exclude: t.id) { m.moveArtifact(a.id, from: t.id, to: $0) } }
        }
        if !addingCtx {
            Button { addingCtx = true } label: { Label(m.L("addSource"), systemImage: "plus") }.padding(.top, 8)
        } else {
        GroupBox(m.L("addCtx")) {
            VStack(alignment: .leading) {
                TextField(m.L("ctxTitle"), text: $ctxTitle)
                TextField(m.L("link"), text: $ctxUrl)
                TextEditor(text: $ctxBody).frame(minHeight: 70).font(.body).overlay(alignment: .topLeading) {
                    if ctxBody.isEmpty { Text(m.L("ctxBody")).foregroundStyle(.tertiary).padding(5).allowsHitTesting(false) }
                }
                HStack {
                    Button(m.L("cancel")) { addingCtx = false }
                    Button(m.L("addCtx")) {
                        m.addContext(t.id, title: ctxTitle, url: ctxUrl, content: ctxBody); ctxTitle = ""; ctxUrl = ""; ctxBody = ""; addingCtx = false
                    }.disabled(ctxUrl.isEmpty && ctxBody.isEmpty).keyboardShortcut(.defaultAction)
                }
            }.padding(4)
        }.padding(.top, 8)
        }
    }

    @ViewBuilder var timeline: some View {
        let entries = d.timeline.filter { $0.kind != "brief" }
        ForEach(entries) { e in
            EntryRow(key: "e:\(e.id ?? 0)", icon: e.kind == "urgency" ? "arrow.up.arrow.down" : ["me": "person", "slack": "number", "zoom": "video"][e.actor] ?? "circle",
                     title: m.pick(e.summaryEn, e.summaryZh), subtitle: nil, raw: e.raw, url: e.sourceUrl, when: fmtTime(e.at))
        }
        if entries.isEmpty { Text(m.L("empty")).foregroundStyle(.secondary) }
    }

    @ViewBuilder func claude(_ proxy: ScrollViewProxy) -> some View {
        let jobs = Dictionary(d.jobs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        if d.chat.isEmpty { Text(m.L("claudeEmpty")).foregroundStyle(.secondary) }
        ForEach(d.chat) { c in
            switch c.role {
            case "run": RunCard(row: c, job: c.jobId.flatMap { jobs[$0] })
            case "user":
                HStack { Spacer(minLength: 60); Text(c.textEn).textSelection(.enabled).padding(9).background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10)) }
            default:
                VStack(alignment: .leading, spacing: 6) {
                    MarkdownText(text: m.pick(c.textEn, c.textZh))
                    ActionList(row: c)
                }.padding(10).background(RoundedRectangle(cornerRadius: 10).stroke(.quaternary)).padding(.trailing, 60)
            }
        }
        if d.chatBusy { HStack { ProgressView().controlSize(.small); Text(m.L("thinking")).foregroundStyle(.secondary) }.id("busy") }
    }

    var chatInput: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button { chatFocused = true; AppModel.dictate() } label: { Image(systemName: "mic") }.help(m.L("dictate"))
                TextField(m.L("ask"), text: $chatText).textFieldStyle(.roundedBorder).focused($chatFocused)
                    .onSubmit { m.sendChat(t.id, chatText); chatText = "" }
                Button(m.L("send")) { m.sendChat(t.id, chatText); chatText = "" }.keyboardShortcut(.return, modifiers: .command)
            }
            Text(m.L("askNote")).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 36).padding(.vertical, 10)
        .frame(maxWidth: 860).frame(maxWidth: .infinity)
        .background(.bar)
    }
}

extension Color {
    /// Content background: white in light mode, the standard dark text background in dark mode.
    static let canvas = Color(nsColor: .textBackgroundColor)
}

/// Underlined text tabs (lighter than a segmented control).
struct TabBar: View {
    @Binding var selection: DetailTab
    let items: [(DetailTab, String)]
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 22) {
                ForEach(items, id: \.0) { tab, label in
                    Button { selection = tab } label: {
                        VStack(spacing: 6) {
                            Text(label).fontWeight(selection == tab ? .semibold : .regular)
                                .foregroundStyle(selection == tab ? Color.primary : Color.secondary)
                            Rectangle().fill(selection == tab ? Color.primary : Color.clear).frame(height: 2)
                        }.fixedSize()
                    }.buttonStyle(.plain)
                }
                Spacer()
            }
            Divider()
        }
    }
}

/// A context or timeline row: expands in place to show the raw content; "Open" goes to the source.
struct EntryRow: View {
    @Environment(AppModel.self) var m
    let key: String, icon: String, title: String, subtitle: String?, raw: String?, url: String?, when: String?
    var runAction: (() -> Void)? = nil
    var body: some View {
        let open = m.expanded.contains(key)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: raw == nil ? "circle.fill" : (open ? "chevron.down" : "chevron.right")).font(.caption2).foregroundStyle(.tertiary).frame(width: 12).opacity(raw == nil ? 0 : 1)
                if let when { Text(when).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 74, alignment: .leading) }
                Image(systemName: icon).foregroundStyle(.secondary).frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).fontWeight(when == nil ? .medium : .regular)
                    if let s = subtitle, !s.isEmpty { Text(s).font(.callout).foregroundStyle(.secondary) }
                }
                Spacer()
                if let runAction { Button(m.L("seeRun"), action: runAction).buttonStyle(.link).font(.caption) }
                else if let url, let u = URL(string: url) { Link("\(m.L("open")) ↗", destination: u).font(.caption) }
            }
            .contentShape(Rectangle())
            .onTapGesture { guard raw != nil else { return }; if open { m.expanded.remove(key) } else { m.expanded.insert(key) } }
            if open, let raw { Text(raw).font(.callout).textSelection(.enabled).padding(.leading, 34).padding(.vertical, 4) }
            Divider()
        }
    }
}

struct RunCard: View {
    @Environment(AppModel.self) var m
    let row: ChatRow
    let job: Job?
    var body: some View {
        let key = "r:\(row.id ?? 0)", open = m.expanded.contains(key)
        VStack(alignment: .leading, spacing: 4) {
            Text("\(fmtTime(row.at)) · \(m.pick(row.textEn, row.textZh))")
            if open, let j = job {
                Text("\(j.model) · \((j.durationMs ?? 0) / 1000) s · $\(String(format: "%.2f", j.costUsd ?? 0)) · in \(fmtN(j.inputTokens)) · out \(fmtN(j.outputTokens)) · cache \(fmtN(j.cacheRead)) / \(fmtN(j.cacheWrite))")
                    .textSelection(.enabled)
                if let sid = j.sessionId { Button(m.L("viewT")) { m.sheet = .transcript(sid) }.buttonStyle(.link) }
            }
        }
        .font(.caption).foregroundStyle(.tertiary)
        .contentShape(Rectangle())
        .onTapGesture { if open { m.expanded.remove(key) } else { m.expanded.insert(key) } }
    }
}

/// Proposed actions on a chat message: applied ones can be undone; pending ones need Confirm.
struct ActionList: View {
    @Environment(AppModel.self) var m
    let row: ChatRow
    var body: some View {
        let items = row.decodedActions?.items ?? [], states = row.decodedStates
        ForEach(Array(items.enumerated()), id: \.offset) { i, a in
            let s = i < states.count ? states[i].state : "pending", text = m.pick(a.textEn, a.textZh)
            switch s {
            case "applied":
                HStack { Text("✓ \(text)"); Button(m.L("undo")) { m.undo(row, i) }.buttonStyle(.link) }.font(.caption).foregroundStyle(.secondary)
            case "pending":
                VStack(alignment: .leading, spacing: 6) {
                    Text(text + (a.value.isEmpty || text.contains(a.value) ? "" : "  \(a.value)"))
                    if let tid = a.topicId, !tid.isEmpty, let t = m.store.topic(tid) { Text("→ \(m.title(t))").font(.caption).foregroundStyle(.secondary) }
                    HStack { Button(m.L("confirm")) { m.confirm(row, i, true) }.buttonStyle(.borderedProminent); Button(m.L("cancel")) { m.confirm(row, i, false) } }
                }.padding(8).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            default:
                Text("\(s == "undone" ? "↩ " + m.L("undone") : s == "confirmed" ? "✓ " + m.L("confirmed") : m.L("cancelled")): \(text)").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Shows the reminder ("10:30 (in 2 h)" / "2 h overdue") and a menu to set it.
/// `quiet`: the due banner above already says it is overdue, so this shows the plain time.
struct RemindControl: View {
    @Environment(AppModel.self) var m
    let topic: Topic
    var quiet = false
    var body: some View {
        let label = topic.remindAt.map { reminderLabel($0, zh: m.lang == "zh") }
        RemindMenu(topic: topic, label: quiet ? (topic.remindAt.map(fmtTime) ?? m.L("remindSet")) : label?.0 ?? m.L("remindSet"))
            .foregroundStyle(label?.1 == true && !quiet ? Color.orange : Color.primary)
    }
}

/// The due date, editable: Claude's guess can be wrong, and an overdue date triples the score.
struct DueControl: View {
    @Environment(AppModel.self) var m
    let topic: Topic
    @State private var picking = false
    @State private var day = Date()
    var body: some View {
        let due = topic.dueAt.flatMap { parseISO($0) ?? parseISO(String($0.prefix(10))) }
        let late = due.map { $0 < Date() && !Calendar.current.isDateInToday($0) } ?? false
        Button { day = due ?? Date(); picking = true } label: {
            Label(topic.dueAt.map { "\(m.L("dueAt")) \($0.prefix(16).replacingOccurrences(of: "T", with: " "))" + (topic.dueSource == "ai" ? " · " + m.L("auto") : "") } ?? m.L("setDue"),
                  systemImage: "calendar")
                .foregroundStyle(late ? Color.red : Color.secondary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $picking) {
            VStack(alignment: .leading, spacing: 10) {
                DatePicker("", selection: $day, displayedComponents: .date).datePickerStyle(.graphical).labelsHidden()
                HStack {
                    if topic.dueAt != nil { Button(m.L("clearDue")) { m.patch(topic.id) { $0.dueAt = .some(nil) }; picking = false } }
                    Spacer()
                    Button(m.L("cancel")) { picking = false }
                    Button(m.L("ok")) { let d = localDay(day); m.patch(topic.id) { $0.dueAt = .some(d) }; picking = false }.keyboardShortcut(.defaultAction)
                }
            }.padding(14)
        }
    }
}

/// A link that has no text yet: being read, or failed with a retry.
struct LinkPendingRow: View {
    @Environment(AppModel.self) var m
    let topicId: String
    let artifact: Artifact
    var body: some View {
        let reading = m.readingLinks.contains(artifact.id)
        let host = artifact.url.flatMap { URL(string: $0)?.host } ?? artifact.title
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "link").foregroundStyle(.secondary).frame(width: 16).padding(.leading, 20)
                Text(artifact.title.isEmpty || artifact.title == artifact.url ? host : artifact.title).fontWeight(.medium).lineLimit(1)
                if reading { ProgressView().controlSize(.small); Text(m.L("reading")).font(.caption).foregroundStyle(.secondary) }
                else {
                    Text(m.L("readFailed")).font(.caption).foregroundStyle(.orange)
                    Button(m.L("retry")) { m.retryLink(topicId, artifact) }.buttonStyle(.link).font(.caption)
                }
                Spacer()
                if let u = artifact.url.flatMap(URL.init(string:)) { Link("\(m.L("open")) ↗", destination: u).font(.caption) }
            }
            Divider()
        }
    }
}

/// Quick picks (1 h, 3 h, tomorrow 9:00, next Monday 9:00), a custom date and time, or clear.
struct RemindMenu: View {
    @Environment(AppModel.self) var m
    let topic: Topic
    let label: String
    @State private var picking = false
    @State private var custom = Date().addingTimeInterval(3600)
    var body: some View {
        Menu(label) {
            Button(m.L("remind1h")) { m.setReminder(topic.id, TopicOps.reminderTime(.oneHour)) }
            Button(m.L("remind3h")) { m.setReminder(topic.id, TopicOps.reminderTime(.threeHours)) }
            Button(m.L("remindTomorrow")) { m.setReminder(topic.id, TopicOps.reminderTime(.tomorrowMorning)) }
            Button(m.L("remindMonday")) { m.setReminder(topic.id, TopicOps.reminderTime(.nextMonday)) }
            Divider()
            Button(m.L("remindPick")) { custom = topic.remindAt.flatMap(parseISO) ?? Date().addingTimeInterval(3600); picking = true }
            if topic.remindAt != nil { Button(m.L("remindClear")) { m.setReminder(topic.id, nil) } }
        }
        .fixedSize()
        .popover(isPresented: $picking) {
            VStack(alignment: .leading, spacing: 10) {
                DatePicker("", selection: $custom, displayedComponents: [.date, .hourAndMinute]).datePickerStyle(.graphical).labelsHidden()
                HStack { Spacer(); Button(m.L("cancel")) { picking = false }
                    Button(m.L("ok")) { m.setReminder(topic.id, ISO8601DateFormatter().string(from: custom)); picking = false }.keyboardShortcut(.defaultAction) }
            }.padding(14)
        }
    }
}

/// An optional YYYY-MM-DD date: a button when empty, a date picker with a clear button when set.
struct OptionalDate: View {
    @Environment(AppModel.self) var m
    let value: String?
    let set: (String?) -> Void
    var body: some View {
        if let v = value, let d = parseISO(v) {
            HStack(spacing: 2) {
                DatePicker("", selection: Binding(get: { d }, set: { set(localDay($0)) }), displayedComponents: .date).labelsHidden().fixedSize()
                Button { set(nil) } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.tertiary)
            }
        } else {
            Button(m.L("noDate")) { set(localDay(Calendar.current.date(byAdding: .day, value: 1, to: Date())!)) }.font(.caption)
        }
    }
}

/// Markdown for briefs and replies: headings, bullets, numbered items, quotes, code blocks, tables, and inline styles.
struct MarkdownText: View {
    let text: String

    enum Block { case line(String), code(String), table([[String]]) }

    /// Fenced code and runs of `| a | b |` lines become blocks; everything else stays line by line.
    var blocks: [Block] {
        var out: [Block] = [], code: [String]? = nil, table: [[String]] = []
        func flushTable() { if !table.isEmpty { out.append(.table(table)); table = [] } }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let c = code { out.append(.code(c.joined(separator: "\n"))); code = nil } else { flushTable(); code = [] }
                continue
            }
            if code != nil { code!.append(raw); continue }
            if line.hasPrefix("|") && line.hasSuffix("|") && line.count > 1 {
                let cells = line.dropFirst().dropLast().split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                if !cells.allSatisfy({ $0.allSatisfy { "-: ".contains($0) } }) { table.append(cells) } // skip the |---| row
                continue
            }
            flushTable()
            out.append(.line(raw))
        }
        if let c = code { out.append(.code(c.joined(separator: "\n"))) }
        flushTable()
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in
                switch b {
                case .code(let c):
                    ScrollView(.horizontal) { Text(c).font(.callout.monospaced()).padding(8) }
                        .frame(maxWidth: .infinity, alignment: .leading).background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                case .table(let rows):
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                            GridRow { ForEach(Array(r.enumerated()), id: \.offset) { _, c in Text(inline(c)).fontWeight(i == 0 ? .semibold : .regular) } }
                            if i == 0 { Divider() }
                        }
                    }.padding(8).background(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                case .line(let raw): lineView(raw)
                }
            }
        }.textSelection(.enabled)
    }

    @ViewBuilder func lineView(_ raw: String) -> some View {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty { Spacer().frame(height: 2) }
                else if line.hasPrefix("#") {
                    Text(inline(line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces))).font(.callout.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 6)
                } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                    HStack(alignment: .firstTextBaseline, spacing: 6) { Text("•"); Text(inline(String(line.dropFirst(2)))) }
                } else if let r = line.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) { Text(line[r].trimmingCharacters(in: .whitespaces)); Text(inline(String(line[r.upperBound...]))) }
                } else if line.hasPrefix(">") {
                    Text(inline(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))).padding(.leading, 8)
                        .overlay(alignment: .leading) { Rectangle().fill(.quaternary).frame(width: 2) }
                } else { Text(inline(line)) }
    }
    func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

/// The summary in sections: the ask and the next step stay open, facts and questions fold, the draft reply can be copied.
struct BriefView: View {
    @Environment(AppModel.self) var m
    let text: String
    @State private var copied = false

    struct Section: Identifiable { let id: Int; let heading: String; let body: String }

    var sections: [Section] {
        var out: [Section] = [], heading = "", lines: [String] = []
        func flush() { if !heading.isEmpty || !lines.joined().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(Section(id: out.count, heading: heading, body: lines.joined(separator: "\n").trimmingCharacters(in: .newlines))) } }
        for l in text.components(separatedBy: "\n") {
            if l.hasPrefix("#") { flush(); heading = l.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces); lines = [] } else { lines.append(l) }
        }
        flush()
        return out
    }

    static func kind(_ h: String) -> String {
        let s = h.lowercased()
        if ["draft", "草稿"].contains(where: s.contains) { return "draft" }
        return "open"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(sections) { sec in
                switch BriefView.kind(sec.heading) {
                case "draft":
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(sec.heading).font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                            Spacer()
                            Button(copied ? m.L("copied") : m.L("copy")) {
                                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(sec.body, forType: .string); copied = true
                            }.controlSize(.small)
                        }
                        MarkdownText(text: sec.body).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                    }
                default:
                    VStack(alignment: .leading, spacing: 4) {
                        if !sec.heading.isEmpty { Text(sec.heading).font(.callout.weight(.semibold)).foregroundStyle(.secondary) }
                        MarkdownText(text: sec.body)
                    }
                }
            }
        }
    }
}
