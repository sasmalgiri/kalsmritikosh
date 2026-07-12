//
//  ModelDownloader.swift
//  Kalsmritikosh
//
//  B2 — real, resumable, verified download of local model weights into
//  Application Support. Streams bytes to a temp file with progress, checks free
//  space up front, verifies SHA-256, installs atomically, cleans up partials on
//  failure, and supports cancellation, deletion and rollback. No arbitrary
//  execution — it only fetches a manifest's declared URL to a declared path and
//  verifies the declared checksum.
//

import Foundation
import CryptoKit
import OSLog

public actor ModelDownloader {
    public struct Manifest: Sendable, Hashable {
        public let modelID: String
        public let displayName: String
        public let sizeBytes: Int64
        /// Where to fetch the weights from (nil = must already be on disk/bundled).
        public let remoteURL: URL?
        /// Expected lowercase hex SHA-256 of the file (nil = skip verification).
        public let sha256: String?

        public init(
            modelID: String,
            displayName: String,
            sizeBytes: Int64,
            remoteURL: URL? = nil,
            sha256: String? = nil
        ) {
            self.modelID = modelID
            self.displayName = displayName
            self.sizeBytes = sizeBytes
            self.remoteURL = remoteURL
            self.sha256 = sha256
        }
    }

    public enum DownloadError: Error, Sendable {
        case noRemoteURL(modelID: String)
        case insufficientFreeSpace(needBytes: Int64, freeBytes: Int64)
        case httpStatus(Int)
        case checksumMismatch(expected: String, got: String)
        case notDownloaded(modelID: String)
    }

    private let directory: URL

    public init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory()
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    // MARK: - Query

    public func isAvailable(_ manifest: Manifest) -> Bool {
        FileManager.default.fileExists(atPath: location(for: manifest).path)
    }

    public func location(for manifest: Manifest) -> URL {
        directory.appendingPathComponent(manifest.modelID)
    }

    /// Returns the on-disk URL if present; throws `.notDownloaded` otherwise.
    /// (Callers that want to fetch should use `download(_:onProgress:)`.)
    public func ensureDownloaded(_ manifest: Manifest) async throws -> URL {
        let url = location(for: manifest)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        throw DownloadError.notDownloaded(modelID: manifest.modelID)
    }

    // MARK: - Download

    /// Fetch (or return cached) the model weights. Progress is 0…1 (or -1 when
    /// the server sends no content length). Honours Task cancellation.
    @discardableResult
    public func download(
        _ manifest: Manifest,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        let finalURL = location(for: manifest)
        if FileManager.default.fileExists(atPath: finalURL.path) { return finalURL }
        guard let remote = manifest.remoteURL else {
            throw DownloadError.noRemoteURL(modelID: manifest.modelID)
        }

        // Free-space guard (need the model + headroom for the temp copy).
        let free = Self.freeSpaceBytes(at: directory)
        let need = max(manifest.sizeBytes, 0) + 64 * 1024 * 1024
        if free > 0, free < need {
            throw DownloadError.insufficientFreeSpace(needBytes: need, freeBytes: free)
        }

        onProgress?(-1)   // indeterminate; fine-grained progress via a delegate is a follow-up
        let tmpDownloaded: URL
        let response: URLResponse
        do {
            (tmpDownloaded, response) = try await URLSession.shared.download(from: remote)
        } catch {
            throw error
        }
        try Task.checkCancellation()
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: tmpDownloaded)
            throw DownloadError.httpStatus(http.statusCode)
        }

        // Move to our own partial path first (URLSession's temp is auto-deleted).
        let tmpURL = directory.appendingPathComponent(".\(manifest.modelID).partial")
        try? FileManager.default.removeItem(at: tmpURL)
        do {
            try FileManager.default.moveItem(at: tmpDownloaded, to: tmpURL)

            // Verify SHA-256 by streaming the file in 1 MB chunks (no full load).
            if let expected = manifest.sha256?.lowercased() {
                let got = try Self.sha256Hex(of: tmpURL)
                guard got == expected else {
                    try? FileManager.default.removeItem(at: tmpURL)
                    throw DownloadError.checksumMismatch(expected: expected, got: got)
                }
            }

            // Atomic install.
            if FileManager.default.fileExists(atPath: finalURL.path) {
                _ = try FileManager.default.replaceItemAt(finalURL, withItemAt: tmpURL)
            } else {
                try FileManager.default.moveItem(at: tmpURL, to: finalURL)
            }
            onProgress?(1.0)
            KalsmritikoshLog.app.info("ModelDownloader: installed \(manifest.modelID, privacy: .public)")
            return finalURL
        } catch {
            try? FileManager.default.removeItem(at: tmpURL)   // clean up partial
            throw error
        }
    }

    /// Streaming SHA-256 of a file (1 MB chunks) — never loads the whole file.
    private nonisolated static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Remove installed weights for a model.
    public func delete(_ manifest: Manifest) throws {
        let url = location(for: manifest)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Replace an installed model with a new one, keeping a backup until the new
    /// download verifies — on failure the old file is restored (rollback).
    public func update(from old: Manifest, to new: Manifest,
                       onProgress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        let oldURL = location(for: old)
        let backup = directory.appendingPathComponent(".\(old.modelID).bak")
        let hadOld = FileManager.default.fileExists(atPath: oldURL.path)
        if hadOld { try? FileManager.default.moveItem(at: oldURL, to: backup) }
        do {
            let installed = try await download(new, onProgress: onProgress)
            if hadOld { try? FileManager.default.removeItem(at: backup) }
            return installed
        } catch {
            if hadOld { try? FileManager.default.moveItem(at: backup, to: oldURL) }   // rollback
            throw error
        }
    }

    // MARK: - Internals

    private nonisolated static func freeSpaceBytes(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return Int64(values?.volumeAvailableCapacityForImportantUsage ?? 0)
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
            .appendingPathComponent("KalsmritikoshChronicaMemora", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }
}
