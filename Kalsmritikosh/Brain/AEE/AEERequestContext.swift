//
//  AEERequestContext.swift
//  Kalsmritikosh
//
//  AEE-M1 — the request-scoped facts the mission compiler needs that are NOT part of
//  the query-analysis authorities: a stable request id, whether the request arrived as
//  an EXPLICIT Stage-3 workflow/job invocation, and whether a proven deterministic
//  handler is available for it. These are supplied by the caller (MasterBrain), never
//  inferred from the question text inside AEE.
//

import Foundation

public nonisolated struct AEERequestContext: Sendable, Hashable {
    public let requestID: UUID
    /// True only when the request is an actual Stage-3 workflow/job invocation. A plain
    /// natural-language question always passes false — the professionalWorkflow lane is
    /// unreachable from text alone.
    public let workflowInvocationPresent: Bool
    /// True when a proven deterministic handler (exact structured/durable answer) is
    /// known to be available for this request before any retrieval runs.
    public let deterministicHandlerAvailable: Bool

    public init(
        requestID: UUID = UUID(),
        workflowInvocationPresent: Bool = false,
        deterministicHandlerAvailable: Bool = false
    ) {
        self.requestID = requestID
        self.workflowInvocationPresent = workflowInvocationPresent
        self.deterministicHandlerAvailable = deterministicHandlerAvailable
    }
}
