//
//  InvestigationMethodService.swift
//  Kalsmritikosh
//
//  INV-01-C2 — the real Investigator "run a professional method" entry point. Orchestration only: it does
//  NOT own method lifecycle, evidence semantics, or a second registry. It composes the SHARED
//  ProfessionalMethodRegistry + MethodRunRepository + evidence gate, and enforces ONE extra dimension —
//  the active InvestigationCase's authorized source scope — BEFORE any MethodRun state is created.
//
//  Hard boundary (§2): every evidence reference supplied to a case-scoped MethodRun must resolve to a
//  source version authorized for the active case. Unauthorized OR unresolvable evidence is REJECTED, and
//  the rejection happens BEFORE createRun so nothing partial is ever committed (§14, atomic). Case
//  authorization reuses the ONE CaseRetrievalScopeResolver (B2/C1) — Ask, Methods and DataLab therefore
//  inherit identical case→source-version semantics.
//
//  Two independent pre-checks run before creation: (1) case authorization (this layer) and (2) the shared
//  gate's verdict (existence + workspace + SensitiveScope). Both must pass; neither weakens the other
//  (§16). Case authorization resolves the source-anchored reference kinds through the shared EvidenceStore
//  — `.sourceVersion` (the exact version id) and `.evidenceBlock` (via resolveEvidenceBlocks). Any other
//  reference kind is UNRESOLVABLE within an active case and is rejected fail-closed; extending resolution
//  to further kinds can only tighten, never loosen, this boundary.
//

import Foundation

/// A request to attach one canonical evidence reference to a case-scoped MethodRun (no run id yet).
public nonisolated struct InvestigationMethodEvidenceSpec: Sendable, Equatable {
    public let targetKind: WorkflowProvenanceReferenceKind
    public let targetID: UUID
    public let role: MethodEvidenceLinkRole
    public let inputRole: MethodInputRole?
    public let ordinal: Int

    public nonisolated init(targetKind: WorkflowProvenanceReferenceKind, targetID: UUID,
                            role: MethodEvidenceLinkRole = .supporting, inputRole: MethodInputRole? = nil, ordinal: Int) {
        self.targetKind = targetKind; self.targetID = targetID
        self.role = role; self.inputRole = inputRole; self.ordinal = ordinal
    }
}

/// The case-authorization decision for one evidence reference.
public nonisolated enum InvestigationEvidenceAuthorization: Sendable, Equatable {
    case authorized(sourceVersionID: UUID)
    case unauthorized            // resolves to a source version OUTSIDE the case scope
    case unresolvable            // cannot be resolved to a source version → rejected in an active case
}

/// A case-scoped MethodRun: the shared run plus the scope it was authorized under (durable case↔run
/// association + scope fingerprint arrive in INV-01-C4; this is the in-memory integration point).
public nonisolated struct InvestigationMethodRun: Sendable {
    public let caseID: UUID
    public let scope: RetrievalSourceScope
    public let run: MethodRun

    public nonisolated init(caseID: UUID, scope: RetrievalSourceScope, run: MethodRun) {
        self.caseID = caseID; self.scope = scope; self.run = run
    }
}

public nonisolated enum InvestigationMethodError: Error, Sendable, Equatable {
    case caseNotFound(UUID)
    case unknownMethod(String)
    case unauthorizedEvidence(kind: String, id: UUID)   // outside the active case's authorized scope
    case unresolvableEvidence(kind: String, id: UUID)   // source identity not resolvable → fail-closed
    case evidenceDenied(reason: String)                 // shared gate: existence / workspace / SensitiveScope
}

public actor InvestigationMethodService {
    private let cases: InvestigationCaseRepository
    private let resolver: CaseRetrievalScopeResolver
    private let evidence: EvidenceStore
    private let methodRuns: MethodRunRepository
    private let registry: ProfessionalMethodRegistry
    private let gate: any WorkflowEvidenceReferenceGating

    /// The INV-01 recommended method set — SHARED catalog ids only (no persona-specific definitions).
    public static let inv01RecommendedMethodIDs: [String] = [
        "com.kalsmritikosh.method.5w1h",
        "com.kalsmritikosh.method.evidence-collection-plan",
        "com.kalsmritikosh.method.gap-analysis",
        "com.kalsmritikosh.method.timeline-analysis",
        "com.kalsmritikosh.method.contradiction-matrix",
        "com.kalsmritikosh.method.hypothesis-matrix",
    ]

    public init(cases: InvestigationCaseRepository, resolver: CaseRetrievalScopeResolver, evidence: EvidenceStore,
                methodRuns: MethodRunRepository, registry: ProfessionalMethodRegistry,
                gate: any WorkflowEvidenceReferenceGating) {
        self.cases = cases; self.resolver = resolver; self.evidence = evidence
        self.methodRuns = methodRuns; self.registry = registry; self.gate = gate
    }

    /// Recommended methods for an active case — each resolved to its SHARED registered definition (a
    /// recommendation whose id is not registered is simply omitted; never a duplicate definition).
    public func recommendedMethods(caseID: UUID) async throws -> [ProfessionalMethodDefinition] {
        guard try await cases.fetch(caseID: caseID) != nil else { throw InvestigationMethodError.caseNotFound(caseID) }
        return Self.inv01RecommendedMethodIDs.compactMap { registry.latest(id: ProfessionalMethodDefinitionID(rawValue: $0)) }
    }

    /// The case-authorization decision for a single reference under a resolved scope.
    public func authorization(for spec: InvestigationMethodEvidenceSpec, scope: RetrievalSourceScope) async -> InvestigationEvidenceAuthorization {
        switch spec.targetKind {
        case .sourceVersion:
            return scope.authorizedSourceVersionIDs.contains(spec.targetID)
                ? .authorized(sourceVersionID: spec.targetID) : .unauthorized
        case .evidenceBlock:
            guard let ref = try? await evidence.resolveEvidenceBlocks([spec.targetID]).first,
                  let version = ref.sourceVersionID else { return .unresolvable }
            return scope.authorizedSourceVersionIDs.contains(version)
                ? .authorized(sourceVersionID: version) : .unauthorized
        default:
            return .unresolvable   // claim/entity/event/issue/gap/contradiction/outputs — reject fail-closed
        }
    }

    /// Throw on the FIRST reference that is not authorized for the case (fail-closed).
    public func authorizeAll(_ specs: [InvestigationMethodEvidenceSpec], scope: RetrievalSourceScope) async throws {
        for spec in specs {
            switch await authorization(for: spec, scope: scope) {
            case .authorized: continue
            case .unauthorized: throw InvestigationMethodError.unauthorizedEvidence(kind: spec.targetKind.rawValue, id: spec.targetID)
            case .unresolvable: throw InvestigationMethodError.unresolvableEvidence(kind: spec.targetKind.rawValue, id: spec.targetID)
            }
        }
    }

    /// Start a shared MethodRun inside an active case. Every supplied reference must pass BOTH the case
    /// authorization and the shared gate BEFORE the run is created; any failure throws and creates nothing.
    public func startMethod(caseID: UUID, methodDefinitionID: String, evidenceSpecs: [InvestigationMethodEvidenceSpec],
                            createdBy: String, now: Date) async throws -> InvestigationMethodRun {
        guard let record = try await cases.fetch(caseID: caseID) else { throw InvestigationMethodError.caseNotFound(caseID) }
        guard let definition = registry.latest(id: ProfessionalMethodDefinitionID(rawValue: methodDefinitionID)) else {
            throw InvestigationMethodError.unknownMethod(methodDefinitionID)
        }
        let scope = try await resolver.scope(for: record)
        let workspaceID = record.caseHeader.workspaceID

        // Pre-checks BEFORE any creation (atomic): case authorization, then the shared canonical gate.
        try await authorizeAll(evidenceSpecs, scope: scope)
        for spec in evidenceSpecs {
            guard let gateKind = spec.targetKind.evidenceGateKind else {
                throw InvestigationMethodError.unresolvableEvidence(kind: spec.targetKind.rawValue, id: spec.targetID)
            }
            if case .denied(let reason) = await gate.verdict(kind: gateKind, canonicalObjectID: spec.targetID, workspaceID: workspaceID) {
                throw InvestigationMethodError.evidenceDenied(reason: reason)
            }
        }

        // All references authorized + gated — create the shared run and attach through the shared path.
        var run = try await methodRuns.createRun(
            workspaceID: workspaceID, methodDefinitionID: definition.id, methodDefinitionVersion: definition.version,
            title: record.caseHeader.title, createdBy: createdBy, now: now)
        for spec in evidenceSpecs.sorted(by: { $0.ordinal < $1.ordinal }) {
            let link = MethodEvidenceLink(methodRunID: run.id, targetKind: spec.targetKind, targetID: spec.targetID,
                                          role: spec.role, inputRole: spec.inputRole, ordinal: spec.ordinal,
                                          addedBy: createdBy, addedAt: now)
            run = try await methodRuns.addEvidenceLink(link, expectedRevision: run.revision, gate: gate, now: now)
        }
        return InvestigationMethodRun(caseID: caseID, scope: scope, run: run)
    }
}
