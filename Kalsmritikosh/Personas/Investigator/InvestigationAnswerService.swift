//
//  InvestigationAnswerService.swift
//  Kalsmritikosh
//
//  INV-01-C1 — the REAL Investigator "Ask" entry point. It is orchestration only: it does NOT answer,
//  retrieve, or synthesize. It loads the active InvestigationCase, resolves its authorized source scope,
//  wraps the SHARED retriever in a SourceScopedRetriever, and runs the SHARED MasterBrain. There is no
//  InvestigatorBrain and no InvestigatorRetriever — the persona contributes the active-case scope, the
//  one engine does the work.
//
//  Because MasterBrain holds its retriever and uses it as-is on every pass (initial, corrective,
//  Full-Evidence, reconstruction), injecting the SourceScopedRetriever governs ALL passes: no nested or
//  later retrieval can escape the case boundary. MasterBrain is constructed per request via an injected
//  factory so the engine stays untouched and the same shared collaborators are reused (building the actor
//  only stores references — it is cheap).
//
//  Fast and Full Evidence are answer-depth concerns of the shared engine; BOTH run through the identical
//  scoped retriever, so "Full Evidence" can deepen only WITHIN authorized sources — it is never a licence
//  to widen to the workspace.
//

import Foundation
import OSLog

/// The immutable scope context for one investigation, resolved from the case's authorized bindings.
/// (INV-01-C4 will extend this with a deterministic scope fingerprint for staleness/audit.)
public nonisolated struct InvestigationScopeContext: Sendable, Equatable {
    public let caseID: UUID
    public let workspaceID: UUID
    public let status: InvestigationCaseStatus
    public let scope: RetrievalSourceScope
    /// INV-01-C4 — the case revision + the ONE deterministic scope fingerprint this context resolves to.
    /// Every case-produced artifact (Ask / Methods / DataLab) is stamped with THIS fingerprint, so a later
    /// scope change is detectable as staleness the same way for all engines.
    public let caseRevision: Int
    public let fingerprint: CaseScopeFingerprint

    public nonisolated init(caseID: UUID, workspaceID: UUID, status: InvestigationCaseStatus, scope: RetrievalSourceScope,
                            caseRevision: Int, fingerprint: CaseScopeFingerprint) {
        self.caseID = caseID; self.workspaceID = workspaceID; self.status = status; self.scope = scope
        self.caseRevision = caseRevision; self.fingerprint = fingerprint
    }
}

/// A case-scoped answer: the shared engine's VerifiedAnswer plus the exact scope it was produced under.
public nonisolated struct InvestigationAnswer: Sendable {
    public let context: InvestigationScopeContext
    public let verified: VerifiedAnswer

    public nonisolated init(context: InvestigationScopeContext, verified: VerifiedAnswer) {
        self.context = context; self.verified = verified
    }
}

public nonisolated enum InvestigationAnswerError: Error, Sendable, Equatable {
    case caseNotFound(UUID)
}

public actor InvestigationAnswerService {
    private let cases: InvestigationCaseRepository
    private let resolver: CaseRetrievalScopeResolver
    private let baseRetriever: any Retriever
    private let evidence: EvidenceStore
    private let makeBrain: @Sendable (any Retriever) -> MasterBrain
    /// PHASE B-2 (v115) — records that the ask phase produced a verified
    /// answer for the case, so the conformance assessor can OBSERVE the
    /// phase. Only a question HASH is stored, never the question text.
    private let artifacts: CasePhaseArtifactRepository?
    /// F08 — scope-restricted keyword recall so a small case is not crowded out by the global corpus.
    private let scopedRecall: SourceScopedRetriever.ScopedRecall?
    /// B4 — each document in a set of source versions → its versions among them (the ledger's
    /// object↔version map). With it, a case answer's cloud sends are bound to the case's scope.
    private let objectVersions: (@Sendable (Set<UUID>) async throws -> [UUID: Set<UUID>])?
    /// Plan A — the whole-case AI reader (nil: the service answers exactly as before).
    private let caseReading: CaseWholeReading?
    /// Unified path REASON-17 (owner 2026-11-22) — not tested yet. Each answer is recorded with the
    /// case-scope fingerprint it was made under, so a later scope change shows it as stale.
    private let scopeLedger: InvestigationScopeLedger?

    public init(cases: InvestigationCaseRepository,
                resolver: CaseRetrievalScopeResolver,
                baseRetriever: any Retriever,
                evidence: EvidenceStore,
                makeBrain: @escaping @Sendable (any Retriever) -> MasterBrain,
                artifacts: CasePhaseArtifactRepository? = nil,
                scopedRecall: SourceScopedRetriever.ScopedRecall? = nil,
                objectVersions: (@Sendable (Set<UUID>) async throws -> [UUID: Set<UUID>])? = nil,
                caseReading: CaseWholeReading? = nil,
                scopeLedger: InvestigationScopeLedger? = nil) {
        self.scopeLedger = scopeLedger
        self.caseReading = caseReading
        self.scopedRecall = scopedRecall
        self.objectVersions = objectVersions
        self.cases = cases
        self.resolver = resolver
        self.baseRetriever = baseRetriever
        self.evidence = evidence
        self.makeBrain = makeBrain
        self.artifacts = artifacts
    }

    /// Resolve the active case into its scope context (reused by Methods/DataLab so no downstream surface
    /// re-derives case filtering). Throws if the case does not exist.
    public func scopeContext(caseID: UUID) async throws -> InvestigationScopeContext {
        guard let record = try await cases.fetch(caseID: caseID) else {
            throw InvestigationAnswerError.caseNotFound(caseID)
        }
        let scope = try await resolver.scope(for: record)
        let fingerprint = CaseScopeFingerprinter.fingerprint(
            caseID: caseID, caseRevision: record.caseHeader.revision, scope: scope)
        return InvestigationScopeContext(caseID: caseID, workspaceID: record.caseHeader.workspaceID,
                                         status: record.caseHeader.status, scope: scope,
                                         caseRevision: record.caseHeader.revision, fingerprint: fingerprint)
    }

    /// B4 — the binding a case answer's cloud sends carry: re-resolved at the send boundary, it
    /// names the documents the case may use NOW and their authorised versions (an erased case throws,
    /// so nothing is sent). Without the object↔version map the scope is empty: no document may go.
    public nonisolated func cloudScope(caseID: UUID) -> CloudScopeBinding {
        let objectVersions = self.objectVersions
        return CloudScopeBinding(scopeID: caseID) { [self] in
            guard let objectVersions else { return [:] }
            let context = try await self.scopeContext(caseID: caseID)
            return try await objectVersions(context.scope.authorizedSourceVersionIDs)
        }
    }

    /// The case-scoped retriever for a case — the SHARED retriever wrapped so every retrieval pass is
    /// bounded to the case's authorized sources. Exposed so Methods/DataLab can acquire evidence through
    /// the identical boundary.
    public func scopedRetriever(caseID: UUID) async throws -> any Retriever {
        let context = try await scopeContext(caseID: caseID)
        return SourceScopedRetriever(base: baseRetriever, evidence: evidence, scope: context.scope, scopedRecall: scopedRecall)
    }

    /// I-5 — answer over an explicit set of source versions (e.g. "everything dated on or before a day"),
    /// through the SAME fail-closed SourceScopedRetriever a case uses. An empty set authorizes nothing,
    /// so the honest result is "no evidence", never a silent widen to the whole archive.
    public func answer(scopedTo sourceVersionIDs: Set<UUID>, question: String,
                       access: SensitiveAccessContext) async -> VerifiedAnswer {
        let scoped = SourceScopedRetriever(base: baseRetriever, evidence: evidence,
                                           scope: .authorizing(sourceVersionIDs), scopedRecall: scopedRecall)
        return await makeBrain(scoped).answer(question: question, access: access)
    }

    /// AI split AI-49 — the search over an explicit set of source versions (as-of-date answers): the same fail-closed
    /// SourceScopedRetriever, returning the app's search results. The archive agent reads only what this finds.
    public func searchResults(scopedTo sourceVersionIDs: Set<UUID>, question: String, access: SensitiveAccessContext,
                              limit: Int) async -> VerifiedAnswer {
        let scoped = SourceScopedRetriever(base: baseRetriever, evidence: evidence,
                                           scope: .authorizing(sourceVersionIDs), scopedRecall: scopedRecall)
        return await makeBrain(scoped).searchResults(question: question, access: access, limit: limit)
    }

    /// Ask a question inside an active investigation. The answer is produced by the shared MasterBrain
    /// over the case-scoped retriever, so no unauthorized source can enter the evidence packet or the
    /// citations on any pass. Fast vs Full Evidence is the engine's depth concern; the scope is identical.
    public func answer(caseID: UUID, question: String, access: SensitiveAccessContext) async throws -> InvestigationAnswer {
        // LN1 — every send made while answering this question (the interpreter's and rewriter's
        // question-only sends included) is recorded with the case's marker, so erasing the case erases it.
        try await CaseSendScope.$caseID.withValue(caseID) {
            try await answerInCase(caseID: caseID, question: question, access: access)
        }
    }

    private func answerInCase(caseID: UUID, question: String, access: SensitiveAccessContext) async throws -> InvestigationAnswer {
        let context = try await scopeContext(caseID: caseID)
        let scoped = SourceScopedRetriever(base: baseRetriever, evidence: evidence, scope: context.scope, scopedRecall: scopedRecall)
        let brain = makeBrain(scoped)
        await brain.setCloudScope(cloudScope(caseID: caseID))
        await brain.setTableScope(Set(context.scope.authorizedSourceVersionIDs))   // Unified path AI-30 (owner 2026-11-22, round 2) — not tested yet.
        guard let caseReading else { return try await pipelineAnswer(brain: brain, caseID: caseID, question: question, access: access, context: context) }
        return try await planAAnswer(caseReading, brain: brain, caseID: caseID, question: question, access: access, context: context)
    }

    // MARK: - Plan A: the whole-case reader (owner, 2026-11-04)

    /// Which path answered a case question (the bench and the tests read it).
    public enum CaseReadPath: String, Sendable { case wholeCase, retrievalFallback, offlineSearch, notPermitted, nothingSendable }
    public private(set) var lastCasePath: CaseReadPath?
    /// GUI walk 2026-11-18: with AI set up, a reading that failed or was not used said "No AI is set up". Each says its own.
    static let readingFailed = "The AI reading did not come back"
    static let readingNotUsed = "No AI reading was used"

    /// With AI: permission once per case, then one call reading the whole case (or, too large, today's
    /// retrieval with an honest note). Without AI: search results, never rules-written prose.
    private func planAAnswer(_ plan: CaseWholeReading, brain: MasterBrain, caseID: UUID, question: String,
                             access: SensitiveAccessContext, context: InvestigationScopeContext) async throws -> InvestigationAnswer {
        func offline(_ path: CaseReadPath, note: String?, reason: String? = nil) async throws -> InvestigationAnswer {
            lastCasePath = path
            await brain.setCloudReaders(CloudReaders())   // nothing is sent on this path
            let a = try await pipelineAnswer(brain: brain, caseID: caseID, question: question, access: access, context: context)
            var shown = OfflineSearchResults.present(a.verified, question: question, reason: reason)
            if let note { shown = CaseReader.noting(shown, note) }
            return InvestigationAnswer(context: context, verified: shown)
        }
        guard let reader = await plan.reader() else {
            // AI split AI-47 (owner 2026-11-23): the passage composer path is the retired rule pipeline; without the case
            // reader the case shows search results (RetiredPaths.ruleAnswerComposers restores the old fallback).
            if RetiredPaths.isOn(.ruleAnswerComposers), await plan.otherReadersAvailable() {
                lastCasePath = .retrievalFallback
                return try await pipelineAnswer(brain: brain, caseID: caseID, question: question, access: access, context: context)
            }
            return try await offline(.offlineSearch, note: nil, reason: await plan.offlineReason())
        }
        let (firstPrepared, excluded) = await plan.prepare(caseID: caseID, versions: context.scope.authorizedSourceVersionIDs,
                                                           binding: cloudScope(caseID: caseID))
        guard var prepared = firstPrepared else {
            let why = excluded.isEmpty ? "" : " (\(excluded.count) withheld: " + Set(excluded.compactMap(\.reason)).sorted().joined(separator: ", ") + ")"
            return try await offline(.nothingSendable, note: "(No document of this case may be sent to the AI\(why), so these are search results.)",
                                     reason: "No document of this case may be sent to the AI")
        }
        guard await plan.permitted(caseID: caseID, prepared: prepared, question: question) else {
            return try await offline(.notPermitted, note: "(You have not allowed the AI to read this case's documents, so these are search results. Ask again to review the permission.)",
                                     reason: "The AI has not been allowed to read this case")
        }
        // Unified-path program (owner 2026-11-22), AI-17 — ONE path for every case size. Every Brain step
        // runs first (no reader on this brain, no model call): it is the cross-check, and the documents it
        // found are the relevance hint. Then the briefing + the documents in parts, the tools loop, the
        // merge, the second look and the verifier over every document.
        lastCasePath = .wholeCase
        // AI split AI-45 (owner 2026-11-23). The case picture is the briefing: the first AI question of a case waits for it
        // (the AI reads every document once and records what it finds, each record quote-checked), then the case is prepared
        // again so this and every later question send the same prefix. Later document changes are read in the background.
        if let state = await plan.pictureState(caseID: caseID), state.isEmpty {
            await plan.ensurePicture(reader, prepared, caseID: caseID)
            let (again, _) = await plan.prepare(caseID: caseID, versions: context.scope.authorizedSourceVersionIDs, binding: cloudScope(caseID: caseID))
            if let again, again.fingerprint == prepared.fingerprint { prepared = again }
        }
        await brain.setCloudReaders(CloudReaders())
        let steps = await brain.caseEvidenceSteps(question: question, access: access)
        if let refusal = steps.refusal {
            let final = await brain.commitReading(question: question, verified: refusal, originScopeID: caseID)
            await recordAsk(caseID: caseID, question: question, context: context, committedAnswerID: final.ledgerAnswerID)
            return InvestigationAnswer(context: context, verified: final)
        }
        let rules = steps.answer
        let number = Dictionary(prepared.documents.enumerated().map { ($1.objectID, $0 + 1) }, uniquingKeysWith: { a, _ in a })
        var related: [Int] = []
        for c in rules.citations { if let n = number[c.objectID], !related.contains(n) { related.append(n) } }
        // Speed PERF-22 (owner 2026-11-23) — not tested yet: the case id, so finished parts are kept for a retry.
        // AI split AI-44 (owner 2026-11-23): the agent loop — up to CaseAgent.maxRounds tool steps under the token ceiling;
        // AI-46: the second look is asked about the VERIFIED answer.
        let agent = plan.agentTools(caseID: caseID, question: question, documents: prepared.documents)
        // ALCOA ALC-02 — the question is a recorded AI run (who asked, provider, model asked for, input versions, coverage);
        // the records it stores link to it, and it is finished with the model(s) that answered and the usage.
        let runStamp = agent == nil ? nil : await plan.openRun(caseID: caseID, kind: .question, task: question, prepared: prepared,
                                                               parts: prepared.parts.count)
        agent?.setRun(runStamp)
        var runState = "done", runReason: String? = nil
        let calls = CaseCallUsages()
        let documents = prepared.documents
        var path = CaseReader.PathContext(tools: plan.tools(question, prepared.documents), concurrency: plan.concurrency(),
                                          toolRounds: agent == nil ? 2 : CaseAgent.maxRounds, caseID: caseID, agent: agent,
                                          tokenCeiling: agent == nil ? nil : CaseAgent.tokenCeiling(caseTokens: prepared.tokens, limit: prepared.limit))
        path.verifiedAnswer = { merged in
            guard case .answered(let a) = CaseReader.verdict(reply: merged, question: question, documents: documents, rules: nil,
                                                             arithmetic: agent?.arithmetic ?? []) else { return nil }
            return CaseReader.verifiedText(a)
        }
        // FAIR3 §8 item 3 (2026-11-25): the second look is told which statements the checker dropped and why.
        path.droppedClaims = { merged in CaseReader.droppedClaims(reply: merged, documents: documents) }
        // Accuracy F2 (FAIR3 root cause, 2026-11-25): a trace / where / net / kept question gets the named parties' money in,
        // out and kept in its task (the app's exact sums over the AI's picture records; the prefix is unchanged).
        let pictureRecords = await agent?.allRecords().filter { $0.origin == "picture" } ?? []
        path.taskNotes = CaseAIUnderstanding.questionMoneyLines(question, records: pictureRecords, number: number)
        // Accuracy F3: the second look gets the picture records about the question's / answer's names that no shown claim
        // cites, and must address each or say why not.
        path.checklist = { merged, answer in
            var shown: [String] = []
            if case .answered(let a) = CaseReader.verdict(reply: merged, question: question, documents: documents, rules: nil,
                                                          arithmetic: agent?.arithmetic ?? []) {
                shown = a.citations.map(\.snippet)
            }
            return CaseReader.subjectChecklist(question: question, answer: answer, shownQuotes: shown, records: pictureRecords, number: number)
        }
        var written: VerifiedAnswer
        do {
            let clearance = prepared.clearance, ttl = plan.questionTTL
            let (merged, look) = try await reader.readCase(parts: prepared.parts, question: question, related: related, context: path) { prefix, suffix in
                let reply = try await reader.send(CaseReadSend(caseID: caseID, prefix: prefix, suffix: suffix, ttl: ttl, purpose: "case.question", clearance: clearance))
                calls.add(reply.usage)
                return reply
            }
            switch CaseReader.verdict(reply: merged, question: question, documents: prepared.documents, rules: rules, arithmetic: agent?.arithmetic ?? [],
                                      look: look) {
            case .answered(let a):
                let parts = prepared.parts.count
                var shown = parts > 1 ? CaseReader.noting(a, "(Read by AI in \(parts) parts, every part with the case briefing; the claims were merged and each checked against its document.)") : a
                if let note = CaseReader.secondLookNote(reply: look, question: question, documents: prepared.documents) { shown = CaseReader.noting(shown, note) }
                // Fix (AI-50 hard eval, 2026-11-24): the second look said the verified answer may not address the question.
                if let warning = CaseReader.relevanceWarning(look: look) { shown = CaseReader.warning(shown, warning) }
                // AI split AI-49 — the conflicts the AI recorded (quote checked) about the documents this answer cites, and
                // those it recorded while answering, are the answer's conflicts (the Quality strip counts only these).
                if let agent {
                    let cited = Set(shown.citations.map(\.objectID))
                    let conflicts = await agent.allRecords().filter { r in
                        r.kind == .conflict && (agent.recorded.contains { $0.id == r.id }
                            || r.document.map(cited.contains) == true || r.documentB.map(cited.contains) == true)
                    }
                    shown = AIFindingLabels.withAIConflicts(shown, conflicts)
                }
                written = shown
            case .notStated(let a): written = a
            case .failed(let reason):
                written = VerifiedAnswerComposer.flagged(OfflineSearchResults.present(rules, question: question, reason: Self.readingFailed), reason: reason)
            case .notSent:
                written = OfflineSearchResults.present(rules, question: question, reason: Self.readingNotUsed)
            }
        } catch is CancellationError {
            KalsmritikoshLog.brain.info("case reading cancelled")
            written = OfflineSearchResults.present(rules, question: question, reason: Self.readingNotUsed)
            runState = "cancelled"; runReason = "cancelled"
        } catch {
            KalsmritikoshLog.brain.error("case reading failed: \(OnlineFailure.scrubbed(String(describing: error)), privacy: .public)")
            written = VerifiedAnswerComposer.flagged(OfflineSearchResults.present(rules, question: question, reason: Self.readingFailed), reason: OnlineFailure.note(for: error))
            runState = "failed"; runReason = OnlineFailure.scrubbed(String(describing: error))
        }
        if let agent {
            await plan.finishRun(runStamp, caseID: caseID, state: runState, reason: runReason, usage: calls.all,
                                 stored: agent.recorded.count, rejected: agent.rejected, transcript: agent.transcript, rejectedWrites: agent.rejectedWrites)
        }
        // ALCOA ALC-08 — a reply answered by another model than the one asked for (a server-side fallback) says so.
        if let note = CaseWholeReading.fallbackNote(requested: plan.modelRequested(), served: calls.served), !written.refused {
            written = CaseReader.noting(written, note)
        }
        // ALCOA ALC-09 — the answer says when the reading stopped before the AI was done: the step limit, the cost ceiling, or
        // a failed part of the case picture (K documents not read for it). The Quality strip shows the same line.
        var stops = agent?.stoppedEarly ?? []
        let unreadPicture = CasePictureFailures.shared.documents(caseID: caseID).intersection(prepared.documents.map(\.objectID))
        if !unreadPicture.isEmpty { stops.append(CaseAgent.pictureFailedNote(unreadPicture.count)) }
        if !stops.isEmpty, !written.refused { written = CaseReader.stoppedEarly(written, stops) }
        let final = await brain.commitReading(question: question, verified: written, originScopeID: caseID)
        await recordAsk(caseID: caseID, question: question, context: context, committedAnswerID: final.ledgerAnswerID)
        // Unified path AI-26 (owner 2026-11-22) — not tested yet. The independent second reading
        // runs after the AI-read case answer (AI is on on this path); a differing value marks it
        // "Needs review" in the Answer Journal.
        await brain.scheduleComposeTwin(question: question, committed: final)
        // Unified path AI-37 (owner 2026-11-22, round 2) — not tested yet. AI all the time: the briefing's AI
        // suggestions, once per case document set, after the answer (never delays it).
        let suggestionPlan = plan, readPrepared = prepared
        // Fix (AI-50 hard eval, 2026-11-24): the after-answer work is kept per case, so closing the ledger or erasing the
        // case cancels it (`cancelBackgroundWork`) instead of leaving it running against a closed ledger.
        if !closed {
            let token = UUID()
            let work = Task(priority: .utility) {
                await suggestionPlan.ensureAISuggestions(reader, readPrepared, caseID: caseID)
                // AI split AI-45 (owner 2026-11-23): new or changed documents are read into the case picture after the answer.
                if !Task.isCancelled { await suggestionPlan.ensurePicture(reader, readPrepared, caseID: caseID) }
                await self.backgroundFinished(caseID: caseID, token: token)
            }
            backgroundWork[caseID, default: [:]][token] = work
        }
        return InvestigationAnswer(context: context, verified: final)
    }

    /// Fix (AI-50 hard eval, 2026-11-24) — the after-answer background work (AI suggestions, case picture) per case.
    private var backgroundWork: [UUID: [UUID: Task<Void, Never>]] = [:]
    private var closed = false

    private func backgroundFinished(caseID: UUID, token: UUID) {
        backgroundWork[caseID]?[token] = nil
        if backgroundWork[caseID]?.isEmpty == true { backgroundWork[caseID] = nil }
    }

    /// How many after-answer jobs are running (nil = every case).
    public func backgroundWorkCount(caseID: UUID? = nil) -> Int {
        caseID.map { backgroundWork[$0]?.count ?? 0 } ?? backgroundWork.values.reduce(0) { $0 + $1.count }
    }

    /// Cancel the after-answer work of one case (nil = every case, and no new work starts: the ledger is closing).
    /// Returns at once; the jobs stop at their next suspension point (a cancelled send throws CancellationError).
    public func cancelBackgroundWork(caseID: UUID? = nil) {
        if caseID == nil { closed = true }
        let jobs = caseID.map { backgroundWork[$0].map { Array($0.values) } ?? [] } ?? backgroundWork.values.flatMap(\.values)
        for job in jobs { job.cancel() }
        if let caseID { backgroundWork[caseID] = nil } else { backgroundWork.removeAll() }
        // ALCOA ALC-09 — the remembered failed picture parts of an erased (or closed) case go with it.
        if let caseID { CasePictureFailures.shared.forget(caseID: caseID) }
        if !jobs.isEmpty { KalsmritikoshLog.brain.info("case background work cancelled: \(jobs.count, privacy: .public) job(s)") }
    }

    /// The ledger closed (`cancelBackgroundWork()` with no case): no question starts more after-answer work.
    public var isClosed: Bool { closed }

    /// Unified path REASON-17 (owner 2026-11-22, round 2) — not tested yet. One recorded artifact and whether the case's
    /// scope changed since it was recorded.
    public struct ScopeArtifactStatus: Sendable, Identifiable, Hashable {
        public let id: UUID
        public let kind: InvestigationScopeArtifactKind
        public let artifactID: String
        public let recordedAt: Date
        public let stale: Bool
    }

    /// Unified path REASON-17 (owner 2026-11-22, round 2) — not tested yet. Records the case's methods, data sets and work
    /// products not yet in the scope ledger, under the scope current NOW (an artifact is recorded the first time this runs
    /// after it was made: after each case question and when the scope list opens), then lists every recorded artifact with
    /// its stale state (its fingerprint differs from the case's current one).
    public func scopeArtifactStatus(caseID: UUID) async throws -> [ScopeArtifactStatus] {
        guard let scopeLedger else { return [] }
        let context = try await scopeContext(caseID: caseID)
        for item in try await scopeLedger.unrecordedArtifacts(caseID: caseID) {
            do {
                try await scopeLedger.record(caseID: caseID, kind: item.kind, artifactID: item.id, fingerprint: context.fingerprint,
                                             caseRevision: context.caseRevision, at: Date())
            } catch InvestigationScopeLedgerError.alreadyRecorded {
                continue
            } catch {
                KalsmritikoshLog.storage.error("scope artifact not recorded: \(String(describing: error), privacy: .public)")
            }
        }
        return try await scopeLedger.artifacts(caseID: caseID).map {
            ScopeArtifactStatus(id: $0.id, kind: $0.kind, artifactID: $0.artifactID, recordedAt: $0.createdAt,
                                stale: $0.fingerprint != context.fingerprint)
        }
    }

    private func recordAsk(caseID: UUID, question: String, context: InvestigationScopeContext, committedAnswerID: UUID?) async {
        // Unified path REASON-17 (owner 2026-11-22) — not tested yet.
        if let scopeLedger, let committedAnswerID {
            do {
                try await scopeLedger.record(caseID: caseID, kind: .ask, artifactID: committedAnswerID.uuidString,
                                             fingerprint: context.fingerprint, caseRevision: context.caseRevision, at: Date())
            } catch {
                KalsmritikoshLog.storage.error("ask scope-artifact record failed: \(String(describing: error), privacy: .public)")
            }
        }
        // Unified path REASON-17 (owner 2026-11-22, round 2) — not tested yet. Methods, data sets and work products made
        // since the last question are recorded too.
        if scopeLedger != nil {
            do { _ = try await scopeArtifactStatus(caseID: caseID) } catch {
                KalsmritikoshLog.storage.error("scope artifact sweep failed: \(String(describing: error), privacy: .public)")
            }
        }
        guard let artifacts, let committedAnswerID else { return }
        do {
            try await artifacts.record(caseID: caseID, caseRevision: context.caseRevision, scope: context.scope, phase: .ask,
                                       artifactID: committedAnswerID,
                                       detail: "question=\(CasePhaseArtifactRepository.questionDigest(question))", at: Date())
        } catch {
            KalsmritikoshLog.storage.error("ask phase-artifact record failed (phase stays unobserved): \(error)")
        }
    }

    /// The case-scoped pipeline answer (the path before plan A, unchanged).
    private func pipelineAnswer(brain: MasterBrain, caseID: UUID, question: String, access: SensitiveAccessContext,
                                context: InvestigationScopeContext) async throws -> InvestigationAnswer {
        // NINTH/TENTH AUDIT — consume the lifecycle STREAM and require the
        // COMMIT PROOF: `.verifiedFinal` carries the ledger answer ID only
        // when `lockVerifiedFinal` actually succeeded (a degraded no-ledger
        // final carries nil; a persistence failure yields a non-refused
        // `.incomplete`). Only an answer with its durable ledger identity
        // may count as machine-observed phase evidence — and that identity
        // IS the recorded artifact ID, validated by the repository against
        // a real verifiedFinal ledger event.
        var verified: VerifiedAnswer?
        var committedAnswerID: UUID?
        // TWELFTH AUDIT — the answer's ORIGIN (this case) is stamped on the
        // durable answer header at creation, so phase evidence later
        // requires artifact origin, not merely first binding.
        for await update in await brain.answerStream(question: question, access: access,
                                                     originScopeID: caseID) {
            switch update {
            case .verifiedFinal(let a): verified = a; committedAnswerID = a.ledgerAnswerID
            case .corrected(let a, _):  verified = a
            case .incomplete(let a):    verified = a; committedAnswerID = nil
            default: continue
            }
        }
        let answer = verified ?? VerifiedAnswer(
            body: "Investigations Made Easy produced no terminal answer.", citations: [], confidence: .zero,
            refused: true, refusalReason: "answerStream closed without a terminal event.")
        // PHASE B-2 — observable ask phase (question digest only in the
        // detail; the question text never persists). A failed write loses
        // only the OBSERVATION (the phase stays machine-unobserved —
        // fail-closed for conformance), but it is logged, never swallowed.
        if let artifacts, let committedAnswerID {
            do {
                // ELEVENTH AUDIT — the observation is bound to the exact case
                // state the answer was produced under (revision + INV-01-C4
                // scope fingerprint from THIS request's resolved context).
                try await artifacts.record(
                    caseID: caseID, caseRevision: context.caseRevision,
                    scope: context.scope,
                    phase: .ask,
                    artifactID: committedAnswerID,
                    detail: "question=\(CasePhaseArtifactRepository.questionDigest(question))",
                    at: Date())
            } catch {
                KalsmritikoshLog.storage.error("ask phase-artifact record failed (phase stays unobserved): \(error)")
            }
        }
        return InvestigationAnswer(context: context, verified: answer)
    }
}
