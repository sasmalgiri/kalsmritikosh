//
//  EnrichmentJob.swift
//  Kalsmritikosh
//
//  PERF.2 — a unit of deferred deep-enrichment work in the two-pass ingest model
//  (06_INGESTION_PIPELINE §5). Pass 1 commits the queryable core (structural parse, FTS,
//  tables, basic deterministic entities/events) fast; Pass 2 "deep" work is queued as
//  durable, idempotent, resumable jobs so a large ingest is searchable immediately and
//  deepens in the background — surviving restarts (§4 recovery) without duplicating work.
//

import Foundation

/// The kinds of deferred deep enrichment (Pass 2). Each maps to a background processor.
public enum EnrichmentJobKind: String, Sendable, Codable, Hashable, CaseIterable {
    case embedding                // semantic vectors
    case typedFacts               // domain-pack GenericFacts + document roles
    case entityReconciliation     // canonical entity unification
    case contradictionScan        // contradiction/gap detection
    case ocr                      // deferred OCR/ASR for likely-evidence media
    case deepStudy                // on-demand Tier-3 deep analysis
}

/// The durable lifecycle of a job. `pending` → `running` → `done` | `failed`.
/// `failed` jobs are retryable (attempts bounded by the drainer).
public enum EnrichmentJobState: String, Sendable, Codable, Hashable {
    case pending
    case running
    case done
    case failed
}

public struct EnrichmentJob: Sendable, Hashable, Identifiable, Codable {
    public let id: UUID
    /// The object/source this job enriches.
    public let subjectID: UUID
    public let kind: EnrichmentJobKind
    public let state: EnrichmentJobState
    public let attempts: Int
    public let lastError: String?
    public let createdAt: Date
    public let updatedAt: Date

    public nonisolated init(
        id: UUID = UUID(),
        subjectID: UUID,
        kind: EnrichmentJobKind,
        state: EnrichmentJobState = .pending,
        attempts: Int = 0,
        lastError: String? = nil,
        createdAt: Date = .init(),
        updatedAt: Date = .init()
    ) {
        self.id = id
        self.subjectID = subjectID
        self.kind = kind
        self.state = state
        self.attempts = attempts
        self.lastError = lastError
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
