//
//  MissionEvidenceAssessor.swift
//  Kalsmritikosh
//
//  AEE-M1 — evaluates whether a mission's evidence OBLIGATIONS are met. It is NOT a
//  source-truth system: it reuses the existing EvidenceSufficiency (field coverage) and
//  the durable USF completion states, and wraps readiness/corroboration/mission
//  obligations around them to produce a single disposition. It never mutates a source's
//  state and never fabricates past a blocked source.
//

import Foundation

/// The closed disposition of a mission's evidence.
public nonisolated enum MissionEvidenceDisposition: String, Sendable, Codable, CaseIterable, Hashable {
    case satisfied
    case partial
    case blocked
    case unsupported
}

/// The result of assessing a mission's obligations against retrieved evidence.
public nonisolated struct MissionEvidenceAssessment: Sendable, Hashable {
    public let disposition: MissionEvidenceDisposition
    public let coveredFields: [RequestedField]
    public let missingFields: [RequestedField]
    public let decisiveSourceVersionIDs: [UUID]
    public let insufficientReadinessSourceVersionIDs: [UUID]
    public let independentSourceCount: Int
    public let contradictionCount: Int
    public let blockers: [String]
    public let limitations: [String]
    public let correctivePassUsed: Bool

    public init(
        disposition: MissionEvidenceDisposition,
        coveredFields: [RequestedField],
        missingFields: [RequestedField],
        decisiveSourceVersionIDs: [UUID],
        insufficientReadinessSourceVersionIDs: [UUID],
        independentSourceCount: Int,
        contradictionCount: Int,
        blockers: [String],
        limitations: [String],
        correctivePassUsed: Bool
    ) {
        self.disposition = disposition
        self.coveredFields = coveredFields
        self.missingFields = missingFields
        self.decisiveSourceVersionIDs = decisiveSourceVersionIDs
        self.insufficientReadinessSourceVersionIDs = insufficientReadinessSourceVersionIDs
        self.independentSourceCount = independentSourceCount
        self.contradictionCount = contradictionCount
        self.blockers = blockers
        self.limitations = limitations
        self.correctivePassUsed = correctivePassUsed
    }
}

public nonisolated struct MissionEvidenceAssessor: Sendable {
    public init() {}

    /// Assess the mission against the evidence.
    /// - decisiveReadiness: the DERIVED completion state of each decisive exact source
    ///   version (as reported by the USF completion authority). Non-decisive/context
    ///   sources are not passed here.
    /// - independentSourceCount: distinct source families (the caller already excludes
    ///   duplicate copies — duplicates never count as corroboration).
    public func assess(
        mission: QueryMission,
        sufficiency: EvidenceSufficiency,
        decisiveReadiness: [UUID: SourceCompletionState],
        independentSourceCount: Int,
        contradictionCount: Int,
        correctivePassUsed: Bool,
        externalBlockers: [String] = []
    ) -> MissionEvidenceAssessment {
        let obl = mission.evidenceObligations
        let floor = obl.minimumSourceReadiness

        let decisiveIDs = decisiveReadiness.keys.sorted { $0.uuidString < $1.uuidString }
        let belowFloor = decisiveReadiness
            .filter { !floor.isMet(by: $0.value) }
            .keys.sorted { $0.uuidString < $1.uuidString }
        let permanentlyBlocked = decisiveReadiness
            .filter { !floor.isMet(by: $0.value) && !floor.isUpgradable(from: $0.value) }
            .keys.sorted { $0.uuidString < $1.uuidString }

        var blockers = externalBlockers
        for id in permanentlyBlocked {
            let state = decisiveReadiness[id].map(\.rawValue) ?? "unknown"
            blockers.append("Decisive source \(id.uuidString) cannot reach \(floor.rawValue) (state: \(state)).")
        }

        var limitations: [String] = []
        if obl.requiresGapDisclosure {
            let disclosure = sufficiency.disclosure()
            if !disclosure.isEmpty { limitations.append(disclosure) }
        }
        if !belowFloor.isEmpty {
            limitations.append("\(belowFloor.count) decisive source(s) are not yet \(floor.rawValue).")
        }

        let corroborationOK = !obl.requiresCorroboration
            || independentSourceCount >= mission.queryPlan.evidencePolicy.minIndependentSources
        if obl.requiresCorroboration && !corroborationOK {
            limitations.append("Corroboration requires \(mission.queryPlan.evidencePolicy.minIndependentSources) independent sources; found \(independentSourceCount).")
        }

        let disposition = Self.decideDisposition(
            mission: mission, obligations: obl,
            fieldsComplete: sufficiency.missing.isEmpty,
            belowFloorEmpty: belowFloor.isEmpty,
            permanentlyBlockedEmpty: permanentlyBlocked.isEmpty,
            corroborationOK: corroborationOK)

        return MissionEvidenceAssessment(
            disposition: disposition,
            coveredFields: sufficiency.covered,
            missingFields: sufficiency.missing,
            decisiveSourceVersionIDs: decisiveIDs,
            insufficientReadinessSourceVersionIDs: belowFloor,
            independentSourceCount: independentSourceCount,
            contradictionCount: contradictionCount,
            blockers: blockers,
            limitations: limitations,
            correctivePassUsed: correctivePassUsed)
    }

    static func decideDisposition(
        mission: QueryMission,
        obligations obl: MissionEvidenceObligations,
        fieldsComplete: Bool,
        belowFloorEmpty: Bool,
        permanentlyBlockedEmpty: Bool,
        corroborationOK: Bool
    ) -> MissionEvidenceDisposition {
        // An unsupported class can never ship a material answer.
        if mission.queryClass == .unsupported { return .unsupported }

        // A decisive source that can never reach the required floor, on a lane that will
        // NOT accept a disclosed partial (analytical/reconstruction/workflow/deterministic),
        // blocks the mission — a blocked upgrade must not be answered around.
        if !permanentlyBlockedEmpty && !obl.allowSearchablePartialWithDisclosure {
            return .blocked
        }

        // Everything the mission requires is in hand.
        if fieldsComplete && belowFloorEmpty && corroborationOK {
            return .satisfied
        }

        // A low-risk lane may ship a disclosed partial; anything else that is short of a
        // required floor without permission to disclose-partial is blocked.
        if obl.allowSearchablePartialWithDisclosure {
            return .partial
        }
        // High-risk lane, short of the floor/corroboration, no disclose-partial permission.
        return belowFloorEmpty && corroborationOK ? .partial : .blocked
    }
}
