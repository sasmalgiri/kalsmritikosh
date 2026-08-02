//
//  MissionEvidenceObligations.swift
//  Kalsmritikosh
//
//  AEE-M1 — the evidence contract a mission must satisfy before it may ship a
//  material answer. This is NOT a second readiness system: `minimumSourceReadiness`
//  is a two-value REQUIREMENT threshold that references the existing USF truth
//  (search-ready vs evidence-ready). It never stores or invents a source's state —
//  it only states the floor a decisive source must clear for THIS mission.
//

import Foundation

/// The minimum durable readiness a decisive source must reach for the mission.
/// Two values only — it maps onto the existing USF SourceUpgradeGoal / completion
/// truth, and declares no new persisted vocabulary.
public nonisolated enum MissionReadinessFloor: String, Sendable, Codable, CaseIterable, Hashable {
    case searchReady
    case evidenceReady

    /// The USF upgrade goal that raises a source to this floor.
    public var upgradeGoal: SourceUpgradeGoal {
        switch self {
        case .searchReady:   return .searchReady
        case .evidenceReady: return .evidenceReady
        }
    }

    /// Whether a source in the given DERIVED completion state already meets this floor.
    public func isMet(by state: SourceCompletionState) -> Bool {
        switch self {
        case .searchReady:   return state == .searchablePartial || state == .evidenceReady
        case .evidenceReady: return state == .evidenceReady
        }
    }

    /// Whether a source in the given state can be UPGRADED to this floor at all, versus
    /// being permanently unable to reach it (encrypted/corrupt/unsupported/failed). A
    /// blocked source is never fabricated past — the assessor reports it honestly.
    public func isUpgradable(from state: SourceCompletionState) -> Bool {
        switch state {
        case .evidenceReady:                                   return true
        case .searchablePartial, .preservedOnly, .deferred:    return true
        case .encrypted, .corrupt, .unsupported, .failed:      return false
        }
    }
}

/// The obligations a mission places on its evidence before a material answer ships.
public nonisolated struct MissionEvidenceObligations: Sendable, Codable, Hashable {
    public let minimumSourceReadiness: MissionReadinessFloor
    public let requiresCitation: Bool
    public let requiresResolvableLocator: Bool
    public let requiresCorroboration: Bool
    public let requiresConflictDisclosure: Bool
    public let requiresGapDisclosure: Bool
    /// When true, a low-risk mission may answer from search-ready/partial evidence
    /// PROVIDED the limitations are disclosed. High-risk lanes set this false.
    public let allowSearchablePartialWithDisclosure: Bool
    public let maxCorrectivePasses: Int

    public init(
        minimumSourceReadiness: MissionReadinessFloor,
        requiresCitation: Bool,
        requiresResolvableLocator: Bool,
        requiresCorroboration: Bool,
        requiresConflictDisclosure: Bool,
        requiresGapDisclosure: Bool,
        allowSearchablePartialWithDisclosure: Bool,
        maxCorrectivePasses: Int
    ) {
        self.minimumSourceReadiness = minimumSourceReadiness
        self.requiresCitation = requiresCitation
        self.requiresResolvableLocator = requiresResolvableLocator
        self.requiresCorroboration = requiresCorroboration
        self.requiresConflictDisclosure = requiresConflictDisclosure
        self.requiresGapDisclosure = requiresGapDisclosure
        self.allowSearchablePartialWithDisclosure = allowSearchablePartialWithDisclosure
        self.maxCorrectivePasses = maxCorrectivePasses
    }

    /// The conservative per-lane obligation set (spec §13). Corroboration defers to the
    /// plan's EvidencePolicy so we never demand more than the existing authority asks.
    public static func forLane(_ lane: AEELane, plan: QueryPlan) -> MissionEvidenceObligations {
        let corroboration = plan.evidencePolicy.requiresCorroboration
        // The corrective cap is bounded by the existing CorrectiveRetrievalPlanner cap.
        let correctiveCap = min(1, CorrectiveRetrievalPlanner.maxCorrectivePasses)
        switch lane {
        case .deterministic:
            return .init(
                minimumSourceReadiness: .searchReady,
                requiresCitation: true, requiresResolvableLocator: true,
                requiresCorroboration: false,
                requiresConflictDisclosure: true, requiresGapDisclosure: true,
                allowSearchablePartialWithDisclosure: false, maxCorrectivePasses: 0)
        case .focused:
            return .init(
                minimumSourceReadiness: .searchReady,
                requiresCitation: true, requiresResolvableLocator: true,
                requiresCorroboration: false,
                requiresConflictDisclosure: true, requiresGapDisclosure: true,
                allowSearchablePartialWithDisclosure: true, maxCorrectivePasses: correctiveCap)
        case .analytical, .reconstruction, .professionalWorkflow:
            return .init(
                minimumSourceReadiness: .evidenceReady,
                requiresCitation: true, requiresResolvableLocator: true,
                requiresCorroboration: corroboration,
                requiresConflictDisclosure: true, requiresGapDisclosure: true,
                allowSearchablePartialWithDisclosure: false, maxCorrectivePasses: correctiveCap)
        }
    }
}
