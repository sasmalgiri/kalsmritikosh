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

    public init(cases: InvestigationCaseRepository,
                resolver: CaseRetrievalScopeResolver,
                baseRetriever: any Retriever,
                evidence: EvidenceStore,
                makeBrain: @escaping @Sendable (any Retriever) -> MasterBrain,
                artifacts: CasePhaseArtifactRepository? = nil,
                scopedRecall: SourceScopedRetriever.ScopedRecall? = nil,
                objectVersions: (@Sendable (Set<UUID>) async throws -> [UUID: Set<UUID>])? = nil,
                caseReading: CaseWholeReading? = nil) {
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

    /// Ask a question inside an active investigation. The answer is produced by the shared MasterBrain
    /// over the case-scoped retriever, so no unauthorized source can enter the evidence packet or the
    /// citations on any pass. Fast vs Full Evidence is the engine's depth concern; the scope is identical.
    public func answer(caseID: UUID, question: String, access: SensitiveAccessContext) async throws -> InvestigationAnswer {
        let context = try await scopeContext(caseID: caseID)
        let scoped = SourceScopedRetriever(base: baseRetriever, evidence: evidence, scope: context.scope, scopedRecall: scopedRecall)
        let brain = makeBrain(scoped)
        await brain.setCloudScope(cloudScope(caseID: caseID))
        guard let caseReading else { return try await pipelineAnswer(brain: brain, caseID: caseID, question: question, access: access, context: context) }
        return try await planAAnswer(caseReading, brain: brain, caseID: caseID, question: question, access: access, context: context)
    }

    // MARK: - Plan A: the whole-case reader (owner, 2026-11-04)

    /// Which path answered a case question (the bench and the tests read it).
    public enum CaseReadPath: String, Sendable { case wholeCase, retrievalFallback, offlineSearch, notPermitted, nothingSendable }
    public private(set) var lastCasePath: CaseReadPath?

    /// With AI: permission once per case, then one call reading the whole case (or, too large, today's
    /// retrieval with an honest note). Without AI: search results, never rules-written prose.
    private func planAAnswer(_ plan: CaseWholeReading, brain: MasterBrain, caseID: UUID, question: String,
                             access: SensitiveAccessContext, context: InvestigationScopeContext) async throws -> InvestigationAnswer {
        func offline(_ path: CaseReadPath, note: String?) async throws -> InvestigationAnswer {
            lastCasePath = path
            await brain.setCloudReaders(CloudReaders())   // nothing is sent on this path
            let a = try await pipelineAnswer(brain: brain, caseID: caseID, question: question, access: access, context: context)
            var shown = OfflineSearchResults.present(a.verified, question: question)
            if let note { shown = CaseReader.noting(shown, note) }
            return InvestigationAnswer(context: context, verified: shown)
        }
        guard let reader = await plan.reader() else {
            if await plan.otherReadersAvailable() {
                lastCasePath = .retrievalFallback
                return try await pipelineAnswer(brain: brain, caseID: caseID, question: question, access: access, context: context)
            }
            return try await offline(.offlineSearch, note: nil)
        }
        let (prepared, excluded) = await plan.prepare(caseID: caseID, versions: context.scope.authorizedSourceVersionIDs,
                                                      binding: cloudScope(caseID: caseID))
        guard let prepared else {
            let why = excluded.isEmpty ? "" : " (\(excluded.count) withheld: " + Set(excluded.compactMap(\.reason)).sorted().joined(separator: ", ") + ")"
            return try await offline(.nothingSendable, note: "(No document of this case may be sent to the AI\(why), so these are search results.)")
        }
        guard await plan.permitted(caseID: caseID, prepared: prepared, question: question) else {
            return try await offline(.notPermitted, note: "(You have not allowed the AI to read this case's documents, so these are search results. Ask again to review the permission.)")
        }
        guard prepared.fits else {
            // Too large to read whole: today's retrieval path, said so. The person already allowed this
            // case's documents, so passages FROM them carry that permission (no second per-send preview;
            // masking, re-clearance and the record still run); any other document is previewed as before.
            lastCasePath = .retrievalFallback
            let permitted = CaseReadPermittedSet(caseID: caseID, versions: prepared.clearance.versions)
            let a = try await CaseReadPermittedSet.$current.withValue(permitted) {
                try await pipelineAnswer(brain: brain, caseID: caseID, question: question, access: access, context: context)
            }
            let note = CaseReader.retrievalNote(documentsRead: await brain.lastReadingDocumentCount, caseDocuments: prepared.documents.count,
                                                caseTokens: prepared.tokens, limit: prepared.limit)
            return InvestigationAnswer(context: context, verified: CaseReader.noting(a.verified, note))
        }
        lastCasePath = .wholeCase
        // The evidence-only reading is only the cross-check: no reader on this brain, no model call.
        await brain.setCloudReaders(CloudReaders())
        let rules = await brain.evidenceOnlyReading(question: question, access: access)
        let written: VerifiedAnswer
        do {
            let reply = try await reader.send(CaseReadSend(caseID: caseID, prefix: prepared.prefix, suffix: CaseReader.questionSuffix(question),
                                                           ttl: plan.questionTTL, purpose: "case.question", clearance: prepared.clearance))
            switch CaseReader.verdict(reply: reply.text, question: question, documents: prepared.documents, rules: rules) {
            case .answered(let a), .notStated(let a): written = a
            case .failed(let reason):
                written = VerifiedAnswerComposer.flagged(OfflineSearchResults.present(rules, question: question), reason: reason)
            case .notSent:
                written = OfflineSearchResults.present(rules, question: question)
            }
        } catch is CancellationError {
            KalsmritikoshLog.brain.info("case reading cancelled")
            written = OfflineSearchResults.present(rules, question: question)
        } catch {
            KalsmritikoshLog.brain.error("case reading failed: \(OnlineFailure.scrubbed(String(describing: error)), privacy: .public)")
            written = VerifiedAnswerComposer.flagged(OfflineSearchResults.present(rules, question: question), reason: OnlineFailure.note(for: error))
        }
        let final = await brain.commitReading(question: question, verified: written, originScopeID: caseID)
        await recordAsk(caseID: caseID, question: question, context: context, committedAnswerID: final.ledgerAnswerID)
        return InvestigationAnswer(context: context, verified: final)
    }

    private func recordAsk(caseID: UUID, question: String, context: InvestigationScopeContext, committedAnswerID: UUID?) async {
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
