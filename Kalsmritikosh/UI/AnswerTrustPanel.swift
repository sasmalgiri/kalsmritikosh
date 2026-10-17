//
//  AnswerTrustPanel.swift
//  Kalsmritikosh
//
//  The answer trust layer under each answer's quality strip: corroboration
//  (I-3), the contradicting-evidence check (I-4) and how the answer was found
//  (I-11). Each section appears only when its module is switched on.
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
            if !answer.refused, let note = ArchiveSelfScore.calibratedNote(confidence: answer.confidence.value) {
                Label(note, systemImage: "target")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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

    /// I-5 — the same question, using only evidence available on a chosen day.
    @ViewBuilder
    private func asOfSection(_ question: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                DatePicker("As of", selection: $asOfDate, displayedComponents: .date)
                    .font(.caption).fixedSize()
                Button(asOfRunning ? "Asking…" : "Ask as of this date") {
                    Task {
                        asOfRunning = true
                        asOf = await appState.answerAsOf(asOfDate, question: question, current: answer)
                        asOfRunning = false
                    }
                }
                .font(.caption).disabled(asOfRunning)
            }
            if let r = asOf {
                let text = r.answer.refused ? "On that day your archive had no evidence for this." : (r.answer.answerText ?? r.answer.body)
                Text(text).font(.caption).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Used only the \(r.sourcesAvailable) source\(r.sourcesAvailable == 1 ? "" : "s") dated on or before that day.")
                    .font(.caption2).foregroundStyle(.secondary)
                if !r.laterDocuments.isEmpty {
                    Text("Changed later by: \(r.laterDocuments.joined(separator: ", "))")
                        .font(.caption2).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private func corroborationRow(_ r: CorroborationReading) -> some View {
        let color: Color = {
            switch r.verdict {
            case .corroborated: return .green
            case .singleSource: return .orange
            case .none: return .secondary
            }
        }()
        VStack(alignment: .leading, spacing: 2) {
            Label(r.headline, systemImage: r.verdict == .corroborated ? "person.2.fill" : "person.fill.questionmark")
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
            if r.citedSources > 0 {
                Text(r.detail)
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
