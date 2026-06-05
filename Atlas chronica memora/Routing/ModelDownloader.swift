//
//  ModelDownloader.swift
//  Atlas chronica memora
//
//  Fetches local model weights into Application Support. M3 ships a
//  stub that returns the on-disk path if present, and reports "not
//  downloaded" otherwise. The MLXProvider hooks into it when SPM
//  brings mlx-swift in.
//

import Foundation

public actor ModelDownloader {
    public struct Manifest: Sendable, Hashable {
        public let modelID: String
        public let displayName: String
        public let sizeBytes: Int64
        public init(modelID: String, displayName: String, sizeBytes: Int64) {
            self.modelID = modelID
            self.displayName = displayName
            self.sizeBytes = sizeBytes
        }
    }

    private let directory: URL

    public init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory()
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    public func isAvailable(_ manifest: Manifest) -> Bool {
        let url = directory.appendingPathComponent(manifest.modelID)
        return FileManager.default.fileExists(atPath: url.path)
    }

    public func location(for manifest: Manifest) -> URL {
        directory.appendingPathComponent(manifest.modelID)
    }

    /// Real download lives in M5 once we wire URLSession + checksum +
    /// progress. M3 records intent so the UI can show "Model not
    /// downloaded — open settings to fetch".
    public func ensureDownloaded(_ manifest: Manifest) async throws -> URL {
        let url = location(for: manifest)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        throw NSError(
            domain: "atlas.model.downloader",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Model \(manifest.modelID) is not downloaded."]
        )
    }

    private static func defaultDirectory() -> URL {
        let fm = FileManager.default
        let base = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fm.temporaryDirectory
        return base
            .appendingPathComponent("AtlasChronicaMemora", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }
}
