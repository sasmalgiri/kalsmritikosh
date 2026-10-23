//
//  FundFlowView.swift
//  Kalsmritikosh
//
//  Visual money-flow (Sankey-style) view — the forensic-accountant wish that
//  can't be a workflow step. It draws payer → payee flows from the ledger's
//  payment relationships as ribbons whose thickness reflects how strongly the
//  payment is corroborated, with a ranked, evidence-linked edge list beneath.
//
//  A-8 — amounts. The ledger's payment relationships carry no amount of their
//  own; amounts live as separate money facts. FundsTrace ties a document's
//  amount to a payment only when that document backs exactly one payment and
//  holds exactly one distinct amount; everything else is listed as not
//  assigned, with the reason. With those amounts the view shows a money-flow
//  chart per currency (currencies are never added together), totals on each
//  edge, a per-party in / out / net table, and "follow the money" from a chosen
//  party, where each party passes on at most what it received in the trace.
//  Every figure lists the facts and documents it came from.
//

import SwiftUI
import os
#if canImport(AppKit)
import AppKit
#endif

public struct FundFlowView: View {
    @Environment(AppState.self) private var appState

    @State private var payers: [Node] = []
    @State private var payees: [Node] = []
    @State private var edges: [FundFlowEdge] = []
    @State private var totalEdges = 0
    @State private var omitted = 0
    @State private var loading = true

    // A-8 amounts
    @State private var transfers: [FundsTransfer] = []
    @State private var unattributed: [FundsUnattributed] = []
    @State private var edgeTotals: [FundsEdgeTotal] = []
    @State private var balances: [FundsPartyBalance] = []
    @State private var documentNames: [String: String] = [:]
    @State private var edgeLimitReached = false
    @State private var currency: String = ""
    @State private var traceOrigin: String = ""
    @State private var traceResult: FundsTraceResult?
    @State private var openSource: CitationOpenTarget?
    @State private var amountsError: String?

    struct Node: Hashable { let label: String; let total: Double }
    struct Link: Hashable { let from: String; let to: String; let weight: Double }

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
                    diagram(payers: payers, payees: payees,
                            links: edges.map { Link(from: $0.fromLabel, to: $0.toLabel, weight: Double($0.weight)) },
                            labelFor: nil)
                    if omitted > 0 {
                        Text("Showing the top \(maxPerSide) payers and payees by corroboration. \(omitted) smaller flow(s) are not drawn.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    edgeList
                    disclaimer
                    Divider()
                    amountsSection
                }
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .navigationTitle("Fund Flow")
        .task { await load() }
        .sheet(item: $openSource) { target in
            CitationSourceSheet(target: target) { openSource = nil }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Fund flow", systemImage: "arrow.triangle.branch")
                .font(.title2.bold())
            Text("How money moved between parties, drawn from the payment relationships in your evidence. Payers on the left, payees on the right; ribbon thickness reflects how strongly each payment is corroborated. Below, the amounts recorded in the same documents.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var empty: some View {
        ContentUnavailableView("No payment flows yet",
            systemImage: "arrow.triangle.branch",
            description: Text("When the ledger extracts payment relationships (payer → payee) from your documents, they'll be drawn here."))
    }

    private func diagram(payers: [Node], payees: [Node], links: [Link], labelFor: ((Node) -> String)?) -> some View {
        let rowCount = max(payers.count, payees.count)
        let height = max(320, CGFloat(rowCount) * 40)
        return Canvas { ctx, size in draw(in: ctx, size: size, payers: payers, payees: payees, links: links, labelFor: labelFor) }
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
            Text("Ribbon width above is corroboration strength (how often and from how many documents the payment was observed) — not an amount. \"×N\" is the corroboration count; \"src\" is the number of distinct source documents. Amounts are shown separately below, only where a document ties one amount to one payment.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 8)
    }

    // MARK: - A-8 amounts

    private var currencies: [String] { Array(Set(edgeTotals.map(\.currency))).sorted() }

    @ViewBuilder
    private var amountsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Amounts", systemImage: "banknote").font(.title3.bold())
            if let amountsError {
                Text(amountsError).font(.callout).foregroundStyle(.secondary)
            } else if transfers.isEmpty {
                Text("No amount could be tied to a payment without guessing. A document's amount is used only when the document records one payment and one amount.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                if currencies.count > 1 {
                    Picker("Currency", selection: $currency) {
                        ForEach(currencies, id: \.self) { Text(currencyLabel($0)).tag($0) }
                    }
                    .pickerStyle(.segmented).frame(maxWidth: 420)
                    Text("Each currency is shown on its own — amounts in different currencies are never added together.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                amountDiagram
                amountEdgeList
                partyTable
                traceSection
            }
            if edgeLimitReached {
                Text("Only the 2,000 strongest payment relationships were read; weaker ones are not in these figures.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            unattributedList
        }
        .onChange(of: currency) { _, _ in traceResult = nil; traceOrigin = "" }
    }

    private var currentTotals: [FundsEdgeTotal] { edgeTotals.filter { $0.currency == currency } }

    private var amountDiagram: some View {
        let totals = currentTotals
        var pTot: [String: Double] = [:], qTot: [String: Double] = [:]
        for e in totals {
            let v = (e.total as NSDecimalNumber).doubleValue
            pTot[e.fromLabel, default: 0] += v; qTot[e.toLabel, default: 0] += v
        }
        let topP = Set(pTot.sorted { $0.value > $1.value }.prefix(maxPerSide).map(\.key))
        let topQ = Set(qTot.sorted { $0.value > $1.value }.prefix(maxPerSide).map(\.key))
        let visible = totals.filter { topP.contains($0.fromLabel) && topQ.contains($0.toLabel) }
        var vp: [String: Double] = [:], vq: [String: Double] = [:]
        for e in visible {
            let v = (e.total as NSDecimalNumber).doubleValue
            vp[e.fromLabel, default: 0] += v; vq[e.toLabel, default: 0] += v
        }
        let ps = vp.map { Node(label: $0.key, total: $0.value) }.sorted { $0.total > $1.total }
        let qs = vq.map { Node(label: $0.key, total: $0.value) }.sorted { $0.total > $1.total }
        let cur = currency
        return VStack(alignment: .leading, spacing: 6) {
            Text("Money flow — \(currencyLabel(currency))").font(.headline)
            Text("Ribbon width here is the amount.").font(.caption).foregroundStyle(.secondary)
            diagram(payers: ps, payees: qs,
                    links: visible.map { Link(from: $0.fromLabel, to: $0.toLabel, weight: ($0.total as NSDecimalNumber).doubleValue) },
                    labelFor: { node in "\(node.label) · \(FundsTrace.format(Decimal(node.total), currency: cur))" })
            if visible.count < totals.count {
                Text("\(totals.count - visible.count) smaller flow(s) are not drawn; all are listed below.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var amountEdgeList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Amounts per flow").font(.headline)
            ForEach(currentTotals) { e in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 10) {
                        Text(e.fromLabel).fontWeight(.medium).lineLimit(1)
                        Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                        Text(e.toLabel).fontWeight(.medium).lineLimit(1)
                        Spacer()
                        Text(FundsTrace.format(e.total, currency: e.currency)).font(.callout.monospacedDigit().weight(.semibold))
                        Text("\(e.transferCount) payment\(e.transferCount == 1 ? "" : "s")").font(.caption2).foregroundStyle(.secondary)
                    }
                    sources(factIDs: e.factIDs, documentIDs: e.documentIDs)
                }
                .padding(8)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private var partyTable: some View {
        let rows = balances.filter { $0.currency == currency }
        return VStack(alignment: .leading, spacing: 8) {
            Text("Per party — in, out, net").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("Party").font(.caption.weight(.semibold))
                    Text("Received").font(.caption.weight(.semibold)).gridColumnAlignment(.trailing)
                    Text("Paid out").font(.caption.weight(.semibold)).gridColumnAlignment(.trailing)
                    Text("Net").font(.caption.weight(.semibold)).gridColumnAlignment(.trailing)
                    Text("Sources").font(.caption.weight(.semibold))
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(rows) { b in
                    GridRow(alignment: .top) {
                        Text(b.label).lineLimit(2)
                        Text(FundsTrace.format(b.received, currency: b.currency)).monospacedDigit()
                        Text(FundsTrace.format(b.sent, currency: b.currency)).monospacedDigit()
                        Text(FundsTrace.format(b.net, currency: b.currency)).monospacedDigit()
                            .foregroundStyle(b.net < 0 ? Color.orange : Color.primary)
                        sources(factIDs: b.factIDs, documentIDs: b.documentIDs)
                    }
                    .font(.caption)
                }
            }
            Text("Net = received − paid out, counting only the payments whose amount is recorded here. A negative net means the documents show it paying out more than they show it receiving — not that money is missing.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var traceSection: some View {
        let senders = balances.filter { $0.currency == currency && $0.sent > 0 }.sorted { $0.label < $1.label }
        return VStack(alignment: .leading, spacing: 10) {
            Text("Follow the money").font(.headline)
            Text("Pick a party to follow what it paid, hop by hop. Each later party can pass on at most what reached it in this trace; where it received more than it passed on, or nothing onward is recorded, the money stops.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Picker("From", selection: $traceOrigin) {
                    Text("Choose a party").tag("")
                    ForEach(senders) { Text($0.label).tag($0.partyID) }
                }
                .frame(maxWidth: 320)
                Button("Follow") {
                    traceResult = FundsTrace.trace(from: traceOrigin, currency: currency, edges: edgeTotals)
                }
                .disabled(traceOrigin.isEmpty)
            }
            if let t = traceResult { traceView(t) }
        }
    }

    private func traceView(_ t: FundsTraceResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(t.originLabel) paid out \(FundsTrace.format(t.sentByOrigin, currency: t.currency)) in the recorded payments.")
                .font(.callout.weight(.semibold))
            ForEach(t.steps) { s in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("Hop \(s.depth)").font(.caption2.weight(.bold)).foregroundStyle(.tint).frame(width: 46, alignment: .leading)
                        Text(s.fromLabel).lineLimit(1)
                        Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                        Text(s.toLabel).lineLimit(1)
                        Spacer()
                        Text(FundsTrace.format(s.traced, currency: t.currency)).monospacedDigit().fontWeight(.semibold)
                    }
                    .font(.caption)
                    if s.capped {
                        Text("Recorded payment is \(FundsTrace.format(s.recorded, currency: t.currency)); only \(FundsTrace.format(s.traced, currency: t.currency)) of it can come from the money traced here.")
                            .font(.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                    sources(factIDs: s.factIDs, documentIDs: s.documentIDs)
                }
                .padding(8).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
            }
            if !t.stops.isEmpty {
                Text("Where the money stops").font(.subheadline.bold()).padding(.top, 4)
                ForEach(t.stops) { s in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: "stop.circle").foregroundStyle(.secondary)
                            Text(s.label).lineLimit(1)
                            Text("— \(s.explanation)").foregroundStyle(.secondary).lineLimit(2)
                            Spacer()
                            Text(FundsTrace.format(s.amount, currency: t.currency)).monospacedDigit()
                        }
                        .font(.caption)
                        sources(factIDs: s.factIDs, documentIDs: s.documentIDs)
                    }
                }
            }
            Text("This is arithmetic over the recorded amounts, not a finding: money is fungible, and a party may have paid from funds the documents don't show.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var unattributedList: some View {
        if !unattributed.isEmpty {
            DisclosureGroup("\(unattributed.count) payment document\(unattributed.count == 1 ? "" : "s") without an assigned amount") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(unattributed) { u in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                documentButton(u.documentID)
                                Text("— \(u.explanation)").font(.caption).foregroundStyle(.secondary)
                            }
                            Text(u.payments.joined(separator: "; ")).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                            if !u.factIDs.isEmpty {
                                Text("Facts: \(u.factIDs.joined(separator: ", "))").font(.caption2.monospaced()).foregroundStyle(.tertiary)
                                    .textSelection(.enabled).lineLimit(3)
                            }
                        }
                    }
                }
                .padding(.top, 4)
            }
            .font(.callout)
        }
    }

    /// The citation list for one figure: the documents (each opens its source) and the fact ids.
    private func sources(factIDs: [String], documentIDs: [String]) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(documentIDs, id: \.self) { documentButton($0) }
                Text("Facts: \(factIDs.joined(separator: ", "))")
                    .font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Button { copyCitation(factIDs: factIDs, documentIDs: documentIDs) } label: {
                    Label("Copy citation", systemImage: "doc.on.doc").font(.caption2)
                }
                .buttonStyle(.borderless)
            }
        } label: {
            Text("\(documentIDs.count) document\(documentIDs.count == 1 ? "" : "s") · \(factIDs.count) fact\(factIDs.count == 1 ? "" : "s")")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func documentButton(_ id: String) -> some View {
        Button { open(documentID: id) } label: {
            Label(documentNames[id] ?? id, systemImage: "doc.text").font(.caption2).lineLimit(1)
        }
        .buttonStyle(.borderless)
        .help("Open the source · \(id)")
    }

    private func open(documentID: String) {
        guard let objectID = UUID(uuidString: documentID) else { return }
        Task { @MainActor in
            do {
                guard let url = try await appState.objects?.fetchSourceURL(id: objectID) else {
                    KalsmritikoshLog.ui.info("Fund flow: no source file for \(documentID, privacy: .public)")
                    return
                }
                openSource = CitationOpenTarget(url: url, objectID: objectID, quote: nil)
            } catch {
                KalsmritikoshLog.ui.error("Fund flow source open failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func copyCitation(factIDs: [String], documentIDs: [String]) {
        #if canImport(AppKit)
        let docs = documentIDs.map { "\(documentNames[$0] ?? "document") [\($0)]" }.joined(separator: "; ")
        let text = "Documents: \(docs)\nFacts: \(factIDs.joined(separator: ", "))"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }

    private func currencyLabel(_ c: String) -> String { c == FundsMoney.unstated ? "Currency not stated" : c }

    // MARK: - Canvas drawing

    private func draw(in ctx: GraphicsContext, size: CGSize, payers: [Node], payees: [Node], links: [Link],
                      labelFor: ((Node) -> String)?) {
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
        let ordered = links.sorted { $0.from != $1.from ? $0.from < $1.from : $0.weight > $1.weight }
        for e in ordered {
            guard let pr = payerRects[e.from], let qr = payeeRects[e.to] else { continue }
            let payerTotal = payers.first { $0.label == e.from }?.total ?? e.weight
            let payeeTotal = payees.first { $0.label == e.to }?.total ?? e.weight
            let hL = pr.height * CGFloat(e.weight / max(Double.leastNonzeroMagnitude, payerTotal))
            let hR = qr.height * CGFloat(e.weight / max(Double.leastNonzeroMagnitude, payeeTotal))
            let y0 = payerCursor[e.from] ?? pr.minY
            let y1 = payeeCursor[e.to] ?? qr.minY
            payerCursor[e.from] = y0 + hL
            payeeCursor[e.to] = y1 + hR

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
            ctx.draw(Text(labelFor?(node) ?? node.label).font(.caption2).foregroundColor(.primary),
                     at: CGPoint(x: r.minX - 6, y: r.midY), anchor: .trailing)
        }
        for node in payees {
            guard let r = payeeRects[node.label] else { continue }
            ctx.fill(Path(roundedRect: r, cornerRadius: 3), with: .color(.green))
            ctx.draw(Text(labelFor?(node) ?? node.label).font(.caption2).foregroundColor(.primary),
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
        let totalWeight = max(Double.leastNonzeroMagnitude, nodes.reduce(0) { $0 + $1.total })
        var y: CGFloat = 0
        var out: [String: CGRect] = [:]
        for node in nodes {
            let h = max(6, usable * CGFloat(node.total / totalWeight))
            out[node.label] = CGRect(x: x, y: y, width: nodeWidth, height: h)
            y += h + gap
        }
        return out
    }

    // MARK: - Load

    private func load() async {
        loading = true
        guard let repo = appState.relationships else { loading = false; return }
        let all: [FundFlowEdge]
        do { all = try await repo.fundFlowEdges() } catch {
            KalsmritikoshLog.ui.error("Fund flow edges failed: \(error.localizedDescription, privacy: .public)")
            all = []
        }
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
        payers = pTot.map { Node(label: $0.key, total: Double($0.value)) }.sorted { $0.total > $1.total }
        payees = qTot.map { Node(label: $0.key, total: Double($0.value)) }.sorted { $0.total > $1.total }
        edges = visible
        omitted = totalEdges - visible.count
        await loadAmounts()
        loading = false
    }

    private func loadAmounts() async {
        guard let database = appState.database else { return }
        do {
            let snap = try await FundsTraceLoader.load(database)
            let attributed = FundsTrace.attribute(edges: snap.edges, amounts: snap.amounts)
            transfers = attributed.transfers
            unattributed = attributed.unattributed
            edgeTotals = FundsTrace.edgeTotals(attributed.transfers)
            balances = FundsTrace.partyBalances(attributed.transfers)
            documentNames = snap.documentNames
            edgeLimitReached = snap.edgeLimitReached
            let cs = Array(Set(edgeTotals.map(\.currency))).sorted()
            if !cs.contains(currency) { currency = cs.first ?? "" }
            amountsError = nil
        } catch {
            KalsmritikoshLog.ui.error("Fund flow amounts failed: \(error.localizedDescription, privacy: .public)")
            amountsError = "Couldn't read the amounts from the ledger: \(error.localizedDescription)"
        }
    }
}

#if DEBUG
#Preview("Fund flow — empty") {
    FundFlowView()
        .environment(AppState())
        .frame(width: 940, height: 720)
}
#endif
