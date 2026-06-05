//
//  ModelCapabilityCatalog.swift
//  Atlas chronica memora
//
//  Declarative capability matrix consulted by the Router when choosing
//  a model for a given UserIntent. Avoids if/else trees by mapping
//  intents → required capabilities.
//

import Foundation

public struct ModelCapabilityCatalog: Sendable {
    public static func requiredCapabilities(for intent: UserIntent.Kind) -> Set<ModelCapability> {
        switch intent {
        case .factualLookup, .semanticSearch:
            return [.textGeneration]
        case .reconstructTimeline, .reconstructProject, .reconstructRelationship, .executiveBriefing:
            return [.textGeneration, .longContext]
        case .riskDetection, .missingInformation:
            return [.textGeneration, .structuredOutput]
        case .unknown:
            return [.textGeneration]
        }
    }
}
