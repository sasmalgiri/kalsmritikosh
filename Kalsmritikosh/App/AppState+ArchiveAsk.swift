//
//  AppState+ArchiveAsk.swift
//  Kalsmritikosh
//
//  AI split AI-47 (owner 2026-11-23) — Ask outside a case. With AI set up: the archive agent loop (ArchiveAgent) over the
//  documents the search finds, every send an Online document send (clearance, masking, preview, outbound record). With no AI
//  set up: "Set up AI (your key or a plan)" and the search results as a list — never prose. The rule answer path runs only
//  when RetiredPaths.ruleAnswerComposers is switched back on (then Ask is exactly as before).
//

import Foundation
import os

extension AppState {
    /// The archive agent over this ledger (nil while the ledger is not open).
    func archiveAgent(access: SensitiveAccessContext,
                      search: (@Sendable (String, Int) async -> VerifiedAnswer)? = nil) -> ArchiveAgent? {
        guard let objects, let sensitiveScopes else { return nil }
        let brain = self.brain
        let searcher: @Sendable (String, Int) async -> VerifiedAnswer = search ?? { words, limit in
            await brain.searchResults(question: words, access: access, limit: limit)
        }
        let gate = CloudSourceGate(sensitiveScope: sensitiveScopes, objects: objects, localCeiling: access.scope.maximumSensitivity)
        return ArchiveAgent(
            search: { words in
                let found = await searcher(words, 20)
                return found.citations.map { ArchiveAgent.Hit(objectID: $0.objectID, snippet: $0.snippet) }
            },
            document: { id in
                do {
                    guard let stored = try await objects.fetchReaderText(id: id), !stored.content.isEmpty else { return nil }
                    let text = stored.clean ?? ReaderTextCleaner.clean(stored.content)
                    guard !text.isEmpty else { return nil }
                    let name: String?
                    do { name = try await objects.sourceFilenames(for: [id])[id] } catch {
                        KalsmritikoshLog.brain.error("archive reading: file name unreadable: \(String(describing: error), privacy: .public)")
                        name = nil
                    }
                    return CaseReader.Document(objectID: id, fileName: name, text: text)
                } catch {
                    KalsmritikoshLog.brain.error("archive reading: document unreadable: \(String(describing: error), privacy: .public)")
                    return nil
                }
            },
            clear: { ids in await gate.clear(ids, purpose: ArchiveQuestionPermission.purpose) },
            send: { [weak self] prompt, clearance in
                guard let provider = await self?.onlineProvider, await provider.acceptsDocuments() else {
                    throw VerifiedAnswerComposer.NotSent("Online document reading is not set up")
                }
                do {
                    return try await provider.generateFromDocuments(
                        prompt: prompt, options: GenerationOptions(maxTokens: OnlineRequestBuilder.caseReadReplyTokens, temperature: 0,
                                                                   sourceClearance: clearance))
                } catch OnlineCloudProvider.OnlineError.declined {
                    KalsmritikoshLog.brain.info("archive reading declined by the person")
                    throw VerifiedAnswerComposer.NotSent("declined")
                }
            })
    }

    /// Ask outside a case (AI-47). AI-49: every archive-wide question caller comes here (Ask, the Library's topic story,
    /// the History question box, Highlights, an investigation's steps, as-of-date answers, Shortcuts and AppleScript):
    /// the agent reads, with the person's permission asked ONCE for the question (`session` shares one permission across
    /// the several agent runs of one question, e.g. an investigation's steps). `search` narrows what the agent may find
    /// (as-of-date: only documents that existed on the day); nil = the whole archive the person may read.
    func answerArchive(question q: String, session: ArchiveQuestionSession? = nil,
                       search: (@Sendable (String, Int) async -> VerifiedAnswer)? = nil,
                       commit: Bool = true) async -> VerifiedAnswer {
        let access = SensitiveAccessContext(scope: .globalOwnerRetrieval())
        if RetiredPaths.isOn(.ruleAnswerComposers), search == nil {
            // The retired path, unchanged: the rule pipeline, shown as search results without an AI reader.
            let pipelineAnswer = await brain.answer(question: q, access: access)
            return await aiReadsDocuments()
                ? pipelineAnswer
                : OfflineSearchResults.present(pipelineAnswer, question: q, reason: AISetupCenter.shared.noteOffline()?.note)
        }
        let brain = self.brain
        let searcher: @Sendable (String, Int) async -> VerifiedAnswer = search ?? { words, limit in
            await brain.searchResults(question: words, access: access, limit: limit)
        }
        let found = await searcher(q, 12)
        func list(_ reason: String?) async -> VerifiedAnswer {
            let shown = OfflineSearchResults.present(found, question: q, reason: reason)
            return commit ? await brain.commitReading(question: q, verified: shown, originScopeID: nil) : shown
        }
        guard await aiReadsDocuments(), var agent = archiveAgent(access: access, search: searcher) else {
            return await list(AISetupCenter.shared.noteOffline()?.note ?? OfflineSearchResults.defaultReason)
        }
        // AI-49 — asked once for this question (after the app's first search, before anything is sent); the agent's
        // steps then run without another prompt. The permission ends when the question is done.
        let owned = session == nil
        let shared = session ?? ArchiveQuestionSession(question: q, maxDocuments: agent.maxDocuments)
        defer { if owned { shared.end() } }
        agent.permit = Self.questionPermit(session: shared, agent: agent)
        let outcome = await ArchiveQuestionPermission.$current.withValue(shared.permission) { await agent.answer(question: q) }
        switch outcome {
        case .read(let a, let documents, let steps):
            KalsmritikoshLog.brain.info("archive reading: \(documents, privacy: .public) document(s), \(steps, privacy: .public) step(s)")
            return commit ? await brain.commitReading(question: q, verified: a, originScopeID: nil) : a
        case .noDocuments(let withheld):
            let why = withheld > 0 ? "No matching document may be sent to the AI (\(withheld) privileged or restricted)" : "The search found no document for the AI to read"
            return await list(why)
        case .notAllowed:
            return await list(Self.notNowReason)
        case .failed(let reason, let notSent):
            let shown = await list(notSent ? InvestigationAnswerService.readingNotUsed : InvestigationAnswerService.readingFailed)
            return notSent ? shown : VerifiedAnswerComposer.flagged(shown, reason: reason)
        }
    }

    /// AI-49 — the investigation runner whose steps the archive agent reads (one permission per investigation).
    func makeInvestigationRunner(capabilities: CapabilityRegistry, investigations: InvestigationsRepository) -> InvestigationRunner {
        let step: InvestigationRunner.StepAnswerer = { [weak self] question, step, steps in
            guard let self else {
                return VerifiedAnswer(body: "The app is closing.", citations: [], confidence: .zero, refused: true, refusalReason: "The app is closing.")
            }
            return await self.answerInvestigationStep(question: question, step: step, steps: steps)
        }
        return InvestigationRunner(brain: brain, capabilities: capabilities, investigations: investigations,
                                   answerStep: step, finished: { question in AppState.endInvestigationSession(question: question) })
    }

    /// AI-49 — the open investigations' question sessions (one permission per investigation, shared by its steps).
    nonisolated static let investigationSessions = OSAllocatedUnfairLock<[String: ArchiveQuestionSession]>(initialState: [:])

    /// AI-49 — one investigation step, read by the archive agent under the investigation's one permission (cap: the
    /// agent's per-run documents times the steps).
    func answerInvestigationStep(question: String, step: String, steps: Int) async -> VerifiedAnswer {
        let perRun = ArchiveAgent.defaultMaxDocuments
        let session = Self.investigationSessions.withLock { all -> ArchiveQuestionSession in
            if let s = all[question] { return s }
            let s = ArchiveQuestionSession(question: question, maxDocuments: perRun * max(1, steps))
            all[question] = s
            return s
        }
        return await answerArchive(question: step, session: session, commit: false)
    }

    /// AI-49 — the investigation is done: its permission ends.
    nonisolated static func endInvestigationSession(question: String) {
        let s = investigationSessions.withLock { $0.removeValue(forKey: question) }
        s?.end()
    }

    /// AI-49 — shown with the search results when the person says "Not now" to a question.
    nonisolated static let notNowReason = "You chose not to let the AI read documents for this question. These are the search results"

    /// AI-49 — the once-per-question ask: the sheet (document cap, estimate) the first time the question's agent wants to
    /// read, then the grant the provider checks. Later runs of the same question reuse the decision.
    nonisolated static func questionPermit(session: ArchiveQuestionSession, agent: ArchiveAgent) -> @Sendable (Int, Int) async -> Bool {
        let perDoc = agent.perDocumentCharacters, rounds = agent.maxRounds, perRun = agent.maxDocuments
        return { found, withheld in
            await session.decide {
                let cap = session.permission.maxDocuments
                let request = ArchiveQuestionConsent.makeRequest(
                    question: session.question, maxDocuments: cap, perDocumentCharacters: perDoc, maxRounds: rounds,
                    runs: max(1, (cap + perRun - 1) / perRun), found: found, withheld: withheld)
                let identity = CaseReadPermissionStore.live.currentIdentity()
                guard await ArchiveQuestionConsent.shared.request(request) else { return false }
                // A change of AI destination, model or key while the sheet was open voids the answer.
                guard CaseReadPermissionStore.live.currentIdentity() == identity else {
                    KalsmritikoshLog.app.info("archive question permission void: the AI account changed while asking")
                    return false
                }
                ArchiveQuestionPermission.grant(session.permission, identity: identity)
                return true
            }
        }
    }
}

/// AI-49 — one question the person asked, which may run the archive agent more than once (an investigation's steps): the
/// permission is asked once, its answer reused by every run, and the document cap counted across all of them.
public final nonisolated class ArchiveQuestionSession: Sendable {
    public let question: String
    public let permission: ArchiveQuestionPermission
    private let decision = OSAllocatedUnfairLock<Task<Bool, Never>?>(initialState: nil)

    public init(question: String, maxDocuments: Int) {
        self.question = question
        self.permission = ArchiveQuestionPermission(maxDocuments: maxDocuments)
    }

    /// The person's decision: asked by the first caller, every other caller waits for the same answer.
    public func decide(_ ask: @escaping @Sendable () async -> Bool) async -> Bool {
        let task = decision.withLock { current -> Task<Bool, Never> in
            if let current { return current }
            let t = Task { await ask() }
            current = t
            return t
        }
        return await task.value
    }

    /// The question is done: its permission ends.
    public func end() { ArchiveQuestionPermission.end(permission) }
}
