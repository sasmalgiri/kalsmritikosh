//
//  WorkflowProvenanceCodecTests.swift
//  KalsmritikoshTests
//
//  PJE-007 Part M §34 — deterministic snapshot serialization + the stored-byte
//  hash rule (snapshot_sha256 = SHA-256 of the exact stored UTF-8 JSON bytes,
//  the PJE-006B.1 contract; no third hash interpretation).
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PJE-007 — provenance codec")
@MainActor
struct WorkflowProvenanceCodecTests {

    private let runID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let ownerID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let refA = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    private let refB = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!

    private func makeSnapshot(
        references: [WorkflowProvenanceReference]? = nil
    ) -> WorkflowProvenanceSnapshot {
        WorkflowProvenanceSnapshot(
            ownerKind: .stepState,
            workflowRunID: runID,
            ownerID: ownerID,
            workflowRunRevision: 3,
            producerID: "com.kalsmritikosh.step.select-evidence",
            producerVersion: "1",
            sourceStateSHA256: String(repeating: "a", count: 64),
            references: references ?? [
                WorkflowProvenanceReference(
                    kind: .claim, canonicalObjectID: refA, role: .selected,
                    locatorJSON: #"{"page":3,"line":12}"#, label: "claim A"),
                WorkflowProvenanceReference(
                    kind: .sourceVersion, canonicalObjectID: refB, role: .supporting,
                    sourceVersionID: refB, note: "supporting version")
            ])
    }

    @Test("The same snapshot encodes to byte-identical JSON")
    func sameSnapshotProducesIdenticalJSON() throws {
        let first = try WorkflowProvenanceCodec.encode(makeSnapshot())
        let second = try WorkflowProvenanceCodec.encode(makeSnapshot())
        #expect(first.json == second.json)
    }

    @Test("The same snapshot produces an identical hash, computed from the exact stored bytes")
    func sameSnapshotProducesIdenticalStoredByteHash() throws {
        let first = try WorkflowProvenanceCodec.encode(makeSnapshot())
        let second = try WorkflowProvenanceCodec.encode(makeSnapshot())
        #expect(first.sha256 == second.sha256)
        // The ONE hash rule: SHA-256 of the exact stored UTF-8 JSON bytes.
        #expect(first.sha256 == WorkflowPersistedJSONIntegrity.rawSHA256(of: first.json))
    }

    @Test("Reference order is preserved through encode and decode")
    func referenceOrderIsPreserved() throws {
        let encoded = try WorkflowProvenanceCodec.encode(makeSnapshot())
        let decoded = try WorkflowProvenanceCodec.decodeAndVerify(
            json: encoded.json, expectedSHA256: encoded.sha256)
        #expect(decoded.references.count == 2)
        #expect(decoded.references[0].canonicalObjectID == refA)
        #expect(decoded.references[1].canonicalObjectID == refB)
        // Order is also visible in the stored bytes themselves.
        let indexA = try #require(encoded.json.range(of: refA.uuidString)).lowerBound
        let indexB = try #require(encoded.json.range(of: refB.uuidString)).lowerBound
        #expect(indexA < indexB)
    }

    @Test("Locator JSON is stored verbatim and the encoded output stays deterministic")
    func locatorJSONIsDeterministic() throws {
        let locator = #"{"b":2,"a":1,"nested":{"z":true,"y":false}}"#
        let reference = WorkflowProvenanceReference(
            kind: .evidenceBlock, canonicalObjectID: refA,
            role: .contextual, locatorJSON: locator)
        let first = try WorkflowProvenanceCodec.encode(makeSnapshot(references: [reference]))
        let second = try WorkflowProvenanceCodec.encode(makeSnapshot(references: [reference]))
        #expect(first.json == second.json)
        let decoded = try WorkflowProvenanceCodec.decodeAndVerify(
            json: first.json, expectedSHA256: first.sha256)
        // Verbatim: the caller's key order inside the locator string is untouched.
        #expect(decoded.references[0].locatorJSON == locator)
    }

    @Test("Tampered snapshot JSON fails the stored-byte hash check")
    func tamperedJSONFails() throws {
        let encoded = try WorkflowProvenanceCodec.encode(makeSnapshot())
        let tampered = encoded.json.replacingOccurrences(of: "claim A", with: "claim B")
        #expect(tampered != encoded.json)
        #expect(throws: WorkflowProvenanceError.self) {
            _ = try WorkflowProvenanceCodec.decodeAndVerify(
                json: tampered, expectedSHA256: encoded.sha256)
        }
    }

    @Test("A tampered stored hash fails verification of intact JSON")
    func tamperedHashFails() throws {
        let encoded = try WorkflowProvenanceCodec.encode(makeSnapshot())
        let wrongHash = String(repeating: "0", count: 64)
        #expect(throws: WorkflowProvenanceError.self) {
            _ = try WorkflowProvenanceCodec.decodeAndVerify(
                json: encoded.json, expectedSHA256: wrongHash)
        }
    }

    @Test("Decoded owner identity is byte-exact — real IDs, never substituted")
    func ownerAndReferenceIDsRoundTripExactly() throws {
        let encoded = try WorkflowProvenanceCodec.encode(makeSnapshot())
        let decoded = try WorkflowProvenanceCodec.decodeAndVerify(
            json: encoded.json, expectedSHA256: encoded.sha256)
        #expect(decoded.ownerKind == .stepState)
        #expect(decoded.ownerID == ownerID)
        #expect(decoded.workflowRunID == runID)
        #expect(decoded.workflowRunRevision == 3)
        #expect(decoded.references.map(\.canonicalObjectID) == [refA, refB])
    }

    @Test("An empty provenance snapshot is valid and round-trips")
    func emptySnapshotIsValid() throws {
        let encoded = try WorkflowProvenanceCodec.encode(makeSnapshot(references: []))
        let decoded = try WorkflowProvenanceCodec.decodeAndVerify(
            json: encoded.json, expectedSHA256: encoded.sha256)
        #expect(decoded.references.isEmpty)
    }

    @Test("A blank producer identity is rejected")
    func blankProducerIdentityFails() {
        let snapshot = WorkflowProvenanceSnapshot(
            ownerKind: .artifact, workflowRunID: runID, ownerID: ownerID,
            workflowRunRevision: 1, producerID: "  ", producerVersion: "1",
            sourceStateSHA256: nil, references: [])
        #expect(throws: WorkflowProvenanceError.invalidProducerIdentity) {
            _ = try WorkflowProvenanceCodec.encode(snapshot)
        }
    }

    @Test("A step-state snapshot without a source-state hash is rejected")
    func stepStateSnapshotRequiresStateHash() {
        let snapshot = WorkflowProvenanceSnapshot(
            ownerKind: .stepState, workflowRunID: runID, ownerID: ownerID,
            workflowRunRevision: 1, producerID: "p", producerVersion: "1",
            sourceStateSHA256: nil, references: [])
        #expect(throws: WorkflowProvenanceError.snapshotStateHashMismatch(ownerID)) {
            _ = try WorkflowProvenanceCodec.encode(snapshot)
        }
    }

    @Test("A reference with malformed locator JSON is rejected")
    func malformedLocatorJSONFails() {
        let reference = WorkflowProvenanceReference(
            kind: .claim, canonicalObjectID: refA, role: .selected,
            locatorJSON: "{not json")
        #expect(throws: WorkflowProvenanceError.invalidLocatorJSON) {
            _ = try WorkflowProvenanceCodec.encode(makeSnapshot(references: [reference]))
        }
    }
}
