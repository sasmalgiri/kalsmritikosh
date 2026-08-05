//
//  InvestigationCausalService.swift
//  Kalsmritikosh
//
//  INV-13 (Five Whys) + INV-14 (Fishbone) + INV-15 (Root-cause). Orchestration only: the causal triad is
//  NOT a persona-native store — the architecture forbids concrete-method-named tables (see
//  WorkflowMethodBoundaryGuardTests). Instead this service REUSES the SHARED professional-method engine:
//  the five-whys / fishbone / root-cause methods are registered concrete methods whose validators already
//  enforce the persona invariants —
//    • Five Whys / Fishbone emit NO findings (a why-level and a bone stay proposal-layer: a step ≠ a
//      confirmed cause, a bone ≠ the root cause), and
//    • Root-Cause admits a `confirmedRootCause` finding ONLY when a recorded HUMAN `rootCauseDecision`
//      review selects it (a candidate ≠ a confirmed root cause; the app never confirms).
//  The persona contribution is CASE SCOPE: a causal method run is started through the same case-scoped
//  authorization as INV-01-C2 (InvestigationMethodService), so every evidence reference must resolve to a
//  source version authorized for the active case. No second run store, lifecycle, or review authority.
//

import Foundation

public nonisolated enum InvestigationCausalError: Error, Sendable, Equatable {
    case caseNotFound(UUID)
    case notCausalMethod(String)   // an id outside the five-whys / fishbone / root-cause set
}

public actor InvestigationCausalService {
    private let cases: InvestigationCaseRepository
    private let registry: ProfessionalMethodRegistry
    private let methods: InvestigationMethodService

    /// The SHARED causal method ids (registered in ProfessionalMethodCatalog). The Investigator forks none of them.
    public static let causalMethodIDs: [String] = [
        "com.kalsmritikosh.method.five-whys",
        "com.kalsmritikosh.method.fishbone",
        "com.kalsmritikosh.method.root-cause",
    ]
    public static let rootCauseMethodID = "com.kalsmritikosh.method.root-cause"

    public init(cases: InvestigationCaseRepository, registry: ProfessionalMethodRegistry, methods: InvestigationMethodService) {
        self.cases = cases; self.registry = registry; self.methods = methods
    }

    /// The causal methods recommended for an active case — each resolved to its SHARED registered definition.
    public func recommendedCausalMethods(caseID: UUID) async throws -> [ProfessionalMethodDefinition] {
        guard try await cases.fetch(caseID: caseID) != nil else { throw InvestigationCausalError.caseNotFound(caseID) }
        return Self.causalMethodIDs.compactMap { registry.latest(id: ProfessionalMethodDefinitionID(rawValue: $0)) }
    }

    /// The shared Root-Cause method definition, whose `confirmedRootCause` finding is admitted only via a
    /// human `rootCauseDecision` review — surfaced so a caller can see the human-determination requirement.
    public func rootCauseMethod() -> ProfessionalMethodDefinition? {
        registry.latest(id: ProfessionalMethodDefinitionID(rawValue: Self.rootCauseMethodID))
    }

    /// Start a causal method run inside an active case. Restricted to the causal method set; the run itself
    /// is created through the SHARED case-scoped method entry, so every evidence reference must be authorized
    /// for the case (unauthorized/unresolvable evidence is rejected before any run state is created).
    public func startCausalMethod(caseID: UUID, methodDefinitionID: String, evidenceSpecs: [InvestigationMethodEvidenceSpec],
                                  createdBy: String, now: Date) async throws -> InvestigationMethodRun {
        guard Self.causalMethodIDs.contains(methodDefinitionID) else {
            throw InvestigationCausalError.notCausalMethod(methodDefinitionID)
        }
        return try await methods.startMethod(caseID: caseID, methodDefinitionID: methodDefinitionID,
                                             evidenceSpecs: evidenceSpecs, createdBy: createdBy, now: now)
    }
}
