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
    var supportedTypes: Set<SourceType> { get }

    /// Read the file at `url` (already resolved through a security-scoped
    /// bookmark) and return a fully-populated KnowledgeObject. Throws if
    /// the file can't be read or parsed. Must not write to the database.
    func ingest(fileAt url: URL, type: SourceType) async throws -> KnowledgeObject
}

public enum IngestorError: Error, Sendable {
    case unsupportedType(SourceType)
    case unreadable(URL, underlying: Error?)
    case parseFailure(URL, reason: String)
    case empty(URL)
}
