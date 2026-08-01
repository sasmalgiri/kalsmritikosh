//
//  SourceByteCapture.swift
//  Kalsmritikosh
//
//  USF-001 — bounded streaming byte capture. Hashes a file through an incremental
//  SHA-256 over a FileHandle (never Data(contentsOf:) for whole-file hashing), so empty,
//  large, unknown, binary and larger-than-memory files are all handled safely. Captures
//  a stable attribute snapshot before and after; if the bytes may have changed during
//  hashing, it refuses to register a version. Type detection (declared extension, detected
//  type, detection basis, MIME) is recorded separately — never treated as proof a parser
//  succeeded.
//

import Foundation
import CryptoKit
import UniformTypeIdentifiers

public enum SourceByteCapture {

    /// 1 MiB streaming window — bounded memory regardless of file size.
    private static let chunkSize = 1 << 20

    /// Stream `url`'s bytes into a SHA-256 and return the captured source metadata.
    /// Throws when the input is not a regular file, cannot be read, or changes during capture.
    public static func capture(_ url: URL) throws -> CapturedSource {
        try streamCapture(url, identityURL: url, snapshotHandle: nil, snapshotURL: nil).captured
    }

    /// USF-001.2 — capture the exact bytes AND, in the SAME verified streaming pass, write an
    /// immutable processing snapshot into `snapshotDirectory` (named after the original file so
    /// filename-derived loader/parser behaviour is preserved). The bytes fed to the SHA-256 are
    /// the SAME bytes written to the snapshot, so the snapshot content is provably the content
    /// that produced the intake hash. The loader and structural parser consume ONLY this snapshot
    /// — never the mutable original — so a source that changes after capture can never be parsed
    /// under an intake hash it no longer matches. Returns the captured metadata and the snapshot
    /// URL; the caller owns the snapshot's lifetime and removes it after processing.
    public static func captureToSnapshot(_ url: URL, snapshotDirectory: URL) throws -> (captured: CapturedSource, snapshotURL: URL) {
        try captureToSnapshot(byteURL: url, identityURL: url, snapshotDirectory: snapshotDirectory)
    }

    /// USF-M2 §10 — capture bytes from `byteURL` (e.g. a temporary extracted archive member) while
    /// recording IDENTITY from `identityURL` (a stable virtual origin like
    /// `kalsmritikosh-container://<parent>/<ordinal>/<name>`). The bytes/hash/snapshot come from
    /// `byteURL`; the filename, declared extension, path-pattern/extension detection, and MIME come
    /// from `identityURL`, so a temporary extraction path never becomes durable custody identity.
    public static func captureToSnapshot(byteURL: URL, identityURL: URL, snapshotDirectory: URL) throws -> (captured: CapturedSource, snapshotURL: URL) {
        try FileManager.default.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)
        let snapshotURL = snapshotDirectory.appendingPathComponent(identityURL.lastPathComponent, isDirectory: false)
        FileManager.default.createFile(atPath: snapshotURL.path, contents: nil)
        guard let out = try? FileHandle(forWritingTo: snapshotURL) else {
            throw SourceIntakeError.snapshotCreationFailed(byteURL)
        }
        do {
            let captured = try streamCapture(byteURL, identityURL: identityURL, snapshotHandle: out, snapshotURL: snapshotURL).captured
            try? out.close()
            return (captured, snapshotURL)
        } catch {
            try? out.close()
            try? FileManager.default.removeItem(at: snapshotURL)
            throw error
        }
    }

    /// Shared bounded streaming pass. Bytes/hash come from `url`; type detection + filename come from
    /// `identityURL` (usually the same). When `snapshotHandle` is provided, every hashed chunk is
    /// ALSO written to it, so the snapshot bytes and the hashed bytes are identical by construction.
    private static func streamCapture(_ url: URL, identityURL: URL, snapshotHandle: FileHandle?, snapshotURL: URL?) throws
    -> (captured: CapturedSource, snapshotURL: URL?) {
        // Must be a regular file.
        let preValues = try resourceSnapshot(url)
        guard preValues.isRegularFile else { throw SourceIntakeError.notARegularFile(url) }

        // Stream-hash through a bounded window.
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw SourceIntakeError.inputNotAccessible(url)
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        var size: Int64 = 0
        var head = Data()
        do {
            while true {
                let chunk = try handle.read(upToCount: chunkSize) ?? Data()
                if chunk.isEmpty { break }
                if head.count < 4096 { head.append(chunk.prefix(4096 - head.count)) }
                size += Int64(chunk.count)
                hasher.update(data: chunk)
                if let snapshotHandle { try snapshotHandle.write(contentsOf: chunk) }
            }
        } catch {
            throw SourceIntakeError.hashComputationFailed(url)
        }
        let digest = hasher.finalize()
        let contentHash = digest.map { String(format: "%02x", $0) }.joined()

        // Re-snapshot: reject if the bytes may have changed while we read them.
        let postValues = try resourceSnapshot(url)
        guard preValues.size == postValues.size,
              preValues.size == size,
              datesEqual(preValues.modifiedAt, postValues.modifiedAt),
              identifiersEqual(preValues.resourceID, postValues.resourceID) else {
            throw SourceIntakeError.sourceChangedDuringCapture(url)
        }

        let (detectedType, basis, declaredExtension) = detectType(url: identityURL, head: head)
        return (CapturedSource(
            contentHash: contentHash,
            sizeBytes: size,
            modifiedAt: preValues.modifiedAt,
            filename: identityURL.lastPathComponent,
            declaredExtension: declaredExtension,
            detectedType: detectedType,
            detectionBasis: basis,
            mimeType: mimeType(for: identityURL)), snapshotURL)
    }

    // MARK: - Type detection (recorded separately; never proof a parser ran)

    /// USF-001.1 + USF-M2 — the ONE authoritative type detector. Order (spec §5, USF-M2 §1):
    /// canonical path/filename pattern → specific unambiguous magic → compound-container
    /// disambiguation → declared extension → unknown.
    /// A canonical pattern (e.g. chat.db, browser History) wins over magic bytes so a
    /// SQLite-backed iMessage/browser source is never flattened to generic `.sqlite`.
    private static func detectType(url: URL, head: Data)
    -> (SourceType, SourceDetectionBasis, String) {
        let declaredExtension = url.pathExtension.lowercased()
        // 1. canonical path / filename pattern.
        if let pattern = SourceType.detectPathPattern(from: url) {
            return (pattern, .pathPattern, declaredExtension)
        }
        // 2. magic bytes.
        if let magic = SourceType.sniffMagicBytes(head) {
            // 2a. USF-M2 compound-container disambiguation: DOCX/XLSX/PPTX/ODT/ODS/EPUB are ZIPs, so
            // ZIP magic + one of those extensions selects the logical subtype. The basis stays
            // .magicBytes (the ZIP signature is what led here); the extension is a subtype selector,
            // NOT proof the package parses. Everything else keeps the unambiguous magic result.
            if magic == .zip {
                return (SourceType.zipSubtype(forDeclaredExtension: declaredExtension), .magicBytes, declaredExtension)
            }
            return (magic, .magicBytes, declaredExtension)
        }
        // 3. declared extension.
        let byExtension = SourceType.detect(from: url)
        if byExtension != .unknown {
            return (byExtension, .declaredExtension, declaredExtension)
        }
        // 4. unknown.
        return (.unknown, .unknown, declaredExtension)
    }

    private static func mimeType(for url: URL) -> String? {
        let ext = url.pathExtension
        guard !ext.isEmpty else { return nil }
        return UTType(filenameExtension: ext)?.preferredMIMEType
    }

    // MARK: - Stable attribute snapshot

    private struct Snapshot {
        let isRegularFile: Bool
        let size: Int64
        let modifiedAt: Date?
        let resourceID: (any NSObjectProtocol)?
    }

    private static func resourceSnapshot(_ url: URL) throws -> Snapshot {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey,
                                         .contentModificationDateKey, .fileResourceIdentifierKey]
        guard let v = try? url.resourceValues(forKeys: keys) else {
            throw SourceIntakeError.inputNotAccessible(url)
        }
        return Snapshot(
            isRegularFile: v.isRegularFile ?? false,
            size: Int64(v.fileSize ?? 0),
            modifiedAt: v.contentModificationDate,
            resourceID: v.fileResourceIdentifier)
    }

    private static func datesEqual(_ a: Date?, _ b: Date?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (x?, y?): return abs(x.timeIntervalSince(y)) < 0.000_5
        default: return false
        }
    }

    private static func identifiersEqual(_ a: (any NSObjectProtocol)?, _ b: (any NSObjectProtocol)?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (x?, y?): return x.isEqual(y)
        default: return false
        }
    }
}
