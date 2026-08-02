//
//  SourceUpgradeExecutor.swift
//  Kalsmritikosh
//
//  USF-M3 (USF-009 §17/§20) — runs the actual upgrade work for a kind via a registered idempotent
//  handler. Handlers are provided by the pipeline (they reopen exact bytes through SourceVersionByteResolver
//  and parse through the ONE UniversalParserRegistry — never a bypass). A kind with no registered handler
//  is an unsupported capability (the planner/coordinator turns that into a blocker, not an endless job).
//

import Foundation

public struct SourceUpgradeExecutor: Sendable {

    /// Idempotent per-source-version work for one kind. Re-running after a crash must be safe.
    public typealias Handler = @Sendable (_ sourceVersionID: UUID) async throws -> Void

    private let handlers: [SourceUpgradeKind: Handler]

    public init(handlers: [SourceUpgradeKind: Handler]) { self.handlers = handlers }

    public func handles(_ kind: SourceUpgradeKind) -> Bool { handlers[kind] != nil }

    public func execute(kind: SourceUpgradeKind, sourceVersionID: UUID) async throws {
        guard let handler = handlers[kind] else { throw SourceUpgradeError.unsupportedCapability(kind) }
        try await handler(sourceVersionID)
    }
}
