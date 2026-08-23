//
//  CaseloadView.swift
//  Kalsmritikosh
//
//  A caseload / triage dashboard over the user's matters (workspaces). The
//  professional pain (SIU / HR / legal): "which of my open matters needs
//  attention first?" — hand-tracked in spreadsheets today. This ranks every
//  active matter by an attention score (how long since it was touched, scaled
//  by how much evidence it holds), and shows the size + status distribution.
//
//  Read-only over the ledger; a matter is a filtered view, never a data copy.
//

import SwiftUI
import Charts

public struct CaseloadView: View {
    @Environment(AppState.self) private var appState

    struct MatterRow: Identifiable {
        let id: UUID
        let title: String
        let template: String
        let archived: Bool
        let sources: Int
        let subjects: Int
        let updated: Date
        let ageDays: Int
        let score: Double
        let band: Band
    }
    enum Band: String { case high = "Needs attention", medium = "Watch", low = "Current" }

    @State private var rows: [MatterRow] = []
    @State private var loading = true

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if loading {
                    ProgressView().frame(maxWidth: .infinity, alignment: .center).padding(.top, 40)
                } else if rows.isEmpty {
                    empty
                } else {
                    summaryStrip
                    sizeChart
                    triageList
                }
            }
            .padding(24)
            .frame(maxWidth: 860, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .navigationTitle("Caseload")
        .task { await load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Caseload triage", systemImage: "square.stack.3d.up")
                .font(.title2.bold())
            Text("Every matter ranked by how much attention it needs — so the oldest, largest untouched cases don't slip. Active matters only; archived ones are excluded.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var empty: some View {
        ContentUnavailableView("No matters yet",
            systemImage: "folder.badge.questionmark",
            description: Text("Create a workspace for a case or project and it will appear here, triaged."))
    }

    private var summaryStrip: some View {
        let active = rows.filter { !$0.archived }
        let high = active.filter { $0.band == .high }.count
        let med = active.filter { $0.band == .medium }.count
        let low = active.filter { $0.band == .low }.count
        return HStack(spacing: 16) {
            summaryCard("\(active.count)", "active matters", .blue)
            summaryCard("\(high)", Band.high.rawValue, .red)
            summaryCard("\(med)", Band.medium.rawValue, .orange)
            summaryCard("\(low)", Band.low.rawValue, .green)
        }
    }

    private func summaryCard(_ value: String, _ label: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.title.bold()).foregroundStyle(color)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private var sizeChart: some View {
        let top = Array(rows.filter { !$0.archived }.sorted { $0.sources > $1.sources }.prefix(8))
        return VStack(alignment: .leading, spacing: 8) {
            Text("Evidence per matter").font(.headline)
            Chart(top) { row in
                BarMark(
                    x: .value("Sources", row.sources),
                    y: .value("Matter", row.title)
                )
                .foregroundStyle(bandColor(row.band))
            }
            .chartXAxisLabel("Sources")
            .frame(height: max(120, CGFloat(top.count) * 34))
        }
    }

    private var triageList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Triaged").font(.headline)
            ForEach(rows.filter { !$0.archived }) { row in
                HStack(alignment: .top, spacing: 12) {
                    Circle().fill(bandColor(row.band)).frame(width: 10, height: 10).padding(.top, 5)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title).fontWeight(.medium)
                        Text("\(row.template) · \(row.sources) sources · \(row.subjects) subjects")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(row.band.rawValue).font(.caption.bold()).foregroundStyle(bandColor(row.band))
                        Text(ageLabel(row.ageDays)).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func bandColor(_ b: Band) -> Color {
        switch b { case .high: return .red; case .medium: return .orange; case .low: return .green }
    }
    private func ageLabel(_ days: Int) -> String {
        if days <= 0 { return "updated today" }
        if days == 1 { return "1 day ago" }
        if days < 30 { return "\(days) days ago" }
        let months = days / 30
        return months == 1 ? "1 month ago" : "\(months) months ago"
    }

    private func load() async {
        loading = true
        guard let repo = appState.workspaces else { rows = []; loading = false; return }
        let workspaces = (try? await repo.all(includeArchived: true)) ?? []
        let now = Date()
        var built: [MatterRow] = []
        for ws in workspaces {
            let sources = (try? await repo.sourceCount(in: ws.id)) ?? 0
            let subjects = (try? await repo.entityIDs(in: ws.id))?.count ?? 0
            let ageDays = max(0, Int(now.timeIntervalSince(ws.updatedAt) / 86_400))
            // Attention score: staleness, amplified by how much evidence is at
            // stake. Bounded so one giant matter can't dominate.
            let sizeFactor = 1.0 + min(3.0, Double(sources) / 25.0)
            let score = Double(ageDays) * sizeFactor
            let band: Band = ws.status == .archived ? .low
                : (ageDays >= 30 ? .high : (ageDays >= 10 ? .medium : .low))
            built.append(MatterRow(
                id: ws.id, title: ws.title, template: ws.template.rawValue,
                archived: ws.status == .archived, sources: sources, subjects: subjects,
                updated: ws.updatedAt, ageDays: ageDays, score: score, band: band))
        }
        rows = built.sorted { $0.score > $1.score }
        loading = false
    }
}

#if DEBUG
#Preview("Caseload — empty") {
    CaseloadView()
        .environment(AppState())
        .frame(width: 940, height: 720)
}
#endif
