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

    private let defaultsKey = "kalsmritikosh.privacy.allowCloud"
    private let queue = DispatchQueue(label: "kalsmritikosh.privacy")

    private let noLLMKey = "kalsmritikosh.privacy.offlineNoLLM"

    /// RELEASE builds compile-lock this to `false` (fifteenth review): the
    /// shipped product contract is zero network, so cloud routing cannot be
    /// enabled by any persisted setting, migration artifact, or defaults
    /// tampering. The setter is inert outside DEBUG. Dev builds keep the
    /// toggle for provider experiments.
    public nonisolated var allowCloudRouting: Bool {
        get {
            #if DEBUG
            queue.sync { UserDefaults.standard.bool(forKey: defaultsKey) }
            #else
            false
            #endif
        }
        set {
            #if DEBUG
            queue.sync { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
            #else
            _ = newValue
            #endif
        }
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
