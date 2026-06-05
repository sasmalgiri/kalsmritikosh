//
//  Router.swift
//  Atlas chronica memora
//
//  Dynamic routing: given a UserIntent, decide which capabilities a
//  fulfilling model needs, which experts run, which retrieval layers are
//  consulted, and the level of parallelism.
//
//  M6.1 contract change: the router NEVER picks a specific model. It
//  describes what the call needs (a CapabilitySpec) and the
//  CapabilityRegistry resolves that spec to a concrete provider.
//

import Foundation

public struct UserIntent: Codable, Sendable, Hashable {
    public let kind: Kind
    public let scope: Scope
    public let timeframe: Timeframe?
    public let entityHints: [String]
    public let rawQuestion: String

    public init(
        kind: Kind,
        scope: Scope,
        timeframe: Timeframe? = nil,
        entityHints: [String] = [],
        rawQuestion: String
    ) {
        self.kind = kind
        self.scope = scope
        self.timeframe = timeframe
        self.entityHints = entityHints
        self.rawQuestion = rawQuestion
    }

    public enum Kind: String, Codable, Sendable, CaseIterable {
        case factualLookup
        case reconstructTimeline
        case reconstructProject
        case reconstructRelationship
        case executiveBriefing
        case riskDetection
        case missingInformation
        case semanticSearch
        case unknown
    }

    public enum Scope: Codable, Sendable, Hashable {
        case global
        case project(String)
        case person(String)
        case organization(String)
        case folder(String)
    }

    public struct Timeframe: Codable, Sendable, Hashable {
        public let start: Date?
        public let end: Date?
        public init(start: Date?, end: Date?) {
            self.start = start
            self.end = end
        }
    }
}

public struct RoutingDecision: Codable, Sendable {
    /// What the brain needs from a model for this question. The
    /// MasterBrain hands this spec to the CapabilityRegistry when it
    /// needs to synthesize a final answer; experts get their own
    /// CapabilitySpec via the registry directly.
    public let answerSpec: CapabilitySpec
    public let expertIDs: [String]
    public let retrievalLayers: [RetrievalLayer]
    public let parallelism: Int
    public let complexity: Int        // 1...5, produced by ComplexityAnalyzer
    public let rationale: String

    public init(
        answerSpec: CapabilitySpec,
        expertIDs: [String],
        retrievalLayers: [RetrievalLayer],
        parallelism: Int,
        complexity: Int,
        rationale: String
    ) {
        self.answerSpec = answerSpec
        self.expertIDs = expertIDs
        self.retrievalLayers = retrievalLayers
        self.parallelism = parallelism
        self.complexity = complexity
        self.rationale = rationale
    }
}

public enum RetrievalLayer: String, Codable, Sendable, CaseIterable {
    case memory     // first — MemoryObject layer (M6.4)
    case timeline
    case entity
    case metadata
    case summary
    case graph
    case vector     // fallback only — per locked retrieval order
}

public protocol Router: Sendable {
    func route(intent: UserIntent) async throws -> RoutingDecision
}

public protocol IntentDetector: Sendable {
    func detect(question: String) async throws -> UserIntent
}
