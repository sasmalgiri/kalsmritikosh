//
//  WorkflowStepPayloadCodecTests.swift
//  KalsmritikoshTests
//
//  PJE-006A — Canonical JSON serialization and SHA-256 integrity.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PJE-006A — WorkflowStepPayloadCodec")
struct WorkflowStepPayloadCodecTests {

    // MARK: - Encoder

    @Test("makeEncoder uses sortedKeys")
    func encoderSortsKeys() throws {
        struct Payload: Encodable, Sendable { let z: Int; let a: Int }
        let json = try WorkflowStepPayloadCodec.encode(Payload(z: 2, a: 1))
        // sorted keys → "a" before "z"
        let aPos = try #require(json.range(of: "\"a\""))
        let zPos = try #require(json.range(of: "\"z\""))
        #expect(aPos.lowerBound < zPos.lowerBound)
    }

    // MARK: - Canonicalize

    @Test("canonicalize reorders JSON keys deterministically")
    func canonicalizeKeyOrder() throws {
        let unordered = "{\"z\":2,\"a\":1}"
        let canonical = try WorkflowStepPayloadCodec.canonicalize(unordered)
        let reordered = String(data: canonical, encoding: .utf8) ?? ""
        let aPos = try #require(reordered.range(of: "\"a\""))
        let zPos = try #require(reordered.range(of: "\"z\""))
        #expect(aPos.lowerBound < zPos.lowerBound)
    }

    @Test("canonicalize on invalid JSON throws")
    func canonicalizeInvalidJSON() {
        #expect(throws: (any Error).self) {
            _ = try WorkflowStepPayloadCodec.canonicalize("not-json")
        }
    }

    // MARK: - Hash

    @Test("hashString returns 64-character lowercase hex")
    func hashStringFormat() throws {
        let data = Data("hello".utf8)
        let hex = WorkflowStepPayloadCodec.hashString(canonicalJSON: data)
        #expect(hex.count == 64)
        #expect(hex == hex.lowercased())
        #expect(hex.allSatisfy { $0.isHexDigit })
    }

    @Test("hashJSON is deterministic for same input")
    func hashJSONDeterministic() throws {
        let json = "{\"key\":\"value\"}"
        let h1 = try WorkflowStepPayloadCodec.hashJSON(json)
        let h2 = try WorkflowStepPayloadCodec.hashJSON(json)
        #expect(h1 == h2)
    }

    @Test("hashJSON differs for different content")
    func hashJSONDiffers() throws {
        let h1 = try WorkflowStepPayloadCodec.hashJSON("{\"a\":1}")
        let h2 = try WorkflowStepPayloadCodec.hashJSON("{\"a\":2}")
        #expect(h1 != h2)
    }

    // MARK: - Encode / Decode roundtrip

    @Test("encode/decode roundtrip preserves value")
    func encodeDecodeRoundtrip() throws {
        struct Payload: Codable, Sendable, Equatable { let name: String; let count: Int }
        let original = Payload(name: "test", count: 42)
        let json = try WorkflowStepPayloadCodec.encode(original)
        let decoded = try WorkflowStepPayloadCodec.decode(Payload.self, from: json)
        #expect(decoded == original)
    }

    @Test("decode invalid JSON throws malformedStateJSON")
    func decodeInvalidJSON() {
        struct Dummy: Codable, Sendable {}
        #expect(throws: (any Error).self) {
            _ = try WorkflowStepPayloadCodec.decode(Dummy.self, from: "not-json{{{")
        }
    }

    @Test("key-order differences in JSON produce same hash after canonicalize")
    func sameContentDifferentOrderSameHash() throws {
        let j1 = "{\"z\":2,\"a\":1}"
        let j2 = "{\"a\":1,\"z\":2}"
        let h1 = try WorkflowStepPayloadCodec.hashJSON(j1)
        let h2 = try WorkflowStepPayloadCodec.hashJSON(j2)
        #expect(h1 == h2)
    }
}
