//
//  AnswerTrustPanel.swift
//  Kalsmritikosh
//
//  The answer trust layer under each answer's quality strip: source counts
//  (I-3), the contradicting-evidence check (I-4) and how the answer was found
//  (I-11). Each section appears only when its module is switched on.
//  2026-11-06 scope: no meter or "corroborated" verdict — explicit counts, a
//  dependence note and the review state; no self-test accuracy line under
//  answers (archiveSelfScore is a diagnostic); the date control filters by
//  document date and says so.
//

import SwiftUI

struct AnswerTrustPanel: View {
    let answer: VerifiedAnswer
    var onOpenSource: (UUID, String?) -> Void

    @Environment(AppState.self) private var appState
    @State private var corroboration: CorroborationReading?
    @State private var disconfirmation: DisconfirmationReport?
    @State private var checking = false
    @State private var path: [AnswerPathStep]?
    @State private var pathExpanded = false
    @State private var missing: [GapNode]?
    // I-5
    @State private var asOfDate = Date()
    @State private var asOf: AsOfResult?
    @State private var asOfRunning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let corroboration {
                corroborationRow(corroboration)
            }
            if checking {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Looking for evidence against this answer…")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } else if let disconfirmation {
                disconfirmationRow(disconfirmation)
            }
            if let missing, !missing.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Label("What may be missing for this answer", systemImage: "puzzlepiece.extension")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(missing) { g in
                        Text("• \(g.description) — \(g.reason)")
                            .font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if ProductModuleFlags.isEnabled(.timeTravel), !answer.refused, let question = answer.resolvedQuestion, !question.isEmpty {
                asOfSection(question)
            }
            if let path, !path.isEmpty {
                DisclosureGroup(isExpanded: $pathExpanded) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(path) { step in
                            Label(step.text, systemImage: step.symbol)
                                .font(.caption)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.top, 2)
                } label: {
                    Text("How this answer was found").font(.caption.weight(.medium))
                }
            }
        }
        .task(id: answer.ledgerAnswerID ?? UUID(uuidString: "00000000-0000-0000-0000-000000000000")) {
            path = appState.answerPath(for: answer)
            corroboration = await appState.corroboration(for: answer)
            missing = await appState.gaps(relevantTo: answer)
            if ProductModuleFlags.isEnabled(.devilsAdvocate) && !answer.refused {
                checking = true
                disconfirmation = await appState.disconfirmation(for: answer)
                checking = false
            }
        }
    }

    /// I-5 — the same question, using only documents dated on or before a chosen day (a document-date
    /// filter: it does not reconstruct what anyone knew on that day).
    @ViewBuilder
    private func asOfSection(_ question: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                DatePicker("Documents dated on or before", selection: $asOfDate, displayedComponents: .date)
                    .font(.caption).fixedSize()
                Button(asOfRunning ? "Asking…" : "Ask using only these documents") {
                    Task {
                        asOfRunning = true
                        asOf = await appState.answerAsOf(asOfDate, question: question, current: answer)
                        asOfRunning = false
                    }
                }
                .font(.caption).disabled(asOfRunning)
            }
            if let r = asOf {
                let text = r.answer.refused ? "No document dated on or before that day supports an answer." : (r.answer.answerText ?? r.answer.body)
                Text(text).font(.caption).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Used only the \(r.sourcesAvailable) document\(r.sourcesAvailable == 1 ? "" : "s") whose file date is on or before that day. A file date is not when anyone learned of it.")
                    .font(.caption2).foregroundStyle(.secondary)
                if !r.laterDocuments.isEmpty {
                    Text("Later-dated documents that change the answer: \(r.laterDocuments.joined(separator: ", "))")
                        .font(.caption2).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private func corroborationRow(_ r: CorroborationReading) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(r.headline, systemImage: "doc.on.doc")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if r.citedSources > 0 {
                Text(r.detail)
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(r.dependenceNote)
                    .font(.caption2).foregroundStyle(r.verdict == .singleSource ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(CorroborationReading.reviewState)
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func disconfirmationRow(_ r: DisconfirmationReport) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(r.headline, systemImage: r.conflicts.isEmpty ? "checkmark.shield" : "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(r.conflicts.isEmpty ? Color.secondary : Color.orange)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(r.conflicts) { c in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\u{201C}\(c.sentence)\u{201D}").font(.caption).textSelection(.enabled)
                    HStack(spacing: 8) {
                        Text(c.reason).font(.caption2).foregroundStyle(.secondary)
                        Button("Open source") { onOpenSource(c.objectID, c.sentence) }
                            .font(.caption2)
                            .buttonStyle(.borderless)
                    }
                }
                .padding(6)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.orange.opacity(0.4)))
            }
        }
    }
}
