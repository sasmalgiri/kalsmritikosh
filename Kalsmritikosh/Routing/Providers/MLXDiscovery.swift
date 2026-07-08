//
//  MLXDiscovery.swift
//  Kalsmritikosh
//
//  Discovers user-supplied MLX checkpoints under the app's user
//  models directory. Each subdirectory containing a `config.json`
//  is treated as an MLX model the user wants the app to be aware of.
//
//  The MLX runtime itself is still scaffolded (M6.2); registering
//  the discovered model here means the advisor can recommend it and
//  the SettingsView can surface it as a choice. When the runtime
//  ships, no AppState change is needed — the registration is
//  already done.
//

import Foundation
import OSLog

public enum MLXDiscovery {

    public struct UserMLXModel: Sendable, Equatable {
        public let id: String
        public let displayName: String
        public let directoryURL: URL
        public let sizeBytes: Int64
        public let contextWindow: Int
        public let tier: ModelManifest.Tier

        public init(
            id: String,
            displayName: String,
            directoryURL: URL,
            sizeBytes: Int64,
            contextWindow: Int,
            tier: ModelManifest.Tier
        ) {
            self.id = id
            self.displayName = displayName
            self.directoryURL = directoryURL
            self.sizeBytes = sizeBytes
            self.contextWindow = contextWindow
            self.tier = tier
        }

        /// Conservative RAM estimate — disk size × 1.4 (MLX uses
        /// less KV cache overhead than llama.cpp). Used to set the
        /// manifest's minRAMBytes for the advisor's fit check.
        public var estimatedRAMBytes: Int64 {
            Int64(Double(sizeBytes) * 1.4)
        }
    }

    /// Default directory the app scans for user-supplied MLX models.
    /// The user drops MLX checkpoint folders here (or symlinks to
    /// existing checkpoint dirs); each subdirectory with a config.json
    /// becomes a registered model.
    public static func defaultUserModelsDirectory() -> URL {
        let appSupport = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return appSupport
            .appendingPathComponent("Kalsmritikosh", isDirectory: true)
            .appendingPathComponent("MLXModels", isDirectory: true)
    }

    /// Scan `directory` for MLX model folders. Each direct child
    /// directory that contains `config.json` (the standard MLX
    /// checkpoint shape) is treated as one model. Returns [] when
    /// the directory doesn't exist — user hasn't dropped any models.
    public static func list(directory: URL = defaultUserModelsDirectory()) -> [UserMLXModel] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return [] }
        let children: [URL]
        do {
            children = try fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            KalsmritikoshLog.routing.debug("MLXDiscovery: list failed — \(String(describing: error), privacy: .public)")
            return []
        }
        var out: [UserMLXModel] = []
        for child in children {
            guard let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory),
                  isDir == true else { continue }
            let configURL = child.appendingPathComponent("config.json")
            guard fm.fileExists(atPath: configURL.path) else { continue }
            let (ctx, paramCount) = parseConfig(configURL)
            let size = directorySize(child)
            let tier: ModelManifest.Tier = {
                if let n = paramCount {
                    switch n {
                    case ..<3_000_000_000: return .small
                    case ..<14_000_000_000: return .medium
                    default: return .large
                    }
                }
                switch size {
                case ..<(2 * 1_073_741_824): return .small
                case ..<(10 * 1_073_741_824): return .medium
                default: return .large
                }
            }()
            out.append(UserMLXModel(
                id: "provider.local.mlx.user.\(child.lastPathComponent)",
                displayName: "MLX \(child.lastPathComponent)",
                directoryURL: child,
                sizeBytes: size,
                contextWindow: ctx ?? 4_096,
                tier: tier
            ))
        }
        return out
    }

    /// Pull (context_length, num_parameters?) from an MLX
    /// config.json. MLX configs use the same field names as
    /// Hugging Face transformers configs.
    private static func parseConfig(_ url: URL) -> (Int?, Int?) {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return (nil, nil) }
        let ctx = (obj["max_position_embeddings"] as? Int)
            ?? (obj["max_sequence_length"] as? Int)
            ?? (obj["n_positions"] as? Int)
        let params = (obj["num_parameters"] as? Int)
            ?? (obj["n_params"] as? Int)
        return (ctx, params)
    }

    /// Recursive size of `dir` — sums regular-file sizes. Used to
    /// estimate the on-disk and RAM footprint when the config
    /// doesn't expose parameter count.
    private static func directorySize(_ dir: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values?.isRegularFile == true, let size = values?.fileSize {
                total += Int64(size)
            }
        }
        return total
    }
}
