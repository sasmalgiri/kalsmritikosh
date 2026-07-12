//
//  ArchiveLoader.swift
//  Kalsmritikosh
//
//  ZIP archives are walked recursively: every entry is extracted to a
//  per-archive temp directory and returned via `extractedURLs` so the
//  IngestCoordinator can re-feed each one through the standard pipeline.
//  RAR / 7Z remain metadata-only stubs (no Apple-bundled decoder).
//

import Foundation

public struct ArchiveLoader: Ingestor {
    public let supportedTypes: Set<SourceType> = [.zip, .rar, .sevenZip]

    public nonisolated init() {}

    public func ingest(fileAt url: URL, type: SourceType) async throws -> KnowledgeObject {
        switch type {
        case .zip:
            return try ingestZIP(at: url)
        default:
            return binaryStub(at: url, type: type)
        }
    }

    /// Reads the ZIP central directory and reports a manifest. Extraction
    /// to disk is offered as a static helper the IngestCoordinator can
    /// use to recursively ingest each entry.
    private func ingestZIP(at url: URL) throws -> KnowledgeObject {
        let reader: ZIPReader
        do { reader = try ZIPReader(url: url) }
        catch { throw IngestorError.unreadable(url, underlying: error) }
        let entries = (try? reader.entries()) ?? []
        let summary = entries.prefix(80).map { entry in
            "- \(entry.name) (\(entry.uncompressedSize) bytes)"
        }.joined(separator: "\n")
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let size = (attrs[.size] as? Int64) ?? 0
        return KnowledgeObject(
            sourceFile: url,
            sourceType: .zip,
            content: "ZIP archive containing \(entries.count) entry(ies):\n\(summary)",
            metadata: [
                "filename": AnyCodable(.string(url.lastPathComponent)),
                "binarySize": AnyCodable(.int(size)),
                "loader": AnyCodable(.string("zip-manifest")),
                "entryCount": AnyCodable(.int(Int64(entries.count)))
            ],
            confidence: .medium
        )
    }

    private func binaryStub(at url: URL, type: SourceType) -> KnowledgeObject {
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let size = (attrs[.size] as? Int64) ?? 0
        let label: String
        switch type {
        case .rar: label = "RAR archive; native decoder pending."
        case .sevenZip: label = "7z archive; native decoder pending."
        default: label = "Archive; native decoder pending."
        }
        return KnowledgeObject(
            sourceFile: url,
            sourceType: type,
            content: label,
            metadata: [
                "filename": AnyCodable(.string(url.lastPathComponent)),
                "binarySize": AnyCodable(.int(size)),
                "loaderStub": AnyCodable(.string("archive"))
            ],
            confidence: .low
        )
    }

    // MARK: - Static expansion helper

    // P4.11 — ZIP expansion security limits. Defends against zip bombs,
    // entry floods, and path-traversal / zip-slip.
    /// Max entries expanded from one archive (entry-flood guard).
    public nonisolated static let maxEntries = 20_000
    /// Max total uncompressed bytes across all entries (zip-bomb guard).
    public nonisolated static let maxTotalExpandedBytes: Int = 4 * 1024 * 1024 * 1024   // 4 GB
    /// Max uncompressed bytes for any single entry.
    public nonisolated static let maxEntryBytes: Int = 1024 * 1024 * 1024               // 1 GB

    public enum ArchiveSecurityError: Error, Sendable {
        case tooManyEntries(Int)
        case expandedTooLarge(Int)
        case entryTooLarge(name: String, size: Int)
    }

    /// Expands a ZIP archive into a per-archive temp directory and returns the
    /// URLs of each regular-file entry, ready for the IngestCoordinator to
    /// re-ingest. Enforces P4.11 security limits: entry count, total + per-entry
    /// expanded size (zip bomb), and canonical containment (zip-slip / symlink
    /// traversal). Malformed or escaping entries are skipped, not fatal — but a
    /// zip bomb aborts the whole expansion.
    public nonisolated static func expandZIP(at url: URL) throws -> (root: URL, files: [URL]) {
        let reader = try ZIPReader(url: url)
        let entries = try reader.entries()
        guard entries.count <= maxEntries else {
            throw ArchiveSecurityError.tooManyEntries(entries.count)
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kalsmritikosh-zip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Canonical root path with a trailing slash so prefix checks can't be
        // fooled by a sibling dir sharing the prefix (e.g. root vs root-evil).
        let rootPath = root.standardizedFileURL.path + "/"

        var out: [URL] = []
        var totalBytes = 0
        for entry in entries {
            // Directory marker — name ends with "/".
            if entry.name.hasSuffix("/") { continue }
            // Reject absolute paths and traversal outright.
            if entry.name.hasPrefix("/") || entry.name.contains("..") { continue }
            // Per-entry size guard BEFORE inflating.
            if entry.uncompressedSize > maxEntryBytes {
                throw ArchiveSecurityError.entryTooLarge(name: entry.name, size: entry.uncompressedSize)
            }

            let destination = root.appendingPathComponent(entry.name)
            // Canonical containment (zip-slip): the resolved path MUST stay
            // inside root. Catches ../ that survived and symlink-style escapes.
            guard destination.standardizedFileURL.path.hasPrefix(rootPath) else { continue }

            let data = try reader.extract(entry: entry)
            totalBytes += data.count
            if totalBytes > maxTotalExpandedBytes {
                throw ArchiveSecurityError.expandedTooLarge(totalBytes)
            }
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: destination)
            out.append(destination)
        }
        return (root, out)
    }
}
