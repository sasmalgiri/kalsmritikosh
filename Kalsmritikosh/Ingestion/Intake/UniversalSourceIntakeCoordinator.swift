//
//  UniversalSourceIntakeCoordinator.swift
//  Kalsmritikosh
//
//  USF-001 — the single public façade the ingest pipeline calls BEFORE any loader/parser.
//  It captures a file's bytes (streaming SHA-256 + stable snapshot) and resolves canonical
//  custody through the atomic CanonicalSourceIntakeRepository, returning the durable
//  SourceIntakeHandle. Type detection and custody decisions live below it; this is only
//  the ordering guarantee: custody first, understanding later.
//

import Foundation

public struct UniversalSourceIntakeCoordinator: Sendable {

    private let repository: CanonicalSourceIntakeRepository

    public init(repository: CanonicalSourceIntakeRepository) {
        self.repository = repository
    }

    /// Capture an ACCESSIBLE file's bytes and resolve its canonical source + version
    /// custody, atomically. Throws a typed `SourceIntakeError` when the input is not a
    /// regular file, cannot be read, or changed during capture — the caller records a
    /// by-URL access failure and never fabricates a hash or a fake source version.
    public func admit(url: URL, custodyMode: SourceCustodyMode = .referenced,
                      parent: SourceParentReference? = nil, now: Date) async throws -> SourceIntakeHandle {
        let captured = try SourceByteCapture.capture(url)
        let request = SourceIntakeRequest(url: url, custodyMode: custodyMode, parent: parent, recordedAt: now)
        return try await repository.intake(request: request, captured: captured)
    }
}
