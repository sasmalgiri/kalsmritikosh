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

/// HISTORY follow-on — which retrieval shape produced the answer.
/// The UI surfaces this so the user knows whether they're looking at
/// a structured-event reconstruction (high trust, every claim tied
/// to a dated Event) or a chunk-grounded LLM synthesis (lower trust,
/// the same shape a generic ChatGPT-with-files setup produces).
public nonisolated enum AnswerSource: String, Codable, Sendable, Hashable {
    /// Structured ledger answer — narrative composer built chapters
    /// from Events with 5W+H slots and per-sentence event citations.
    case historical
    /// "Normal AI" RAG fallback — the chunk-LLM path. Used when the
    /// structured composer can't produce useful chapters.
    case ragFallback
    /// Expert pipeline answer — verifier-graded, multi-source.
    case experts
    /// Cached memory hit (Phase 1 instant read).
    case memoryCache
    /// Generic / unknown source (legacy callers, refusals).
    case unknown

    public var displayName: String {
        switch self {
        case .historical:  return "Historical reconstruction"
        case .ragFallback: return "RAG (chunk grounded)"
        case .experts:     return "Expert pipeline"
        case .memoryCache: return "Memory cache"
        case .unknown:     return "Unknown"
        }
    }
}

/// Closed-corpus answer state (Ledger AI contract). Distinct from
/// `AnswerSource` (which says HOW the answer was produced): this says
/// WHETHER the ingested corpus supports the claim. The brain's
/// answerability gate resolves this before prose generation so the
/// UI can show an honest, evidence-bounded verdict.
public nonisolated enum AnswerState: String, Codable, Sendable, Hashable {
    /// The archive contains evidence that directly supports the answer.
    case supported
    /// The archive supports part of the answer but not all of it (e.g.
    /// a cause is named but not proven to be the only cause).
    case partiallySupported = "partially_supported"
    /// Sources disagree — the answer surfaces both sides as a conflict.
    case contradicted
    /// No evidence for this was found in the ingested archive.
    case notFound = "not_found"
    /// Relevant files exist but are still pending OCR / indexing /
    /// enrichment, so the answer may be incomplete.
    case insufficientlyIndexed = "insufficiently_indexed"
    /// Legacy / not-yet-classified (default for pre-v28 callers).
    case unknown

    public var displayName: String {
        switch self {
        case .supported:             return "Supported"
        case .partiallySupported:    return "Partially supported"
        case .contradicted:          return "Contradicted"
        case .notFound:              return "Not found"
        case .insufficientlyIndexed: return "Insufficiently indexed"
        case .unknown:               return "Unknown"
        }
    }
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
    /// G3.20/G3.22 — typed walk-path steps inherited from the
    /// RetrievalResult. EvalKit aggregates this into a "walk coverage"
    /// metric; the UI "Why this answer?" panel renders the chain.
    /// Empty when the answer wasn't bond-walked (no entity seed, no
    /// walker wired, or non-multihop intent).
    public let walkSteps: [WalkStep]
    /// HISTORY follow-on — which retrieval shape produced this
    /// answer (historical / RAG / experts / memory / unknown). The
    /// UI surfaces this as a small badge so the user can tell a
    /// "real reconstruction from dated events" apart from a
    /// "generic chunk-RAG synthesis". Defaults to .unknown for
    /// legacy callers that don't set it.
    public let source: AnswerSource
    /// Phase J.1 — "ExplainPlan" trace. When the brain has captured
    /// the path (which layers fired, which experts ran, which LLM
    /// purposes were invoked, assumptions + uncertainties), the
    /// Quality Strip's "Why this answer?" disclosure renders it.
    /// Optional — legacy callers that don't set it just don't show
    /// the disclosure.
    public let reasoningTrace: ReasoningTrace?
    /// Closed-corpus answer state (v28 Ledger AI contract). Whether the
    /// ingested archive SUPPORTS / PARTIALLY_SUPPORTS / CONTRADICTS the
    /// answer, or the corpus has NOT_FOUND / INSUFFICIENTLY_INDEXED
    /// evidence. Defaults to `.unknown` for legacy callers that don't
    /// run the answerability gate yet.
    public let answerState: AnswerState

    public nonisolated init(
        body: String,
        answerText: String? = nil,
        intentKind: String? = nil,
        citations: [Citation],
        confidence: Confidence,
        contradictions: [Contradiction] = [],
        refused: Bool = false,
        refusalReason: String? = nil,
        report: ConfidenceReport? = nil,
        walkSteps: [WalkStep] = [],
        source: AnswerSource = .unknown,
        reasoningTrace: ReasoningTrace? = nil,
        answerState: AnswerState = .unknown
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
        self.walkSteps = walkSteps
        self.source = source
        self.reasoningTrace = reasoningTrace
        self.answerState = answerState
    }

    private enum CodingKeys: String, CodingKey {
        case body, answerText, intentKind, citations, confidence, contradictions, refused, refusalReason, report, walkSteps, source, reasoningTrace, answerState
    }

    public nonisolated init(from decoder: Decoder) throws {
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
        self.walkSteps = try c.decodeIfPresent([WalkStep].self, forKey: .walkSteps) ?? []
        self.source = try c.decodeIfPresent(AnswerSource.self, forKey: .source) ?? .unknown
        self.reasoningTrace = try c.decodeIfPresent(ReasoningTrace.self, forKey: .reasoningTrace)
        self.answerState = try c.decodeIfPresent(AnswerState.self, forKey: .answerState) ?? .unknown
    }

    public struct Citation: Codable, Sendable, Hashable {
        public let objectID: KnowledgeObject.ID
        public let chunkID: Chunk.ID?
        public let eventID: Event.ID?
        public let snippet: String

        public nonisolated init(
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

    public nonisolated struct Contradiction: Codable, Sendable, Hashable {
        public let description: String
        public let claimA: String
        public let claimB: String
        public nonisolated init(description: String, claimA: String, claimB: String) {
            self.description = description
            self.claimA = claimA
            self.claimB = claimB
        }

        // Explicit nonisolated Hashable/Equatable — the synthesized witnesses
        // are main-actor under the module's default isolation.
        public nonisolated static func == (lhs: Contradiction, rhs: Contradiction) -> Bool {
            lhs.description == rhs.description && lhs.claimA == rhs.claimA && lhs.claimB == rhs.claimB
        }

        public nonisolated func hash(into hasher: inout Hasher) {
            hasher.combine(description)
            hasher.combine(claimA)
            hasher.combine(claimB)
        }
    }
}
