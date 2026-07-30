//
//  WorkflowProvenanceCodec.swift
//  Kalsmritikosh
//
//  PJE-007 — deterministic serialization + integrity hashing for provenance
//  snapshots. The hash rule is the SAME contract as PJE-006B.1:
//
//      snapshot_sha256 = SHA-256 of the exact UTF-8 bytes stored in snapshot_json
//
//  via WorkflowPersistedJSONIntegrity — no third JSON-hash interpretation.
//

import Foundation

public nonisolated struct EncodedWorkflowProvenanceSnapshot: Sendable, Equatable {
    public let json: String
    public let sha256: String

    public nonisolated init(json: String, sha256: String) {
        self.json = json
        self.sha256 = sha256
    }
}

public enum WorkflowProvenanceCodec {

    /// UTF-8 JSON, sorted keys, ISO-8601 dates, no pretty printing; reference
    /// array order preserved. Hash = exact stored bytes.
    public static nonisolated func encode(
        _ snapshot: WorkflowProvenanceSnapshot
    ) throws -> EncodedWorkflowProvenanceSnapshot {
        try snapshot.validateStructure()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        guard let json = String(data: data, encoding: .utf8) else {
            throw WorkflowProvenanceError.invalidLocatorJSON
        }
        let sha256 = try WorkflowPersistedJSONIntegrity.sha256(storedJSON: json)
        return EncodedWorkflowProvenanceSnapshot(json: json, sha256: sha256)
    }

    /// Decode a stored snapshot, verifying the stored-byte hash FIRST.
    /// `snapshotID` identifies the stored row in thrown integrity errors.
    public static nonisolated func decodeAndVerify(
        json: String,
        expectedSHA256: String,
        snapshotID: UUID = UUID()
    ) throws -> WorkflowProvenanceSnapshot {
        let computed = WorkflowPersistedJSONIntegrity.rawSHA256(of: json)
        guard computed == expectedSHA256 else {
            throw WorkflowProvenanceError.snapshotHashMismatch(snapshotID)
        }
        guard let data = json.data(using: .utf8) else {
            throw WorkflowProvenanceError.invalidLocatorJSON
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(WorkflowProvenanceSnapshot.self, from: data)
        try snapshot.validateStructure()
        return snapshot
    }
}
