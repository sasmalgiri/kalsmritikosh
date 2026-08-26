//
//  InvestigationLinkageService.swift
//  Kalsmritikosh
//
//  INV-09 (Investigation timeline) + INV-10 (Relationship graph) + INV-11 (Transaction & asset flow).
//  Orchestration only: like the causal triad, these are NOT persona-native stores — the architecture forbids
//  concrete-method-named schema. They REUSE the SHARED professional-method engine, whose validators already
//  enforce the persona invariants:
//    • Timeline Analysis — a dated row must cite its source or be explicitly marked undated (dates are never
//      invented or padded); confirmInclusion is a human review.
//    • Relationship Analysis — every asserted relationship edge must cite evidence; confirmEdges is human.
//    • Transaction Flow — every transaction's amount must trace to a source; the flow never concludes fraud
//      on its own; confirmFlow is human.
//  All three emit NO findings (proposal-layer). The persona contribution is CASE SCOPE: a run is started
//  through the same case-scoped authorization as INV-01-C2 (InvestigationMethodService), so every evidence
//  reference must resolve to a source version authorized for the active case. No second run store.
//

import Foundation

public nonisolated enum InvestigationLinkageError: Error, Sendable, Equatable {
    case caseNotFound(UUID)
    case notLinkageMethod(String)   // an id outside the timeline / relationship / transaction set
}

public actor InvestigationLinkageService {
    private let cases: InvestigationCaseRepository
    private let registry: ProfessionalMethodRegistry
    private let methods: InvestigationMethodService

    /// The SHARED evidence-mapping method ids (registered in ProfessionalMethodCatalog). The Investigator forks none.
    public static let linkageMethodIDs: [String] = [
        "com.kalsmritikosh.method.timeline-analysis",     // INV-09
        "com.kalsmritikosh.method.relationship-analysis", // INV-10
        "com.kalsmritikosh.method.transaction-flow",      // INV-11
    ]

    public init(cases: InvestigationCaseRepository, registry: ProfessionalMethodRegistry, methods: InvestigationMethodService) {
        self.cases = cases; self.registry = registry; self.methods = methods
    }

    /// The timeline / relationship / transaction methods recommended for an active case — each resolved to
    /// its SHARED registered definition.
    public func recommendedLinkageMethods(caseID: UUID) async throws -> [ProfessionalMethodDefinition] {
        guard try await cases.fetch(caseID: caseID) != nil else { throw InvestigationLinkageError.caseNotFound(caseID) }
        return Self.linkageMethodIDs.compactMap { registry.latest(id: ProfessionalMethodDefinitionID(rawValue: $0)) }
    }

    /// Start an evidence-mapping method run inside an active case. Restricted to the linkage method set; the
    /// run is created through the SHARED case-scoped method entry, so every evidence reference must be
    /// authorized for the case (unauthorized/unresolvable evidence is rejected before any run is created).
    public func startLinkageMethod(caseID: UUID, methodDefinitionID: String, evidenceSpecs: [InvestigationMethodEvidenceSpec],
                                   createdBy: String, now: Date) async throws -> InvestigationMethodRun {
        guard Self.linkageMethodIDs.contains(methodDefinitionID) else {
            throw InvestigationLinkageError.notLinkageMethod(methodDefinitionID)
        }
        return try await methods.startMethod(caseID: caseID, methodDefinitionID: methodDefinitionID,
                                             evidenceSpecs: evidenceSpecs, createdBy: createdBy, now: now,
                                             phaseKind: .linkage)
    }
}
