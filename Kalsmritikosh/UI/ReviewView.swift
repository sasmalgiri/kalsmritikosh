//
//  ReviewView.swift
//  Kalsmritikosh
//
//  Persona features Epic (F5). Turns automated contradiction + gap detection
//  into a human-reviewable workflow. Each card shows both sides of a conflict
//  (never averaged away) or the specific reason a gap is expected, and lets
//  the reviewer record an append-only, reversible decision through the shared
//  review ledger. Absence is never labelled as proof (§10.4).
//
//  COMPETITOR-DNA (2026-08-19) — the review-queue pattern the eDiscovery
//  veterans converged on (Relativity Review Center's "Start review →
//  decide → Save and Next", Everlaw's single-keystroke coding): one item
//  at a time, numbered keys apply a decision and auto-advance, progress
//  always visible. The list stays for browsing; the queue is for clearing.
//

import SwiftUI

public struct ReviewView: View {
    @Environment(AppState.self) private var appState

    private enum Mode: String, CaseIterable { case contradictions, gaps
        var title: String { self == .contradictions ? "Contradictions" : "Missing Evidence" }
        var symbol: String { self == .contradictions ? "exclamationmark.arrow.triangle.2.circlepath" : "questionmark.folder" }
    }
    @State private var mode: Mode = .contradictions

    @State private var contradictions: [Contradiction] = []
    @State private var gaps: [GapNode] = []
    /// targetID → latest recorded decision raw value.
    @State private var decisionByTarget: [String: String] = [:]
    /// Review queue position (nil = browsing the list).
    @State private var queuePosition: Int? = nil

    public init() {}

    /// The ids of the current mode's items, queue order.
    private var queueIDs: [String] {
        switch mode {
        case .contradictions: return contradictions.map { $0.id.uuidString }
        case .gaps:           return gaps.map { $0.id.uuidString }
        }
    }
    private var reviewedCount: Int {
        queueIDs.filter { decisionByTarget[$0] != nil }.count
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(AuroraBackdrop(intensity: 0.5))
        .task { await reload() }
    }

    private var header: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "checkmark.bubble").foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Review").font(Theme.display(26, .bold))
                    Text("Resolve conflicts and follow up on missing evidence. Every decision is recorded and reversible; nothing changes your sources.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).controlSize(.small)
            }
            Picker("", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { m in
                    Label("\(m.title)", systemImage: m.symbol).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: mode) { _, _ in queuePosition = nil }

            if !queueIDs.isEmpty {
                HStack(spacing: 10) {
                    if let position = queuePosition {
                        ProgressView(value: Double(reviewedCount), total: Double(queueIDs.count))
                            .tint(.green)
                            .frame(maxWidth: 240)
                        Text("Item \(position + 1) of \(queueIDs.count) · \(reviewedCount) reviewed")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text("←/→ move · 1–9 decide")
                            .font(.caption2).foregroundStyle(.tertiary)
                        Button("Exit queue") { queuePosition = nil }
                            .controlSize(.small)
                    } else {
                        Button {
                            queuePosition = firstUnreviewed() ?? 0
                        } label: {
                            Label("Start review queue (\(queueIDs.count - reviewedCount) to go)",
                                  systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(queueIDs.count == reviewedCount)
                        .help("Work through items one at a time — decide with the number keys, and it advances for you")
                        if reviewedCount > 0 {
                            Text("\(reviewedCount) of \(queueIDs.count) reviewed")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    // MARK: - Queue engine

    private func firstUnreviewed() -> Int? {
        queueIDs.firstIndex { decisionByTarget[$0] == nil }
    }

    /// After a queue decision: advance to the next unreviewed item (wrapping),
    /// or exit with everything done.
    private func advanceQueue(from position: Int) {
        let ids = queueIDs
        guard !ids.isEmpty else { queuePosition = nil; return }
        let order = Array(position + 1 ..< ids.count) + Array(0 ... position)
        if let next = order.first(where: { decisionByTarget[ids[$0]] == nil }) {
            queuePosition = next
        } else {
            queuePosition = nil   // queue cleared
        }
    }

    private func moveQueue(_ delta: Int) {
        guard let position = queuePosition, !queueIDs.isEmpty else { return }
        queuePosition = min(max(position + delta, 0), queueIDs.count - 1)
    }

    /// Hidden buttons carrying the queue's keyboard: ←/→ (and j/k) move,
    /// 1–9 apply the matching decision and auto-advance.
    @ViewBuilder
    private var queueKeyboard: some View {
        if let position = queuePosition {
            Group {
                Button("") { moveQueue(-1) }.keyboardShortcut(.leftArrow, modifiers: [])
                Button("") { moveQueue(1) }.keyboardShortcut(.rightArrow, modifiers: [])
                Button("") { moveQueue(-1) }.keyboardShortcut("k", modifiers: [])
                Button("") { moveQueue(1) }.keyboardShortcut("j", modifiers: [])
                ForEach(0..<9, id: \.self) { slot in
                    Button("") { applyQueueDecision(slot: slot, position: position) }
                        .keyboardShortcut(KeyEquivalent(Character("\(slot + 1)")), modifiers: [])
                }
            }
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
    }

    private func applyQueueDecision(slot: Int, position: Int) {
        switch mode {
        case .contradictions:
            guard position < contradictions.count else { return }
            let c = contradictions[position]
            let options = ContradictionReviewDecision.allCases
            guard slot < options.count else { return }
            let prior = decisionByTarget[c.id.uuidString]
                .flatMap(ContradictionReviewDecision.init(rawValue:)) ?? .unresolved
            Task {
                await recordContradiction(c, decision: options[slot], prior: prior)
                advanceQueue(from: position)
            }
        case .gaps:
            guard position < gaps.count else { return }
            let g = gaps[position]
            let options = GapReviewDecision.allCases
            guard slot < options.count else { return }
            let prior = decisionByTarget[g.id.uuidString]
                .flatMap(GapReviewDecision.init(rawValue:)) ?? (g.dismissed ? .dismissed : .open)
            Task {
                await recordGap(g, decision: options[slot], prior: prior)
                advanceQueue(from: position)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let position = queuePosition {
            queueView(position)
        } else {
            switch mode {
            case .contradictions:
                if contradictions.isEmpty { empty("No contradictions detected", "checkmark.seal") }
                else { list { ForEach(contradictions) { contradictionCard($0) } } }
            case .gaps:
                if gaps.isEmpty { empty("No missing-evidence gaps flagged", "checkmark.seal") }
                else { list { ForEach(gaps) { gapCard($0) } } }
            }
        }
    }

    /// One item at a time: the full card plus numbered decision buttons —
    /// press the number (or click) and the queue advances itself.
    @ViewBuilder
    private func queueView(_ position: Int) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                switch mode {
                case .contradictions:
                    if position < contradictions.count {
                        contradictionCard(contradictions[position])
                        numberedDecisions(ContradictionReviewDecision.allCases.map(\.displayName)) { slot in
                            applyQueueDecision(slot: slot, position: position)
                        }
                    }
                case .gaps:
                    if position < gaps.count {
                        gapCard(gaps[position])
                        numberedDecisions(GapReviewDecision.allCases.map(\.displayName)) { slot in
                            applyQueueDecision(slot: slot, position: position)
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: 820, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .background(queueKeyboard)
    }

    private func numberedDecisions(_ titles: [String], apply: @escaping (Int) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("DECIDE — press the number or click")
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            FlowingDecisionButtons(titles: titles, apply: apply)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.tint.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }

    private func list<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) { content() }
                .padding(14)
                .frame(maxWidth: 820, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
    }

    private func empty(_ text: String, _ symbol: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 34)).foregroundStyle(.green)
            Text(text).font(.title3.weight(.medium)).foregroundStyle(.secondary)
            // A green tick on an EMPTY archive would be a false all-clear —
            // say what has to happen before this screen means anything.
            Text("Contradictions and gaps are found as your files are read and questions are asked — an empty archive has nothing to disagree yet.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button("Add your files") { SurfaceOpener.open(.sources) }
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Contradiction card

    private func contradictionCard(_ c: Contradiction) -> some View {
        let current = decisionByTarget[c.id.uuidString].flatMap(ContradictionReviewDecision.init(rawValue:)) ?? .unresolved
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(c.kind.displayName)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.tint.opacity(0.15), in: .capsule).foregroundStyle(.tint)
                severityChip(c.severity)
                Spacer()
                Text(c.detectedAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Text(c.description).font(.callout.weight(.medium)).textSelection(.enabled)
            HStack(alignment: .top, spacing: 10) {
                claimBox(title: "Claim A", claim: c.claimA, evidence: c.evidenceA)
                claimBox(title: "Claim B", claim: c.claimB, evidence: c.evidenceB)
            }
            HStack(spacing: 8) {
                Text("Decision").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: Binding(
                    get: { current },
                    set: { newValue in Task { await recordContradiction(c, decision: newValue, prior: current) } }
                )) {
                    ForEach(ContradictionReviewDecision.allCases, id: \.self) { d in
                        Text(d.displayName).tag(d)
                    }
                }
                .labelsHidden().frame(maxWidth: 260)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .cardSurface(cornerRadius: 12)
    }

    private func claimBox(title: String, claim: String, evidence: UUID?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            Text(claim).font(.callout).textSelection(.enabled)
            if evidence != nil {
                Label("source on file", systemImage: "doc.text.magnifyingglass")
                    .font(.caption2).foregroundStyle(.tertiary)
            } else {
                Label("source not linked", systemImage: "questionmark.circle")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func severityChip(_ s: Contradiction.Severity) -> some View {
        let color: Color = s == .high ? .red : (s == .medium ? .orange : .secondary)
        return Text(s.displayName)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15), in: .capsule).foregroundStyle(color)
    }

    // MARK: - Gap card

    private func gapCard(_ g: GapNode) -> some View {
        let current = decisionByTarget[g.id.uuidString].flatMap(GapReviewDecision.init(rawValue:))
            ?? (g.dismissed ? .dismissed : .open)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(g.kind.displayName, systemImage: g.kind.systemImage)
                    .font(.caption.weight(.semibold)).foregroundStyle(.tint)
                Spacer()
                Text("confidence \(Int(g.confidence * 100))%")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Text(g.description).font(.callout.weight(.medium)).textSelection(.enabled)
            Text(g.reason).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if let entity = g.nearEntity {
                Label(entity, systemImage: "person.crop.circle").font(.caption2).foregroundStyle(.tertiary)
            }
            Text("This flags an expected-but-absent item. Absence is not proof — the item may simply live outside this archive.")
                .font(.caption2).foregroundStyle(.tertiary).italic()
            HStack(spacing: 8) {
                Text("Decision").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: Binding(
                    get: { current },
                    set: { newValue in Task { await recordGap(g, decision: newValue, prior: current) } }
                )) {
                    ForEach(GapReviewDecision.allCases, id: \.self) { d in
                        Text(d.displayName).tag(d)
                    }
                }
                .labelsHidden().frame(maxWidth: 240)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .cardSurface(cornerRadius: 12)
    }

    // MARK: - I/O

    private func reload() async {
        let cs = await appState.contradictions?.all() ?? []
        let gs = await appState.gapNodes?.all(includeDismissed: true) ?? []
        var map: [String: String] = [:]
        if let review = appState.review {
            for c in cs {
                if let d = try? await review.history(forTarget: .contradiction, id: c.id.uuidString),
                   let latest = latestState(d) { map[c.id.uuidString] = latest }
            }
            for g in gs {
                if let d = try? await review.history(forTarget: .gap, id: g.id.uuidString),
                   let latest = latestState(d) { map[g.id.uuidString] = latest }
            }
        }
        await MainActor.run {
            self.contradictions = cs
            self.gaps = gs
            self.decisionByTarget = map
        }
    }

    /// Latest non-reversed `.reviewState` decision raw string.
    private func latestState(_ history: [ReviewDecision]) -> String? {
        let reversed = Set(history.compactMap(\.reversalOf))
        return history.filter { $0.dimension == .reviewState && !reversed.contains($0.id) }.last?.decision
    }

    private func recordContradiction(_ c: Contradiction, decision: ContradictionReviewDecision, prior: ContradictionReviewDecision) async {
        guard let review = appState.review else { return }
        try? await review.append(ReviewDecision(
            targetKind: .contradiction, targetID: c.id.uuidString,
            dimension: .reviewState, decision: decision.rawValue, priorValue: prior.rawValue
        ))
        // Reflect into the contradiction's lifecycle status (open/resolved/dismissed).
        let status: Contradiction.Status
        switch decision {
        case .unresolved, .needsMoreEvidence:        status = .open
        case .notActuallyConflict:                   status = .dismissed
        default:                                     status = .resolved
        }
        await appState.contradictions?.setStatus(c.id, status)
        await reload()
    }

    fileprivate struct FlowingDecisionButtons: View {
        let titles: [String]
        let apply: (Int) -> Void
        var body: some View {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
                    Button {
                        apply(index)
                    } label: {
                        HStack(spacing: 6) {
                            Text("\(index + 1)")
                                .font(.caption.monospacedDigit().weight(.bold))
                                .frame(width: 18, height: 18)
                                .background(.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                            Text(title).font(.callout).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private func recordGap(_ g: GapNode, decision: GapReviewDecision, prior: GapReviewDecision) async {
        guard let review = appState.review else { return }
        try? await review.append(ReviewDecision(
            targetKind: .gap, targetID: g.id.uuidString,
            dimension: .reviewState, decision: decision.rawValue, priorValue: prior.rawValue
        ))
        switch decision {
        case .dismissed:                       await appState.gapNodes?.dismiss(g.id)
        case .open, .reopened:                 await appState.gapNodes?.reopen(g.id)
        case .actionPlanned, .resolvedByNewEvidence: break
        }
        await reload()
    }
}
