//
//  StructuralDigest.swift
//  Kalsmritikosh
//
//  Speed PERF-24 (owner 2026-11-23) — not tested yet. Intake hashes a file's bytes once, as it writes the
//  immutable processing snapshot. The structural parse of THOSE snapshot bytes used to hash them again. The
//  parser adapter now hands the intake digest down for the exact `Data` it passes (matched by byte count
//  and storage address, so a container member or any other buffer is still hashed); anything else is hashed
//  as before.
//

import CryptoKit
import Foundation

public nonisolated enum StructuralDigest {
    struct Known: Sendable {
        let hash: String
        let count: Int
        let base: UInt
    }

    @TaskLocal static var known: Known?

    private static func base(of data: Data) -> UInt {
        data.withUnsafeBytes { UInt(bitPattern: $0.baseAddress) }
    }

    /// Run `body` with `hash` recorded as the digest of exactly `data`.
    public static func withKnown<T>(_ hash: String, for data: Data, _ body: () async throws -> T) async rethrows -> T {
        let normalized = hash.lowercased()
        guard normalized.count == 64, normalized.allSatisfy(\.isHexDigit), data.count > 32 else { return try await body() }
        return try await $known.withValue(Known(hash: normalized, count: data.count, base: base(of: data)), operation: body)
    }

    /// The lowercase SHA-256 of `data`: the intake digest when `data` is the buffer it was recorded for, else hashed.
    public static func sha256(_ data: Data) -> String {
        if let k = known, k.count == data.count, k.base != 0, k.base == base(of: data) { return k.hash }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
