//
//  WorkflowRunSnapshotCodec.swift
//  Kalsmritikosh
//
//  PJE-003 — Canonical JSON encoder/decoder and SHA-256 hashing for
//  WorkflowRunContractSnapshot and WorkflowCheckpointPayload.
//
//  Encoding contract:
//    • JSONEncoder.outputFormatting = [.sortedKeys] — all object keys sorted
//    • dateEncodingStrategy = .iso8601 — deterministic timestamps
//    • SHA-256 via CryptoKit.SHA256, hex-string representation
//    • snapshotSchemaVersion = 1 for PJE-003 snapshots
//

import Foundation
import CryptoKit

// MARK: - Encoded contract

/// The wire output of `WorkflowRunSnapshotCodec.encode(_:)`.
public struct EncodedWorkflowRunContract: Sendable {
    public let json: String
    public let sha256: String

    public nonisolated init(json: String, sha256: String) {
        self.json = json
        self.sha256 = sha256
    }
}

// MARK: - Codec

public struct WorkflowRunSnapshotCodec: Sendable {

    public nonisolated init() {}

    // MARK: Contract encode/decode

    /// Encode a `WorkflowRunContractSnapshot` to canonical JSON + SHA-256.
    public nonisolated func encode(_ contract: WorkflowRunContractSnapshot) throws -> EncodedWorkflowRunContract {
        let data = try contractEncoder.encode(contract)
        guard let json = String(data: data, encoding: .utf8) else {
            throw WorkflowRunRepositoryError.snapshotEncodingFailed("contract JSON not valid UTF-8")
        }
        return EncodedWorkflowRunContract(json: json, sha256: Self.hashString(data))
    }

    /// Decode a previously encoded `WorkflowRunContractSnapshot` and verify its hash.
    public nonisolated func decode(json: String, expectedSHA256: String) throws -> WorkflowRunContractSnapshot {
        guard let data = json.data(using: .utf8) else {
            throw WorkflowRunRepositoryError.snapshotDecodingFailed("JSON is not valid UTF-8")
        }
        let actual = Self.hashString(data)
        guard actual == expectedSHA256 else {
            throw WorkflowRunRepositoryError.contractHashMismatch(stored: expectedSHA256, computed: actual)
        }
        do {
            return try contractDecoder.decode(WorkflowRunContractSnapshot.self, from: data)
        } catch {
            throw WorkflowRunRepositoryError.snapshotDecodingFailed("\(error)")
        }
    }

    // MARK: Checkpoint payload encode/decode

    /// Encode a `WorkflowCheckpointPayload` to canonical JSON + SHA-256.
    public nonisolated func encodeCheckpoint(_ payload: WorkflowCheckpointPayload) throws -> EncodedWorkflowRunContract {
        let data = try contractEncoder.encode(payload)
        guard let json = String(data: data, encoding: .utf8) else {
            throw WorkflowRunRepositoryError.snapshotEncodingFailed("checkpoint JSON not valid UTF-8")
        }
        return EncodedWorkflowRunContract(json: json, sha256: Self.hashString(data))
    }

    /// Decode a stored checkpoint payload JSON.
    public nonisolated func decodeCheckpoint(json: String) throws -> WorkflowCheckpointPayload {
        guard let data = json.data(using: .utf8) else {
            throw WorkflowRunRepositoryError.snapshotDecodingFailed("checkpoint JSON is not valid UTF-8")
        }
        do {
            return try contractDecoder.decode(WorkflowCheckpointPayload.self, from: data)
        } catch {
            throw WorkflowRunRepositoryError.snapshotDecodingFailed("\(error)")
        }
    }

    // MARK: - Shared encoder/decoder

    private nonisolated var contractEncoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private nonisolated var contractDecoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    // MARK: - Hashing

    /// SHA-256 of `data`, returned as a lowercase hex string.
    public nonisolated static func hashString(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
