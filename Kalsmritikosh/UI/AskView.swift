//
//  AskView.swift
//  Kalsmritikosh
//
//  Conversational Ask. Every prompt + answer is persisted via
//  ConversationsRepository so the user can scroll back, follow up, and
//  return to old threads. New conversations start automatically on
//  first launch and via the "New" button.
//

import SwiftUI
import OSLog

public struct AskView: View {
    @Environment(AppState.self) private var appState
    @State private var question: String = ""
    @State private var asking = false
    @State private var conversationID: UUID?
    @State private var turns: [ConversationTurn] = []

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if turns.isEmpty {
                            placeholder.padding(40)
                        } else {
                            ForEach(turns) { turn in
                                turnBubble(turn).id(turn.id)
                            }
                        }
                    }
                    .padding()
                }
                .onChange(of: turns.count) { _, _ in
                    if let last = turns.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            Divider()
            input
        }
        .task { await loadOrCreateConversation() }
    }

    private var header: some View {
        HStack {
            Text("Ask Atlas")
                .font(.headline)
            Spacer()
            Button {
                Task { await startNewConversation() }
            } label: {
                Label("New", systemImage: "plus.bubble")
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var placeholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "brain")
                .font(.system(size: 36))
                .foregroundStyle(.tint)
            Text("Ask about projects, people, contracts, money, events.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
            suggestionGrid
        }
    }

    private var suggestionGrid: some View {
        let suggestions = [
            "What happened with Supplier ABC?",
            "Reconstruct Project Delta.",
            "What changed this week?",
            "What risks exist?"
        ]
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            ForEach(suggestions, id: \.self) { s in
                Button {
                    question = s
                    submit()
                } label: {
                    Text(s)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: 520)
        .padding(.top)
    }

    private var input: some View {
        HStack(spacing: 8) {
            TextField("e.g. What happened with Supplier ABC?", text: $question)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
            Button(action: submit) {
                if asking {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "paperplane.fill")
                }
            }
            .keyboardShortcut(.return, modifiers: [])
            .disabled(asking || question.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(12)
    }

    // MARK: - Turn bubbles

    @ViewBuilder
    private func turnBubble(_ turn: ConversationTurn) -> some View {
        switch turn.role {
        case .user:
            HStack {
                Spacer(minLength: 60)
                Text(turn.body)
                    .padding(10)
                    .background(.tint.opacity(0.15), in: .rect(cornerRadius: 10))
                    .frame(maxWidth: 520, alignment: .trailing)
            }
        case .assistant:
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "brain")
                            .foregroundStyle(.tint)
                            .imageScale(.small)
                        Text(turn.createdAt.formatted(date: .omitted, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(turn.body)
                        .textSelection(.enabled)
                        .padding(10)
                        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 10))
                }
                .frame(maxWidth: 620, alignment: .leading)
                Spacer(minLength: 60)
            }
        }
    }

    // MARK: - Lifecycle

    private func loadOrCreateConversation() async {
        guard let repo = appState.conversations else { return }
        // Pick the most recent conversation if it has any turns;
        // otherwise create a fresh one.
        if let recent = (try? await repo.recent(limit: 1))?.first {
            let existing = (try? await repo.turns(for: recent.id)) ?? []
            await MainActor.run {
                self.conversationID = recent.id
                self.turns = existing
            }
            if !existing.isEmpty { return }
        }
        await startNewConversation()
    }

    private func startNewConversation() async {
        guard let repo = appState.conversations else { return }
        do {
            let conv = try await repo.create()
            await MainActor.run {
                self.conversationID = conv.id
                self.turns = []
            }
        } catch {
            AtlasLog.ui.error("Failed to start conversation: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Submit

    private func submit() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !asking else { return }
        asking = true
        question = ""

        Task {
            guard let repo = appState.conversations, let convID = conversationID else {
                await MainActor.run { asking = false }
                return
            }

            // 1) Persist + append the user turn.
            let userOrdinal = (try? await repo.nextOrdinal(for: convID)) ?? 0
            let userTurn = ConversationTurn(
                conversationID: convID,
                ordinal: userOrdinal,
                role: .user,
                body: q
            )
            try? await repo.appendTurn(userTurn)
            await MainActor.run { self.turns.append(userTurn) }

            // 2) Placeholder assistant turn that we mutate in place as
            //    stream chunks arrive. SwiftUI re-renders the bubble
            //    each time `turns[index].body` grows.
            let assistantOrdinal = (try? await repo.nextOrdinal(for: convID)) ?? userOrdinal + 1
            let placeholder = ConversationTurn(
                conversationID: convID,
                ordinal: assistantOrdinal,
                role: .assistant,
                body: ""
            )
            await MainActor.run { self.turns.append(placeholder) }
            let placeholderID = placeholder.id

            // 3) Streaming preview + the full brain answer run in parallel.
            //    The stream gives the user typed feedback immediately; the
            //    brain's verified answer lands when ready and replaces
            //    the body with cited evidence.
            async let verified = appState.brain.answer(question: q)
            await streamPreview(question: q, into: placeholderID)
            let answer = await verified

            // 4) Replace the bubble body with the verified, cited answer.
            let assistantBody = renderAnswer(answer)
            let finalTurn = ConversationTurn(
                id: placeholderID,
                conversationID: convID,
                ordinal: assistantOrdinal,
                role: .assistant,
                body: assistantBody,
                createdAt: placeholder.createdAt
            )
            try? await repo.appendTurn(finalTurn)
            await MainActor.run {
                if let idx = self.turns.firstIndex(where: { $0.id == placeholderID }) {
                    self.turns[idx] = finalTurn
                }
                self.asking = false
            }

            if userOrdinal == 0 {
                let head = String(q.prefix(60))
                try? await repo.updateTitle(head, for: convID)
            }
        }
    }

    /// Pipes the resolved provider's stream into the placeholder bubble.
    /// If no provider fulfils the spec, leave the bubble empty for the
    /// brain's verified answer to fill.
    private func streamPreview(question: String, into turnID: UUID) async {
        guard let registry = appState.capabilities else { return }
        let spec = CapabilitySpec.reasoning(
            contextTokens: 2_000,
            purpose: "ask.streaming-preview"
        )
        guard let provider = try? await registry.resolve(spec),
              await provider.isAvailable() else { return }

        let stream = provider.generateStream(
            prompt: question,
            options: GenerationOptions(
                maxTokens: 400,
                temperature: 0.4,
                systemPrompt: "You are Atlas. Answer concisely from context. Verified, cited evidence will arrive once the brain finishes."
            )
        )
        do {
            for try await delta in stream {
                await MainActor.run {
                    guard let idx = self.turns.firstIndex(where: { $0.id == turnID }) else { return }
                    let existing = self.turns[idx]
                    let updated = ConversationTurn(
                        id: existing.id,
                        conversationID: existing.conversationID,
                        ordinal: existing.ordinal,
                        role: existing.role,
                        body: existing.body + delta,
                        createdAt: existing.createdAt
                    )
                    self.turns[idx] = updated
                }
            }
        } catch {
            AtlasLog.ui.debug("Stream preview ended early: \(String(describing: error), privacy: .public)")
        }
    }

    private func renderAnswer(_ answer: VerifiedAnswer) -> String {
        var lines: [String] = []
        if answer.refused {
            lines.append("Atlas can't ground an answer to that yet.")
            if let reason = answer.refusalReason { lines.append("Reason: \(reason)") }
        } else {
            lines.append(answer.body)
        }
        let pct = Int(answer.confidence.value * 100)
        lines.append("")
        lines.append("Confidence \(pct)% · \(answer.citations.count) citation(s)")
        if !answer.contradictions.isEmpty {
            lines.append("⚠ Contradictions:")
            for c in answer.contradictions {
                lines.append("  - \(c.description)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
