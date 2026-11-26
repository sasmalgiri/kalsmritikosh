//
//  CaseMapPresentations.swift
//  Kalsmritikosh
//
//  Smart-map S3 (MAP-07, plan §18 SM-03): the same records of the current view as a TABLE and as a TIMELINE with date
//  and amount distributions. One model, one selection, one subset: choosing a date range or an amount band highlights
//  the same records in the map, the list, the table and the timeline. Counts, currencies and undated records are said
//  explicitly; amounts in different currencies are never added together. Widths are pinned (macOS 26 split-view rule).
//

import SwiftUI

/// The table: one row per record shown in this view, sortable by its columns.
struct CaseMapTable: View {
    let map: CaseMapWorkspaceModel
    let projection: CaseMapProjection
    let result: CaseMapViewResult

    struct Row: Identifiable {
        let node: CaseMapNode
        var id: CaseMapNodeID { node.id }
        var kind: String { node.kind.label }
        var title: String { node.title }
        var state: String { node.status.kind.label + ": " + node.status.text }
        var review: String { node.review.label }
        var date: String { node.dateLabel ?? "—" }
        var amount: String { node.money?.display ?? "—" }
        var sources: Int { node.sources.count }
        var dateSort: Double { node.eventDate?.timeIntervalSince1970 ?? .greatestFiniteMagnitude }
    }
    @State private var order = [KeyPathComparator(\Row.dateSort)]

    var body: some View {
        let rows = result.shown.compactMap { projection.node($0) }.map(Row.init).sorted(using: order)
        VStack(alignment: .leading, spacing: 4) {
            if let s = map.subset {
                subsetBar(s)
            }
            Table(rows, selection: Binding<CaseMapNodeID?>(get: { if case .node(let id)? = map.selection { return id }; return nil },
                                                           set: { map.select($0.map { .node($0) }) }), sortOrder: $order) {
                TableColumn("") { r in
                    Image(systemName: map.isInSubset(r.id) ? "largecircle.fill.circle" : r.node.kind.symbol)
                        .accessibilityLabel(map.isInSubset(r.id) ? "In the chosen range" : r.node.kind.label)
                }.width(22)
                TableColumn("Kind", value: \.kind).width(min: 80, ideal: 110)
                TableColumn("Item", value: \.title).width(min: 160, ideal: 280)
                TableColumn("State", value: \.state).width(min: 120, ideal: 200)
                TableColumn("Review", value: \.review).width(min: 80, ideal: 120)
                TableColumn("Date", value: \.dateSort) { r in Text(r.date) }.width(min: 90, ideal: 140)
                TableColumn("Amount", value: \.amount).width(min: 70, ideal: 110)
                TableColumn("Sources", value: \.sources) { r in Text("\(r.sources)").monospacedDigit() }.width(56)
            }
            .accessibilityIdentifier("case.map.table")
            Text("\(rows.count) row(s) — the records this view shows; the footer counts the rest. Amounts are each in their own currency.")
                .font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.bottom, 4)
        }
    }

    func subsetBar(_ s: CaseMapBucket) -> some View { CaseMapSubsetBar(map: map, bucket: s) }
}

/// "Chosen range: March 2026 — 4 record(s)" with Clear — shown in every presentation while a range is chosen.
struct CaseMapSubsetBar: View {
    let map: CaseMapWorkspaceModel
    let bucket: CaseMapBucket
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "largecircle.fill.circle").accessibilityHidden(true)
            Text("Chosen range: \(bucket.label) — \(bucket.members.count) record(s)"
                 + (bucket.total.map { t in " · total " + CaseMapMoney(amount: t, currency: bucket.currency ?? FundsMoney.unstated).display } ?? ""))
                .font(.caption)
            Spacer()
            Button("Clear range") { map.subset = nil }.buttonStyle(.borderless).font(.caption)
                .help("Stops highlighting the chosen records. Nothing in the case changes.")
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 8)
    }
}

/// The timeline: date distribution (and amount bands for money), then the dated records by bucket.
struct CaseMapTimeline: View {
    let map: CaseMapWorkspaceModel
    let projection: CaseMapProjection
    let result: CaseMapViewResult
    @State private var grain: CaseMapDistribution.DateGrain = .month

    var body: some View {
        let dates = CaseMapDistribution.byDate(result.shown, in: projection, grain: grain)
        let amounts = CaseMapDistribution.byAmount(result.shown, in: projection)
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Recorded dates").font(.headline)
                    Picker("Group by", selection: $grain) {
                        Text("Year").tag(CaseMapDistribution.DateGrain.year)
                        Text("Month").tag(CaseMapDistribution.DateGrain.month)
                        Text("Day").tag(CaseMapDistribution.DateGrain.day)
                    }
                    .pickerStyle(.segmented).frame(maxWidth: 220)
                    Spacer()
                }
                Text("Each record sits at the precision its date was recorded with: a date known only to the month is in its own “(month only)” band, never placed on an invented day. \(dates.undated) record(s) in this view have no recorded date.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let s = map.subset { CaseMapSubsetBar(map: map, bucket: s) }
                bars(dates.buckets)
                if !amounts.isEmpty {
                    Text("Money by amount, per currency").font(.headline).padding(.top, 6)
                    Text("Bands are per currency; no total adds currencies together. An amount is what a document states, not a verified payment.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    bars(amounts)
                }
                Divider()
                ForEach(dates.buckets) { b in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(b.label) (\(b.members.count))").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(b.members, id: \.self) { id in
                            if let n = projection.node(id) {
                                Button { map.select(.node(id)) } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: n.kind.symbol).frame(width: 16).accessibilityHidden(true)
                                        Text(n.title).lineLimit(1)
                                        Spacer()
                                        Text(n.dateLabel ?? "").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    .padding(.vertical, 2).padding(.horizontal, 4)
                                    .background(map.selection == .node(id) ? Color.accentColor.opacity(0.18) : (map.isInSubset(id) ? Color.accentColor.opacity(0.07) : .clear),
                                                in: RoundedRectangle(cornerRadius: 4))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(CaseMapSpoken.nodeLabel(n))
                                .accessibilityValue(n.dateLabel ?? "No date")
                            }
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("case.map.timeline")
    }

    /// Bars as buttons: choosing one highlights its records everywhere (the map, the list, the table and here).
    private func bars(_ buckets: [CaseMapBucket]) -> some View {
        let most = max(1, buckets.map(\.members.count).max() ?? 1)
        return VStack(alignment: .leading, spacing: 3) {
            if buckets.isEmpty { Text("Nothing in this view has one.").font(.caption).foregroundStyle(.secondary) }
            ForEach(buckets) { b in
                Button { map.subset = map.subset?.id == b.id ? nil : b } label: {
                    HStack(spacing: 6) {
                        Text(b.label).font(.caption).frame(width: 170, alignment: .leading).lineLimit(1)
                        GeometryReader { geo in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(map.subset?.id == b.id ? Color.accentColor : Color.secondary.opacity(0.45))
                                .frame(width: max(2, geo.size.width * CGFloat(b.members.count) / CGFloat(most)), height: 10)
                                .frame(maxHeight: .infinity, alignment: .center)
                        }
                        .frame(height: 14).frame(maxWidth: 360)
                        Text("\(b.members.count)" + (b.total.map { " · " + CaseMapMoney(amount: $0, currency: b.currency ?? FundsMoney.unstated).display } ?? ""))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(b.label): \(b.members.count) record(s)")
                .accessibilityHint("Highlights these records in every presentation.")
                .accessibilityAddTraits(map.subset?.id == b.id ? [.isSelected] : [])
            }
        }
    }
}
