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

/// The immutable scope context for one investigation, resolved from the case's authorized bindings.
/// (INV-01-C4 will extend this with a deterministic scope fingerprint for staleness/audit.)
public nonisolated struct InvestigationScopeContext: Sendable, Equatable {
    public let caseID: UUID
    public let workspaceID: UUID
    public let status: InvestigationCaseStatus
    public let scope: RetrievalSourceScope

    public nonisolated init(caseID: UUID, workspaceID: UUID, status: InvestigationCaseStatus, scope: RetrievalSourceScope) {
        self.caseID = caseID; self.workspaceID = workspaceID; self.status = status; self.scope = scope
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

    public init(cases: InvestigationCaseRepository,
                resolver: CaseRetrievalScopeResolver,
                baseRetriever: any Retriever,
                evidence: EvidenceStore,
                makeBrain: @escaping @Sendable (any Retriever) -> MasterBrain) {
        self.cases = cases
        self.resolver = resolver
        self.baseRetriever = baseRetriever
        self.evidence = evidence
        self.makeBrain = makeBrain
    }

    /// Resolve the active case into its scope context (reused by Methods/DataLab so no downstream surface
    /// re-derives case filtering). Throws if the case does not exist.
    public func scopeContext(caseID: UUID) async throws -> InvestigationScopeContext {
        guard let record = try await cases.fetch(caseID: caseID) else {
            throw InvestigationAnswerError.caseNotFound(caseID)
        }
        let scope = try await resolver.scope(for: record)
        return InvestigationScopeContext(caseID: caseID, workspaceID: record.caseHeader.workspaceID,
                                         status: record.caseHeader.status, scope: scope)
    }

    /// The case-scoped retriever for a case — the SHARED retriever wrapped so every retrieval pass is
    /// bounded to the case's authorized sources. Exposed so Methods/DataLab can acquire evidence through
    /// the identical boundary.
    public func scopedRetriever(caseID: UUID) async throws -> any Retriever {
        let context = try await scopeContext(caseID: caseID)
        return SourceScopedRetriever(base: baseRetriever, evidence: evidence, scope: context.scope)
    }

    /// Ask a question inside an active investigation. The answer is produced by the shared MasterBrain
    /// over the case-scoped retriever, so no unauthorized source can enter the evidence packet or the
    /// citations on any pass. Fast vs Full Evidence is the engine's depth concern; the scope is identical.
    public func answer(caseID: UUID, question: String, access: SensitiveAccessContext) async throws -> InvestigationAnswer {
        let context = try await scopeContext(caseID: caseID)
        let scoped = SourceScopedRetriever(base: baseRetriever, evidence: evidence, scope: context.scope)
        let brain = makeBrain(scoped)
        let verified = await brain.answer(question: question, access: access)
        return InvestigationAnswer(context: context, verified: verified)
    }
}
