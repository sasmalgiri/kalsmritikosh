//
//  ReasoningTrace.swift
//  Kalsmritikosh
//
//  Phase J.1 — "ExplainPlan" per the V09 (Query Planner / Historical
//  Reasoning) reference standard. Every VerifiedAnswer can carry an
//  optional ReasoningTrace so the UI's Quality Strip can show the
//  user:
//
//      • Which path the brain took (historical reconstruction, chunk
//        RAG fallback, expert pipeline, memory cache, refusal).
//      • Which intent was detected.
//      • Which retrieval layers fired and what each returned.
//      • Which experts ran (when the expert pipeline was the path).
//      • Which LLM purposes were invoked (capability resolves).
//      • What assumptions / downgrades / uncertainties remain.
//
//  Quality-or-nothing: traces are *additive*. A nil trace doesn't
//  break any caller; it just means the answer pre-dates the trace
//  capture wiring or came from a path that hasn't been instrumented
//  yet. The Quality Strip falls back to its existing counts.
//

import Foundation

public struct ReasoningTrace: Codable, Sendable, Hashable {
    /// Human-readable path label. Use the small enum below to keep
    /// strings consistent; the column is `String` so callers can
    /// extend it without a model rev.
    public let pathTaken: String
    public let intent: String
    /// Phase J.6 — Vol 09 §Query Categories. The 9-axis classifier's
    /// best-fit category for this question. Optional so legacy
    /// traces don't need to know about it.
    public let queryCategory: String?
    public let retrievalLayers: [String]
    public let shortCircuitedAt: String?
    public let expertIDs: [String]
    public let llmPurposes: [String]
    public let retrievalCounts: RetrievalCounts
    /// Free-text assumptions / downgrades the brain wants to flag.
    /// Examples: "Synthetic-question layer not warmed yet",
    /// "Verifier downgraded 2 chapter(s)", "Ingest coverage 0.62".
    public let assumptions: [String]
    /// Outstanding questions / data the user could provide to make
    /// the answer stronger. Empty when the brain is confident the
    /// archive carries the answer.
    public let uncertainties: [String]

    // AEE-M1 — the single QueryMission that served this request. All optional so
    // legacy/uninstrumented traces stay valid; the mission is DERIVED from the existing
    // signals, so these are observational only (no second trace authority).
    public let missionLane: String?
    public let missionObjective: String?
    public let missionDeliverable: String?
    public let evidenceRisk: String?
    public let missionReadinessFloor: String?
    public let missionCorrectivePassCount: Int?
    /// Exact-version upgrades the adaptive lane requested, as "sourceVersionID:goal".
    public let missionUpgradeActions: [String]?

    public struct RetrievalCounts: Codable, Sendable, Hashable {
        public let events: Int
        public let entities: Int
        public let chunks: Int
        public let relationships: Int
        public let summaries: Int
        public let walkSteps: Int
        /// SEM — domain-pack facts that rode this retrieval's evidence (option A).
        /// Surfaced in the "Why this answer?" trace so the fact layer is observable.
        public let genericFacts: Int

        public nonisolated init(
            events: Int = 0,
            entities: Int = 0,
            chunks: Int = 0,
            relationships: Int = 0,
            summaries: Int = 0,
            walkSteps: Int = 0,
            genericFacts: Int = 0
        ) {
            self.events = events
            self.entities = entities
            self.chunks = chunks
            self.relationships = relationships
            self.summaries = summaries
            self.walkSteps = walkSteps
            self.genericFacts = genericFacts
        }
    }

    public nonisolated init(
        pathTaken: String,
        intent: String,
        queryCategory: String? = nil,
        retrievalLayers: [String] = [],
        shortCircuitedAt: String? = nil,
        expertIDs: [String] = [],
        llmPurposes: [String] = [],
        retrievalCounts: RetrievalCounts = RetrievalCounts(),
        assumptions: [String] = [],
        uncertainties: [String] = [],
        missionLane: String? = nil,
        missionObjective: String? = nil,
        missionDeliverable: String? = nil,
        evidenceRisk: String? = nil,
        missionReadinessFloor: String? = nil,
        missionCorrectivePassCount: Int? = nil,
        missionUpgradeActions: [String]? = nil
    ) {
        self.pathTaken = pathTaken
        self.intent = intent
        self.queryCategory = queryCategory
        self.retrievalLayers = retrievalLayers
        self.shortCircuitedAt = shortCircuitedAt
        self.expertIDs = expertIDs
        self.llmPurposes = llmPurposes
        self.retrievalCounts = retrievalCounts
        self.assumptions = assumptions
        self.uncertainties = uncertainties
        self.missionLane = missionLane
        self.missionObjective = missionObjective
        self.missionDeliverable = missionDeliverable
        self.evidenceRisk = evidenceRisk
        self.missionReadinessFloor = missionReadinessFloor
        self.missionCorrectivePassCount = missionCorrectivePassCount
        self.missionUpgradeActions = missionUpgradeActions
    }

    /// Canonical path labels — kept as static strings (not an enum)
    /// so callers can extend without a model rev and trace tables
    /// stay forward-compatible. The UI groups on prefix.
    public nonisolated static let pathHistorical: String       = "historical reconstruction"
    public nonisolated static let pathChunkRAG: String         = "chunk RAG fallback"
    public nonisolated static let pathExpertPipeline: String   = "expert pipeline"
    public nonisolated static let pathMemoryCache: String      = "memory cache"
    public nonisolated static let pathRefusal: String          = "refusal"
}
