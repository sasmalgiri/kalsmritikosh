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

        let (detectedType, basis, declaredExtension) = detectType(url: url, head: head)
        return CapturedSource(
            contentHash: contentHash,
            sizeBytes: size,
            modifiedAt: preValues.modifiedAt,
            filename: url.lastPathComponent,
            declaredExtension: declaredExtension,
            detectedType: detectedType,
            detectionBasis: basis,
            mimeType: mimeType(for: url))
    }

    // MARK: - Type detection (recorded separately; never proof a parser ran)

    private static func detectType(url: URL, head: Data)
    -> (SourceType, SourceDetectionBasis, String) {
        let declaredExtension = url.pathExtension.lowercased()
        // 1. magic bytes take priority over any claimed extension.
        if let magic = SourceType.sniffMagicBytes(head) {
            return (magic, .magicBytes, declaredExtension)
        }
        // 2/3. path + declared extension (SourceType.detect covers both).
        let byPath = SourceType.detect(from: url)
        if byPath != .unknown {
            return (byPath, declaredExtension.isEmpty ? .pathPattern : .declaredExtension, declaredExtension)
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
