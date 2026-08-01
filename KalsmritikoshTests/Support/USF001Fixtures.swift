//
//  USF001Fixtures.swift
//  KalsmritikoshTests
//
//  USF-001 — shared rig for universal safe intake tests. Builds a v82 database, a temp
//  working directory for REAL synthetic files, and an EvidenceVault. Synthetic sources
//  only — never real personal or customer data.
//

import Foundation
@testable import Kalsmritikosh

struct USFRig {
    let db: Database
    let repo: CanonicalSourceIntakeRepository
    let vault: EvidenceVault
    let dir: URL
    let dbURL: URL
    static let t0 = Date(timeIntervalSince1970: 1_753_900_000)
}

enum USF001Fixtures {
    static let t0 = USFRig.t0

    static func makeRig(withVault: Bool = true,
                        atVersion version: Int = SchemaMigrations.latestVersion) async throws -> USFRig {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("usf001-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let dbURL = base.appendingPathComponent("intake.sqlite")
        let db = try await MigrationFixtureBuilder.database(atVersion: version, at: dbURL)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let vault = EvidenceVault(root: base.appendingPathComponent("vault", isDirectory: true))
        let repo = CanonicalSourceIntakeRepository(database: db, vault: withVault ? vault : nil)
        return USFRig(db: db, repo: repo, vault: vault, dir: base, dbURL: dbURL)
    }

    /// Write a real synthetic file into the rig's working directory and return its URL.
    @discardableResult
    static func writeFile(_ rig: USFRig, name: String, bytes: Data) throws -> URL {
        let url = rig.dir.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    /// Capture + intake a file in one step (reference mode by default).
    @discardableResult
    static func intake(_ rig: USFRig, url: URL, custody: SourceCustodyMode = .referenced,
                       parent: SourceParentReference? = nil, at: Date = t0) async throws -> SourceIntakeHandle {
        let captured = try SourceByteCapture.capture(url)
        let request = SourceIntakeRequest(url: url, custodyMode: custody, parent: parent, recordedAt: at)
        return try await rig.repo.intake(request: request, captured: captured)
    }

    /// USF-001.2 — capture a file through the immutable processing snapshot (as the coordinator
    /// does) and intake it, passing the snapshot so managed custody copies the exact captured
    /// bytes. Returns the handle (its `processingSnapshotURL` points at the live snapshot).
    @discardableResult
    static func intakeWithSnapshot(_ rig: USFRig, url: URL, custody: SourceCustodyMode = .referenced,
                                   at: Date = t0) async throws -> SourceIntakeHandle {
        let snapDir = rig.dir.appendingPathComponent("snap-\(UUID().uuidString)", isDirectory: true)
        let (captured, snapshotURL) = try SourceByteCapture.captureToSnapshot(url, snapshotDirectory: snapDir)
        let request = SourceIntakeRequest(url: url, custodyMode: custody, parent: nil, recordedAt: at)
        return try await rig.repo.intake(request: request, captured: captured, snapshotURL: snapshotURL)
    }

    static func bytes(_ s: String) -> Data { Data(s.utf8) }

    /// A tiny valid PNG header (magic-byte sniffing recognises image/png).
    static func pngBytes() -> Data {
        Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + Array(repeating: 0x00, count: 32))
    }
}
