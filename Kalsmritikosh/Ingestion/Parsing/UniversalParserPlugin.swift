//
//  UniversalParserPlugin.swift
//  Kalsmritikosh
//
//  USF-M1 (USF-003) — the one contract every parser executes behind. A plugin has a stable
//  code-backed identity and produces a UniversalParserResult from the immutable processing
//  snapshot. Existing loaders + structural parsers reach this contract via ExistingParserPluginAdapter;
//  their algorithms are NOT rewritten.
//

import Foundation

public protocol UniversalParserPlugin: Sendable {
    /// Stable code-backed identity (never blank).
    nonisolated var pluginID: String { get }
    nonisolated var pluginVersion: String { get }
    /// The source types this plugin owns (never empty).
    nonisolated var supportedTypes: Set<SourceType> { get }
    nonisolated var capabilities: UniversalParserCapabilities { get }
    nonisolated var executionMode: UniversalParserExecutionMode { get }
    nonisolated var primaryLane: ResourceLane { get }

    /// Parse the request's immutable snapshot into the common result. Implementations do not gate
    /// their own identity — the UniversalParserExecutor validates the result against the request.
    func execute(_ request: UniversalParserRequest) async throws -> UniversalParserResult
}
