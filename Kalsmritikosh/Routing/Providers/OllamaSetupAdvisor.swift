//
//  OllamaSetupAdvisor.swift
//  Kalsmritikosh
//
//  Onboards a user who has no reasoning model. Recommends:
//    1. Install Ollama if the daemon isn't reachable
//    2. Pull the best-fit model for their device's RAM
//  Pure value-typed helper — no I/O. The actual /api/pull network
//  call lives in OllamaInstaller.
//

import Foundation

public enum OllamaSetupAdvisor {

    /// One curated recommendation. Includes the model tag we'd
    /// `ollama pull`, its approximate RAM footprint, and a short
    /// reason the user sees in the UI.
    public struct ModelSuggestion: Sendable, Equatable {
        public let modelTag: String
        public let displayName: String
        public let approxRAMBytes: Int64
        public let approxDiskBytes: Int64
        public let contextWindow: Int
        public let reason: String

        public init(
            modelTag: String,
            displayName: String,
            approxRAMBytes: Int64,
            approxDiskBytes: Int64,
            contextWindow: Int,
            reason: String
        ) {
            self.modelTag = modelTag
            self.displayName = displayName
            self.approxRAMBytes = approxRAMBytes
            self.approxDiskBytes = approxDiskBytes
            self.contextWindow = contextWindow
            self.reason = reason
        }
    }

    /// The complete setup state surfaced to the UI.
    public struct SetupSuggestion: Sendable, Equatable {
        public enum Action: String, Sendable, Equatable {
            case nothingNeeded         // Ollama running, ≥1 compatible model
            case installOllama         // daemon not reachable; user must install
            case pullRecommendedModel  // daemon running but no compatible model
        }

        public let action: Action
        public let recommendedModel: ModelSuggestion?
        public let ollamaInstallInstructions: String
        public let summary: String

        public init(
            action: Action,
            recommendedModel: ModelSuggestion?,
            ollamaInstallInstructions: String,
            summary: String
        ) {
            self.action = action
            self.recommendedModel = recommendedModel
            self.ollamaInstallInstructions = ollamaInstallInstructions
            self.summary = summary
        }
    }

    /// Pick the best model for a device with `totalRAMBytes` of RAM
    /// AND `availableDiskBytes` of free disk. Curated list — these
    /// are the Ollama tags we know work well for the per-chunk
    /// reasoning prompts that G2-3 issues. Bigger is better only as
    /// long as it actually fits comfortably (< 70% device RAM).
    public static func recommendModel(
        totalRAMBytes: Int64,
        availableDiskBytes: Int64 = .max
    ) -> ModelSuggestion {
        // RAM budget: model itself + KV cache + OS headroom. We size
        // for ≤ 60% of device RAM so background apps don't get
        // evicted.
        let budget = Int64(Double(totalRAMBytes) * 0.6)

        let curated: [ModelSuggestion] = [
            // Largest first; we pick the biggest that fits.
            ModelSuggestion(
                modelTag: "qwen2.5:14b",
                displayName: "Qwen 2.5 14B",
                approxRAMBytes: gb(11),
                approxDiskBytes: gb(9),
                contextWindow: 32_768,
                reason: "Strongest reasoning quality of the family on Apple Silicon — best context-prefix output."
            ),
            ModelSuggestion(
                modelTag: "qwen2.5:7b",
                displayName: "Qwen 2.5 7B",
                approxRAMBytes: gb(6),
                approxDiskBytes: gb(5),
                contextWindow: 32_768,
                reason: "Best balance of quality + speed for mid-range Macs. 32K context fits long documents."
            ),
            ModelSuggestion(
                modelTag: "llama3.1:8b",
                displayName: "Llama 3.1 8B",
                approxRAMBytes: gb(6),
                approxDiskBytes: gb(5),
                contextWindow: 128_000,
                reason: "Reliable Meta release with 128K context for long-document understanding."
            ),
            ModelSuggestion(
                modelTag: "llama3.2:3b",
                displayName: "Llama 3.2 3B",
                approxRAMBytes: gb(3),
                approxDiskBytes: gb(2),
                contextWindow: 128_000,
                reason: "Fits comfortably on 8 GB Macs with room to spare for other apps."
            ),
            ModelSuggestion(
                modelTag: "phi3.5:3.8b",
                displayName: "Phi 3.5 mini (3.8B)",
                approxRAMBytes: gb(3),
                approxDiskBytes: gb(2),
                contextWindow: 128_000,
                reason: "Microsoft's small high-quality model — strong on extraction and structured output."
            ),
            ModelSuggestion(
                modelTag: "llama3.2:1b",
                displayName: "Llama 3.2 1B",
                approxRAMBytes: gb(2),
                approxDiskBytes: gb(1),
                contextWindow: 128_000,
                reason: "Last-resort fit for low-RAM devices. Limited quality but unblocks the brain."
            )
        ]

        for c in curated where c.approxRAMBytes <= budget && c.approxDiskBytes <= availableDiskBytes {
            return c
        }
        // Even the smallest didn't fit — return it anyway so the UI
        // can surface "your device is too small but try this".
        return curated.last!
    }

    /// One call. Returns the action the user should take next, the
    /// recommended model, and a copy-pasteable install line.
    public static func advise(
        ollamaReachable: Bool,
        installedReasoningModels: [String],
        totalRAMBytes: Int64,
        availableDiskBytes: Int64 = .max
    ) -> SetupSuggestion {
        let installLines = """
        Install Ollama with Homebrew:
          brew install ollama
        Or download from: https://ollama.com/download

        After installing, launch the Ollama menu-bar app once so the daemon starts at login.
        """

        if !ollamaReachable {
            let suggestion = recommendModel(
                totalRAMBytes: totalRAMBytes,
                availableDiskBytes: availableDiskBytes
            )
            return SetupSuggestion(
                action: .installOllama,
                recommendedModel: suggestion,
                ollamaInstallInstructions: installLines,
                summary: "Atlas needs a local reasoning model to answer questions. Install Ollama, then pull \(suggestion.displayName) — it's the right fit for your \(formatGB(totalRAMBytes)) device."
            )
        }

        // Ollama reachable. Do we have ANY compatible reasoning model?
        if installedReasoningModels.isEmpty {
            let suggestion = recommendModel(
                totalRAMBytes: totalRAMBytes,
                availableDiskBytes: availableDiskBytes
            )
            return SetupSuggestion(
                action: .pullRecommendedModel,
                recommendedModel: suggestion,
                ollamaInstallInstructions: installLines,
                summary: "Ollama is installed but no reasoning model is pulled. Recommended for your \(formatGB(totalRAMBytes)) device: \(suggestion.displayName) (\(formatGB(suggestion.approxDiskBytes)) download)."
            )
        }

        return SetupSuggestion(
            action: .nothingNeeded,
            recommendedModel: nil,
            ollamaInstallInstructions: installLines,
            summary: "Ollama is running with \(installedReasoningModels.count) reasoning model(s) installed."
        )
    }

    private static func gb(_ n: Int) -> Int64 {
        Int64(n) * 1_073_741_824
    }

    private static func formatGB(_ bytes: Int64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
    }
}
