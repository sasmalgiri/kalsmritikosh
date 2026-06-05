//
//  ModelManifest.swift
//  Kalsmritikosh
//
//  Each ModelProvider exposes a ModelManifest. The CapabilityRegistry
//  reads manifests to decide which provider best fulfils a CapabilitySpec
//  on this hardware.
//
//  Manifests are the ONLY place model-specific identifiers (Qwen, Gemma,
//  DeepSeek, etc.) appear in Swift code. They're loaded from
//  Resources/Models/manifest.json by AutoRecommendation at boot. Callers
//  outside the registry never see them.
//

import Foundation

public struct ModelManifest: Codable, Sendable, Hashable {
    /// Stable identifier the registry uses internally. Opaque to callers.
    public let id: String

    /// Human-readable name shown in Settings. Should describe the role,
    /// not the model — e.g. "Local reasoning model" rather than "Qwen3 8B".
    public let displayName: String

    /// What this provider can do.
    public let capabilities: Set<ModelCapability>

    /// Minimum RAM (in bytes) the model needs to load without swap thrashing.
    public let minRAMBytes: Int64

    /// On-disk size after download (in bytes). 0 if the model is bundled
    /// or runs out-of-process.
    public let diskBytes: Int64

    /// Maximum context window in tokens. Drives long-context selection.
    public let contextWindow: Int

    /// Where this provider runs.
    public let privacyLevel: PrivacyLevel

    /// Whether the model needs a download before it's usable.
    public let requiresDownload: Bool

    /// Optional source URL the downloader can fetch from.
    public let sourceURL: URL?

    /// Optional SHA256 the downloader verifies after fetch.
    public let sha256: String?

    /// Tier hint used by AutoRecommendation: small/medium/large drives
    /// which capability fulfilment role this provider gets nominated for.
    public let tier: Tier

    public enum Tier: String, Codable, Sendable, Hashable, CaseIterable {
        case small
        case medium
        case large
    }

    public init(
        id: String,
        displayName: String,
        capabilities: Set<ModelCapability>,
        minRAMBytes: Int64 = 0,
        diskBytes: Int64 = 0,
        contextWindow: Int = 4096,
        privacyLevel: PrivacyLevel = .onDevice,
        requiresDownload: Bool = false,
        sourceURL: URL? = nil,
        sha256: String? = nil,
        tier: Tier = .medium
    ) {
        self.id = id
        self.displayName = displayName
        self.capabilities = capabilities
        self.minRAMBytes = minRAMBytes
        self.diskBytes = diskBytes
        self.contextWindow = contextWindow
        self.privacyLevel = privacyLevel
        self.requiresDownload = requiresDownload
        self.sourceURL = sourceURL
        self.sha256 = sha256
        self.tier = tier
    }
}
