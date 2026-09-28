//
//  Ingestor.swift
//  Kalsmritikosh
//
//  Protocol for everything that turns bytes on disk into KnowledgeObjects.
//  Concrete loaders live under Ingestion/Loaders/ and the IngestCoordinator
//  multiplexes between them by SourceType.
//

import Foundation

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

    public nonisolated init(maxObjects: Int, maxContentBytes: Int) {
        self.maxObjects = max(1, maxObjects)
        self.maxContentBytes = max(1, maxContentBytes)
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
