//
//  PrivacyGate.swift
//  Kalsmritikosh
//
//  U-0 (privacy invariant closure), amended by O-1 (owner decision
//  2026-10-15): cloud routing exists ONLY in Online mode — chosen by the user,
//  with a bundled network helper and the online-answers module on (see
//  OnlineSettings.cloudAllowed, enforced in CapabilityRegistry). Private mode is
//  the default and never resolves a cloud provider. This gate keeps the
//  offline/no-LLM stance below, which overrides Online mode too.
//

import Foundation

public final class PrivacyGate: @unchecked Sendable {
    public nonisolated static let shared = PrivacyGate()

    private let queue = DispatchQueue(label: "kalsmritikosh.privacy")

    private let noLLMKey = "kalsmritikosh.privacy.offlineNoLLM"

    /// Fully-private / offline stance: when true, the CapabilityRegistry
    /// refuses to resolve ANY generative model (on-device Apple, local
    /// Ollama, or cloud), so every caller falls back to its deterministic
    /// rule/NL/extractive path. Embeddings (on-device, non-generative) are
    /// unaffected, so vector retrieval still works. Default off.
    public nonisolated var offlineNoLLM: Bool {
        get {
            if EvidenceOnlyRelease.enforced { return true }
            #if DEBUG
            if let o = Self.TestOverride.offlineNoLLM { return o }   // a test's own switch (its task tree only)
            #endif
            return queue.sync { AppDefaults.store.bool(forKey: noLLMKey) }
        }
        set { queue.sync { AppDefaults.store.set(newValue, forKey: noLLMKey) } }
    }

    #if DEBUG
    /// Deep dive 2026-11-14 batch 1 — the Fully-private switch for one test's task tree (Debug builds only), the same
    /// pattern as `ProductModuleFlags.TestOverride`. Tests that put the switch into the process-wide argument domain
    /// and put it back afterwards undid each other's switch while the other was still running.
    public nonisolated enum TestOverride {
        @TaskLocal public static var offlineNoLLM: Bool?
    }
    #endif
}
