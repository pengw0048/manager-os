import SwiftUI
import AppKit
import ManagerCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        #if DEBUG
        if let dir = ProcessInfo.processInfo.environment["MOS_SNAPSHOTS"] { Task { @MainActor in await DebugSnapshots.run(dir: dir) } }
        #endif
    }
}

#if DEBUG
/// Dev only: walks a few screens and saves window snapshots (AppKit draws the window itself; no screen-recording permission needed).
@MainActor enum DebugSnapshots {
    static func run(dir: String) async {
        func wait(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }
        func main() -> NSWindow? { NSApp.windows.first { $0.isVisible && $0.frame.width > 500 && !$0.title.contains("Manager OS ·") && !$0.title.contains("· Manager OS") } }
        func shot(_ name: String) {
            guard let w = main(), let v = w.contentView?.superview ?? w.contentView,
                  let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        }
        await wait(3)
        guard let m = AppModel.shared else { return }
        if let link = ProcessInfo.processInfo.environment["MOS_DEBUG_LINK"] {
            m.createTopic(title: "", text: "", url: link, requester: "", parent: nil)
            await wait(12); shot("link-context-before-brief"); m.tab = .ctx; await wait(1); shot("link-context")
            return
        }
        main()?.setFrame(NSRect(x: 80, y: 80, width: 1360, height: 860), display: true)
        m.view = .all; await wait(1); shot("1-brief")
        m.tab = .ctx; await wait(1); shot("2-context")
        m.tab = .tl; await wait(1); shot("3-timeline")
        m.tab = .claude; await wait(1); shot("4-claude")
        m.page = .activity; await wait(1.5); shot("5-activity")
        m.page = .topics; m.tab = .brief; m.lang = "zh"
        main()?.setFrame(NSRect(x: 80, y: 80, width: 990, height: 860), display: true)
        await wait(1); shot("6a-narrow"); m.showAssistant = true; await wait(1.5); shot("6-zh-assistant")
        m.showAssistant = false; m.searchText = "回滚"; await wait(1.5); shot("7-search")
        m.searchText = ""; m.lang = "en"
        if let id = m.selection { m.sheet = .confirmDelete(id) }; await wait(1); shot("8-delete-sheet"); m.sheet = nil
    }
}
#endif

@main
struct ManagerOSApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var model: AppModel? = try? AppModel()

    var body: some Scene {
        WindowGroup("Manager OS", id: "main") {
            if let model {
                ContentView().environment(model)
            } else {
                Text("Could not open the Manager OS database.").padding(40)
            }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(model?.L("newTopic") ?? "New topic") { model?.sheet = .newTopic(parent: nil) }.keyboardShortcut("n")
                Button(model?.L("pasteTopic") ?? "New topic from clipboard") { model?.pasteAsTopic() }.keyboardShortcut("v", modifiers: [.command, .shift])
            }
            CommandMenu("Manager OS") {
                Button(model?.L("assistant") ?? "Assistant") { model?.showAssistant.toggle() }.keyboardShortcut("k")
                Button(model?.L("refresh") ?? "Refresh brief") { if let id = model?.selection { model?.refreshBrief(id) } }.keyboardShortcut("r")
            }
        }
        Settings { if let model { SettingsView().environment(model) } }
        MenuBarExtra {
            if let model { MenuBarView().environment(model) }
        } label: {
            let n = model?.count(.needs) ?? 0
            Label("\(n)", systemImage: (model?.rows.contains { $0.topic.urgency == .P0 && !$0.topic.isArchived && $0.topic.status != .done } ?? false) ? "exclamationmark.circle.fill" : "checklist")
        }
    }
}

struct MenuBarView: View {
    @Environment(AppModel.self) var m
    @Environment(\.openWindow) var openWindow
    var body: some View {
        let top = m.visibleTop().filter { m.matches($0, in: .needs) }.prefix(6)
        Text("\(m.count(.needs)) \(m.L("needsMeN"))")
        Divider()
        ForEach(Array(top)) { r in
            Button("\(r.topic.urgency.rawValue) · \(m.title(r.topic))") { m.select(r.id); openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        }
        Divider()
        Button(m.L("openApp")) { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        Button(m.L("quit")) { NSApp.terminate(nil) }
    }
}

struct ContentView: View {
    @Environment(AppModel.self) var m
    var body: some View {
        @Bindable var m = m
        Group {
            switch m.page {
            case .topics: TopicsSplit()
            case .knowledge: KnowledgeView().assistantInspector()
            case .activity: ActivityView().assistantInspector()
            }
        }
        // The window grows when the assistant opens, so the sidebar and detail keep their minimum widths.
        .frame(minWidth: m.showAssistant ? 1240 : 900, minHeight: 620)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("", selection: $m.page) { ForEach(Page.allCases) { Text(m.L($0.rawValue)).tag($0) } }.pickerStyle(.segmented).fixedSize()
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Picker("", selection: $m.lang) { Text("EN").tag("en"); Text("中文").tag("zh") }.pickerStyle(.segmented).fixedSize()
                Button { m.pasteAsTopic() } label: { Label(m.L("pasteTopic"), systemImage: "doc.on.clipboard") }.help(m.L("pasteTopicHelp"))
                Button { m.sheet = .newTopic(parent: nil) } label: { Label(m.L("newTopic"), systemImage: "plus") }
                Button { m.showAssistant.toggle() } label: { Label(m.L("assistant"), systemImage: "sparkles") }
            }
        }
        .sheet(item: $m.sheet) { SheetHost(kind: $0).environment(m) }
        .overlay(alignment: .bottom) {
            if let t = m.toast {
                Text(t).padding(.horizontal, 14).padding(.vertical, 9).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9)).padding(.bottom, 20)
            }
        }
    }
}

struct TopicsSplit: View {
    @Environment(AppModel.self) var m
    var body: some View {
        NavigationSplitView {
            SidebarView().navigationSplitViewColumnWidth(min: 280, ideal: 330, max: 460)
        } detail: {
            Group {
                if m.showingSort && !m.toSort.isEmpty { SortView() }
                else if let d = m.detail { TopicDetailView(d: d).id(d.topic.id) }
                else { Text(m.L("empty")).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.canvas) }
            }
            .frame(minWidth: 560)
            .assistantInspector()
        }
    }
}

extension View {
    /// The assistant sits in the detail column, as macOS expects for an inspector next to a split view.
    func assistantInspector() -> some View { modifier(AssistantInspector()) }
}

struct AssistantInspector: ViewModifier {
    @Environment(AppModel.self) var m
    func body(content: Content) -> some View {
        @Bindable var m = m
        content.inspector(isPresented: $m.showAssistant) { AssistantView().inspectorColumnWidth(min: 320, ideal: 360, max: 520) }
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) var m
    var body: some View {
        @Bindable var m = m
        let selection = Binding<String?>(get: { m.selection }, set: { if let id = $0 { m.select(id) } })
        VStack(spacing: 0) {
            if m.searchText.isEmpty {
                Picker("", selection: $m.view) {
                    ForEach(ListView.allCases) { v in Text("\(m.L("v_" + v.rawValue)) (\(m.count(v)))").tag(v) }
                }.labelsHidden().padding(.horizontal, 10).padding(.vertical, 8)
                if m.view == .archived { Text(m.L("archivedNote")).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.bottom, 6) }
                if !m.toSort.isEmpty {
                    Button { m.showingSort = true; m.page = .topics } label: {
                        HStack {
                            Image(systemName: "tray.full")
                            Text(m.L("toSort")).fontWeight(.medium)
                            Spacer()
                            Text("\(m.toSort.count)").font(.caption.weight(.semibold)).padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.15), in: Capsule())
                        }
                        .padding(.horizontal, 10).padding(.vertical, 7).contentShape(Rectangle())
                        .background(m.showingSort ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                    }.buttonStyle(.plain).padding(.horizontal, 10)
                }
                List(selection: selection) {
                    ForEach(m.listItems(), id: \.row.id) { item in
                        TopicRowView(row: item.row, child: item.child).tag(item.row.id).contextMenu { TopicMenuItems(id: item.row.id) }
                    }
                }
            } else {
                SearchResultsView()
            }
        }
        .searchable(text: $m.searchText, placement: .sidebar, prompt: m.L("search"))
        .onSubmit(of: .search) { m.runAISearch() }
    }
}

struct TopicRowView: View {
    @Environment(AppModel.self) var m
    let row: TopicRow
    let child: Bool
    var body: some View {
        let t = row.topic
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(t.urgency.color).frame(width: 8, height: 8).padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(m.title(t)).fontWeight(child ? .regular : .medium).lineLimit(2)
                Text([t.requester, ago(t.lastActivityAt)].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if row.followupDue, let r = t.remindAt { Label(reminderLabel(r, zh: m.lang == "zh").0, systemImage: "bell.fill").font(.caption).foregroundStyle(.orange) }
            else if t.briefState == "running" || t.briefState == "queued" { ProgressView().controlSize(.small) }
            else if let due = t.dueAt { Text(String(due.prefix(10))).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.leading, child ? 18 : 0).padding(.vertical, 2)
    }
    func ago(_ iso: String) -> String {
        guard let d = parseISO(iso) else { return "" }
        let mins = max(0, Date().timeIntervalSince(d) / 60), zh = m.lang == "zh"
        if mins < 1 { return zh ? "刚刚" : "just now" }
        if mins < 60 { return zh ? "\(Int(mins)) 分钟前" : "\(Int(mins)) min ago" }
        if mins < 1440 { return zh ? "\(Int(mins / 60)) 小时前" : "\(Int(mins / 60)) h ago" }
        return zh ? "\(Int(mins / 1440)) 天前" : "\(Int(mins / 1440)) d ago"
    }
}

/// Archive / rename / delete and the structure actions, shared by the row context menu and the detail "⋯" menu.
struct TopicMenuItems: View {
    @Environment(AppModel.self) var m
    let id: String
    var body: some View {
        let t = m.rows.first { $0.id == id }?.topic
        Button(m.L("rename")) { m.sheet = .rename(id) }
        Button(m.L("merge")) { m.sheet = .merge(id) }
        Button(m.L("split")) { m.select(id); m.sheet = .split(id) }
        Button(m.L("moveUnder")) { m.sheet = .move(id) }
        if t?.parentId != nil { Button(m.L("promote")) { m.patch(id) { $0.parentId = .some(nil) } } }
        Divider()
        if t?.isArchived == true { Button(m.L("unarchive")) { m.unarchive(id) } } else { Button(m.L("archive")) { m.archive(id) } }
        Button(m.L("delete"), role: .destructive) { m.sheet = .confirmDelete(id) }
    }
}

struct SearchResultsView: View {
    @Environment(AppModel.self) var m
    var body: some View {
        List {
            Section(m.L("aiResults")) {
                if m.aiSearching { HStack { ProgressView().controlSize(.small); Text(m.L("aiSearching")).foregroundStyle(.secondary) } }
                else if let a = m.aiAnswer {
                    let ans = m.pick(a.answerEn, a.answerZh)
                    if !ans.isEmpty { Text(ans).font(.callout) }
                    ForEach(a.hits, id: \.self) { h in
                        if let t = m.store.topic(h.topicId) {
                            Button { m.select(t.id) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack { Circle().fill(t.urgency.color).frame(width: 7, height: 7); Text(m.title(t)).fontWeight(.medium); if t.isArchived { Text(m.L("archived")).font(.caption2).foregroundStyle(.secondary) } }
                                    Text(m.pick(h.reasonEn, h.reasonZh)).font(.caption).foregroundStyle(.secondary)
                                }
                            }.buttonStyle(.plain)
                        }
                    }
                    if a.hits.isEmpty { Text(m.L("empty")).foregroundStyle(.secondary) }
                } else {
                    Button { m.runAISearch() } label: { Label("\(m.L("askAI")): “\(m.searchText)”", systemImage: "sparkles") }
                    if let e = m.aiError { Text(e).font(.caption).foregroundStyle(.red) }
                }
            }
            Section(m.L("kwResults")) {
                ForEach(m.keywordHits, id: \.self) { h in
                    if let t = m.store.topic(h.topicId) {
                        Button { m.select(t.id) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Circle().fill(t.urgency.color).frame(width: 7, height: 7)
                                    Text(m.title(t)).fontWeight(.medium)
                                    Text(m.L("m_" + h.kind)).font(.caption2).foregroundStyle(.secondary)
                                    if t.isArchived { Text(m.L("archived")).font(.caption2).foregroundStyle(.secondary) }
                                }
                                Text(h.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }.buttonStyle(.plain)
                    }
                }
                if m.keywordHits.isEmpty { Text(m.L("empty")).foregroundStyle(.secondary) }
            }
        }
    }
}
