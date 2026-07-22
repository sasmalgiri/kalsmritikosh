//
//  EvidenceVaultTests.swift
//  KalsmritikoshTests
//
//  EV-005 — the managed-mode content-addressed vault stores immutable copies, dedups
//  identical bytes, reopens exact original bytes, reports size, and deletes only on
//  explicit request.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("EvidenceVault (EV-005)")
struct EvidenceVaultTests {

    private func freshVault() -> EvidenceVault {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vault-\(UUID().uuidString)", isDirectory: true)
        return EvidenceVault(root: root)
    }

    @Test("Store returns the content address and reopens exact bytes")
    func storeReopen() async throws {
        let vault = freshVault()
        let bytes = Data("evidence bytes \(UUID())".utf8)
        let hash = try await vault.store(bytes)
        #expect(hash == EvidenceVault.address(for: bytes))
        #expect(await vault.contains(hash))
        #expect(await vault.data(for: hash) == bytes)
        #expect(await vault.url(for: hash) != nil)
    }

    @Test("Identical bytes dedup to one entry; different bytes are separate")
    func dedup() async throws {
        let vault = freshVault()
        let a = Data("same".utf8)
        let h1 = try await vault.store(a)
        let sizeAfterFirst = await vault.totalBytes()
        let h2 = try await vault.store(a)          // same bytes again
        #expect(h1 == h2)
        #expect(await vault.totalBytes() == sizeAfterFirst)   // no growth
        #expect(await vault.estimatedAddedBytes(for: a) == 0) // already vaulted
        _ = try await vault.store(Data("different".utf8))
        #expect(await vault.totalBytes() > sizeAfterFirst)
    }

    @Test("Explicit remove deletes the copy; missing hash reopens nil")
    func remove() async throws {
        let vault = freshVault()
        let hash = try await vault.store(Data("removable".utf8))
        try await vault.remove(hash)
        #expect(!(await vault.contains(hash)))
        #expect(await vault.data(for: hash) == nil)
        try await vault.remove(hash)   // no-op, no throw
    }
}
