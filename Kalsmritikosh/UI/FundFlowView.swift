//
//  FundFlowView.swift
//  Kalsmritikosh
//
//  Visual money-flow (Sankey-style) view — the forensic-accountant wish that
//  can't be a workflow step. It draws payer → payee flows from the ledger's
//  payment relationships as ribbons whose thickness reflects how strongly the
//  payment is corroborated, with a ranked, evidence-linked edge list beneath.
//
//  Honesty note: the ledger records who-paid-whom and how well-corroborated it
//  is, but not a reliable per-edge amount (amounts live as separate money
//  facts). So ribbon thickness is corroboration weight, NOT dollars — the view
//  says so plainly rather than drawing invented amounts.
//

import SwiftUI

public struct FundFlowView: View {
    @Environment(AppState.self) private var appState

    @State private var payers: [Node] = []
    @State private var payees: [Node] = []
    @State private var edges: [FundFlowEdge] = []
    @State private var totalEdges = 0
    @State private var omitted = 0
    @State private var loading = true

    struct Node: Hashable { let label: String; let total: Int }

    private let maxPerSide = 12
    private let nodeWidth: CGFloat = 14
    private let labelMargin: CGFloat = 130

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if loading {
                    ProgressView().frame(maxWidth: .infinity, alignment: .center).padding(.top, 40)
                } else if edges.isEmpty {
                    empty
                } else {
                    diagram
                    if omitted > 0 {
                        Text("Showing the top \(maxPerSide) payers and payees by corroboration. \(omitted) smaller flow(s) are not drawn.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    edgeList
                    disclaimer
                }
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .navigationTitle("Fund Flow")
        .task { await load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Fund flow", systemImage: "arrow.triangle.branch")
                .font(.title2.bold())
            Text("How money moved between parties, drawn from the payment relationships in your evidence. Payers on the left, payees on the right; ribbon thickness reflects how strongly each payment is corroborated.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var empty: some View {
        ContentUnavailableView("No payment flows yet",
            systemImage: "arrow.triangle.branch",
            description: Text("When the ledger extracts payment relationships (payer → payee) from your documents, they'll be drawn here."))
    }

    private var diagram: some View {
        let rowCount = max(payers.count, payees.count)
        let height = max(320, CGFloat(rowCount) * 40)
        return Canvas { ctx, size in draw(in: ctx, size: size) }
            .frame(height: height)
            .background(.quaternary.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
    }

    private var edgeList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Flows by strength").font(.headline)
            ForEach(edges.sorted { $0.weight > $1.weight }) { e in
                HStack(spacing: 10) {
                    Text(e.fromLabel).fontWeight(.medium).lineLimit(1)
                    Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                    Text(e.toLabel).fontWeight(.medium).lineLimit(1)
                    Spacer()
                    Text("×\(e.weight)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Text("\(e.evidenceCount) src").font(.caption2).foregroundStyle(.secondary)
                }
                .padding(8)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private var disclaimer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What the thickness means").font(.subheadline.bold())
            Text("Ribbon width is corroboration strength (how often and from how many documents the payment was observed) — not a dollar amount. The ledger doesn't hold a reliable per-payment figure, so none is drawn. \"×N\" is the corroboration count; \"src\" is the number of distinct source documents.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 8)
    }

    // MARK: - Canvas drawing

    private func draw(in ctx: GraphicsContext, size: CGSize) {
        guard !payers.isEmpty, !payees.isEmpty else { return }
        let leftX = labelMargin
        let rightX = size.width - labelMargin - nodeWidth
        guard rightX > leftX else { return }

        let payerRects = columnRects(payers, x: leftX, height: size.height)
        let payeeRects = columnRects(payees, x: rightX, height: size.height)

        // Ribbon cursors per node (fill from top of each node's bar).
        var payerCursor: [String: CGFloat] = [:]
        var payeeCursor: [String: CGFloat] = [:]
        for node in payers { payerCursor[node.label] = payerRects[node.label]?.minY ?? 0 }
        for node in payees { payeeCursor[node.label] = payeeRects[node.label]?.minY ?? 0 }

        // Draw ribbons first (behind nodes), grouped by payer for contiguity.
        let ordered = edges.sorted {
            ($0.fromLabel, $1.weight) < ($1.fromLabel, $0.weight)
        }
        for e in ordered {
            guard let pr = payerRects[e.fromLabel], let qr = payeeRects[e.toLabel] else { continue }
            let payerTotal = payers.first { $0.label == e.fromLabel }?.total ?? e.weight
            let payeeTotal = payees.first { $0.label == e.toLabel }?.total ?? e.weight
            let hL = pr.height * CGFloat(e.weight) / CGFloat(max(1, payerTotal))
            let hR = qr.height * CGFloat(e.weight) / CGFloat(max(1, payeeTotal))
            let y0 = payerCursor[e.fromLabel] ?? pr.minY
            let y1 = payeeCursor[e.toLabel] ?? qr.minY
            payerCursor[e.fromLabel] = y0 + hL
            payeeCursor[e.toLabel] = y1 + hR

            let xL = pr.maxX
            let xR = qr.minX
            let midX = (xL + xR) / 2
            var path = Path()
            path.move(to: CGPoint(x: xL, y: y0))
            path.addCurve(to: CGPoint(x: xR, y: y1),
                          control1: CGPoint(x: midX, y: y0),
                          control2: CGPoint(x: midX, y: y1))
            path.addLine(to: CGPoint(x: xR, y: y1 + hR))
            path.addCurve(to: CGPoint(x: xL, y: y0 + hL),
                          control1: CGPoint(x: midX, y: y1 + hR),
                          control2: CGPoint(x: midX, y: y0 + hL))
            path.closeSubpath()
            ctx.fill(path, with: .color(.accentColor.opacity(0.28)))
        }

        // Draw nodes + labels.
        for node in payers {
            guard let r = payerRects[node.label] else { continue }
            ctx.fill(Path(roundedRect: r, cornerRadius: 3), with: .color(.blue))
            ctx.draw(Text(node.label).font(.system(size: 10)).foregroundColor(.primary),
                     at: CGPoint(x: r.minX - 6, y: r.midY), anchor: .trailing)
        }
        for node in payees {
            guard let r = payeeRects[node.label] else { continue }
            ctx.fill(Path(roundedRect: r, cornerRadius: 3), with: .color(.green))
            ctx.draw(Text(node.label).font(.system(size: 10)).foregroundColor(.primary),
                     at: CGPoint(x: r.maxX + 6, y: r.midY), anchor: .leading)
        }
    }

    /// Vertical bars for one column, sized proportionally to each node's total.
    /// Keyed by label for lookup; vertical order follows the input array.
    private func columnRects(_ nodes: [Node], x: CGFloat, height: CGFloat) -> [String: CGRect] {
        let n = nodes.count
        guard n > 0 else { return [:] }
        let gap: CGFloat = 8
        let usable = max(0, height - gap * CGFloat(n - 1))
        let totalWeight = max(1, nodes.reduce(0) { $0 + $1.total })
        var y: CGFloat = 0
        var out: [String: CGRect] = [:]
        for node in nodes {
            let h = max(6, usable * CGFloat(node.total) / CGFloat(totalWeight))
            out[node.label] = CGRect(x: x, y: y, width: nodeWidth, height: h)
            y += h + gap
        }
        return out
    }

    // MARK: - Load

    private func load() async {
        loading = true
        guard let repo = appState.relationships else { loading = false; return }
        let all = (try? await repo.fundFlowEdges()) ?? []
        totalEdges = all.count

        var payerTotals: [String: Int] = [:]
        var payeeTotals: [String: Int] = [:]
        for e in all {
            payerTotals[e.fromLabel, default: 0] += e.weight
            payeeTotals[e.toLabel, default: 0] += e.weight
        }
        let topPayers = Set(payerTotals.sorted { $0.value > $1.value }.prefix(maxPerSide).map { $0.key })
        let topPayees = Set(payeeTotals.sorted { $0.value > $1.value }.prefix(maxPerSide).map { $0.key })
        let visible = all.filter { topPayers.contains($0.fromLabel) && topPayees.contains($0.toLabel) }

        // Recompute totals from the visible edges so ribbon bands fill exactly.
        var pTot: [String: Int] = [:]
        var qTot: [String: Int] = [:]
        for e in visible {
            pTot[e.fromLabel, default: 0] += e.weight
            qTot[e.toLabel, default: 0] += e.weight
        }
        payers = pTot.map { Node(label: $0.key, total: $0.value) }.sorted { $0.total > $1.total }
        payees = qTot.map { Node(label: $0.key, total: $0.value) }.sorted { $0.total > $1.total }
        edges = visible
        omitted = totalEdges - visible.count
        loading = false
    }
}
