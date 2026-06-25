//
//  Tier3Escalator.swift
//  Kalsmritikosh
//
//  Demand-driven Tier-3 enrichment trigger. When the user asks a
//  question that comes back with a thin answer — low confidence,
//  few citations, no walk steps — the gap suggests the subject
//  hasn't been Tier-3-distilled deeply enough yet. Rather than
//  waiting for the periodic Tier-3 sweep, this actor injects a
//  SubjectInvalidation into the same stream IncrementalUpdater
//  already consumes, which kicks MemoryDistiller for the affected
//  subject within the debounce window.
//
//  The whole point of the enrichment ladder (CLAUDE.md): Tier 0
//  is seconds (parse), Tier 1 is minutes (structure), Tier 2 runs
//  background (vectors + LLM extraction), Tier 3 is "deep study —
//  on demand". This actor implements the "on demand" half by
//  giving callers a single entry point: `escalate(subject:)`.
//

import Foundation
import OSLog

public actor Tier3Escalator {
    private static let log = Logger(subsystem: "kalsmritikosh", category: "Tier3Escalator")

    /// Where to drop invalidation events. Same channel
    /// IncrementalUpdater listens on; the consumer doesn't know or
    /// care whether the trigger was an ingest or a query gap.
    private let invalidationContinuation: AsyncStream<SubjectInvalidation>.Continuation

    /// Per-subject cooldown so a user re-asking the same question
    /// three times doesn't fire three duplicate distillations.
    private var lastEscalation: [String: Date] = [:]
    private let cooldownSeconds: TimeInterval

    /// Heuristic tunables. A retrieval is judged "thin" when ALL of
    /// these fall below threshold. Confidence is the primary
    /// signal; citationCount and walkStepCount are secondary.
    public struct Thresholds: Sendable {
        public var confidence: Double
        public var citationCount: Int
        public var walkStepCount: Int

        public static let `default` = Thresholds(
            confidence: 0.5,
            citationCount: 2,
            walkStepCount: 1
        )
    }
    public let thresholds: Thresholds

    public init(
        continuation: AsyncStream<SubjectInvalidation>.Continuation,
        thresholds: Thresholds = .default,
        cooldownSeconds: TimeInterval = 60
    ) {
        self.invalidationContinuation = continuation
        self.thresholds = thresholds
        self.cooldownSeconds = cooldownSeconds
    }

    /// Decide whether the answer is thin enough to warrant
    /// escalating the subject, and if so, fire the invalidation.
    /// `triggeringObjectID` is the most-recent KO touched — used as
    /// the invalidation's triggering ID for traceability.
    public func considerEscalation(
        subjectKind: MemoryObject.SubjectKind,
        subjectIdentifier: String,
        confidence: Double,
        citationCount: Int,
        walkStepCount: Int,
        triggeringObjectID: KnowledgeObject.ID
    ) async {
        let identifier = subjectIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty else { return }

        let thin = confidence < thresholds.confidence
            && citationCount < thresholds.citationCount
            && walkStepCount < thresholds.walkStepCount
        guard thin else { return }

        let key = "\(subjectKind.rawValue)|\(identifier.lowercased())"
        if let last = lastEscalation[key],
           Date().timeIntervalSince(last) < cooldownSeconds {
            Self.log.debug("Tier-3 escalation suppressed (cooldown): \(key, privacy: .public)")
            return
        }
        lastEscalation[key] = Date()

        Self.log.info("Tier-3 escalation requested for \(key, privacy: .public) (conf=\(confidence, privacy: .public))")
        invalidationContinuation.yield(SubjectInvalidation(
            subjects: [SubjectInvalidation.Subject(
                kind: subjectKind,
                identifier: identifier
            )],
            triggeringObjectID: triggeringObjectID
        ))
    }

    /// Force-escalate, ignoring the gap heuristics. For a debug-menu
    /// "rerun deeply" affordance.
    public func forceEscalate(
        subjectKind: MemoryObject.SubjectKind,
        subjectIdentifier: String,
        triggeringObjectID: KnowledgeObject.ID
    ) async {
        let identifier = subjectIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty else { return }
        let key = "\(subjectKind.rawValue)|\(identifier.lowercased())"
        lastEscalation[key] = Date()
        invalidationContinuation.yield(SubjectInvalidation(
            subjects: [SubjectInvalidation.Subject(
                kind: subjectKind,
                identifier: identifier
            )],
            triggeringObjectID: triggeringObjectID
        ))
    }
}
