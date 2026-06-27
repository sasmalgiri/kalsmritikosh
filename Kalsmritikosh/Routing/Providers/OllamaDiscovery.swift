//
//  OllamaDiscovery.swift
//  Kalsmritikosh
//
//  "Any model the device can run." This helper queries the local
//  Ollama daemon for the models the user has actually pulled, then
//  reports their metadata so AppState can register ONE provider per
//  model. The advisor then ranks them by device-fit instead of
//  being limited to one hardcoded tag.
//
//  Pure HTTP, no persisted state. Returns an empty array when
//  Ollama isn't running — discovery is best-effort.
//

import Foundation
import OSLog

public enum OllamaDiscovery {

    public struct InstalledModel: Sendable, Equatable {
        public let name: String
        public let sizeBytes: Int64
        public let family: String?
        public let parameterSizeLabel: String?  // "8B", "14B" from Ollama
        public let contextWindowTokens: Int?    // resolved via /api/show

        public init(
            name: String,
            sizeBytes: Int64,
            family: String? = nil,
            parameterSizeLabel: String? = nil,
            contextWindowTokens: Int? = nil
        ) {
            self.name = name
            self.sizeBytes = sizeBytes
            self.family = family
            self.parameterSizeLabel = parameterSizeLabel
            self.contextWindowTokens = contextWindowTokens
        }

        /// Conservative RAM estimate at inference time. Model weights
        /// fit in roughly the file size; KV cache + buffers add ~50%
        /// for typical contexts. Used to set the manifest's
        /// `minRAMBytes` so the advisor / Chunker.diagnose can flag
        /// OOM risk before the user kicks an ingest off.
        public var estimatedRAMBytes: Int64 {
            Int64(Double(sizeBytes) * 1.5)
        }

        /// Rough tier from disk size — small models (<2 GB on disk)
        /// are typically 1–3B params, medium (2–10 GB) are 3–14B,
        /// large (>10 GB) are 14B+. Matches the routing/heuristic
        /// tiering for benchmark prioritization.
        public var tier: ModelManifest.Tier {
            switch sizeBytes {
            case ..<(2 * 1_073_741_824): return .small
            case ..<(10 * 1_073_741_824): return .medium
            default: return .large
            }
        }
    }

    /// List all models installed in the local Ollama daemon. Returns
    /// `[]` when Ollama isn't reachable, when the response is
    /// malformed, or when no models are installed. Side-effect-free.
    public static func list(
        baseURL: URL = URL(string: "http://localhost:11434")!,
        timeoutSeconds: TimeInterval = 1.5
    ) async -> [InstalledModel] {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = timeoutSeconds
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = timeoutSeconds
        cfg.timeoutIntervalForResource = timeoutSeconds
        let session = URLSession(configuration: cfg)
        let data: Data
        do {
            let (d, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
            data = d
        } catch {
            AtlasLog.routing.debug("Ollama discovery: list failed — \(String(describing: error), privacy: .public)")
            return []
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["models"] as? [[String: Any]] else {
            return []
        }
        var out: [InstalledModel] = []
        for entry in models {
            guard let name = entry["name"] as? String else { continue }
            let size = (entry["size"] as? NSNumber)?.int64Value
                ?? Int64((entry["size"] as? Int) ?? 0)
            let details = entry["details"] as? [String: Any]
            let family = details?["family"] as? String
            let paramLabel = details?["parameter_size"] as? String
            out.append(InstalledModel(
                name: name,
                sizeBytes: size,
                family: family,
                parameterSizeLabel: paramLabel,
                contextWindowTokens: nil
            ))
        }
        return out
    }

    /// Best-effort fetch of a model's exact context window from
    /// Ollama's `/api/show`. Returns nil if the API doesn't surface
    /// the field for this model (older Ollama servers, custom
    /// modelfiles without explicit `num_ctx`). Caller falls back to
    /// a family-based default when nil.
    public static func contextWindow(
        for modelName: String,
        baseURL: URL = URL(string: "http://localhost:11434")!,
        timeoutSeconds: TimeInterval = 1.5
    ) async -> Int? {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/show"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["name": modelName]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = timeoutSeconds
        cfg.timeoutIntervalForResource = timeoutSeconds
        let session = URLSession(configuration: cfg)
        do {
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            // Ollama nests context length under model_info.<family>.context_length
            if let modelInfo = root["model_info"] as? [String: Any] {
                for (key, value) in modelInfo where key.hasSuffix(".context_length") {
                    if let n = value as? Int { return n }
                    if let n = (value as? NSNumber)?.intValue { return n }
                }
            }
            return nil
        } catch {
            return nil
        }
    }

    /// Plain availability ping — does the Ollama daemon answer at
    /// all? Used by the setup advisor to distinguish "install Ollama"
    /// from "Ollama is installed but you haven't pulled a model yet."
    public static func isReachable(
        baseURL: URL = URL(string: "http://localhost:11434")!,
        timeoutSeconds: TimeInterval = 1.5
    ) async -> Bool {
        var request = URLRequest(url: baseURL)
        request.timeoutInterval = timeoutSeconds
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = timeoutSeconds
        cfg.timeoutIntervalForResource = timeoutSeconds
        let session = URLSession(configuration: cfg)
        do {
            let (_, response) = try await session.data(for: request)
            // Ollama returns 200 OK on the root path
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    /// Family-based fallback when the API doesn't return a
    /// context_length. Numbers come from each family's reference
    /// model card. Used by AppState when we still want to register
    /// a discovered model even if /api/show doesn't surface the
    /// field.
    public static func defaultContextWindow(forFamily family: String?) -> Int {
        guard let f = family?.lowercased() else { return 8_192 }
        switch f {
        case "llama":         return 8_192
        case "llama3":        return 8_192
        case "qwen", "qwen2", "qwen2.5": return 32_768
        case "mistral", "mixtral": return 32_768
        case "gemma", "gemma2": return 8_192
        case "phi", "phi3":   return 4_096
        case "deepseek", "deepseek-coder", "deepseek-r1": return 16_384
        default:              return 8_192
        }
    }
}
