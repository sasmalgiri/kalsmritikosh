//
//  ExpertRegistry.swift
//  Atlas chronica memora
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

    public func all() -> [any Expert] {
        Array(experts.values)
    }

    public func experts(for intent: UserIntent) -> [any Expert] {
        let required = domains(for: intent)
        if required.isEmpty { return Array(experts.values) }
        return experts.values.filter { !$0.domains.isDisjoint(with: required) }
    }

    public func expert(byID id: String) -> (any Expert)? {
        experts[id]
    }

    private func domains(for intent: UserIntent) -> Set<ExpertDomain> {
        switch intent.kind {
        case .reconstructTimeline, .reconstructProject:
            return [.timeline, .project, .email]
        case .reconstructRelationship:
            return [.email, .timeline, .project, .financial]
        case .executiveBriefing:
            return [.project, .financial, .legal, .email]
        case .riskDetection:
            return [.legal, .financial, .project]
        case .missingInformation:
            return [.project, .timeline]
        case .factualLookup, .semanticSearch, .unknown:
            return []
        }
    }
}
