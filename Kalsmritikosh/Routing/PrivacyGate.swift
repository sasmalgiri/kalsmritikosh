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
        get { EvidenceOnlyRelease.enforced || queue.sync { UserDefaults.standard.bool(forKey: noLLMKey) } }
        set { queue.sync { UserDefaults.standard.set(newValue, forKey: noLLMKey) } }
    }
}
