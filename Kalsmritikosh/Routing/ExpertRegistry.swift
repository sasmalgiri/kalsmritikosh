//
//  ExpertRegistry.swift
//  Kalsmritikosh
//
//  Registers Expert implementations with declared capabilities + domains
//  so the Router can match them to intents.
//

import Foundation

public actor ExpertRegistry {
    private var experts: [String: any Expert] = [:]

    public init() {}

    public func register(_ expert: any Expert) {
        experts[expert.id] = expert
    }

    // UNIT E: the registry is a Dictionary — unsorted `values` handed the
    // expert lineup to callers in hash order (arbitrary order given
    // authority, at the lineup itself). Stable content key = expert id.
    public func all() -> [any Expert] {
        experts.values.sorted { $0.id < $1.id }
    }

    public func experts(for intent: UserIntent) -> [any Expert] {
        let required = domains(for: intent)
        if required.isEmpty { return all() }
        return all().filter { !$0.domains.isDisjoint(with: required) }
    }

    public func expert(byID id: String) -> (any Expert)? {
        experts[id]
    }

    private func domains(for intent: UserIntent) -> Set<ExpertDomain> {
        // The generalist `.reasoning` expert joins every domain-gated panel
        // so cross-source reasoning is always available. (Empty set = ALL
        // experts, which already includes it.)
        switch intent.kind {
        case .reconstructTimeline, .reconstructProject:
            return [.timeline, .project, .email, .reasoning]
        case .reconstructRelationship:
            return [.email, .timeline, .project, .financial, .reasoning]
        case .executiveBriefing:
            return [.project, .financial, .legal, .email, .reasoning]
        case .riskDetection:
            return [.legal, .financial, .project, .reasoning]
        case .missingInformation:
            return [.project, .timeline, .reasoning]
        case .factualLookup, .semanticSearch, .unknown:
            return []
        }
    }
}
