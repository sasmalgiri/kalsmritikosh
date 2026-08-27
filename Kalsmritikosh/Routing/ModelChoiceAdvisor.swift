//
//  ModelChoiceAdvisor.swift
//  Kalsmritikosh
//
//  Per-user, per-device advisor. Examines:
//    - the registered providers and their manifests
//    - the device's actual RAM
//    - the currently-resolved reasoning provider
//  and produces ONE actionable recommendation surfaced to the user
//  in the Settings banner.
//
//  The system already auto-recommends via `AutoRecommendation.recommend(...)`
//  internally, but the user can pin a provider via UserPreferences.
//  This advisor is the layer that tells the user:
//    "you picked X — but your device fits Y better, here's why"
//  rather than silently sizing down or thrashing the cache.
//

import Foundation

public struct ModelChoiceRecommendation: Sendable, Equatable {
    /// Severity classification — drives the banner's color and
    /// whether SettingsView shows a one-time popup on appear.
    public enum Severity: String, Sendable, Equatable {
        case ok          // current choice is the best fit; nothing to do
        case suggestion  // a better choice exists; user can upgrade
        case warning     // current choice works but uses most of device RAM
        case critical    // current choice will OOM or thrash hard
    }

    public let severity: Severity
    /// Identifier of the provider the resolver picked at boot.
    public let currentProviderID: String?
    /// Human-readable name of the current pick.
    public let currentProviderName: String?
    /// Identifier of what the advisor recommends instead. Nil when
    /// `severity == .ok` (no swap needed).
    public let recommendedProviderID: String?
    public let recommendedProviderName: String?
    /// One-line headline shown in the banner.
    public let summary: String
    /// Detail bullets — RAM math, context-window, why this is the
    /// fit. The Settings banner expands them on tap.
    public let details: [String]

    public init(
        severity: Severity,
        currentProviderID: String?,
        currentProviderName: String?,
        recommendedProviderID: String?,
        recommendedProviderName: String?,
        summary: String,
        details: [String]
    ) {
        self.severity = severity
        self.currentProviderID = currentProviderID
        self.currentProviderName = currentProviderName
        self.recommendedProviderID = recommendedProviderID
        self.recommendedProviderName = recommendedProviderName
        self.summary = summary
        self.details = details
    }
}

public enum ModelChoiceAdvisor {

    /// Pure function — no actors, no I/O. Takes the user's hardware,
    /// the manifests of all registered providers, the manifest of
    /// the currently-resolved reasoning provider (or nil if none
    /// resolved), and returns a single recommendation.
    ///
    /// Decision rules:
    ///   1. No reasoning provider resolved → critical, suggest the
    ///      largest fitting one.
    ///   2. Current model needs more RAM than the device has →
    ///      critical, suggest the largest one that fits.
    ///   3. Current model needs > 70% of device RAM → warning;
    ///      suggest a smaller one if available.
    ///   4. A larger-tier model exists that ALSO fits comfortably
    ///      (< 70% RAM) → suggestion, "you can upgrade".
    ///   5. Otherwise → ok.
    public static func advise(
        hardware: HardwareProfile,
        currentReasoning: ModelManifest?,
        availableReasoning: [ModelManifest]
    ) -> ModelChoiceRecommendation {

        // Pool of provider manifests that (a) actually do reasoning
        // and (b) fit comfortably on this device. Threshold 70%
        // matches Chunker.diagnose's "heavy cache thrash" line.
        let comfortableFit: (ModelManifest) -> Bool = { m in
            m.minRAMBytes > 0
                && Double(m.minRAMBytes) <= Double(hardware.totalRAMBytes) * 0.7
        }
        let reasoningCandidates = availableReasoning.filter {
            $0.capabilities.contains(.reasoning)
        }
        let comfortablePool = reasoningCandidates.filter(comfortableFit)

        // Largest comfortable fit — the "best" reasoning model for
        // this device. Ranked by tier weight then RAM.
        let largestFit = comfortablePool.sorted { a, b in
            if a.tier.weight != b.tier.weight {
                return a.tier.weight > b.tier.weight
            }
            return a.minRAMBytes > b.minRAMBytes
        }.first

        // 1. No current reasoning provider.
        if currentReasoning == nil {
            if let best = largestFit {
                return .init(
                    severity: .critical,
                    currentProviderID: nil,
                    currentProviderName: nil,
                    recommendedProviderID: best.id,
                    recommendedProviderName: best.displayName,
                    summary: "No reasoning model available — enable \(best.displayName) for full quality answers.",
                    details: [
                        "The brain refuses to answer without a reasoning provider.",
                        "Your device (\(formatGB(hardware.totalRAMBytes)) RAM) comfortably fits \(best.displayName).",
                        "Provider tier: \(best.tier.rawValue), context window: \(best.contextWindow) tokens."
                    ]
                )
            }
            #if DEBUG
            // Dev builds can actually install Ollama/MLX — say so.
            return .init(
                severity: .critical,
                currentProviderID: nil,
                currentProviderName: nil,
                recommendedProviderID: nil,
                recommendedProviderName: nil,
                summary: "No reasoning model available — install a local LLM (Ollama or MLX) to enable answers.",
                details: [
                    "The brain refuses to answer without a reasoning provider.",
                    "No reasoning-capable provider is registered for this build."
                ]
            )
            #else
            // SIXTEENTH REVIEW — in Release, deterministic-only is the PROMISED
            // valid mode on macOS 15.6–25 (SHIP_DECISIONS GOV-004, owner
            // decision 2: generative is OPTIONAL). There is nothing for the
            // user to install; never mark the shipped contract critical.
            return .init(
                severity: .ok,
                currentProviderID: nil,
                currentProviderName: nil,
                recommendedProviderID: nil,
                recommendedProviderName: nil,
                summary: "Deterministic evidence mode — answers come straight from your ledger, fully on-device.",
                details: [
                    "AI-written prose requires macOS 26 or later with Apple Intelligence on supported hardware.",
                    "Search, timelines, entities, contradictions, gaps, and cited deterministic reports are fully available in this mode."
                ]
            )
            #endif
        }

        let current = currentReasoning!
        let deviceBytes = hardware.totalRAMBytes
        let currentBytes = current.minRAMBytes
        let currentPct = deviceBytes > 0
            ? Int((Double(currentBytes) / Double(deviceBytes)) * 100)
            : 0

        // 2. Current model needs more RAM than device has.
        if currentBytes > deviceBytes {
            let recommended = largestFit
            return .init(
                severity: .critical,
                currentProviderID: current.id,
                currentProviderName: current.displayName,
                recommendedProviderID: recommended?.id,
                recommendedProviderName: recommended?.displayName,
                summary: "\(current.displayName) needs \(formatGB(currentBytes)) RAM but your device has only \(formatGB(deviceBytes)) — will OOM or swap.",
                details: detailsFor(current: current, device: hardware, recommended: recommended) + [
                    "Switching to a smaller model will let ingest complete instead of stalling on swap."
                ]
            )
        }

        // 3. Current model uses > 70% of device RAM.
        if currentPct >= 70 {
            // Suggest a smaller model if one is registered.
            let smaller = reasoningCandidates
                .filter { $0.minRAMBytes < currentBytes }
                .sorted { $0.tier.weight > $1.tier.weight }
                .first
            return .init(
                severity: .warning,
                currentProviderID: current.id,
                currentProviderName: current.displayName,
                recommendedProviderID: smaller?.id,
                recommendedProviderName: smaller?.displayName,
                summary: "\(current.displayName) uses \(currentPct)% of your device RAM — ingest will compete with other apps.",
                details: detailsFor(current: current, device: hardware, recommended: smaller) + [
                    "Background apps may evict the model from RAM, forcing a cold reload on the next chunk."
                ]
            )
        }

        // 4. Larger-tier model exists that ALSO fits comfortably.
        if let best = largestFit,
           best.id != current.id,
           best.tier.weight > current.tier.weight {
            return .init(
                severity: .suggestion,
                currentProviderID: current.id,
                currentProviderName: current.displayName,
                recommendedProviderID: best.id,
                recommendedProviderName: best.displayName,
                summary: "You can upgrade — \(best.displayName) also fits comfortably on your \(formatGB(deviceBytes)) device.",
                details: detailsFor(current: current, device: hardware, recommended: best) + [
                    "Bigger reasoning models produce higher-quality context prefixes and richer answers."
                ]
            )
        }

        // 5. Current choice is the best fit.
        return .init(
            severity: .ok,
            currentProviderID: current.id,
            currentProviderName: current.displayName,
            recommendedProviderID: nil,
            recommendedProviderName: nil,
            summary: "\(current.displayName) is the best fit for your device.",
            details: detailsFor(current: current, device: hardware, recommended: nil)
        )
    }

    // MARK: - Helpers

    private static func detailsFor(
        current: ModelManifest,
        device: HardwareProfile,
        recommended: ModelManifest?
    ) -> [String] {
        var out: [String] = []
        out.append("Device: \(formatGB(device.totalRAMBytes)) RAM, tier \(device.tier.rawValue).")
        out.append("Current: \(current.displayName) — \(formatGB(current.minRAMBytes)) RAM, context \(current.contextWindow) tokens.")
        if let r = recommended {
            out.append("Recommended: \(r.displayName) — \(formatGB(r.minRAMBytes)) RAM, context \(r.contextWindow) tokens.")
        }
        return out
    }

    private static func formatGB(_ bytes: Int64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
    }
}

private extension ModelManifest.Tier {
    var weight: Int {
        switch self {
        case .small: return 0
        case .medium: return 1
        case .large: return 2
        }
    }
}
