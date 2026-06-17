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
    /// Just the answer portion of `body`, with any subject heading or
    /// retrieval footer stripped. nil for refusal answers and for legacy
    /// pre-UPDATE_13 callers that produced a single combined body.
    /// EvalKitRunner scores keyword-hit against this so a name appearing
    /// only in the "Subjects in scope" footer no longer satisfies the
    /// metric. UPDATE_13 Item 4.
    public let answerText: String?
    /// Raw value of `intent.kind` that the brain resolved for the
    /// question. Surfaced so EvalKit can show how questions actually
    /// classify and so the citation cap can be sanity-checked against
    /// the real intent (UPDATE_14 Item 0). nil on refusal / boot paths.
    public let intentKind: String?
    public let citations: [Citation]
    public let confidence: Confidence
    public let contradictions: [Contradiction]
    public let refused: Bool
    public let refusalReason: String?
    /// Full confidence report, used by the UI quality strip (T11).
    public let report: ConfidenceReport?

    public init(
        body: String,
        answerText: String? = nil,
        intentKind: String? = nil,
        citations: [Citation],
        confidence: Confidence,
        contradictions: [Contradiction] = [],
        refused: Bool = false,
        refusalReason: String? = nil,
        report: ConfidenceReport? = nil
    ) {
        self.body = body
        self.answerText = answerText
        self.intentKind = intentKind
        self.citations = citations
        self.confidence = confidence
        self.contradictions = contradictions
        self.refused = refused
        self.refusalReason = refusalReason
        self.report = report
    }

    private enum CodingKeys: String, CodingKey {
        case body, answerText, intentKind, citations, confidence, contradictions, refused, refusalReason, report
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.body = try c.decode(String.self, forKey: .body)
        self.answerText = try c.decodeIfPresent(String.self, forKey: .answerText)
        self.intentKind = try c.decodeIfPresent(String.self, forKey: .intentKind)
        self.citations = try c.decode([Citation].self, forKey: .citations)
        self.confidence = try c.decode(Confidence.self, forKey: .confidence)
        self.contradictions = try c.decodeIfPresent([Contradiction].self, forKey: .contradictions) ?? []
        self.refused = try c.decodeIfPresent(Bool.self, forKey: .refused) ?? false
        self.refusalReason = try c.decodeIfPresent(String.self, forKey: .refusalReason)
        self.report = try c.decodeIfPresent(ConfidenceReport.self, forKey: .report)
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
