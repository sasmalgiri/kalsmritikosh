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
import OSLog
#if canImport(AppKit)
import AppKit
#endif

public struct HistoryView: View {
    @Environment(AppState.self) private var appState

    @State private var question: String = ""
    @State private var streaming = false
    @State private var chapters: [NarrativeChapter] = []
    @State private var finalAnswer: VerifiedAnswer?
    @State private var error: String?
    /// Phase G.4 follow-on — when the user picks "Propose counterfactual…"
    /// from a causal-chip context menu we open a sheet to capture the
    /// hypothesis note. The optional carries the seed values; nil = no
    /// sheet visible.
    @State private var counterfactualDraft: CounterfactualDraft?
    /// Counterfactuals authored this session, indexed by chapter ID, so
    /// the strip can render a "what-if" annotation row next to the
    /// verified causal chain without re-querying the DB on every render.
    @State private var counterfactualsByChapter: [NarrativeChapter.ID: [HypotheticalCausalLink]] = [:]
    /// Phase J.10 — simulator output per hypothetical id. Updated
    /// inside the what-if strip's `.task` whenever the list of
    /// counterfactuals for the chapter changes; cached by id so
    /// SwiftUI doesn't re-simulate on every render.
    @State private var counterfactualImpacts: [HypotheticalCausalLink.ID: [CounterfactualImpact]] = [:]

    /// Seed payload for the counterfactual-author sheet.
    fileprivate struct CounterfactualDraft: Identifiable {
        let id = UUID()
        let chapterID: NarrativeChapter.ID
        let sourceEventID: Event.ID
        let targetEventID: Event.ID
        let sourceLabel: String       // "E2"
        let targetLabel: String       // "E5"
        var relation: CausalRelation
        var note: String
    }

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            input
        }
        .sheet(item: $counterfactualDraft) { draft in
            counterfactualSheet(draft: draft)
        }
        .background(AuroraBackdrop(intensity: 0.5))
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "book.closed")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("History")
                    .font(Theme.display(28, .bold))
                Text("Reconstructs narratives from your archive — each chapter is built from dated events and cited sources.")
                    .font(.caption).foregroundStyle(.secondary)
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
            Text("Ask Kalsmritikosh to tell you the story of a project, person, or topic. Each chapter is grounded in the source events that produced it.")
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
            HStack(spacing: 8) {
                if let intent = answer.intentKind {
                    Text(intent.replacingOccurrences(of: "reconstruct", with: "Reconstruct: "))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                }
                Spacer()
                sourceBadge(answer.source)
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

    /// HISTORY follow-on — small pill showing which path produced
    /// this answer. Helps the user distinguish a real structured
    /// reconstruction (high trust, dated events with per-sentence
    /// event citations) from a generic RAG synthesis (lower trust,
    /// chunks fed to an LLM).
    @ViewBuilder
    private func sourceBadge(_ source: AnswerSource) -> some View {
        let (icon, label, tint): (String, String, Color) = {
            switch source {
            case .historical:
                return ("book.closed.fill", "Historical", .green)
            case .ragFallback:
                return ("sparkles", "AI / RAG", .orange)
            case .experts:
                return ("brain.head.profile", "Experts", .blue)
            case .memoryCache:
                return ("clock.arrow.circlepath", "Cached", .gray)
            case .unknown:
                return ("questionmark.circle", "Unknown", .gray)
            }
        }()
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(label)
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(tint.opacity(0.18))
        .foregroundStyle(tint)
        .cornerRadius(6)
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
                proseWithCitations(chapter)
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
                if !chapter.causalLinks.isEmpty {
                    Label("\(chapter.causalLinks.count) causal", systemImage: "arrow.triangle.branch")
                        .foregroundStyle(.purple)
                }
                Spacer()
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            if !chapter.causalLinks.isEmpty {
                causalChainStrip(chapter)
            }
            if let cfs = counterfactualsByChapter[chapter.id], !cfs.isEmpty {
                counterfactualStrip(cfs, chapter: chapter)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .cardSurface(cornerRadius: 12)
    }

    /// HISTORY Phase G.7 — small strip rendering the chapter's top 3
    /// causal links as verb-bearing chips ("E2 caused E5", "E1
    /// enabled E3"). Top by confidence; full list available on
    /// expand-on-tap (not in v1 to avoid scope creep).
    ///
    /// Phase G.4 follow-on — each chip carries a context menu so the
    /// user can promote / demote / reject the link. User assertions
    /// land via `EventLinksRepository.supersede` with source=.user;
    /// the local `chapters` state mirrors the change so the strip
    /// refreshes without a full re-compose.
    @ViewBuilder
    private func causalChainStrip(_ chapter: NarrativeChapter) -> some View {
        let idxByID: [Event.ID: Int] = Dictionary(
            uniqueKeysWithValues: chapter.eventIDs.enumerated().map { ($1, $0 + 1) }
        )
        VStack(alignment: .leading, spacing: 4) {
            Text("Causal chain")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.purple)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(chapter.causalLinks.prefix(6), id: \.id) { link in
                        causalChip(for: link, in: chapter, idxByID: idxByID)
                    }
                }
            }
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private func causalChip(
        for link: CausalLink,
        in chapter: NarrativeChapter,
        idxByID: [Event.ID: Int]
    ) -> some View {
        let si = idxByID[link.sourceEventID] ?? 0
        let ti = idxByID[link.targetEventID] ?? 0
        let label = "E\(si) \(link.relation.renderVerb) E\(ti)"
        let isUser = link.source == .user
        let helpText = (link.reason ?? "heuristic match")
            + String(format: " — %.0f%%", link.confidence * 100)
            + (isUser ? " (your assertion)" : "")
            + "\nRight-click to change or reject."
        Text(label)
            .font(.caption2.monospaced())
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                isUser
                    ? Color.purple.opacity(0.35)
                    : Color.purple.opacity(link.relation.isCausal ? 0.20 : 0.10)
            )
            .foregroundStyle(.purple)
            .cornerRadius(5)
            .help(helpText)
            .contextMenu {
                ForEach(CausalRelation.allCases, id: \.self) { rel in
                    if rel != link.relation {
                        Button("Set to \(rel.rawValue)") {
                            assertLink(link, in: chapter, newRelation: rel)
                        }
                    }
                }
                Divider()
                Button("Propose counterfactual…") {
                    counterfactualDraft = CounterfactualDraft(
                        chapterID: chapter.id,
                        sourceEventID: link.sourceEventID,
                        targetEventID: link.targetEventID,
                        sourceLabel: "E\(si)",
                        targetLabel: "E\(ti)",
                        relation: .prevented,
                        note: ""
                    )
                }
                Divider()
                Button("Reject this link", role: .destructive) {
                    rejectLink(link, in: chapter)
                }
            }
    }

    // MARK: - User assertion plumbing

    /// Promote / demote the link via EventLinksRepository.supersede.
    /// The new row carries source=.user and confidence bumped to 0.95
    /// (user assertions are treated as ground-truth-level by the
    /// evidence verifier). UI state is refreshed in-place — no full
    /// re-compose so the chapter cards don't jump.
    private func assertLink(
        _ link: CausalLink,
        in chapter: NarrativeChapter,
        newRelation: CausalRelation
    ) {
        Task {
            guard let repo = appState.eventLinks else { return }
            let newLink = CausalLink(
                sourceEventID: link.sourceEventID,
                targetEventID: link.targetEventID,
                relation: newRelation,
                confidence: max(link.confidence, 0.95),
                evidenceObjectIDs: link.evidenceObjectIDs,
                allen: link.allen,
                source: .user,
                reason: "User assertion: \(newRelation.rawValue)"
            )
            do {
                try await repo.supersede(oldLinkID: link.id, with: newLink)
                await MainActor.run {
                    replaceLink(oldID: link.id, with: newLink, inChapterID: chapter.id)
                }
            } catch {
                KalsmritikoshLog.app.error("HistoryView: link supersede failed — \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func rejectLink(_ link: CausalLink, in chapter: NarrativeChapter) {
        Task {
            guard let repo = appState.eventLinks else { return }
            do {
                try await repo.delete(link.id)
                await MainActor.run {
                    removeLink(id: link.id, fromChapterID: chapter.id)
                }
            } catch {
                KalsmritikoshLog.app.error("HistoryView: link delete failed — \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func replaceLink(
        oldID: UUID,
        with newLink: CausalLink,
        inChapterID: NarrativeChapter.ID
    ) {
        guard let chapIdx = chapters.firstIndex(where: { $0.id == inChapterID }) else { return }
        let chap = chapters[chapIdx]
        var newLinks = chap.causalLinks
        if let li = newLinks.firstIndex(where: { $0.id == oldID }) {
            newLinks[li] = newLink
        }
        chapters[chapIdx] = NarrativeChapter(
            id: chap.id, title: chap.title, subtitle: chap.subtitle,
            timeframeStart: chap.timeframeStart, timeframeEnd: chap.timeframeEnd,
            eventIDs: chap.eventIDs, topicCommunityID: chap.topicCommunityID,
            prose: chap.prose, claimCitations: chap.claimCitations,
            contradictions: chap.contradictions, causalLinks: newLinks,
            confidence: chap.confidence
        )
    }

    private func removeLink(id: UUID, fromChapterID: NarrativeChapter.ID) {
        guard let chapIdx = chapters.firstIndex(where: { $0.id == fromChapterID }) else { return }
        let chap = chapters[chapIdx]
        let newLinks = chap.causalLinks.filter { $0.id != id }
        chapters[chapIdx] = NarrativeChapter(
            id: chap.id, title: chap.title, subtitle: chap.subtitle,
            timeframeStart: chap.timeframeStart, timeframeEnd: chap.timeframeEnd,
            eventIDs: chap.eventIDs, topicCommunityID: chap.topicCommunityID,
            prose: chap.prose, claimCitations: chap.claimCitations,
            contradictions: chap.contradictions, causalLinks: newLinks,
            confidence: chap.confidence
        )
    }

    /// "What-if" annotation row sitting BELOW the verified causal chain.
    /// Different visual treatment (dashed border, italic) so the user
    /// can never confuse a hypothesis with a real link.
    @ViewBuilder
    private func counterfactualStrip(
        _ cfs: [HypotheticalCausalLink],
        chapter: NarrativeChapter
    ) -> some View {
        let idxByID: [Event.ID: Int] = Dictionary(
            uniqueKeysWithValues: chapter.eventIDs.enumerated().map { ($1, $0 + 1) }
        )
        VStack(alignment: .leading, spacing: 4) {
            Text("What-if hypotheses")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.indigo)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(cfs.prefix(4), id: \.id) { cf in
                    let si = idxByID[cf.sourceEventID] ?? 0
                    let ti = idxByID[cf.targetEventID] ?? 0
                    HStack(alignment: .top, spacing: 6) {
                        Text("E\(si) \(cf.relation.renderVerb) E\(ti)")
                            .font(.caption2.monospaced())
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .strokeBorder(Color.indigo.opacity(0.4),
                                                  style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                            )
                            .foregroundStyle(.indigo)
                        Text(cf.hypothesisNote)
                            .font(.caption.italic())
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Spacer()
                        if let impacts = counterfactualImpacts[cf.id], !impacts.isEmpty {
                            Text("⤷ \(impacts.count) event\(impacts.count == 1 ? "" : "s") affected")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.indigo)
                                .help(impacts.prefix(3).map { $0.pathSummary }.joined(separator: "\n"))
                        }
                        Button {
                            removeCounterfactual(cf, in: chapter)
                        } label: {
                            Image(systemName: "xmark.circle")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Remove this counterfactual")
                    }
                }
            }
        }
        .padding(.top, 4)
        .task(id: cfs.map(\.id)) {
            await simulateCounterfactuals(cfs, chapter: chapter)
        }
    }

    /// Phase J.10 — run the CounterfactualSimulator over the
    /// chapter's verified causal links. The result lets us label
    /// each hypothetical with "⤷ N events affected" so the user can
    /// see, at a glance, the downstream blast radius of removing
    /// the prevented event from history.
    private func simulateCounterfactuals(
        _ cfs: [HypotheticalCausalLink],
        chapter: NarrativeChapter
    ) async {
        guard !cfs.isEmpty, let eventsRepo = appState.events else { return }
        // The simulator needs the events touched by `chapter` so it
        // can label paths; the chapter's event ids are sufficient.
        let chapterEvents = (try? await eventsRepo.findByIDs(chapter.eventIDs)) ?? []
        let simulator = CounterfactualSimulator()
        var newImpacts: [HypotheticalCausalLink.ID: [CounterfactualImpact]] = [:]
        for cf in cfs {
            let impacts = simulator.simulate(
                preventedEventID: cf.sourceEventID,
                links: chapter.causalLinks,
                events: chapterEvents
            )
            newImpacts[cf.id] = impacts
        }
        await MainActor.run {
            counterfactualImpacts = newImpacts
        }
    }

    private func removeCounterfactual(
        _ link: HypotheticalCausalLink,
        in chapter: NarrativeChapter
    ) {
        Task {
            guard let repo = appState.eventLinks else { return }
            do {
                try await repo.deleteHypothetical(link.id)
                await MainActor.run {
                    var byChapter = counterfactualsByChapter
                    byChapter[chapter.id] = (byChapter[chapter.id] ?? []).filter { $0.id != link.id }
                    counterfactualsByChapter = byChapter
                }
            } catch {
                KalsmritikoshLog.app.error("HistoryView: counterfactual delete failed — \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: - Counterfactual sheet

    @ViewBuilder
    private func counterfactualSheet(draft: CounterfactualDraft) -> some View {
        CounterfactualSheet(
            seed: draft,
            onCancel: { counterfactualDraft = nil },
            onSave: { working in saveCounterfactual(working) }
        )
    }

    private func saveCounterfactual(_ draft: CounterfactualDraft) {
        let note = draft.note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty else { return }
        let link = HypotheticalCausalLink(
            sourceEventID: draft.sourceEventID,
            targetEventID: draft.targetEventID,
            relation: draft.relation,
            confidence: 0.5,
            source: .user,
            reason: "User counterfactual",
            hypothesisNote: note
        )
        Task {
            guard let repo = appState.eventLinks else { return }
            do {
                try await repo.insertHypothetical(link)
                await MainActor.run {
                    var byChapter = counterfactualsByChapter
                    byChapter[draft.chapterID, default: []].insert(link, at: 0)
                    counterfactualsByChapter = byChapter
                    counterfactualDraft = nil
                }
            } catch {
                KalsmritikoshLog.app.error("HistoryView: counterfactual insert failed — \(String(describing: error), privacy: .public)")
            }
        }
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

    /// HISTORY follow-on — split the chapter prose into sentences and
    /// render each with its `[E?]` citation pills inline. Tapping a
    /// pill reveals the source KO in Finder. Falls back to the raw
    /// prose when no claim citations were recorded for the chapter.
    @ViewBuilder
    private func proseWithCitations(_ chapter: NarrativeChapter) -> some View {
        let sentences = splitSentences(chapter.prose)
        if chapter.claimCitations.isEmpty || sentences.isEmpty {
            Text(chapter.prose)
                .font(.body)
                .textSelection(.enabled)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(sentences.indices, id: \.self) { idx in
                    HStack(alignment: .top, spacing: 6) {
                        Text(sentences[idx])
                            .font(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let citation = chapter.claimCitations.first(where: { $0.sentenceIndex == idx }) {
                            citationPills(citation)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func citationPills(_ citation: NarrativeClaimCitation) -> some View {
        HStack(spacing: 4) {
            ForEach(citation.evidenceObjectIDs.prefix(3), id: \.self) { objID in
                Button {
                    revealSource(objectID: objID)
                } label: {
                    Text(objID.uuidString.prefix(4))
                        .font(.caption2.monospaced())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.18))
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)
                .help("Reveal source")
            }
            if citation.evidenceObjectIDs.count > 3 {
                Text("+\(citation.evidenceObjectIDs.count - 3)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 2)
    }

    private func revealSource(objectID: UUID) {
        Task { @MainActor in
            guard let repo = appState.objects,
                  let url = try? await repo.fetchSourceURL(id: objectID) else { return }
            #if canImport(AppKit)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            #endif
        }
    }

    /// Same splitter as `LLMNarrativeComposer.splitSentences` so the
    /// `sentenceIndex` lookup stays consistent.
    private func splitSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        for c in text {
            current.append(c)
            if c == "." || c == "!" || c == "?" {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { sentences.append(trimmed) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { sentences.append(tail) }
        return sentences
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
            TextField("Ask Kalsmritikosh to reconstruct a history…", text: $question)
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
            error = finalAnswer?.refusalReason ?? "Kalsmritikosh couldn't reconstruct that history."
        }
    }
}

extension NarrativeChapter: Identifiable {}

/// Dedicated sheet view — kept as its own struct so SwiftUI tracks
/// the @State edits to `relation` / `note` correctly. The parent
/// HistoryView only sees the seed + the final committed draft.
private struct CounterfactualSheet: View {
    let seed: HistoryView.CounterfactualDraft
    let onCancel: () -> Void
    let onSave: (HistoryView.CounterfactualDraft) -> Void

    @State private var relation: CausalRelation
    @State private var note: String

    init(
        seed: HistoryView.CounterfactualDraft,
        onCancel: @escaping () -> Void,
        onSave: @escaping (HistoryView.CounterfactualDraft) -> Void
    ) {
        self.seed = seed
        self.onCancel = onCancel
        self.onSave = onSave
        _relation = State(initialValue: seed.relation)
        _note = State(initialValue: seed.note)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "questionmark.bubble")
                    .foregroundStyle(.purple)
                Text("Propose a counterfactual")
                    .font(.headline)
                Spacer()
            }
            Text("This is stored as a hypothesis next to the verified history. It is never mixed into the timeline or used to answer questions as fact.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text(seed.sourceLabel)
                    .font(.callout.monospaced())
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Color.purple.opacity(0.15))
                    .cornerRadius(5)
                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                Text(seed.targetLabel)
                    .font(.callout.monospaced())
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Color.purple.opacity(0.15))
                    .cornerRadius(5)
                Picker("Relation", selection: $relation) {
                    ForEach(CausalRelation.allCases, id: \.self) { rel in
                        Text(rel.rawValue).tag(rel)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 180)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Hypothesis note")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextEditor(text: $note)
                    .font(.callout)
                    .frame(minHeight: 110)
                    .padding(6)
                    .background(Color.secondary.opacity(0.08))
                    .cornerRadius(6)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save counterfactual") {
                    var working = seed
                    working.relation = relation
                    working.note = note
                    onSave(working)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
