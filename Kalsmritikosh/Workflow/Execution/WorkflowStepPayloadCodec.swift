//
//  WorkflowStepPayloadCodec.swift
//  Kalsmritikosh
//
//  PJE-006A — Step Executor Runtime and Working-Surface Pack.
//  Canonical JSON serialization and SHA-256 payload integrity for step state envelopes.
//  Mirrors WorkflowRunSnapshotCodec conventions.
//

import Foundation
import CryptoKit

public enum WorkflowStepPayloadCodec {

    // MARK: - Encoder / Decoder

    public static nonisolated func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    public static nonisolated func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    // MARK: - Canonical JSON

    /// Re-encodes arbitrary JSON through JSONSerialization with `.sortedKeys` to
    /// produce a deterministic byte representation for hashing.
    public static nonisolated func canonicalize(_ json: String) throws -> Data {
        guard let data = json.data(using: .utf8) else {
            throw WorkflowStepExecutionError.malformedStateJSON
        }
        let obj = try JSONSerialization.jsonObject(with: data, options: [])
        return try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    }

    // MARK: - Hash

    /// SHA-256 of the canonical JSON bytes, returned as lowercase hex.
    public static nonisolated func hashString(canonicalJSON: Data) -> String {
        let digest = SHA256.hash(data: canonicalJSON)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Convenience: canonicalize then hash a JSON string.
    public static nonisolated func hashJSON(_ json: String) throws -> String {
        let canonical = try canonicalize(json)
        return hashString(canonicalJSON: canonical)
    }

    // MARK: - Encode typed value to JSON string

    public static nonisolated func encode<T: Encodable>(_ value: T) throws -> String {
        let data = try makeEncoder().encode(value)
        guard let json = String(data: data, encoding: .utf8) else {
            throw WorkflowStepExecutionError.malformedStateJSON
        }
        return json
    }

    // MARK: - Decode JSON string to typed value

    public static nonisolated func decode<T: Decodable>(
        _ type: T.Type,
        from json: String
    ) throws -> T {
        guard let data = json.data(using: .utf8) else {
            throw WorkflowStepExecutionError.malformedStateJSON
        }
        return try makeDecoder().decode(type, from: data)
    }
}
