//
//  OneAI.swift
//  Kalsmritikosh
//
//  Unified path AI-36 (owner 2026-11-22, round 2) — not tested yet. ONE AI: the only AI is the online
//  provider (Claude, on the person's own key or through the owner's relay). The built-in on-device and
//  local generative providers (the system language model, local model servers and files, the legacy cloud
//  stub) are never resolved for a generative capability; embeddings stay on the Mac.
//
//  Privacy stays enforced: a capability that never declared it may go to the cloud reaches the online
//  provider only inside an import the person allowed AI for (ImportAIPermission, asked once per import
//  with the estimated cost). A declined import runs with no AI at all.
//

import Foundation
import os

public nonisolated enum OneAI {
    /// Unified path AI-36 (owner 2026-11-22, round 2) — not tested yet. A built-in generative provider that
    /// is no longer an AI under the one-AI rule (the on-device model, local servers / model files, the stub).
    public static func isRetiredGenerative(id: String, capabilities: Set<ModelCapability>) -> Bool {
        guard capabilities.contains(.textGeneration) else { return false }
        #if DEBUG
        if TestOverride.allowLocalModels == true { return false }
        #endif
        return id == "provider.system.languageModel" || id.hasPrefix("provider.local.")
            || id == "provider.cloud" || id.hasPrefix("provider.cloud.")
    }

    private static let setUpCache = OSAllocatedUnfairLock<(at: Date, value: Bool)?>(initialState: nil)

    /// Unified path AI-36/AI-37 (owner 2026-11-22, round 2) — not tested yet. Whether the one AI is set up now:
    /// the AI regime allows it, Online answers may run, and the chosen kind has its key (or plan credential).
    /// Cached for five seconds (it reads the Keychain).
    public static var isSetUp: Bool {
        #if DEBUG
        if let o = TestOverride.setUp { return o }
        #endif
        let now = Date()
        if let c = setUpCache.withLock({ $0 }), now.timeIntervalSince(c.at) < 5 { return c.value }
        let value = FeatureFlags.aiRegimeValue().allowsAI && OnlineSettings.cloudAllowed
            && OnlineSettings.apiKey(for: OnlineSettings.kind) != nil
        setUpCache.withLock { $0 = (now, value) }
        return value
    }

    /// Forget the cached answer (after the person saved a key, chose a plan or switched Online).
    public static func invalidate() { setUpCache.withLock { $0 = nil } }

    #if DEBUG
    /// Test-only switches for one test's task tree (Debug builds only).
    public enum TestOverride {
        /// Let a test's local/on-device generative provider resolve as before.
        @TaskLocal public static var allowLocalModels: Bool?
        @TaskLocal public static var setUp: Bool?
    }
    #endif
}

/// Unified path AI-36 (owner 2026-11-22, round 2) — not tested yet. The person's once-per-import decision
/// about AI during an import (ImportAIConsent asks it, with the estimated cost). Inside an allowed import,
/// generative work that did not declare the cloud may use the online provider without a per-send preview
/// (the import's permission covers it; masking, protected identities, limits and the outbound record still
/// apply). Inside a declined import no generative capability resolves at all.
public nonisolated enum ImportAIPermission {
    public struct Grant: Sendable, Equatable {
        public let importID: UUID
        public let allowed: Bool
        public let decidedAt: Date
        public init(importID: UUID = UUID(), allowed: Bool, decidedAt: Date = Date()) {
            self.importID = importID; self.allowed = allowed; self.decidedAt = decidedAt
        }
    }

    /// The import this task tree belongs to (nil = not import work).
    @TaskLocal public static var scope: Grant?

    private static let last = OSAllocatedUnfairLock<Grant?>(initialState: nil)

    /// The most recent import's decision (this session only; nothing is stored).
    public static var lastDecision: Grant? { last.withLock { $0 } }
    public static func record(_ grant: Grant) { last.withLock { $0 = grant } }

    /// Whether import-time AI may run in this task tree now.
    public static var allowsAIHere: Bool { scope?.allowed == true }

    /// Unified path AI-36 (owner 2026-11-22, round 2) — not tested yet. Background import levers (memory
    /// distillation, enrichment drain, background upkeep) run under the most recent import's decision; with
    /// no import decided this session they run without AI.
    public static func underLastDecision<T>(_ operation: () async throws -> T) async rethrows -> T {
        if scope != nil { return try await operation() }
        return try await $scope.withValue(lastDecision) { try await operation() }
    }
}
