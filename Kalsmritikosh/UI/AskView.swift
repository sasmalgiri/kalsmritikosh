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
import UniformTypeIdentifiers

#if canImport(AppKit)
import AppKit
#endif

public struct AskView: View {
    @Environment(AppState.self) private var appState
    @State private var question: String = ""
    /// Minimum-touch: the input is focused on appear and after each send /
    /// new conversation, so the flow is simply type → Enter → answer with no
    /// click into the field first.
    @FocusState private var inputFocused: Bool
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
    /// Conversation-history browser. Every Ask is persisted in SQLite
    /// (ConversationsRepository); this lets the user return to an old
    /// thread after starting a new one — they were never lost, just not
    /// previously reachable from the UI.
    @State private var showHistory = false
    @State private var pastConversations: [Conversation] = []
    /// Composer attachments — files picked via the paperclip. Each file is
    /// ingested into the ledger the moment it's picked (initialFast: custody +
    /// searchable text in seconds; deeper tiers arrive as background upgrades),
    /// so the very next question can already retrieve and cite it. Chips clear
    /// on send; the ingested knowledge is durable either way.
    @State private var attachments: [AskAttachment] = []

    public init() {}

    public var body: some View {
        // The middle is ALWAYS a ScrollView (empty-state hero centered via
        // containerRelativeFrame, or the transcript), exactly like every other
        // surface that lays out correctly (Settings, Answers, …): a ScrollView
        // absorbs whatever height the macOS 26 NavigationSplitView proposes,
        // where a raw expanding stack inflates and pushes chrome off-window.
        // The composer is pinned to the VIEWPORT bottom with safeAreaInset —
        // the platform pattern for message bars — so it cannot be pushed out.
        ScrollViewReader { proxy in
            ScrollView {
                if turns.isEmpty {
                    placeholder
                        .frame(maxWidth: .infinity)
                        .containerRelativeFrame(.vertical, alignment: .center)
                } else {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(turns) { turn in
                            turnBubble(turn)
                                .id(turn.id)
                                .transition(.popIn)
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .animation(Theme.springSoft, value: turns.count)
                }
            }
            .scrollContentBackground(.hidden)
            .background(AuroraBackdrop())
            .onChange(of: turns.count) { _, _ in
                if let last = turns.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                header
                Divider().opacity(0.4)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if !attachments.isEmpty {
                    attachmentChips
                }
                input
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await loadOrCreateConversation() }
        .onAppear {
            inputFocused = true
            // Seed from a Home persona "try asking" example, if any.
            if let seeded = appState.pendingAskQuestion, !seeded.isEmpty {
                question = seeded
                appState.pendingAskQuestion = nil
            }
        }
        .sheet(isPresented: $showHistory) {
            ConversationHistorySheet(
                conversations: pastConversations,
                currentID: conversationID,
                onOpen: { id in Task { await openConversation(id) } },
                onDelete: { id in Task { await deleteConversation(id) } },
                onClose: { showHistory = false }
            )
        }
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
                Text(LegalNotice.askEntry)
                    .font(.caption2)
                    .foregroundStyle(.orange.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
            InfoPopoverButton(
                title: "How answers work",
                message: "Ask in plain language. The engine retrieves evidence from your files, has domain experts analyse it, then composes an answer that cites its sources.",
                systemImage: "sparkles",
                bullets: [
                    "Every claim is grounded in your documents",
                    "Sources are listed under each answer",
                    "Tune depth vs. speed in Settings → Answering intelligence"
                ]
            )
            Spacer()
            Button {
                Task { await loadHistory(); showHistory = true }
            } label: {
                Label("History", systemImage: "clock.arrow.circlepath")
            }
            .buttonStyle(.pressable)
            .controlSize(.small)
            .help("Browse past conversations — every Ask is saved.")
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
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.accentColor.opacity(0.22), Color.accentColor.opacity(0.03)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .frame(width: 76, height: 76)
                Image(systemName: "sparkles")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(Theme.brandGradient())
                    .symbolEffect(.pulse)
            }
            VStack(spacing: 10) {
                Text("What do you want to know?")
                    .font(Theme.display(30, .bold))
                    .multilineTextAlignment(.center)
                Text("Kalsmritikosh reconstructs answers only from your ingested files — every claim carries its evidence.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
                Label("Private · on-device · evidence-gated", systemImage: "lock.shield")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color.primary.opacity(0.05), in: Capsule())
                    .padding(.top, 2)
            }
            // SHIP_DECISIONS / P8.3 — Ask opens BLANK: no suggestion grid, no
            // leading the witness. The user discovers their own questions; the
            // input box below is the only affordance.
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 24)
    }

    private var isBlank: Bool { question.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Modern assistant-style composer: a rounded, width-capped bar that grows with the text (1–6 lines),
    /// secondary glyph actions, and a filled circular send. Enter sends; Shift+Enter inserts a newline.
    private var input: some View {
        HStack(alignment: .bottom, spacing: 6) {
            TextField("Message Kalsmritikosh…", text: $question, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .lineLimit(1...6)
                .padding(.leading, 16)
                .padding(.vertical, 11)
                .focused($inputFocused)
                .onSubmit(submit)
            Button(action: attachFiles) {
                Image(systemName: "paperclip").font(.system(size: 15)).frame(width: 32, height: 32)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Attach files — they're ingested into your archive and become searchable, citable evidence for this and every future question.")
            .disabled(appState.ingest == nil)
            .guidance(GuidanceTip("Attach files",
                                  what: "Ingests files into your archive so they become searchable, citable evidence for this and every future question. Nothing is uploaded.",
                                  enabledWhen: "Available once the archive has finished starting up."),
                      enabled: appState.ingest != nil)
            Button {
                Task { await saveCurrentQuestion() }
            } label: {
                Image(systemName: "bookmark").font(.system(size: 15)).frame(width: 32, height: 32)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Save this question for later (visible in the Saved surface).")
            .disabled(appState.savedQueries == nil || isBlank)
            .guidance(GuidanceTip("Save question",
                                  what: "Bookmarks this question so you can return to it from the Saved surface.",
                                  enabledWhen: "Type a question first."),
                      enabled: appState.savedQueries != nil && !isBlank)
            Button {
                startInvestigation()
            } label: {
                if investigationInFlight {
                    ProgressView().controlSize(.small).frame(width: 32, height: 32)
                } else {
                    Image(systemName: "magnifyingglass.circle").font(.system(size: 15)).frame(width: 32, height: 32)
                }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Decompose this question into focused sub-questions and synthesize an answer.")
            .disabled(appState.investigationRunner == nil || investigationInFlight || isBlank)
            .guidance(GuidanceTip("Investigate",
                                  what: "Breaks a big question into focused sub-questions, answers each from your evidence, and synthesizes a cited result. Slower than Ask, but deeper.",
                                  enabledWhen: "Type a question, and wait for any running investigation to finish."),
                      enabled: appState.investigationRunner != nil && !investigationInFlight && !isBlank)
            Button(action: submit) {
                ZStack {
                    Circle().fill(isBlank ? AnyShapeStyle(Color.secondary.opacity(0.25)) : AnyShapeStyle(Theme.brandGradient()))
                        .frame(width: 32, height: 32)
                    if asking {
                        ProgressView().controlSize(.small).tint(.white)
                    } else {
                        Image(systemName: "arrow.up").font(.system(size: 14, weight: .bold))
                            .foregroundStyle(isBlank ? AnyShapeStyle(.secondary) : AnyShapeStyle(.white))
                    }
                }
            }
            .buttonStyle(.pressable)
            .keyboardShortcut(.return, modifiers: [])
            .disabled(asking || isBlank)
            .guidance(GuidanceTip("Send",
                                  what: "Answers your question from your on-device evidence, with citations, a confidence read, and any conflicts. Press Return to send.",
                                  enabledWhen: "Type a question first."),
                      enabled: !asking && !isBlank)
            .animation(Theme.springFast, value: asking)
            .padding(.trailing, 6)
            .padding(.bottom, 4)
        }
        .padding(.vertical, 1)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Theme.brand.opacity(0.18), lineWidth: 1))
        .shadow(color: .black.opacity(0.10), radius: 10, y: 3)
        .frame(maxWidth: 820)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)   // clean pinned-bar backing over scroll content
    }

    // MARK: - Attachments

    /// One row of removable chips above the composer, one per picked file,
    /// each showing its live ingest state. Removing a chip only clears the
    /// chip — content already ingested stays in the archive (durable ledger).
    private var attachmentChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { att in
                    HStack(spacing: 6) {
                        switch att.state {
                        case .ingesting:
                            ProgressView().controlSize(.mini)
                        case .ready:
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .imageScale(.small)
                        case .failed:
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .imageScale(.small)
                        }
                        Text(att.url.lastPathComponent)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 180)
                        Button {
                            attachments.removeAll { $0.id == att.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                                .imageScale(.small)
                        }
                        .buttonStyle(.borderless)
                        .help(att.state == .ready
                              ? "Dismiss chip — the file stays ingested in your archive."
                              : "Dismiss chip.")
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().stroke(Theme.brand.opacity(0.15), lineWidth: 1))
                    .help(att.state.helpText)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
    }

    /// Paperclip action: pick files, then ingest each one immediately with
    /// the fast intent (custody + searchable text now; structure/vectors as
    /// background upgrades) so the next question can already cite them. This
    /// is the evidence-gated equivalent of a chat "attach": nothing rides
    /// along with a single message — attached content joins the archive.
    private func attachFiles() {
        #if canImport(AppKit)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        // Only offer the formats the app can actually read end to end.
        panel.allowedContentTypes = SourceType.attachableContentTypes
        panel.prompt = "Attach"
        panel.message = "Attach a supported document, spreadsheet, email, image, audio or video — it's ingested into your private archive and becomes citable evidence."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            let attachment = AskAttachment(url: url, state: .ingesting)
            attachments.append(attachment)
            Task {
                do {
                    guard let ingest = appState.ingest else {
                        throw CocoaError(.featureUnsupported)
                    }
                    _ = try await ingest.ingest(fileAt: url, intent: .initialFast)
                    await MainActor.run {
                        if let idx = attachments.firstIndex(where: { $0.id == attachment.id }) {
                            attachments[idx].state = .ready
                        }
                    }
                } catch {
                    KalsmritikoshLog.ui.error("Ask attach ingest failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    await MainActor.run {
                        if let idx = attachments.firstIndex(where: { $0.id == attachment.id }) {
                            attachments[idx].state = .failed
                        }
                    }
                }
            }
        }
        #endif
    }

    // MARK: - Turn bubbles

    @ViewBuilder
    private func turnBubble(_ turn: ConversationTurn) -> some View {
        switch turn.role {
        case .user:
            HStack {
                Spacer(minLength: 60)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(turn.body)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 11)
                        .background(Theme.bubbleGradient, in: .rect(cornerRadius: 18, style: .continuous))
                        .shadow(color: Theme.brand.opacity(0.28), radius: 8, y: 3)
                        .frame(maxWidth: 520, alignment: .trailing)
                        .textSelection(.enabled)
                    Text(turn.createdAt.formatted(date: .omitted, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 4)
                }
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
                        if !turn.body.isEmpty {
                            Button {
                                #if canImport(AppKit)
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(turn.body, forType: .string)
                                #endif
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .imageScale(.small)
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("Copy this answer")
                        }
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
                .contextMenu {
                    if verifiedAnswers[turn.id] != nil {
                        Button {
                            exportAnswerReceipt(for: turn)
                        } label: {
                            Label("Export verifiable receipt…", systemImage: "checkmark.seal")
                        }
                    }
                }
                Spacer(minLength: 60)
            }
        }
    }

    /// Export a tamper-evident receipt for this answer: the answer text plus each
    /// supporting citation's verbatim snippet + source, chained so any later edit
    /// breaks the seal. Re-checkable offline in Verify Receipt.
    private func exportAnswerReceipt(for turn: ConversationTurn) {
        guard let answer = verifiedAnswers[turn.id] else { return }
        let idx = turns.firstIndex(where: { $0.id == turn.id })
        let question = (idx.flatMap { $0 > 0 ? turns[$0 - 1].body : nil }) ?? ""
        Task {
            let ids = Set(answer.citations.map(\.objectID))
            let names = (try? await appState.objects?.sourceFilenames(for: ids)) ?? [:]
            let hashes = (try? await appState.objects?.sourceHashes(for: ids)) ?? [:]
            var drafts: [ReceiptDraft] = [
                ReceiptDraft(
                    claim: question.isEmpty ? "Answer" : "Answer to: \(question)",
                    source: "Kalsmritikosh (on-device, evidence-gated)",
                    passage: answer.answerText ?? answer.body
                )
            ]
            for (i, c) in answer.citations.enumerated() {
                var fn = names[c.objectID] ?? "source \(c.objectID.uuidString.prefix(8))"
                if let h = hashes[c.objectID] { fn += " [sha256:\(h)]" }
                drafts.append(ReceiptDraft(claim: "Supporting evidence \(i + 1)", source: fn, passage: c.snippet))
            }
            let sealed = VerifiableReceipt.seal(
                title: question.isEmpty ? "Answer receipt" : "Answer: \(question)", drafts: drafts
            )
            let json = VerifiableReceipt.json(sealed)
            await MainActor.run { saveReceipt(json, suggestedName: question) }
        }
    }

    @MainActor
    private func saveReceipt(_ json: String, suggestedName: String) {
        #if canImport(AppKit)
        let panel = NSSavePanel()
        if let jsonType = UTType(filenameExtension: "json") { panel.allowedContentTypes = [jsonType] }
        let safe = String(suggestedName.prefix(40))
            .replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        panel.nameFieldStringValue = "receipt-\(safe.isEmpty ? "answer" : safe).json"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try json.write(to: url, atomically: true, encoding: .utf8) }
        catch { KalsmritikoshLog.ui.error("Answer receipt export failed: \(String(describing: error), privacy: .public)") }
        #endif
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

    // MARK: - Conversation history

    /// Load the list of past conversations for the history sheet.
    private func loadHistory() async {
        guard let repo = appState.conversations else { return }
        let convs = (try? await repo.recent(limit: 200)) ?? []
        await MainActor.run { self.pastConversations = convs }
    }

    /// Open a past conversation: hydrate its turns into the transcript.
    private func openConversation(_ id: UUID) async {
        guard let repo = appState.conversations else { return }
        let existing = (try? await repo.turns(for: id)) ?? []
        await MainActor.run {
            self.conversationID = id
            self.turns = existing
            // Verified quality strips only re-hydrate for the live session;
            // the answer text itself is persisted in each turn's body.
            self.verifiedAnswers = [:]
            self.showHistory = false
            self.inputFocused = true
        }
    }

    /// Delete a conversation (cascades to its turns). If it's the one on
    /// screen, start a fresh thread.
    private func deleteConversation(_ id: UUID) async {
        guard let repo = appState.conversations else { return }
        try? await repo.delete(id)
        await loadHistory()
        if id == conversationID { await startNewConversation() }
    }

    private func startNewConversation() async {
        guard let repo = appState.conversations else { return }
        do {
            let conv = try await repo.create()
            await MainActor.run {
                self.conversationID = conv.id
                self.turns = []
                self.inputFocused = true
            }
        } catch {
            KalsmritikoshLog.ui.error("Failed to start conversation: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Submit

    private func submit() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !asking else { return }
        asking = true
        question = ""
        // Chips are transient composer UI; the attached files are already
        // (being) ingested durably, so the question below can cite them.
        attachments.removeAll()

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

            // 3) The full brain answer is the ONLY LLM path (spec P1.3).
            //    The previous ungrounded streaming preview — which fed the raw
            //    user question straight to the model, unbudgeted and uncited —
            //    is removed. Ask consumes only the budgeted, evidence-grounded
            //    brain answer, so nothing ungrounded ever reaches the user.
            // OPS-003D — production screen scope (not DEBUG-only testUnrestricted).
            // Global Q&A: no workspace restriction, full sensitivity ceiling, privilege hidden.
            let answer = await appState.brain.answer(question: q,
                                                      access: SensitiveAccessContext(scope: .globalOwnerRetrieval()))

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

    private func renderAnswer(_ answer: VerifiedAnswer) -> String {
        var lines: [String] = []
        if answer.refused {
            lines.append("Kalsmritikosh can't ground an answer to that yet.")
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
// MARK: - Conversation history sheet

/// Browses past Ask conversations (persisted in SQLite). Tapping a row
/// reopens that thread; the trash button deletes it (turns cascade).
private struct ConversationHistorySheet: View {
    let conversations: [Conversation]
    let currentID: UUID?
    let onOpen: (UUID) -> Void
    let onDelete: (UUID) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(.tint)
                Text("Past conversations")
                    .font(.headline)
                Spacer()
                Button("Done", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
            Text("Every question you ask is saved on this Mac. Reopen a thread to keep going where you left off.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            if conversations.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("No past conversations yet.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(conversations) { conv in
                            row(conv)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(20)
        .frame(width: 480, height: 540)
    }

    private func row(_ conv: Conversation) -> some View {
        let isCurrent = conv.id == currentID
        return HStack(spacing: 10) {
            Image(systemName: isCurrent ? "bubble.left.fill" : "bubble.left")
                .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            VStack(alignment: .leading, spacing: 2) {
                Text((conv.title?.isEmpty == false ? conv.title! : "Untitled conversation"))
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(conv.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if isCurrent {
                Text("Open")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tint)
            }
            Button(role: .destructive) {
                onDelete(conv.id)
            } label: {
                Image(systemName: "trash").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Delete this conversation")
        }
        .padding(10)
        .background(
            isCurrent ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.03),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .contentShape(Rectangle())
        .onTapGesture { onOpen(conv.id) }
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

/// One composer attachment and its live ingest state. Value type held in
/// view state only — the durable record is the ingested KnowledgeObject.
private struct AskAttachment: Identifiable {
    enum State: Equatable {
        case ingesting
        case ready
        case failed

        var helpText: String {
            switch self {
            case .ingesting: return "Ingesting — becoming searchable…"
            case .ready:     return "Ingested — searchable and citable in your archive."
            case .failed:    return "Ingest failed — see Sources for details."
            }
        }
    }

    let id = UUID()
    let url: URL
    var state: State
}

#if DEBUG
#Preview("Ask — empty state") {
    AskView()
        .environment(AppState())
        .frame(width: 940, height: 660)
}
#endif


