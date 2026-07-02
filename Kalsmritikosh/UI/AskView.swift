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

#if canImport(AppKit)
import AppKit
#endif

public struct AskView: View {
    @Environment(AppState.self) private var appState
    @State private var question: String = ""
    @State private var asking = false
    @State private var conversationID: UUID?
    @State private var turns: [ConversationTurn] = []
    /// T11 — Verified answers indexed by their turn id so the bubble
    /// can render the quality strip directly (instead of folding it
    /// into a plain-text body line).
    @State private var verifiedAnswers: [UUID: VerifiedAnswer] = [:]
    /// Phase H — currently-open investigation sheet. Holds the
    /// in-flight Investigation as the runner streams updates. nil
    /// when no sheet is showing.
    @State private var activeInvestigation: Investigation?
    /// Phase H — true while the planner+runner are working. Drives the
    /// spinner on the Investigate button.
    @State private var investigationInFlight: Bool = false
    /// Phase H — terminal failure message from the runner. Surfaced
    /// inside the sheet so the user knows why no answer appeared.
    @State private var investigationError: String?

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if turns.isEmpty {
                            placeholder.padding(.horizontal, 40).padding(.top, 20)
                                .transition(.opacity)
                        } else {
                            ForEach(turns) { turn in
                                turnBubble(turn)
                                    .id(turn.id)
                                    .transition(.popIn)
                            }
                        }
                    }
                    .padding()
                    .animation(Theme.springSoft, value: turns.count)
                }
                .onChange(of: turns.count) { _, _ in
                    if let last = turns.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
                .scrollContentBackground(.hidden)
            }
            input
        }
        .background(AuroraBackdrop())
        .task { await loadOrCreateConversation() }
        .sheet(item: $activeInvestigation) { inv in
            InvestigationSheet(
                investigation: inv,
                inFlight: investigationInFlight,
                error: investigationError,
                onDismiss: { activeInvestigation = nil },
                onAcceptAsAnswer: { synthesis in
                    Task { await acceptInvestigationAsAnswer(synthesis) }
                }
            )
        }
    }

    /// Phase J.7 — bookmark the current question. Doesn't submit it;
    /// just persists for later via the Saved Queries tab.
    private func saveCurrentQuestion() async {
        guard let repo = appState.savedQueries else { return }
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        let category = QueryCategoryClassifier().classify(question: q).rawValue
        let saved = SavedQuery(question: q, category: category)
        try? await repo.insert(saved)
    }

    private func startInvestigation() {
        guard let runner = appState.investigationRunner else { return }
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        investigationError = nil
        investigationInFlight = true
        // Seed the sheet with a skeleton investigation so it opens
        // immediately; the runner overwrites it as updates arrive.
        activeInvestigation = Investigation(question: q)
        Task {
            for await update in runner.investigate(question: q) {
                await MainActor.run {
                    apply(update: update)
                }
            }
            await MainActor.run {
                investigationInFlight = false
            }
        }
    }

    private func apply(update: InvestigationUpdate) {
        switch update {
        case .planReady(let plan):
            activeInvestigation = plan
        case .stepStarted:
            // No-op — UI reads each step's `answer == nil` to render
            // an "in progress" row; nothing to flip explicitly.
            break
        case .stepCompleted(let stepID, let answer):
            guard var inv = activeInvestigation,
                  let idx = inv.steps.firstIndex(where: { $0.id == stepID }) else { return }
            inv.steps[idx].answer = answer
            activeInvestigation = inv
        case .synthesizing:
            // Sheet shows the synthesizing label when synthesis is nil
            // and all steps are done. No state change required.
            break
        case .finished(let finalInv):
            activeInvestigation = finalInv
            investigationInFlight = false
        case .failed(let reason):
            investigationError = reason
            investigationInFlight = false
        }
    }

    /// Insert the synthesis as an assistant turn so it lands in the
    /// regular chat history. Useful when the user wants to keep the
    /// investigation's conclusion as part of the conversation.
    private func acceptInvestigationAsAnswer(_ synthesis: String) async {
        guard let repo = appState.conversations,
              let convID = conversationID else {
            activeInvestigation = nil
            return
        }
        let qText = (activeInvestigation?.question ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSynthesis = synthesis.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !qText.isEmpty, !trimmedSynthesis.isEmpty else {
            activeInvestigation = nil
            return
        }
        let userOrdinal = (try? await repo.nextOrdinal(for: convID)) ?? 0
        let userTurn = ConversationTurn(
            conversationID: convID,
            ordinal: userOrdinal,
            role: .user,
            body: qText
        )
        try? await repo.appendTurn(userTurn)

        let assistantOrdinal = (try? await repo.nextOrdinal(for: convID)) ?? userOrdinal + 1
        let assistantTurn = ConversationTurn(
            conversationID: convID,
            ordinal: assistantOrdinal,
            role: .assistant,
            body: trimmedSynthesis
        )
        try? await repo.appendTurn(assistantTurn)

        await MainActor.run {
            turns.append(userTurn)
            turns.append(assistantTurn)
            activeInvestigation = nil
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("Ask")
                    .font(Theme.display(24, .bold))
                Text("Grounded in your archive — every answer cites its evidence")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await startNewConversation() }
            } label: {
                Label("New", systemImage: "plus.bubble")
            }
            .buttonStyle(.pressable)
            .controlSize(.small)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial)
    }

    private var placeholder: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.accentColor.opacity(0.28), Color.accentColor.opacity(0.04)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .frame(width: 92, height: 92)
                Circle()
                    .stroke(Color.accentColor.opacity(0.18), lineWidth: 1)
                    .frame(width: 92, height: 92)
                Image(systemName: "sparkles")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.accentColor, Color.accentColor.opacity(0.6)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .symbolEffect(.pulse)
            }
            VStack(spacing: 8) {
                Text("What do you want to know?")
                    .font(Theme.display(32, .bold))
                    .multilineTextAlignment(.center)
                Text("Kalsmritikosh reconstructs answers only from your ingested files — every claim carries its evidence.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }
            suggestionGrid
        }
        .padding(.top, 24)
    }

    private var suggestionGrid: some View {
        let suggestions: [(icon: String, tint: Color, text: String)] = [
            ("shippingbox.fill",         .orange, "What happened with Supplier ABC?"),
            ("map.fill",                 .blue,   "Reconstruct Project Delta."),
            ("clock.arrow.circlepath",   .green,  "What changed this week?"),
            ("exclamationmark.shield.fill", .red, "What risks exist?")
        ]
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            ForEach(suggestions, id: \.text) { s in
                SuggestionCard(icon: s.icon, tint: s.tint, text: s.text) {
                    question = s.text
                    submit()
                }
            }
        }
        .frame(maxWidth: 560)
        .padding(.top, 10)
    }

    private var input: some View {
        HStack(spacing: 10) {
            TextField("Ask about projects, people, contracts, money…", text: $question)
                .textFieldStyle(.plain)
                .padding(.leading, 16)
                .padding(.vertical, 10)
                .onSubmit(submit)
            Button {
                Task { await saveCurrentQuestion() }
            } label: {
                Image(systemName: "bookmark")
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.borderless)
            .help("Save this question for later (visible in the Saved surface).")
            .disabled(
                appState.savedQueries == nil
                || question.trimmingCharacters(in: .whitespaces).isEmpty
            )
            Button {
                startInvestigation()
            } label: {
                if investigationInFlight {
                    ProgressView().controlSize(.small).frame(width: 30, height: 30)
                } else {
                    Image(systemName: "magnifyingglass.circle")
                        .frame(width: 30, height: 30)
                }
            }
            .buttonStyle(.borderless)
            .help("Decompose this question into focused sub-questions and synthesize an answer.")
            .disabled(
                appState.investigationRunner == nil
                || investigationInFlight
                || question.trimmingCharacters(in: .whitespaces).isEmpty
            )
            Button(action: submit) {
                ZStack {
                    Circle().fill(Theme.brandGradient())
                        .frame(width: 34, height: 34)
                        .shadow(color: Color.accentColor.opacity(0.35), radius: 6, y: 2)
                    if asking {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    } else {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
            }
            .buttonStyle(.pressable)
            .keyboardShortcut(.return, modifiers: [])
            .disabled(asking || question.trimmingCharacters(in: .whitespaces).isEmpty)
            .opacity(question.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
            .animation(Theme.springFast, value: asking)
        }
        .padding(8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Theme.brand.opacity(0.18), lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    // MARK: - Turn bubbles

    @ViewBuilder
    private func turnBubble(_ turn: ConversationTurn) -> some View {
        switch turn.role {
        case .user:
            HStack {
                Spacer(minLength: 60)
                Text(turn.body)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 11)
                    .background(Theme.bubbleGradient, in: .rect(cornerRadius: 18, style: .continuous))
                    .shadow(color: Theme.brand.opacity(0.28), radius: 8, y: 3)
                    .frame(maxWidth: 520, alignment: .trailing)
                    .textSelection(.enabled)
            }
        case .assistant:
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .foregroundStyle(.tint)
                            .imageScale(.small)
                        Text(turn.createdAt.formatted(date: .omitted, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    // HISTORY follow-on — assistant bodies may carry
                    // `## Chapter heading` lines from the narrative
                    // composer's folded VerifiedAnswer.body. Render
                    // markdown so headings break visually. Falls back
                    // to plain text when AttributedString parsing
                    // fails (preserves prior behavior for non-markdown
                    // bodies). Line splits keep paragraph spacing.
                    Group {
                        if turn.body.isEmpty {
                            // Streaming/verifying — show the animated
                            // thinking indicator until the first token
                            // or the verified answer lands.
                            HStack(spacing: 8) {
                                ThinkingIndicator()
                                Text("Reconstructing from your archive…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .cardSurface(cornerRadius: 16)
                        } else {
                            assistantBody(turn.body)
                                .textSelection(.enabled)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 11)
                                .cardSurface(cornerRadius: 16)
                        }
                    }
                    if let verified = verifiedAnswers[turn.id] {
                        QualityStrip(
                            answer: verified,
                            onEvidenceTap: { objectID in
                                revealSource(objectID: objectID)
                            }
                        )
                            .padding(.horizontal, 10)
                            .padding(.bottom, 6)
                    }
                }
                .frame(maxWidth: 620, alignment: .leading)
                Spacer(minLength: 60)
            }
        }
    }

    /// HISTORY follow-on — render an assistant body as markdown when
    /// possible. The narrative composer's folded body carries `##
    /// chapter headings` and bolded contradiction lines; plain Text()
    /// would show the literal `##`. We parse with options that allow
    /// inline + block formatting; failure falls back to plain text.
    @ViewBuilder
    private func assistantBody(_ raw: String) -> some View {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        if let attributed = try? AttributedString(markdown: raw, options: options) {
            Text(attributed)
        } else {
            Text(raw)
        }
    }

    // MARK: - Walk-step clickthrough

    /// G3 Phase 5 UI — resolve a walk-step evidence KO id to its source
    /// file URL and reveal it in Finder. Non-fatal when the KO has no
    /// underlying file row (rare; should only happen mid-ingest).
    private func revealSource(objectID: UUID) {
        Task { @MainActor in
            guard let repo = appState.objects,
                  let url = try? await repo.fetchSourceURL(id: objectID) else {
                return
            }
            #if canImport(AppKit)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            #endif
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

            // Query-driven priority ingest. The moment the user hits
            // send, extract nouns from the question and front-load any
            // filename-matching files in watched roots. Fire-and-forget
            // so the brain's answer call runs in parallel — the user
            // sees something immediately, and the next time they ask the
            // boosted files are already in the canonical store.
            Task { await appState.boostIngestForQuestion(q) }

            // 3) Streaming preview + the full brain answer run in parallel.
            //    The stream gives the user typed feedback immediately; the
            //    brain's verified answer lands when ready and replaces
            //    the body with cited evidence. The stream runs in its own
            //    Task so the verified answer can land the moment it's
            //    ready — and we cancel the stream then so a late delta
            //    can't overwrite the verified body with `verified + delta`.
            async let verified = appState.brain.answer(question: q)
            let streamTask = Task { await streamPreview(question: q, into: placeholderID) }
            let answer = await verified
            streamTask.cancel()
            _ = await streamTask.value

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
                self.verifiedAnswers[placeholderID] = answer
                self.asking = false
            }

            // Ledger-AI v28 — persist the answer against a fresh corpus
            // snapshot (closed-corpus contract). Best-effort.
            await appState.recordAnswer(question: q, answer: answer)

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

// MARK: - Suggestion card

/// Polished starter-prompt card: colored icon chip, material surface,
/// hover lift + accent ring. Extracted so each card owns its hover
/// state (a ForEach can't hold per-row @State cleanly).
private struct SuggestionCard: View {
    let icon: String
    let tint: Color
    let text: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(
                        LinearGradient(
                            colors: [tint, tint.opacity(0.72)],
                            startPoint: .top, endPoint: .bottom
                        ),
                        in: RoundedRectangle(cornerRadius: 9)
                    )
                Text(text)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "arrow.up.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(tint)
                    .opacity(hovering ? 1 : 0)
            }
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(hovering ? tint.opacity(0.5) : Color.secondary.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: hovering ? tint.opacity(0.22) : .clear, radius: 9, y: 3)
            .scaleEffect(hovering ? 1.015 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { h in
            withAnimation(.easeOut(duration: 0.15)) { hovering = h }
        }
    }
}

// MARK: - Phase H Investigation sheet

/// Sheet that renders an in-flight (or finished) Investigation.
/// Shows: original question, per-step sub-question rows (each
/// rendering the verified answer body once it arrives), and a final
/// synthesis block when ready. Accepts an "Add to chat" button that
/// posts the synthesis back into the AskView conversation.
private struct InvestigationSheet: View {
    let investigation: Investigation
    let inFlight: Bool
    let error: String?
    let onDismiss: () -> Void
    let onAcceptAsAnswer: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "magnifyingglass.circle")
                    .foregroundStyle(.tint)
                Text("Investigation")
                    .font(.headline)
                Spacer()
                if inFlight {
                    ProgressView().controlSize(.small)
                }
                Button("Close", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
            }
            Text(investigation.question)
                .font(.title3.weight(.medium))
                .textSelection(.enabled)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .padding(8)
                    .background(Color.orange.opacity(0.08))
                    .cornerRadius(8)
            }
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if investigation.steps.isEmpty {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Planning sub-questions…")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(Array(investigation.steps.enumerated()), id: \.element.id) { idx, step in
                        stepRow(idx: idx + 1, step: step)
                    }
                    if let synthesis = investigation.synthesis, !synthesis.isEmpty {
                        synthesisBlock(synthesis)
                    } else if !investigation.steps.isEmpty
                        && investigation.steps.allSatisfy({ $0.answer != nil })
                        && inFlight {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Synthesizing final answer…")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 6)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(minHeight: 320, maxHeight: 520)
        }
        .padding(20)
        .frame(width: 640)
    }

    @ViewBuilder
    private func stepRow(idx: Int, step: InvestigationStep) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(idx).")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.tint)
                Text(step.question)
                    .font(.callout.weight(.medium))
                    .textSelection(.enabled)
                Spacer()
                if step.answer == nil {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
            if let answer = step.answer {
                Text(answer.answerText ?? answer.body)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.leading, 18)
                let pct = Int(answer.confidence.value * 100)
                Text("Confidence \(pct)% · \(answer.citations.count) citation(s)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 18)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func synthesisBlock(_ synthesis: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "sparkles")
                    .foregroundStyle(.tint)
                Text("Synthesis")
                    .font(.headline)
                Spacer()
                Button {
                    onAcceptAsAnswer(synthesis)
                } label: {
                    Label("Add to chat", systemImage: "plus.bubble")
                }
            }
            Text(synthesis)
                .font(.body)
                .textSelection(.enabled)
                .padding(10)
                .background(.tint.opacity(0.08), in: .rect(cornerRadius: 8))
        }
        .padding(.top, 6)
    }
}


