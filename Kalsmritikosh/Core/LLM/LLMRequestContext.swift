//
//  LLMRequestContext.swift
//  Kalsmritikosh
//
//  The handle that ties every generative call to ONE user request: one
//  root request ID, one shared LLMCallBudget, one declared query class.
//  Threaded through the whole call graph (experts → synthesis → council →
//  chapters → investigation steps → fallback) so nested operations spend the
//  SAME allowance instead of each inventing its own.
//
//  `child(purpose:)` mints a new leaf requestID for tracing a specific
//  sub-operation while keeping the shared budget + rootRequestID intact — a
//  nested brain.answer() during an investigation MUST use `child`, never a
//  fresh context, or it would get a fresh five-call budget (§12).
//

import Foundation

public struct LLMRequestContext: Sendable {
    public let requestID: UUID
    public let rootRequestID: UUID
    public let budget: LLMCallBudget
    public let queryClass: LLMQueryClass
    public let createdAt: Date
    public let parentPurpose: String?

    public init(
        requestID: UUID = UUID(),
        rootRequestID: UUID? = nil,
        budget: LLMCallBudget,
        queryClass: LLMQueryClass,
        createdAt: Date = Date(),
        parentPurpose: String? = nil
    ) {
        self.requestID = requestID
        self.rootRequestID = rootRequestID ?? requestID
        self.budget = budget
        self.queryClass = queryClass
        self.createdAt = createdAt
        self.parentPurpose = parentPurpose
    }

    /// A child context that shares this request's budget + root ID but carries
    /// its own leaf requestID and a declared purpose for tracing.
    public func child(purpose: String) -> LLMRequestContext {
        LLMRequestContext(
            requestID: UUID(),
            rootRequestID: rootRequestID,
            budget: budget,
            queryClass: queryClass,
            createdAt: createdAt,
            parentPurpose: purpose
        )
    }
}
