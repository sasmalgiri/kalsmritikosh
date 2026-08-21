//
//  FreshnessView.swift
//  Kalsmritikosh
//
//  Stale-fact / freshness monitoring. The pain (journalist / content / legal):
//  a fact you confirmed once quietly goes out of date, and no one re-checks it
//  before it's relied on again. This surfaces every human-confirmed fact by how
//  long since it was last reviewed, so the oldest confirmations get a fresh look
//  before they're trusted again. Recomputed each time the screen opens.
//

import SwiftUI
import Charts

public struct FreshnessView: View {
    @Environment(AppState.self) private var appState

    struct Row: Identifiable {
        let id: UUID
        let label: String
        let kind: String
        let reviewedAt: Date
        let ageDays: Int
        let band: Band
    }
    enum Band: String, CaseIterable { case fresh = "Fresh", aging = "Aging", stale = "Stale" }

    @State private var rows: [Row] = []
    @State private var loading = true

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if loading {
                    ProgressView().frame(maxWidth: .infinity, alignment: .center).padding(.top, 40)
                } else if rows.isEmpty {
                    ContentUnavailableView("No confirmed facts yet",
                        systemImage: "clock.badge.checkmark",
                        description: Text("Once you accept or correct facts in Review/Findings, they're monitored here for staleness."))
                } else {
                    bandStrip
                    bandChart
                    staleList
                    explainer
                }
            }
            .padding(24)
            .frame(maxWidth: 820, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .navigationTitle("Freshness")
        .task { await load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Freshness monitor", systemImage: "clock.badge.exclamationmark")
                .font(.title2.bold())
            Text("Every fact you've confirmed, ranked by how long since it was last checked. Aging and stale confirmations are flagged so they get a fresh look before they're relied on again.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var bandStrip: some View {
        HStack(spacing: 16) {
            card("\(rows.filter { $0.band == .stale }.count)", "Stale (> 1 year)", .red)
            card("\(rows.filter { $0.band == .aging }.count)", "Aging (3–12 mo)", .orange)
            card("\(rows.filter { $0.band == .fresh }.count)", "Fresh (< 3 mo)", .green)
        }
    }

    private func card(_ v: String, _ l: String, _ c: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(v).font(.title.bold()).foregroundStyle(c)
            Text(l).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(c.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private var bandChart: some View {
        let counts = Band.allCases.map { band in
            (band, rows.filter { $0.band == band }.count)
        }
        return VStack(alignment: .leading, spacing: 8) {
            Text("Confirmation age").font(.headline)
            Chart(counts, id: \.0.rawValue) { pair in
                BarMark(x: .value("Band", pair.0.rawValue), y: .value("Count", pair.1))
                    .foregroundStyle(color(pair.0))
            }
            .frame(height: 180)
        }
    }

    private var staleList: some View {
        let stalest = rows.filter { $0.band != .fresh }.prefix(30)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Re-check these first").font(.headline)
            if stalest.isEmpty {
                Text("Nothing aging or stale — all confirmations are recent.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(Array(stalest)) { row in
                    HStack(alignment: .top, spacing: 12) {
                        Circle().fill(color(row.band)).frame(width: 10, height: 10).padding(.top, 5)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.label).fontWeight(.medium).lineLimit(2)
                            Text(row.kind).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(ageLabel(row.ageDays)).font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private var explainer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Why it matters").font(.subheadline.bold())
            Text("A fact confirmed a year ago may no longer hold. Flagging the oldest confirmations keeps them from being reused as if freshly checked — the difference between a current answer and a confidently wrong one.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 8)
    }

    private func color(_ b: Band) -> Color {
        switch b { case .fresh: return .green; case .aging: return .orange; case .stale: return .red }
    }
    private func ageLabel(_ days: Int) -> String {
        if days < 30 { return "\(max(1, days))d ago" }
        if days < 365 { return "\(days / 30)mo ago" }
        let years = days / 365
        return years == 1 ? "1yr ago" : "\(years)yr ago"
    }

    private func load() async {
        loading = true
        guard let repo = appState.factReviews else { rows = []; loading = false; return }
        let latest = (try? await repo.latestBySubject()) ?? [:]
        let now = Date()
        var built: [Row] = []
        for (subjectID, review) in latest {
            // Only monitor confirmations — accepted / corrected / marked authority.
            switch review.action {
            case .accept, .correct, .markAuthority: break
            default: continue
            }
            let ageDays = max(0, Int(now.timeIntervalSince(review.reviewedAt) / 86_400))
            let band: Band = ageDays > 365 ? .stale : (ageDays >= 90 ? .aging : .fresh)
            let label = [review.newValue, review.priorValue]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first(where: { !$0.isEmpty }) ?? "\(review.subjectKind.rawValue) \(subjectID.uuidString.prefix(8))"
            built.append(Row(
                id: subjectID, label: label, kind: review.subjectKind.rawValue.capitalized,
                reviewedAt: review.reviewedAt, ageDays: ageDays, band: band))
        }
        rows = built.sorted { $0.ageDays > $1.ageDays }
        loading = false
    }
}

#if DEBUG
#Preview("Freshness — empty") {
    FreshnessView()
        .environment(AppState())
        .frame(width: 940, height: 720)
}
#endif
