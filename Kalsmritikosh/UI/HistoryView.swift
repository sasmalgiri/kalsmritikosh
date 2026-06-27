//
//  HistoryView.swift
//  Kalsmritikosh
//
//  HISTORY Phase E.1+E.4 — the History tab. The user types a
//  reconstructive question ("what happened with Supplier ABC?",
//  "tell me the story of Project Delta") and the brain streams
//  chapters in via AnswerUpdate.chapterReady. Each chapter renders
//  as a card with the title, optional topic subtitle, timeframe,
//  per-sentence citation pills, and a contradiction badge when the
//  composer detected disagreement.
//
//  This is the surface the project's prime directive — "if the data
//  exists, the system should be able to recreate the history" —
//  lands on. The chat-shaped AskView still works for short factual
//  questions; HistoryView is the place reconstructive intents shine.
//

import SwiftUI

public struct HistoryView: View {
    @Environment(AppState.self) private var appState

    @State private var question: String = ""
    @State private var streaming = false
    @State private var chapters: [NarrativeChapter] = []
    @State private var finalAnswer: VerifiedAnswer?
    @State private var error: String?

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            input
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "book.closed")
                .foregroundStyle(.tint)
            Text("History")
                .font(.headline)
            Spacer()
            if streaming {
                ProgressView().controlSize(.small)
                Text("Composing…").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if chapters.isEmpty, finalAnswer == nil, error == nil {
            placeholder
        } else if let err = error {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(err).font(.callout).foregroundStyle(.secondary)
            }
            .padding(40)
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if let answer = finalAnswer {
                        narrativeSummary(answer: answer)
                    }
                    ForEach(chapters) { chapter in
                        chapterCard(chapter: chapter)
                    }
                    if let answer = finalAnswer, !answer.contradictions.isEmpty {
                        contradictionsBlock(answer.contradictions)
                    }
                }
                .padding(16)
            }
        }
    }

    private var placeholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "book.pages")
                .font(.system(size: 36))
                .foregroundStyle(.tint)
            Text("Reconstruct your history.")
                .font(.title3.weight(.medium))
            Text("Ask Atlas to tell you the story of a project, person, or topic. Each chapter is grounded in the source events that produced it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
            HStack(spacing: 10) {
                suggestion("Tell me the story of Project Delta")
                suggestion("What happened with Supplier ABC?")
                suggestion("Reconstruct my correspondence with Khurana")
            }
            .padding(.top, 8)
        }
        .padding(40)
        .frame(maxWidth: .infinity)
    }

    private func suggestion(_ text: String) -> some View {
        Button {
            question = text
            Task { await start() }
        } label: {
            Text(text)
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.accentColor.opacity(0.10))
                .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Cards

    private func narrativeSummary(answer: VerifiedAnswer) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let intent = answer.intentKind {
                Text(intent.replacingOccurrences(of: "reconstruct", with: "Reconstruct: "))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
            }
            Text(answer.body.components(separatedBy: "\n").first ?? "")
                .font(.title2.weight(.semibold))
            if let snippet = answer.body.components(separatedBy: "\n").dropFirst(2).first {
                Text(snippet)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 14) {
                Label("\(answer.citations.count) sources", systemImage: "doc.text.magnifyingglass")
                Label(String(format: "%.0f%% confidence", answer.confidence.value * 100),
                      systemImage: "checkmark.seal")
                if !answer.contradictions.isEmpty {
                    Label("\(answer.contradictions.count) contradiction(s)",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06))
        .cornerRadius(10)
    }

    private func chapterCard(chapter: NarrativeChapter) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(chapter.title)
                    .font(.title3.weight(.semibold))
                Spacer()
                Text(timeframeText(start: chapter.timeframeStart, end: chapter.timeframeEnd))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let subtitle = chapter.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.tint)
            }
            if !chapter.prose.isEmpty {
                Text(chapter.prose)
                    .font(.body)
                    .textSelection(.enabled)
            } else {
                Text("(\(chapter.eventIDs.count) events in this chapter — no prose available.)")
                    .font(.callout.italic())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Label("\(chapter.eventIDs.count) events", systemImage: "calendar")
                Label(String(format: "%.0f%% confidence", chapter.confidence * 100),
                      systemImage: "checkmark.seal")
                if !chapter.contradictions.isEmpty {
                    Label("\(chapter.contradictions.count)", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                Spacer()
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.04))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        )
        .cornerRadius(10)
    }

    private func contradictionsBlock(_ contradictions: [VerifiedAnswer.Contradiction]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Conflicting evidence detected")
                    .font(.headline)
            }
            ForEach(contradictions, id: \.description) { c in
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.description)
                        .font(.callout.weight(.medium))
                    Text("• \(c.claimA)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("• \(c.claimB)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08))
        .cornerRadius(10)
    }

    private func timeframeText(start: Date, end: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM yyyy"
        let s = formatter.string(from: start)
        let e = formatter.string(from: end)
        return (s == e) ? s : "\(s) – \(e)"
    }

    // MARK: - Input

    private var input: some View {
        HStack(spacing: 8) {
            TextField("Ask Atlas to reconstruct a history…", text: $question)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await start() } }
                .disabled(streaming)
            Button {
                Task { await start() }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .disabled(streaming || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Run

    private func start() async {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !streaming else { return }
        streaming = true
        chapters = []
        finalAnswer = nil
        error = nil
        defer { streaming = false }
        let stream = await appState.brain.answerStream(question: trimmed)
        for await update in stream {
            switch update {
            case .instant:
                continue
            case .synthesisToken:
                continue
            case .expertFindingsArrived:
                continue
            case .chapterReady(let chapter):
                await MainActor.run { chapters.append(chapter) }
            case .verified(let answer):
                await MainActor.run { finalAnswer = answer }
            }
        }
        if chapters.isEmpty && (finalAnswer?.refused ?? false) {
            error = finalAnswer?.refusalReason ?? "Atlas couldn't reconstruct that history."
        }
    }
}

extension NarrativeChapter: Identifiable {}
