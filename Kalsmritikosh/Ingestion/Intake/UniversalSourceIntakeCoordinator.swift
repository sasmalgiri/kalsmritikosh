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
    ///
    /// USF-001.2 — the same verified pass that computes the intake SHA-256 writes an immutable
    /// processing snapshot; the returned handle carries its URL so the loader and structural
    /// parser consume exactly those bytes. The caller (IngestCoordinator) owns the snapshot's
    /// lifetime and removes its containing directory after processing.
    public func admit(url: URL, custodyMode: SourceCustodyMode = .referenced,
                      parent: SourceParentReference? = nil, now: Date) async throws -> SourceIntakeHandle {
        let snapshotDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("usf-intake-snapshot", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let (captured, snapshotURL) = try SourceByteCapture.captureToSnapshot(url, snapshotDirectory: snapshotDir)
        let request = SourceIntakeRequest(url: url, custodyMode: custodyMode, parent: parent, recordedAt: now)
        do {
            let handle = try await repository.intake(request: request, captured: captured, snapshotURL: snapshotURL)
            return handle.withProcessingSnapshot(snapshotURL)
        } catch {
            // Custody resolution failed — the snapshot has no owner, so remove it now.
            try? FileManager.default.removeItem(at: snapshotDir)
            throw error
        }
    }
}
