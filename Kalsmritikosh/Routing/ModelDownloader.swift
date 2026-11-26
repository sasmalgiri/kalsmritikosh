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

        // Speed PERF-25 (owner 2026-11-23) — not tested yet. The download manager's fetch: bytes stream into our own
        // partial file while they are hashed (no second read to verify), progress is real, and a partial left by an
        // interrupted download is RESUMED with an HTTP Range request (the bytes already on disk are hashed once to seed the
        // digest). A server that ignores the range (200) starts over.
        let tmpURL = directory.appendingPathComponent(".\(manifest.modelID).partial")
        let fm = FileManager.default
        do {
            var hasher = SHA256()
            var have: Int64 = 0
            if let st = StreamingFileCopy.stamp(tmpURL), st.size > 0 {
                let h = try FileHandle(forReadingFrom: tmpURL)
                defer { try? h.close() }
                while let chunk = try h.read(upToCount: StreamingFileCopy.bufferBytes), !chunk.isEmpty {
                    hasher.update(data: chunk); have += Int64(chunk.count)
                }
            }
            var request = URLRequest(url: remote)
            if have > 0 { request.setValue("bytes=\(have)-", forHTTPHeaderField: "Range") }
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 200
            if !(200...299).contains(status) {
                if status == 416, have > 0 {
                    // The partial is already the whole file: verify and install below.
                } else {
                    throw DownloadError.httpStatus(status)
                }
            }
            if status == 200, have > 0 {            // the range was ignored: start again
                hasher = SHA256(); have = 0
                try? fm.removeItem(at: tmpURL)
            }
            if !fm.fileExists(atPath: tmpURL.path) { fm.createFile(atPath: tmpURL.path, contents: nil) }
            let out = try FileHandle(forWritingTo: tmpURL)
            var outClosed = false
            defer { if !outClosed { try? out.close() } }
            try out.seekToEnd()
            if status != 416 {
                let expectedTotal: Int64 = response.expectedContentLength > 0 ? have + response.expectedContentLength : max(manifest.sizeBytes, 0)
                var buffer = Data()
                buffer.reserveCapacity(StreamingFileCopy.bufferBytes)
                var lastReported = -1.0
                func flush() throws {
                    guard !buffer.isEmpty else { return }
                    hasher.update(data: buffer)
                    try out.write(contentsOf: buffer)
                    have += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    if expectedTotal > 0 {
                        let p = min(0.999, Double(have) / Double(expectedTotal))
                        if p - lastReported >= 0.005 { lastReported = p; onProgress?(p) }
                    } else {
                        onProgress?(-1)
                    }
                }
                for try await byte in bytes {
                    buffer.append(byte)
                    if buffer.count >= 1 << 20 { try flush(); try Task.checkCancellation() }
                }
                try flush()
            }
            outClosed = true
            try out.close()
            try Task.checkCancellation()

            if let expected = manifest.sha256?.lowercased() {
                let got = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                guard got == expected else {
                    try? fm.removeItem(at: tmpURL)          // a wrong file is never resumed
                    throw DownloadError.checksumMismatch(expected: expected, got: got)
                }
            }

            // Atomic install.
            if fm.fileExists(atPath: finalURL.path) {
                _ = try fm.replaceItemAt(finalURL, withItemAt: tmpURL)
            } else {
                try fm.moveItem(at: tmpURL, to: finalURL)
            }
            onProgress?(1.0)
            KalsmritikoshLog.app.info("ModelDownloader: installed \(manifest.modelID, privacy: .public)")
            return finalURL
        } catch {
            // The partial is KEPT (resumed next time) unless it was proven wrong above.
            KalsmritikoshLog.app.error("ModelDownloader: download stopped; the part fetched is kept to resume: \(error.localizedDescription, privacy: .public)")
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
