//
//  SourceReadinessTypes.swift
//  Kalsmritikosh
//
//  USF-002 — the closed vocabulary for INDEPENDENT source-version readiness. Program 2.0's
//  governing distinction is Preserved ≠ Searchable ≠ Evidence-ready ≠ Analytically ready.
//  Every exact SourceVersion carries exactly ten readiness dimensions; the overall completion
//  state is DERIVED (SourceReadinessEvaluator), never stored or caller-declared. Readiness
//  describes available processing representations only — it never confirms a Claim, changes
//  evidence status, or counts duplicates as corroboration.
//
//  Value types are `nonisolated` so the non-MainActor test target and the actor repository can
//  build them freely (app target runs SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor).
//

import Foundation

// MARK: - Closed vocabularies (mirror the v85 CHECKs)

/// The ten independent readiness dimensions. Exactly these rows exist for every source version.
public nonisolated enum SourceReadinessDimension: String, Sendable, Codable, CaseIterable, Hashable {
    case preservation
    case metadataExtraction
    case textExtraction
    case structuralExtraction
    case ocr
    case transcription
    case indexing
    case basicQuestionAnswering
    case typedFieldExtraction
    case analyticalReadiness

    /// Fixed 0…9 ordinal — the stable display/event-sequencing order.
    public var ordinal: Int {
        switch self {
        case .preservation: return 0
        case .metadataExtraction: return 1
        case .textExtraction: return 2
        case .structuralExtraction: return 3
        case .ocr: return 4
        case .transcription: return 5
        case .indexing: return 6
        case .basicQuestionAnswering: return 7
        case .typedFieldExtraction: return 8
        case .analyticalReadiness: return 9
        }
    }

    /// The complete dimension set in ordinal order — the ten rows every source version must have.
    public static var ordered: [SourceReadinessDimension] { allCases.sorted { $0.ordinal < $1.ordinal } }
}

/// The processing state of one dimension.
public nonisolated enum SourceReadinessDimensionState: String, Sendable, Codable, CaseIterable, Hashable {
    case notStarted
    case running
    case ready
    case partial
    case blocked
    case unsupported
    case failed
}

/// Whether a dimension is relevant to this source at all. `notApplicable` lets a native text
/// document report that transcription is irrelevant without describing it as failed or unsupported.
public nonisolated enum SourceReadinessApplicability: String, Sendable, Codable, CaseIterable, Hashable {
    case required
    case conditional
    case notApplicable
}

/// Why a dimension is blocked. A `blocked` dimension always carries exactly one of these.
public nonisolated enum SourceReadinessCondition: String, Sendable, Codable, CaseIterable, Hashable {
    case deferred
    case encrypted
    case corrupt
    case sourceUnavailable
    case missingDependency
    case awaitingUserAction
    case policy
    case resourceLimit
}

/// The DERIVED overall completion state of a source version. No caller may declare these directly.
public nonisolated enum SourceCompletionState: String, Sendable, Codable, CaseIterable, Hashable {
    case evidenceReady
    case searchablePartial
    case preservedOnly
    case deferred
    case encrypted
    case corrupt
    case unsupported
    case failed
}

/// The event action recorded when a dimension changes. `initialize` is bootstrap-only.
public nonisolated enum SourceReadinessAction: String, Sendable, Codable, CaseIterable, Hashable {
    case initialize
    case begin
    case satisfy
    case partiallySatisfy
    case block
    case markUnsupported
    case fail
    case invalidate
    case reconcile
}

/// The kind of canonical row a dimension's state is based on (its exact evidence).
public nonisolated enum SourceReadinessBasisKind: String, Sendable, Codable, CaseIterable, Hashable {
    case sourceVersion
    case sourceDocument
    case documentProfile
    case evidenceBlock
    case parserRun
    case ftsIndex
    case vectorIndex
    case custody
}

/// An exact basis reference — the canonical row that justifies a dimension's recorded state.
public nonisolated struct SourceReadinessBasis: Sendable, Codable, Hashable {
    public let kind: SourceReadinessBasisKind
    public let identifier: String
    public nonisolated init(kind: SourceReadinessBasisKind, identifier: String) {
        self.kind = kind
        self.identifier = identifier
    }
}

// MARK: - Persisted dimension record

/// One persisted readiness dimension for an exact source version.
public nonisolated struct SourceReadinessDimensionRecord: Sendable, Codable, Hashable {
    public let sourceVersionID: UUID
    public let dimension: SourceReadinessDimension
    public let state: SourceReadinessDimensionState
    public let applicability: SourceReadinessApplicability
    public let condition: SourceReadinessCondition?
    public let completedUnits: Int?
    public let totalUnits: Int?
    public let producerID: String
    public let producerVersion: String
    public let basis: SourceReadinessBasis?
    public let detail: String?
    public let revision: Int
    public let updatedAt: Date

    public nonisolated init(
        sourceVersionID: UUID, dimension: SourceReadinessDimension, state: SourceReadinessDimensionState,
        applicability: SourceReadinessApplicability, condition: SourceReadinessCondition?,
        completedUnits: Int?, totalUnits: Int?, producerID: String, producerVersion: String,
        basis: SourceReadinessBasis?, detail: String?, revision: Int, updatedAt: Date
    ) {
        self.sourceVersionID = sourceVersionID
        self.dimension = dimension
        self.state = state
        self.applicability = applicability
        self.condition = condition
        self.completedUnits = completedUnits
        self.totalUnits = totalUnits
        self.producerID = producerID
        self.producerVersion = producerVersion
        self.basis = basis
        self.detail = detail
        self.revision = revision
        self.updatedAt = updatedAt
    }

    /// True unless the dimension is `notApplicable` (a positive irrelevance, not a limitation).
    public var isApplicable: Bool { applicability != .notApplicable }

    /// Whether this dimension contributes usable, present content (not empty/blocked/failed).
    public var hasPresentContent: Bool {
        switch state {
        case .ready: return totalUnits == nil || (totalUnits ?? 0) > 0
        case .partial: return (completedUnits ?? 0) > 0
        default: return false
        }
    }
}

// MARK: - Caller update input

/// One dimension update a producer submits. The overall completion state is NEVER part of this —
/// callers move individual dimensions; the aggregate completion is derived.
public nonisolated struct SourceReadinessDimensionUpdate: Sendable, Hashable {
    public let dimension: SourceReadinessDimension
    public let state: SourceReadinessDimensionState
    public let applicability: SourceReadinessApplicability
    public let condition: SourceReadinessCondition?
    public let completedUnits: Int?
    public let totalUnits: Int?
    public let basis: SourceReadinessBasis?
    public let detail: String?
    public let action: SourceReadinessAction

    public nonisolated init(
        dimension: SourceReadinessDimension, state: SourceReadinessDimensionState, action: SourceReadinessAction,
        applicability: SourceReadinessApplicability = .required, condition: SourceReadinessCondition? = nil,
        completedUnits: Int? = nil, totalUnits: Int? = nil, basis: SourceReadinessBasis? = nil,
        detail: String? = nil
    ) {
        self.dimension = dimension
        self.state = state
        self.applicability = applicability
        self.condition = condition
        self.completedUnits = completedUnits
        self.totalUnits = totalUnits
        self.basis = basis
        self.detail = detail
        self.action = action
    }
}

/// A plan updating one or more dimensions of a source version atomically, under optimistic CAS.
public nonisolated struct SourceReadinessUpdatePlan: Sendable, Hashable {
    public let sourceVersionID: UUID
    public let expectedRevision: Int
    public let updates: [SourceReadinessDimensionUpdate]
    public let producerID: String
    public let producerVersion: String
    public let occurredAt: Date

    public nonisolated init(
        sourceVersionID: UUID, expectedRevision: Int, updates: [SourceReadinessDimensionUpdate],
        producerID: String, producerVersion: String, occurredAt: Date
    ) {
        self.sourceVersionID = sourceVersionID
        self.expectedRevision = expectedRevision
        self.updates = updates
        self.producerID = producerID
        self.producerVersion = producerVersion
        self.occurredAt = occurredAt
    }
}

// MARK: - Derived snapshot

/// A limitation the user should see: an applicable dimension that is not fully ready.
public nonisolated struct SourceReadinessLimitation: Sendable, Codable, Hashable {
    public let dimension: SourceReadinessDimension
    public let state: SourceReadinessDimensionState
    public let detail: String?
    public nonisolated init(dimension: SourceReadinessDimension, state: SourceReadinessDimensionState, detail: String?) {
        self.dimension = dimension
        self.state = state
        self.detail = detail
    }
}

/// A blocker: a dimension held back by an explicit blocking condition.
public nonisolated struct SourceReadinessBlocker: Sendable, Codable, Hashable {
    public let dimension: SourceReadinessDimension
    public let condition: SourceReadinessCondition
    public let detail: String?
    public nonisolated init(dimension: SourceReadinessDimension, condition: SourceReadinessCondition, detail: String?) {
        self.dimension = dimension
        self.condition = condition
        self.detail = detail
    }
}

/// The deterministic evaluation of a source version's ten dimensions. Deliberately carries NO
/// single overall percentage — coverage is per-dimension only.
public nonisolated struct SourceReadinessSnapshot: Sendable, Hashable {
    public let sourceVersionID: UUID
    public let aggregateRevision: Int
    public let dimensions: [SourceReadinessDimensionRecord]     // exactly 10, ordinal order
    public let completionState: SourceCompletionState
    public let isSearchReady: Bool
    public let isEvidenceReady: Bool
    public let isAnalyticallyReady: Bool
    public let limitations: [SourceReadinessLimitation]
    public let blockers: [SourceReadinessBlocker]
    public let updatedAt: Date

    public nonisolated init(
        sourceVersionID: UUID, aggregateRevision: Int, dimensions: [SourceReadinessDimensionRecord],
        completionState: SourceCompletionState, isSearchReady: Bool, isEvidenceReady: Bool,
        isAnalyticallyReady: Bool, limitations: [SourceReadinessLimitation],
        blockers: [SourceReadinessBlocker], updatedAt: Date
    ) {
        self.sourceVersionID = sourceVersionID
        self.aggregateRevision = aggregateRevision
        self.dimensions = dimensions
        self.completionState = completionState
        self.isSearchReady = isSearchReady
        self.isEvidenceReady = isEvidenceReady
        self.isAnalyticallyReady = isAnalyticallyReady
        self.limitations = limitations
        self.blockers = blockers
        self.updatedAt = updatedAt
    }

    /// The record for a dimension, if present.
    public func dimension(_ d: SourceReadinessDimension) -> SourceReadinessDimensionRecord? {
        dimensions.first { $0.dimension == d }
    }
}
