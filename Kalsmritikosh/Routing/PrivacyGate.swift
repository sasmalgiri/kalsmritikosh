//
//  PrivacyGate.swift
//  Kalsmritikosh
//
//  Local toggle that decides whether cloud routing is allowed. Defaults
//  to on-device-only. Persisted in UserDefaults so the choice survives
//  restarts.
//

import Foundation

public final class PrivacyGate: @unchecked Sendable {
    public nonisolated static let shared = PrivacyGate()

    private let defaultsKey = "atlas.privacy.allowCloud"
    private let queue = DispatchQueue(label: "atlas.privacy")

    private let noLLMKey = "atlas.privacy.offlineNoLLM"

    public nonisolated var allowCloudRouting: Bool {
        get { queue.sync { UserDefaults.standard.bool(forKey: defaultsKey) } }
        set { queue.sync { UserDefaults.standard.set(newValue, forKey: defaultsKey) } }
    }

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
