//
//  Ingestor.swift
//  Kalsmritikosh
//
//  Protocol for everything that turns bytes on disk into KnowledgeObjects.
//  Concrete loaders live under Ingestion/Loaders/ and the IngestCoordinator
//  multiplexes between them by SourceType.
//

import Foundation
import CryptoKit

public protocol Ingestor: Sendable {
    /// The source types this ingestor knows how to handle.
    nonisolated var supportedTypes: Set<SourceType> { get }

    /// Primary hardware resource this ingestor saturates. The
    /// `LaneScheduler` uses this to fan files across independent
    /// lanes so a 4-PDF burst doesn't stall a 1-image OCR job.
    /// Default `.cpu`; loaders that hit Neural Engine / GPU / Disk-I/O
    /// override.
    nonisolated var primaryLane: ResourceLane { get }

    /// Read the file at `url` (already resolved through a security-scoped
    /// bookmark) and return a fully-populated KnowledgeObject. Throws if
    /// the file can't be read or parsed. Must not write to the database.
    func ingest(fileAt url: URL, type: SourceType) async throws -> KnowledgeObject

    /// Read the file at `url` and return one OR MORE KnowledgeObjects.
    /// Default impl wraps `ingest` in a single-element array. Loaders
    /// for archive-shaped formats (mbox, PST, …) override to return one
    /// KO per logical record. T13.1.
    func ingestMany(fileAt url: URL, type: SourceType) async throws -> [KnowledgeObject]
}

extension Ingestor {
    public var primaryLane: ResourceLane { .cpu }

    public func ingestMany(fileAt url: URL, type: SourceType) async throws -> [KnowledgeObject] {
        [try await ingest(fileAt: url, type: type)]
    }
}

/// F01 — how much of a record stream may be resident at once. A batch is flushed as soon as
/// EITHER ceiling is reached, so one oversized record still travels alone rather than stalling.
public struct StreamBatchBudget: Sendable, Equatable {
    public let maxObjects: Int
    public let maxContentBytes: Int
    /// F01/F12 — the largest single record the pipeline will process. A record above it is not
    /// committed: its outcome is `failed` with the reason (custody kept), so raising the budget and
    /// retrying recovers it. A record can never be split, so this is the per-record ceiling.
    public let maxRecordBytes: Int

    public nonisolated init(maxObjects: Int, maxContentBytes: Int, maxRecordBytes: Int = 256 * 1024 * 1024) {
        self.maxObjects = max(1, maxObjects)
        self.maxContentBytes = max(1, maxContentBytes)
        self.maxRecordBytes = max(1, maxRecordBytes)
    }

    public nonisolated static let standard = StreamBatchBudget(maxObjects: 64, maxContentBytes: 8 * 1024 * 1024)
}

/// F01 — an Ingestor for a many-record format that can hand its records over in bounded
/// batches instead of materialising every record of the file at once. `ingestMany` stays
/// the reference path; a streamed run must emit exactly the records it would return, in
/// the same order, with the same metadata.
public protocol StreamingIngestor: Ingestor {
    /// Whether `type` streams under the current configuration. False when producing a record
    /// needs the whole file first (e.g. mbox thread coalescing groups across the archive).
    nonisolated func streamsRecords(type: SourceType) -> Bool

    /// Emit every record of the file in order, `budget` bounding each batch. Only one batch
    /// is resident in the loader at a time; `emit` may persist and drop it before the next.
    func streamRecords(fileAt url: URL, type: SourceType, budget: StreamBatchBudget,
                       emit: ([KnowledgeObject]) async throws -> Void) async throws
}

/// F04 — how much of a resumable source ONE run processes. This is a work budget, not a completeness
/// limit: units beyond it are deferred (counted, resumable from a durable cursor), never dropped.
public struct ResumableStreamBudget: Sendable, Equatable {
    /// Units (e.g. table rows) one run may process across all scopes.
    public let unitsPerRun: Int
    /// Units per record — one KnowledgeObject plus the evidence blocks it owns.
    public let unitsPerRecord: Int

    public nonisolated init(unitsPerRun: Int, unitsPerRecord: Int) {
        self.unitsPerRun = max(1, unitsPerRun)
        self.unitsPerRecord = max(1, unitsPerRecord)
    }

    public nonisolated static let standard = ResumableStreamBudget(unitsPerRun: 1_000_000, unitsPerRecord: 500)
}

/// F05 — one citable unit produced WITH a streamed record (not by a later whole-file parse).
/// `identity` is stable for the version's exact acquired bytes, so a redo of the same record
/// yields the same block.
public struct StreamedEvidence: Sendable {
    public let identity: String
    public let ordinal: Int
    public let kind: EvidenceBlockKind
    public let rawText: String
    public let locator: SourceLocator
    public let attributes: [String: AnyCodable]

    public nonisolated init(identity: String, ordinal: Int, kind: EvidenceBlockKind, rawText: String,
                            locator: SourceLocator, attributes: [String: AnyCodable]) {
        self.identity = identity; self.ordinal = ordinal; self.kind = kind
        self.rawText = rawText; self.locator = locator; self.attributes = attributes
    }

    /// The block id of an evidence unit of a source version: deterministic, so a redo of the same record
    /// (same bytes, same cursor) re-derives the same citation identity instead of a duplicate.
    public nonisolated static func blockID(sourceVersionID: UUID, identity: String) -> UUID {
        let digest = Array(SHA256.hash(data: Data("\(sourceVersionID.uuidString)|\(identity)".utf8)))
        var b = Array(digest.prefix(16))
        b[6] = (b[6] & 0x0F) | 0x50   // name-based UUID layout
        b[8] = (b[8] & 0x3F) | 0x80
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}

/// F04/F05 — one record of a resumable stream: its object, the evidence it owns, and where the
/// scope's walk stands once it commits.
public struct ResumableRecord: Sendable {
    public let object: KnowledgeObject
    /// The continuation scope (e.g. one table) and its index in the source's scope order.
    public let scope: String
    public let scopeIndex: Int
    /// Stable within the version: the same record read from the same cursor has the same position.
    public let position: Int
    /// Opaque continuation after this record — persisted ONLY together with the record's commit.
    public let cursorAfter: String
    /// Units of `scope` processed once this record commits.
    public let unitsAfter: Int
    /// Evidence the object owns (e.g. its rows).
    public let evidence: [StreamedEvidence]
    /// Evidence of the scope itself (e.g. the table header), owned by no single record.
    public let scopeEvidence: [StreamedEvidence]
}

/// F04 — a scope's size, discovered on every run (units = e.g. rows).
public struct ResumableScopeTotal: Sendable, Equatable {
    public let scope: String
    public let scopeIndex: Int
    public let discovered: Int
}

/// F04/F05 — a StreamingIngestor whose walk can stop at a work budget and continue from a durable
/// cursor over the SAME acquired bytes, producing each record's evidence alongside it.
public protocol ResumableStreamingIngestor: StreamingIngestor {
    nonisolated func resumes(type: SourceType) -> Bool
    /// What one unit is, for coverage copy ("rows").
    nonisolated var unitNoun: String { get }

    /// Walk the file from `resume` (scope → cursor from a previous run; absent = from the start),
    /// processing at most `budget.unitsPerRun` units. `emit` returns false to stop the run (the
    /// record was not committed; its cursor is not advanced). Returns every scope's discovered size.
    func streamResumable(fileAt url: URL, type: SourceType, budget: ResumableStreamBudget,
                         resume: [String: String],
                         emit: (ResumableRecord) async throws -> Bool) async throws -> [ResumableScopeTotal]
}

/// F01 — accumulates records up to a `StreamBatchBudget` and hands back a full batch.
struct KnowledgeObjectBatcher {
    let budget: StreamBatchBudget
    private var pending: [KnowledgeObject] = []
    private var pendingBytes = 0

    nonisolated init(budget: StreamBatchBudget) { self.budget = budget }

    /// Adds `object`; returns the batch to flush when a ceiling is reached, else nil.
    nonisolated mutating func add(_ object: KnowledgeObject) -> [KnowledgeObject]? {
        pending.append(object)
        pendingBytes += object.content.utf8.count
        guard pending.count >= budget.maxObjects || pendingBytes >= budget.maxContentBytes else { return nil }
        return drain()
    }

    /// Returns whatever is pending (nil when empty) and resets.
    nonisolated mutating func drain() -> [KnowledgeObject]? {
        guard !pending.isEmpty else { return nil }
        defer { pending = []; pendingBytes = 0 }
        return pending
    }
}

public enum IngestorError: Error, Sendable {
    case unsupportedType(SourceType)
    case unreadable(URL, underlying: Error?)
    case parseFailure(URL, reason: String)
    case empty(URL)
    /// A4 (module .passwordProtectedFiles) — the source is encrypted and needs a
    /// user-supplied password to open. Distinct from `unreadable` so the file is
    /// tracked as "needs password" instead of a silent parse failure.
    case passwordProtected(URL)
}
