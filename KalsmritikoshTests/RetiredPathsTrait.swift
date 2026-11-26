//
//  RetiredPathsTrait.swift
//  KalsmritikoshTests
//
//  Updated for AI-47/48 (owner 2026-11-23). Suites that verify a retired rule path (the rule answer composers and gates,
//  rule question interpretation, rule understanding) run with those switches turned back on for their own tasks only
//  (RetiredPaths.TestOverride is task-local: nothing global changes, and other suites keep the default — off).
//

import Testing
@testable import Kalsmritikosh

nonisolated struct RetiredPathsOnTrait: SuiteTrait, TestTrait, TestScoping {
    let paths: [RetiredPaths.Path: Bool]
    var isRecursive: Bool { true }
    func provideScope(for test: Test, testCase: Test.Case?, performing function: @concurrent @Sendable () async throws -> Void) async throws {
        try await RetiredPaths.TestOverride.$paths.withValue(paths) { try await function() }
    }
}

extension Trait where Self == RetiredPathsOnTrait {
    /// The retired rule-answering paths switched back on (AI-47/48).
    static var ruleAnswering: Self { RetiredPathsOnTrait(paths: RetiredPaths.ruleAnswering) }
}
