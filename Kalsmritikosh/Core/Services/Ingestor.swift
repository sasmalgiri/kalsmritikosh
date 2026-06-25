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
    public func ingestMany(fileAt url: URL, type: SourceType) async throws -> [KnowledgeObject] {
        [try await ingest(fileAt: url, type: type)]
    }
}

public enum IngestorError: Error, Sendable {
    case unsupportedType(SourceType)
    case unreadable(URL, underlying: Error?)
    case parseFailure(URL, reason: String)
    case empty(URL)
}
