//
//  WorkflowPersistedJSONIntegrity.swift
//  Kalsmritikosh
//
//  PJE-006B.1 — Unified Step-State Hash Contract.
//
//  THE rule for persisted step-state integrity:
//
//      state_sha256 = SHA-256 of the exact UTF-8 bytes stored in state_json
//
//  The persisted string is the integrity target. Verification needs no second
//  serializer, no canonicalization pass, and is immune to Foundation
//  serializer-order differences (JSONSerialization's .sortedKeys sorts keys
//  NUMERICALLY while JSONEncoder's .sortedKeys sorts by Unicode scalar — the
//  root cause of the PJE-006B hash-duality discovery).
//
//  All persisted step-state hashing (PJE-004 lifecycle completion, PJE-006A
//  preparation/progress, PJE-006B executor state, future PJE-006C state, and
//  repository reopen verification) routes through this one function.
//

import Foundation
import CryptoKit

// MARK: - Hash semantics

/// Which hash contract a persisted step-run row satisfies.
///
/// `legacyCanonicalizedJSON` covers all rows written before PJE-006B.1 — a mixed
/// historical population (raw-byte hashes from the lifecycle codec, canonicalized
/// hashes from remainActive saves). Legacy rows are verified best-effort and are
/// never rewritten by reopen; they upgrade to `storedUTF8BytesV1` only on the
/// next legitimate state mutation.
public enum WorkflowStepStateHashSemantics: String, Codable, Sendable, CaseIterable, Equatable {
    case legacyCanonicalizedJSON
    case storedUTF8BytesV1
}

// MARK: - Integrity function

public enum WorkflowPersistedJSONIntegrity {

    /// SHA-256 (lowercase hex) of the EXACT UTF-8 bytes of `storedJSON`.
    ///
    /// 1. Verifies `storedJSON` is syntactically valid JSON (fail closed).
    /// 2. Hashes the exact bytes — never parses-and-reserializes before hashing.
    public static nonisolated func sha256(storedJSON: String) throws -> String {
        guard let data = storedJSON.data(using: .utf8) else {
            throw WorkflowStepExecutionError.malformedStateJSON
        }
        do {
            _ = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw WorkflowStepExecutionError.malformedStateJSON
        }
        return rawSHA256(of: data)
    }

    /// SHA-256 (lowercase hex) of arbitrary bytes — no JSON validation.
    /// Used by verification paths where the write-time validation already ran
    /// and by legacy-row classification.
    public static nonisolated func rawSHA256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Convenience: raw-byte hash of a string without JSON validation.
    public static nonisolated func rawSHA256(of string: String) -> String {
        rawSHA256(of: string.data(using: .utf8) ?? Data())
    }
}
