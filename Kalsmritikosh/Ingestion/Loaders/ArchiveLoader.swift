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

    public init() {}

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

    /// Expands a ZIP archive into a per-archive temp directory and
    /// returns the URLs of each regular-file entry, ready for the
    /// IngestCoordinator to re-ingest. Skips directories and entries
    /// with absolute / traversal-style paths.
    public static func expandZIP(at url: URL) throws -> (root: URL, files: [URL]) {
        let reader = try ZIPReader(url: url)
        let entries = try reader.entries()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("atlas-zip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        var out: [URL] = []
        for entry in entries {
            // Directory marker — name ends with "/" and has zero size.
            if entry.name.hasSuffix("/") { continue }
            // Defensively reject absolute paths and traversal.
            if entry.name.hasPrefix("/") || entry.name.contains("..") { continue }

            let destination = root.appendingPathComponent(entry.name)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try reader.extract(entry: entry)
            try data.write(to: destination)
            out.append(destination)
        }
        return (root, out)
    }
}
