import SwiftUI
import ManagerCore

/// "While you were away" and the morning / evening digests: what changed since a time, one card per topic.
struct CatchupView: View {
    @Environment(AppModel.self) var m
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let p = m.catchup {
                    let items = Catchup.changes(m.store, since: p.since)
                    HStack(alignment: .firstTextBaseline) {
                        Text(m.L("cu_" + p.kind.rawValue)).font(.title.weight(.semibold))
                        Text(m.L("since") + " " + fmtTime(p.since)).foregroundStyle(.secondary)
                        Spacer()
                        Button(m.L("markRead")) { Catchup.markRead(m.store) }
                    }
                    Text(m.countsLine(Catchup.counts(m.store, items))).font(.callout).foregroundStyle(.secondary)
                    let overview = m.store.setting("catchup_overview_since") == p.since ? (m.store.setting("catchup_overview") ?? "") : ""
                    if !overview.isEmpty {
                        MarkdownText(text: overview).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    } else if p.kind != .away && m.jobs.contains(where: { $0.kind == "digest" && $0.status == "running" }) {
                        HStack { ProgressView().controlSize(.small); Text(m.L("cu_writing")).foregroundStyle(.secondary) }.font(.callout)
                    }
                    if items.isEmpty { Text(m.L("cu_nothing")).foregroundStyle(.secondary) }
                    ForEach(items) { CatchupCard(item: $0) }
                }
            }
            .padding(.horizontal, 36).padding(.vertical, 28)
            .frame(maxWidth: 860, alignment: .leading).frame(maxWidth: .infinity)
        }
        .background(Color.canvas)
    }
}

struct CatchupCard: View {
    @Environment(AppModel.self) var m
    let item: Catchup.Item
    var body: some View {
        let t = item.topic
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(t.urgency.color).frame(width: 8, height: 8)
                Button(m.title(t)) { m.select(t.id) }.buttonStyle(.link).fontWeight(.semibold)
                Text(m.L("st_" + t.status.rawValue)).font(.caption).foregroundStyle(.secondary)
                if item.isNew { Text(m.L("cu_new")).font(.caption2.weight(.semibold)).padding(.horizontal, 5).padding(.vertical, 1).background(Color.accentColor.opacity(0.15), in: Capsule()) }
                Spacer()
            }
            ForEach(item.entries.suffix(6)) { e in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(fmtTime(e.at)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 74, alignment: .leading)
                    Text(m.pick(e.summaryEn, e.summaryZh)).font(.callout)
                }
            }
            if item.entries.count > 6 { Text("+\(item.entries.count - 6)").font(.caption).foregroundStyle(.secondary) }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
    }
}
