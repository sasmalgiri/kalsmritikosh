//
//  Verifier.swift
//  Kalsmritikosh
//
//  Last gate before the user sees an answer. Without sources, no answer
//  ships. Detects contradictions across expert findings and downgrades
//  or refuses when confidence is too low.
//

import Foundation

public protocol Verifier: Sendable {
    func verify(
        intent: UserIntent,
        findings: [ExpertFindings],
        retrieval: RetrievalResult
    ) async throws -> VerifiedAnswer
}

public struct VerifiedAnswer: Codable, Sendable {
    public let body: String
    public let citations: [Citation]
    public let confidence: Confidence
    public let contradictions: [Contradiction]
    public let refused: Bool
    public let refusalReason: String?

    public init(
        body: String,
        citations: [Citation],
        confidence: Confidence,
        contradictions: [Contradiction] = [],
        refused: Bool = false,
        refusalReason: String? = nil
    ) {
        self.body = body
        self.citations = citations
        self.confidence = confidence
        self.contradictions = contradictions
        self.refused = refused
        self.refusalReason = refusalReason
    }

    public struct Citation: Codable, Sendable, Hashable {
        public let objectID: KnowledgeObject.ID
        public let chunkID: Chunk.ID?
        public let eventID: Event.ID?
        public let snippet: String

        public init(
            objectID: KnowledgeObject.ID,
            chunkID: Chunk.ID? = nil,
            eventID: Event.ID? = nil,
            snippet: String
        ) {
            self.objectID = objectID
            self.chunkID = chunkID
            self.eventID = eventID
            self.snippet = snippet
        }
    }

    public struct Contradiction: Codable, Sendable, Hashable {
        public let description: String
        public let claimA: String
        public let claimB: String
        public init(description: String, claimA: String, claimB: String) {
            self.description = description
            self.claimA = claimA
            self.claimB = claimB
        }
    }
}
