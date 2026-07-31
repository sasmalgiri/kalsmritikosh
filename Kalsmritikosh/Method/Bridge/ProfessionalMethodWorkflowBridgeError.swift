//
//  ProfessionalMethodWorkflowBridgeError.swift
//  Kalsmritikosh
//
//  PM-003 — typed errors for the professional-method workflow bridge.
//

import Foundation

public nonisolated enum ProfessionalMethodWorkflowBridgeError: Error, Equatable, Sendable {
    case unknownMethodDefinition(String)
    case unknownMethodVersion(id: String, version: Int)
    case methodRunNotFound(UUID)
    case workspaceMismatch(UUID)
    case workflowRunMismatch(UUID)
    case workflowStepMismatch(UUID)
    case definitionMismatch(UUID)
    /// A linked run is cancelled or superseded.
    case terminalInvalidRun(UUID, status: String)
    case runNotCompleted(UUID, status: String)
    case missingCompletionTimestamp(UUID)
    case emptyProvenance(UUID)
    case deniedCanonicalReference(kind: String, id: UUID)
    case malformedWorkflowReference(String)
    case invalidResultNarrative(String)
}
