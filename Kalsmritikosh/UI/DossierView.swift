//
//  DossierView.swift
//  Kalsmritikosh
//
//  HISTORY Phase E.3 — per-entity dossier. The user picks an entity
//  (person, organization, project) from the search field and Atlas
//  reconstructs its full history: a top-line MemoryObject summary
//  (if distilled) plus the chronological chapter list from the
//  composer. Differs from the generic History tab in that the
//  question is auto-shaped ("Reconstruct the history of …") and the
//  subject is locked, so the answer always scopes to one entity.
//

import SwiftUI

public struct DossierView: View {
    @Environment(AppState.self) private var appState

    @State private var subject: String = ""
    @State private var streaming = false
    @State private var chapters: [NarrativeChapter] = []
    @State private var finalAnswer: VerifiedAnswer?
    @State private var memorySummary: String?
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
        .background(AuroraBackdrop(intensity: 0.5))
    }

    private var header: some View {
        HStack {
            Image(systemName: "person.text.rectangle")
                .foregroundStyle(.tint)
            Text("Dossier")
                .font(Theme.display(28, .bold))
            if !subject.isEmpty {
                Text("— \(subject)")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if streaming {
                ProgressView().controlSize(.small)
                Text("Composing…").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if chapters.isEmpty, finalAnswer == nil, memorySummary == nil, error == nil {
            placeholder
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if let summary = memorySummary, !summary.isEmpty {
                        memoryCard(summary)
                    }
                    ForEach(chapters) { chapter in
                        chapterCard(chapter)
                    }
                    if let answer = finalAnswer {
                        footer(answer)
                    }
                    if let err = error {
                        Text(err)
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(16)
            }
        }
    }

    private var placeholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.text.rectangle")
                .font(.system(size: 36))
                .foregroundStyle(.tint)
            Text("Open a dossier.")
                .font(.title3.weight(.medium))
            Text("Enter a person, project, organization, or topic. Atlas reconstructs everything it knows about that subject.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
        }
        .padding(40)
        .frame(maxWidth: .infinity)
    }

    private func memoryCard(_ summary: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Distilled memory", systemImage: "brain")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tint)
            Text(summary)
                .font(.body)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.08))
        .cornerRadius(10)
    }

    private func chapterCard(_ chapter: NarrativeChapter) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(chapter.title)
                    .font(.title3.weight(.semibold))
                Spacer()
            }
            if let subtitle = chapter.subtitle, !subtitle.isEmpty {
                Text(subtitle).font(.caption).foregroundStyle(.tint)
            }
            if !chapter.prose.isEmpty {
                Text(chapter.prose).font(.body).textSelection(.enabled)
            } else {
                Text("(\(chapter.eventIDs.count) events recorded.)")
                    .font(.callout.italic())
                    .foregroundStyle(.secondary)
            }
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

    private func footer(_ answer: VerifiedAnswer) -> some View {
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
        .padding(.top, 4)
    }

    private var input: some View {
        HStack(spacing: 8) {
            TextField("Subject (person, project, organization)…", text: $subject)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await start() } }
                .disabled(streaming)
            Button {
                Task { await start() }
            } label: {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .disabled(streaming || subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func start() async {
        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !streaming else { return }
        streaming = true
        chapters = []
        finalAnswer = nil
        memorySummary = nil
        error = nil
        defer { streaming = false }
        let question = "Reconstruct the history of \(trimmed)."
        let stream = await appState.brain.answerStream(question: question)
        for await update in stream {
            switch update {
            case .instant(let body, _):
                await MainActor.run { memorySummary = body }
            case .synthesisToken, .expertFindingsArrived:
                continue
            case .chapterReady(let chapter):
                await MainActor.run { chapters.append(chapter) }
            case .verified(let answer):
                await MainActor.run { finalAnswer = answer }
            }
        }
        if chapters.isEmpty, memorySummary == nil, (finalAnswer?.refused ?? false) {
            error = finalAnswer?.refusalReason ?? "No history found for \(trimmed)."
        }
    }
}
