//
//  CaseAIConflictViews.swift
//  Kalsmritikosh
//
//  Owner request 2026-11-16 — the parts of the contradiction screen for "Look for conflicts with AI…": the sheet shown
//  BEFORE anything runs (what would be sent, what is withheld and why, whether the case is read whole, the estimate and
//  the balance), and the parts of a conflict the AI scaffolding adds (every side beyond the first two, a missing record's
//  expected item, and the AI's own explanation, innocent explanations and stated confidence — each labelled as the AI's).
//  Small views on purpose: no long modifier chains for the type checker.
//

import SwiftUI

/// Shown before the AI look runs: nothing is sent until "Run the look".
struct AIConflictLookSheet: View {
    let preview: AIConflictScanPreview
    let onRun: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Look for conflicts with AI").font(.title3.weight(.semibold))
            Text("The AI reads this case's documents and lists conflicts of any kind. Every quote it gives is checked word for word against its document before anything is kept; what does not check out is dropped. What it finds are proposals until you confirm them. The rules run as well, on this Mac.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            Text(preview.coverageLine).font(.callout).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("case.contradictions.ai.coverage")
            estimateLines
            Text(preview.permissionStored
                 ? "You already allowed the AI to read these documents for this case."
                 : "You will be asked once to allow the AI to read these documents for this case.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Run the look") { onRun() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("case.contradictions.ai.run")
            }
        }
        .padding(20)
        .frame(minWidth: 460, maxWidth: 560)
    }

    @ViewBuilder private var estimateLines: some View {
        if let estimate = preview.estimate {
            Label("Estimate before running: " + estimate, systemImage: "creditcard")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("case.contradictions.ai.estimate")
        }
        if let balance = preview.balance {
            Text(balance).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// The parts of a conflict the AI scaffolding adds, under its first two sides.
struct ConflictDetailExtras: View {
    let detail: CaseConflictDetail
    /// The sides beyond A and B, as the review item matches them (by document and words, not by position), so this
    /// screen, the decision, the citations and the case map show the same sides.
    let extraSides: [ConflictSide]
    let names: [UUID: String]
    let openAt: (UUID, String, UUID?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(extraSides.enumerated()), id: \.offset) { i, side in
                // Lettered as the case map letters them: A and B above, then C, D, …
                sideView(title: CaseMapProjector.sideLetter(i + 2), side: side)
            }
            if let expected = detail.expectedAbsent {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Expected but not found").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                    Text(expected).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let why = detail.aiReasoning {
                labelled("The AI's explanation (its own words; not checked)", why)
            }
            if !detail.innocentExplanations.isEmpty {
                labelled("Possible innocent explanations (the AI's suggestions)", detail.innocentExplanations.map { "• " + $0 }.joined(separator: "\n"))
            }
            if let confidence = detail.statedConfidence {
                Text("Confidence the AI stated: \(confidence) — its own word, not a measured figure.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func labelled(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            Text(text).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func sideView(title: String, side: ConflictSide) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            Text("\u{201C}\(side.quote)\u{201D}").font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Button {
                openAt(side.objectID, side.quote, side.sourceVersionID)
            } label: {
                Label(Self.openTitle(names[side.objectID], side.locator), systemImage: "doc.text.magnifyingglass").font(.caption)
            }
            .buttonStyle(.link)
            .accessibilityIdentifier("case.contradictions.openAt")
        }
    }

    nonisolated static func openTitle(_ name: String?, _ locator: String) -> String {
        let base = "Open at this place"
        guard let name else { return base + " (\(locator))" }
        return base + " — \(name), \(locator)"
    }
}
