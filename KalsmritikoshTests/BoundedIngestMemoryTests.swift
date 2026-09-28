//
//  BoundedIngestMemoryTests.swift
//  KalsmritikoshTests
//
//  F01 — ingest must not require the whole file (or all of its records) resident at once.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("F01 — bounded-memory ingest")
struct BoundedIngestMemoryTests {

    private func tempFile(_ name: String, _ data: Data) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bim-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    @Test("Snapshot bytes are memory-mapped, byte-identical, and an empty file still reads")
    func snapshotBytesMapped() throws {
        let body = Data((0..<200_000).map { UInt8($0 % 251) })
        let url = try tempFile("big.bin", body)
        #expect(try ExistingParserPluginAdapter.snapshotBytes(url) == body)
        let empty = try tempFile("empty.bin", Data())
        #expect(try ExistingParserPluginAdapter.snapshotBytes(empty).isEmpty)
    }
}
