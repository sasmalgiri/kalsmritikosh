//
//  AnswersView.swift
//  Kalsmritikosh
//
//  A8 / A5.9 — the Answer Journal. Every answer the app ships is persisted as a
//  first-class object (answer + claims + claim→evidence) via AnswerLedgerRepository.
//  This surface lists those stored answers so a user can see, and later audit,
//  what was asked, how well-supported the reply was, and when. Reads straight
//  from the ledger — no model is consulted.
//

import SwiftUI

public struct AnswersView: View {
    @Environment(AppState.self) private var appState

    @State private var answers: [StoredAnswer] = []
    @State private var loading = false

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if answers.isEmpty && !loading {
                    emptyState
                } else {
                    ForEach(answers) { answer in
                        AnswerCard(answer: answer)
                    }
                }
            }
            .padding(24)
        }
        .background(AuroraBackdrop(intensity: 0.5))
        .task { await reload() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Answer Journal")
                .font(.largeTitle.weight(.semibold))
            Text("Every answer is recorded with its evidence, so any reply can be traced back to the files, events and blocks that supported it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "text.bubble")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
            Text("No answers recorded yet")
                .font(.headline)
            Text("Ask a question in the Ask tab — grounded answers land here for later audit.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    private func reload() async {
        loading = true
        answers = (try? await appState.answerLedger?.recent(limit: 200)) ?? []
        loading = false
    }
}

/// One stored answer, showing its question, support state, confidence and date,
/// with the answer body available on expansion.
private struct AnswerCard: View {
    let answer: StoredAnswer
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Text(answer.question)
                    .font(.callout.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                stateBadge
            }
            HStack(spacing: 12) {
                Label(confidenceText, systemImage: "gauge.medium")
                Label(dateText, systemImage: "clock")
                if let source = answer.source, !source.isEmpty {
                    Label(source, systemImage: "cpu")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            if expanded {
                Text(answer.body)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(expanded ? "Hide answer" : "Show answer") {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            }
            .font(.caption.weight(.medium))
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var stateBadge: some View {
        Text(stateLabel)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(stateColor.opacity(0.18), in: Capsule())
            .foregroundStyle(stateColor)
    }

    private var stateLabel: String {
        switch answer.answerState {
        case .supported:             return "Supported"
        case .partiallySupported:    return "Partial"
        case .contradicted:          return "Contradicted"
        case .notFound:              return "Not found"
        case .insufficientlyIndexed: return "Low coverage"
        case .unknown:               return "Unknown"
        }
    }

    private var stateColor: Color {
        switch answer.answerState {
        case .supported:             return .green
        case .partiallySupported:    return .yellow
        case .contradicted:          return .red
        case .notFound:              return .orange
        case .insufficientlyIndexed: return .orange
        case .unknown:               return .secondary
        }
    }

    private var confidenceText: String {
        "\(Int((answer.confidence * 100).rounded()))% confidence"
    }

    private var dateText: String {
        answer.createdAt.formatted(date: .abbreviated, time: .shortened)
    }
}

#Preview("Answer cards") {
    ScrollView {
        VStack(spacing: 16) {
            AnswerCard(answer: StoredAnswer(
                question: "When did the Project Delta contract get signed, and by whom?",
                answerState: .supported,
                body: "The Project Delta contract was signed on 14 March 2025 by Alice Martin (Acme Corp) and Bob Chen (Delta Ltd), per the executed signature page in contract-final.pdf.",
                confidence: 0.86, source: "reasoning"
            ))
            AnswerCard(answer: StoredAnswer(
                question: "Was the June invoice paid?",
                answerState: .partiallySupported,
                body: "An invoice for USD 12,000 was issued on 2 June; no matching payment confirmation was found in the archive.",
                confidence: 0.42, source: "financial"
            ))
            AnswerCard(answer: StoredAnswer(
                question: "Who approved the budget increase?",
                answerState: .notFound,
                body: "No document in the archive records an approval for the budget increase.",
                confidence: 0.1, source: nil
            ))
        }
        .padding()
    }
    .frame(width: 560, height: 520)
}
