import SwiftUI
import ManagerCore

/// Settings as toolbar panes (Apple HIG): one group of related settings per pane, label on the left and control on the right.
/// Lists of things (levels, people) show one summary row each; editing happens in a sheet.
struct SettingsView: View {
    @Environment(AppModel.self) var m
    @AppStorage("settingsPane") private var pane = "general"
    var body: some View {
        TabView(selection: $pane) {
            GeneralPane().tabItem { Label(m.L("p_general"), systemImage: "gearshape") }.tag("general")
            SlackPane().tabItem { Label("Slack", systemImage: "number") }.tag("slack")
            LevelsPane().tabItem { Label(m.L("s_levels"), systemImage: "flag") }.tag("levels")
            PeoplePane().tabItem { Label(m.L("s_people"), systemImage: "person.2") }.tag("people")
            ModelsPane().tabItem { Label(m.L("s_ai"), systemImage: "cpu") }.tag("ai")
        }
        .frame(width: 640, height: 500)
    }
}

/// Footer text under a section, the way System Settings explains a group.
func footnote(_ s: String) -> some View {
    Text(s).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
}

struct GeneralPane: View {
    @Environment(AppModel.self) var m
    @State private var digests = true
    @State private var morning = Date()
    @State private var evening = Date()
    var body: some View {
        @Bindable var m = m
        Form {
            Section {
                Picker(m.L("s_lang"), selection: $m.lang) { Text("English").tag("en"); Text("中文").tag("zh") }
            }
            Section {
                Toggle(m.L("dg_on"), isOn: $digests).onChange(of: digests) { m.store.setSetting("digest_enabled", digests ? "1" : "0") }
                DatePicker(m.L("cu_morning"), selection: $morning, displayedComponents: .hourAndMinute).disabled(!digests)
                    .onChange(of: morning) { m.store.setSetting("digest_morning", hm(morning)) }
                DatePicker(m.L("cu_evening"), selection: $evening, displayedComponents: .hourAndMinute).disabled(!digests)
                    .onChange(of: evening) { m.store.setSetting("digest_evening", hm(evening)) }
            } header: { Text(m.L("dg_title")) } footer: { footnote(m.L("dg_D")) }
            Section {
                LabeledContent(m.L("s_home")) { Text(m.home).textSelection(.enabled).lineLimit(2).truncationMode(.middle) }
            } header: { Text(m.L("s_about")) } footer: { footnote(m.L("s_aboutD")) }
        }
        .formStyle(.grouped)
        .onAppear {
            digests = m.store.setting("digest_enabled") != "0"
            morning = Catchup.at(m.store.setting("digest_morning") ?? Catchup.defaultMorning, on: Date()) ?? Date()
            evening = Catchup.at(m.store.setting("digest_evening") ?? Catchup.defaultEvening, on: Date()) ?? Date()
        }
    }
    func hm(_ d: Date) -> String { let c = Calendar.current.dateComponents([.hour, .minute], from: d); return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0) }
}

struct SlackPane: View {
    @Environment(AppModel.self) var m
    @State private var watched = ""
    var body: some View {
        let c = m.slackCtl
        Form {
            Section {
                LabeledContent(m.L("status")) {
                    HStack(spacing: 6) {
                        Circle().fill(c.status == .connected ? Color.green : c.status == .off ? Color.gray : Color.orange).frame(width: 8, height: 8)
                        Text(m.L("st_\(c.status)") + (c.team.isEmpty ? "" : " · \(c.team)"))
                    }
                }
                if let last = c.lastEventAt { LabeledContent(m.L("slackLast"), value: fmtTime(ISO8601DateFormatter().string(from: last))) }
                Toggle(m.L("slackEnable"), isOn: Binding(get: { c.enabled }, set: { c.setEnabled($0) }))
                if c.enabled { LabeledContent(m.L("slackWindow")) { Button(m.L("slackOpen")) { c.showWindow() } } }
            } footer: { footnote(m.L("s_slackD")) }
            Section {
                Toggle(m.L("autoSortSetting"), isOn: Binding(get: { m.store.setting("auto_sort") != "0" }, set: { m.store.setSetting("auto_sort", $0 ? "1" : "0") }))
                TextField(m.L("slackWatchedShort"), text: $watched, prompt: Text("eng-oncall, incidents"))
                    .onChange(of: watched) { m.slack.setWatched(watched) }
            } footer: { footnote(m.L("slackWatchedD")) }
            Section {
                LabeledContent(m.L("readerTitle")) { Button(m.L("readerOpen")) { m.linkReader.showForSignIn() } }
            } footer: { footnote(m.L("readerD")) }
        }
        .formStyle(.grouped)
        .onAppear { watched = m.store.setting("slack_watched") ?? "" }
    }
}

// MARK: Urgency levels

struct LevelsPane: View {
    @Environment(AppModel.self) var m
    @State private var editing: Level?
    var body: some View {
        Form {
            Section {
                ForEach(m.levels) { l in
                    HStack(spacing: 10) {
                        Circle().fill(Color(hex: l.color)).frame(width: 10, height: 10)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.pick(l.nameEn, l.nameZh))
                            Text(summary(l)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(m.L("edit")) { editing = l }
                    }
                }
            } footer: { footnote(m.L("s_levelsD")) }
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { LevelSheet(level: $0) }
    }
    func summary(_ l: Level) -> String {
        [m.L("n_" + l.notify), m.L("lv_first") + " " + LevelSheet.dur(m, l.firstRemindMinutes),
         m.L("lv_repeat") + " " + (l.repeatMinutes == 0 ? m.L("dur_none") : LevelSheet.dur(m, l.repeatMinutes))].joined(separator: " · ")
    }
}

struct LevelSheet: View {
    @Environment(AppModel.self) var m
    @Environment(\.dismiss) var dismiss
    @State var level: Level
    static let firstOptions: [Int?] = [nil, 0, 30, 60, 120, 240, 1440, 2880]
    static let repeatOptions: [Int] = [0, 15, 30, 60, 180, 1440]

    static func dur(_ m: AppModel, _ mins: Int?) -> String {
        guard let mins else { return m.L("dur_none") }
        if mins == 0 { return m.L("dur_0") }
        let zh = m.lang == "zh"
        return mins < 60 ? (zh ? "\(mins) 分钟" : "\(mins) min") : mins < 1440 ? (zh ? "\(mins / 60) 小时" : "\(mins / 60) h") : (zh ? "\(mins / 1440) 天" : "\(mins / 1440) d")
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField(m.L("lv_nameEn"), text: $level.nameEn)
                    TextField(m.L("lv_nameZh"), text: $level.nameZh)
                    ColorPicker(m.L("lv_color"), selection: Binding(get: { Color(hex: level.color) }, set: { level.color = $0.hex }), supportsOpacity: false)
                } header: { Text(level.id) }
                Section {
                    TextField(m.L("lv_desc"), text: $level.description, axis: .vertical).lineLimit(2...4)
                } footer: { footnote(m.L("lv_descD")) }
                Section {
                    Picker(m.L("lv_notify"), selection: $level.notify) { ForEach(["interrupt", "silent", "none"], id: \.self) { Text(m.L("n_" + $0)).tag($0) } }
                    Picker(m.L("lv_first"), selection: $level.firstRemindMinutes) { ForEach(LevelSheet.firstOptions, id: \.self) { Text(LevelSheet.dur(m, $0)).tag($0) } }
                    Picker(m.L("lv_repeat"), selection: $level.repeatMinutes) { ForEach(LevelSheet.repeatOptions, id: \.self) { Text($0 == 0 ? m.L("dur_none") : LevelSheet.dur(m, $0)).tag($0) } }
                }
            }
            .formStyle(.grouped)
        }
        .toolbar { SheetActions { m.saveLevel(level) } }
        .frame(width: 460, height: 470)
    }
}

/// Cancel and Done, placed by macOS at the bottom of the sheet.
struct SheetActions: ToolbarContent {
    @Environment(AppModel.self) var m
    @Environment(\.dismiss) var dismiss
    let save: () -> Void
    var body: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) { Button(m.L("cancel")) { dismiss() } }
        ToolbarItem(placement: .confirmationAction) { Button(m.L("done")) { save(); dismiss() } }
    }
}

// MARK: People

struct PeoplePane: View {
    @Environment(AppModel.self) var m
    @State private var selection: String?
    @State private var editing: Person?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Table(m.people, selection: $selection) {
                TableColumn(m.L("c_name")) { p in Text(p.name.isEmpty ? "—" : p.name) }
                TableColumn(m.L("c_rel")) { p in Text(m.L("r_" + p.relationship)) }.width(90)
                TableColumn(m.L("c_weight")) { p in Text(p.weight.formatted()).monospacedDigit() }.width(50)
                TableColumn("Slack") { p in Text(p.slack).foregroundStyle(.secondary) }.width(110)
                TableColumn(m.L("c_int")) { p in Text(m.L("i_" + p.canInterrupt)) }.width(90)
            }
            .contextMenu(forSelectionType: String.self) { ids in
                if let id = ids.first, let p = m.people.first(where: { $0.id == id }) { Button(m.L("edit")) { editing = p }; Button(m.L("deleteBtn"), role: .destructive) { m.deletePerson(id) } }
            } primaryAction: { ids in editing = ids.first.flatMap { id in m.people.first { $0.id == id } } }
            HStack(spacing: 0) {
                Button { editing = Person(name: "") } label: { Image(systemName: "plus").frame(width: 22, height: 18) }.help(m.L("addPerson"))
                Button { if let id = selection { m.deletePerson(id); selection = nil } } label: { Image(systemName: "minus").frame(width: 22, height: 18) }
                    .disabled(selection == nil).help(m.L("deleteBtn"))
                Spacer()
                Button(m.L("edit")) { editing = selection.flatMap { id in m.people.first { $0.id == id } } }.disabled(selection == nil)
            }.buttonStyle(.borderless)
            footnote(m.L("s_peopleD"))
        }
        .padding(20)
        .sheet(item: $editing) { PersonSheet(person: $0) }
    }
}

struct PersonSheet: View {
    @Environment(AppModel.self) var m
    @State var person: Person
    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField(m.L("c_name"), text: $person.name, prompt: Text(m.L("c_namePh")))
                    Picker(m.L("c_rel"), selection: $person.relationship) {
                        ForEach(["manager", "skip_level", "peer", "report", "partner", "other"], id: \.self) { Text(m.L("r_" + $0)).tag($0) }
                    }
                    TextField(m.L("c_weight"), value: $person.weight, format: .number)
                    Picker(m.L("c_int"), selection: $person.canInterrupt) { ForEach(["never", "if_due_today", "always"], id: \.self) { Text(m.L("i_" + $0)).tag($0) } }
                } footer: { footnote(m.L("weightHelp")) }
                Section {
                    TextField(m.L("c_slack"), text: $person.slack, prompt: Text("U012AB3CD"))
                    TextField(m.L("c_email"), text: $person.email)
                    TextField(m.L("c_zoom"), text: $person.zoom)
                } footer: { footnote(m.L("c_slackD")) }
                Section {
                    TextField(m.L("c_notes"), text: $person.notes, prompt: Text(m.L("c_notesPh")), axis: .vertical).lineLimit(2...4)
                }
            }
            .formStyle(.grouped)
        }
        .toolbar { SheetActions { m.savePerson(person) } }
        .frame(width: 460, height: 520)
    }
}

// MARK: AI models

struct ModelsPane: View {
    @Environment(AppModel.self) var m
    var body: some View {
        Form {
            Section {
                ForEach(JobQueue.kinds, id: \.self) { ModelRow(kind: $0) }
            } footer: { footnote(m.L("s_aiD")) }
        }
        .formStyle(.grouped)
    }
}

/// One feature: name and what it does on the left; model and effort on the right.
struct ModelRow: View {
    @Environment(AppModel.self) var m
    let kind: String
    @State private var model = ""
    @State private var effort = ""
    static let models = ["haiku", "sonnet", "opus"]
    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                Picker(m.L("c_model"), selection: $model) { ForEach(Array(Set(ModelRow.models + [model])).sorted(), id: \.self) { Text($0.capitalized).tag($0) } }
                    .labelsHidden().fixedSize().help(m.L("c_model"))
                    .onChange(of: model) { if model != m.queue.model(kind) { m.store.setSetting("model_\(kind)", model) } }
                Text(m.L("effort")).foregroundStyle(.secondary).padding(.leading, 6)
                Picker(m.L("effort"), selection: $effort) { ForEach(["low", "medium", "high"], id: \.self) { Text(m.L("e_" + $0)).tag($0) } }
                    .labelsHidden().fixedSize().help(m.L("effort"))
                    .onChange(of: effort) { if effort != m.queue.effort(kind) { m.store.setSetting("effort_\(kind)", effort) } }
            }
        } label: {
            Text(m.L("k_" + kind))
            Text(m.L("d_" + kind))
        }
        .onAppear { model = m.queue.model(kind); effort = m.queue.effort(kind) ?? "low" }
    }
}
