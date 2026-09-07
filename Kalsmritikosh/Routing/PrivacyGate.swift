//
//  PrivacyGate.swift
//  Kalsmritikosh
//
//  U-0 (privacy invariant closure): cloud routing does not exist in this
//  product — no network entitlement, no cloud provider, no toggle in any
//  build. The gate's remaining job is the offline/no-LLM stance below.
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
        get { queue.sync { UserDefaults.standard.bool(forKey: noLLMKey) } }
        set { queue.sync { UserDefaults.standard.set(newValue, forKey: noLLMKey) } }
    }
}
