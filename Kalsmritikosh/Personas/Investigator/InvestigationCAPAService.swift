//
//  InvestigationCAPAService.swift
//  Kalsmritikosh
//
//  INV-16 (CAPA register) + INV-17 (Effectiveness review). Orchestration only: like the causal / linkage
//  triads, these run through the SHARED professional-method engine (no persona tables — the architecture
//  forbids concrete-method-named schema). The shared validators already enforce the persona invariants:
//    • CAPA — each corrective/preventive action must LINK a cause, and a CAPA is CLOSED only behind a human
//      `capaClosure` review (the app never closes a CAPA autonomously).
//    • Effectiveness Review — an effectiveness decision is admitted only behind a human `effectivenessDecision`
//      review that cites evidence (effectiveness is never declared without evidence).
//  Both emit NO findings (proposal-layer). The persona contribution is CASE SCOPE: a run is started through
//  the same case-scoped authorization as INV-01-C2 (InvestigationMethodService), so every evidence reference
//  must resolve to a source version authorized for the active case. No second run store.
//

import Foundation

public nonisolated enum InvestigationCAPAError: Error, Sendable, Equatable {
    case caseNotFound(UUID)
    case notCAPAMethod(String)   // an id outside the capa / effectiveness-review set
}

public actor InvestigationCAPAService {
    private let cases: InvestigationCaseRepository
    private let registry: ProfessionalMethodRegistry
    private let methods: InvestigationMethodService

    /// The SHARED CAPA / effectiveness method ids (registered in ProfessionalMethodCatalog). Forks none.
    public static let capaMethodIDs: [String] = [
        "com.kalsmritikosh.method.capa",                  // INV-16
        "com.kalsmritikosh.method.effectiveness-review",  // INV-17
    ]

    public init(cases: InvestigationCaseRepository, registry: ProfessionalMethodRegistry, methods: InvestigationMethodService) {
        self.cases = cases; self.registry = registry; self.methods = methods
    }

    /// The CAPA + effectiveness methods recommended for an active case — each resolved to its SHARED definition.
    public func recommendedCAPAMethods(caseID: UUID) async throws -> [ProfessionalMethodDefinition] {
        guard try await cases.fetch(caseID: caseID) != nil else { throw InvestigationCAPAError.caseNotFound(caseID) }
        return Self.capaMethodIDs.compactMap { registry.latest(id: ProfessionalMethodDefinitionID(rawValue: $0)) }
    }

    /// Start a CAPA or effectiveness-review run inside an active case. Restricted to the CAPA method set; the
    /// run is created through the SHARED case-scoped method entry, so every evidence reference must be
    /// authorized for the case (unauthorized/unresolvable evidence is rejected before any run is created).
    public func startCAPAMethod(caseID: UUID, methodDefinitionID: String, evidenceSpecs: [InvestigationMethodEvidenceSpec],
                                createdBy: String, now: Date) async throws -> InvestigationMethodRun {
        guard Self.capaMethodIDs.contains(methodDefinitionID) else {
            throw InvestigationCAPAError.notCAPAMethod(methodDefinitionID)
        }
        // INV-16 vs INV-17 — the effectiveness review is its OWN observable phase.
        let phase: PersonaJobKind = methodDefinitionID == "com.kalsmritikosh.method.effectiveness-review"
            ? .effectivenessReview : .capaRegister
        return try await methods.startMethod(caseID: caseID, methodDefinitionID: methodDefinitionID,
                                             evidenceSpecs: evidenceSpecs, createdBy: createdBy, now: now,
                                             phaseKind: phase)
    }
}
