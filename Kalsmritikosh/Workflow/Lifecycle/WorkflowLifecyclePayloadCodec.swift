//
//  WorkflowLifecyclePayloadCodec.swift
//  Kalsmritikosh
//
//  PJE-004 — JSON codec helpers for lifecycle payloads.
//  Validates that entry/completion JSON strings are well-formed.
//  Stateless; no storage interaction.
//

import Foundation

public struct WorkflowLifecyclePayloadCodec: Sendable {
    public nonisolated init() {}

    /// Validates that the string is well-formed JSON.
    /// Throws `WorkflowLifecycleError.invalidJSONPayload` on failure.
    public nonisolated func validateJSON(_ string: String) throws {
        guard let data = string.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) != nil else {
            throw WorkflowLifecycleError.invalidJSONPayload
        }
    }

    /// Validate both fields of a `WorkflowStepEntryPayload`.
    public nonisolated func validate(_ payload: WorkflowStepEntryPayload) throws {
        try validateJSON(payload.inputJSON)
        try validateJSON(payload.stateJSON)
    }

    /// Resolve nil-means-preserve semantics for a `WorkflowStepCompletionPayload`.
    /// Returns the concrete (stateJSON, outputJSON) to write, using `current` values when nil.
    public nonisolated func resolveCompletionPayload(
        _ payload: WorkflowStepCompletionPayload,
        current: WorkflowStepRun
    ) throws -> (stateJSON: String, outputJSON: String?) {
        let stateJSON = payload.stateJSON ?? current.stateJSON
        let outputJSON = payload.outputJSON ?? current.outputJSON
        try validateJSON(stateJSON)
        if let out = outputJSON { try validateJSON(out) }
        return (stateJSON, outputJSON)
    }

    /// Compute the SHA-256 hex string of a state JSON string.
    public nonisolated func stateSHA256(for stateJSON: String) -> String {
        let data = stateJSON.data(using: .utf8) ?? Data()
        return WorkflowRunSnapshotCodec.hashString(data)
    }
}
