//
//  ExtractionManifestStructuralParser.swift
//  Kalsmritikosh
//
//  HOST-8b — turns an iOS backup's Manifest.db into the extraction's INVENTORY:
//  citable evidence of what the extraction contained and where each file sits.
//
//  This is a distinct forensic fact from the file contents. The inventory answers
//  questions the contents cannot:
//    • "Did this backup contain WhatsApp at all?" — coverage, including absence.
//    • "Where is sms.db in this folder?" — the SHA-1 mapping, so the examiner can
//      open the actual file.
//    • "What was on the device but is 0 bytes here?" — a truncated extraction.
//
//  Absence is the point of the coverage blocks. "No AppDomain-org.signal.Signal
//  entry in this backup" is a finding; silence about it is not.
//

import Foundation
import CryptoKit

public struct ExtractionManifestStructuralParser: StructuralParser {
    public nonisolated var supportedTypes: Set<SourceType> { [.extractionManifest] }
    public nonisolated var parserName: String { "ios-backup-manifest" }
    public nonisolated var parserVersion: String { "1" }

    /// Per-file blocks are capped; the domain summary always covers everything, so
    /// coverage stays complete even when individual citations stop.
    public nonisolated static let fileBlockCap = 20_000

    public nonisolated init() {}

    public func parse(
        data: Data, filename: String, type: SourceType,
        logicalSourceID: UUID, sourceVersionID: UUID
    ) async throws -> ParsedDocument {
        let documentID = UUID()
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        var blocks: [EvidenceBlock] = []
        var warnings: [ParserWarning] = []

        func add(_ kind: EvidenceBlockKind, _ raw: String, path: [String],
                 attributes: [String: AnyCodable] = [:]) {
            blocks.append(EvidenceBlock(
                documentID: documentID, sourceVersionID: sourceVersionID,
                ordinal: blocks.count, kind: kind, rawText: raw,
                locator: SourceLocator(sectionPath: ["Extraction inventory"] + path),
                attributes: attributes))
        }
        func document(_ status: ExtractionStatus) -> ParsedDocument {
            ParsedDocument(
                id: documentID, logicalSourceID: logicalSourceID, sourceVersionID: sourceVersionID,
                filename: filename, detectedType: .extractionManifest,
                mimeType: "application/vnd.apple.ios-backup-manifest",
                contentHash: hash, blocks: blocks, warnings: warnings, extractionStatus: status)
        }

        guard !data.isEmpty else {
            warnings.append(ParserWarning(severity: .warning, code: "extraction.empty",
                                          message: "Manifest is zero bytes."))
            return document(.empty)
        }

        let manifest: IOSBackupManifest
        do {
            manifest = try IOSBackupManifest(manifestData: data)
        } catch IOSBackupManifest.ManifestError.notAManifest {
            warnings.append(ParserWarning(severity: .error, code: "extraction.no_files_table",
                message: "No Files table: this is a SQLite database but not an iOS backup "
                       + "manifest, so no file mapping can be recovered."))
            return document(.corrupt)
        } catch {
            warnings.append(ParserWarning(severity: .error, code: "extraction.unreadable",
                                          message: "\(error)"))
            return document(.corrupt)
        }

        guard !manifest.entries.isEmpty else {
            for problem in manifest.problems {
                warnings.append(ParserWarning(severity: .warning, code: "extraction.partial",
                                              message: problem))
            }
            return document(.empty)
        }

        let domains = manifest.domainCounts
        let totalBytes = manifest.entries.compactMap(\.size).reduce(0, +)
        add(.documentHeader,
            "iOS backup inventory: \(manifest.entries.count) entr(ies), "
            + "\(manifest.fileCount) file(s) across \(domains.count) domain(s), "
            + "\(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)) accounted for",
            path: [], attributes: [
                "entryCount": AnyCodable(.int(Int64(manifest.entries.count))),
                "fileCount": AnyCodable(.int(Int64(manifest.fileCount))),
                "domainCount": AnyCodable(.int(Int64(domains.count))),
                "totalBytes": AnyCodable(.int(totalBytes))
            ])

        // Coverage first: which app and system areas this extraction actually
        // reaches. This is the block an examiner needs to know what the backup
        // can and cannot answer.
        for (domain, count) in domains {
            var line = "Domain \(domain): \(count) entr(ies)"
            if let bundleID = manifest.entries(inDomain: domain).first?.appBundleID {
                line += " — app \(bundleID)"
            }
            add(.sectionHeading, line, path: ["domains", domain], attributes: [
                "domain": AnyCodable(.string(domain)),
                "entryCount": AnyCodable(.int(Int64(count)))
            ])
        }

        // Then the mapping, which is what lets someone open the real file.
        var emitted = 0
        for entry in manifest.entries where entry.kind == .file {
            if emitted >= Self.fileBlockCap { break }
            var line = entry.virtualPath
            if let size = entry.size {
                line += " (\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))"
                if size == 0 { line += ", EMPTY" }
                line += ")"
            } else {
                // Stated, because an unknown size can mean a truncated extraction.
                line += " (size unknown)"
            }
            if let modified = entry.modified {
                line += " modified \(Self.iso8601.string(from: modified))"
            }
            if let stored = entry.storedRelativePath { line += " → stored at \(stored)" }

            var attributes: [String: AnyCodable] = [
                "domain": AnyCodable(.string(entry.domain)),
                "relativePath": AnyCodable(.string(entry.relativePath)),
                "fileID": AnyCodable(.string(entry.fileID))
            ]
            if let stored = entry.storedRelativePath {
                attributes["storedPath"] = AnyCodable(.string(stored))
            }
            if let size = entry.size { attributes["byteCount"] = AnyCodable(.int(size)) }
            if let modified = entry.modified {
                attributes["timestamp"] = AnyCodable(.string(Self.iso8601.string(from: modified)))
            }
            if let bundleID = entry.appBundleID {
                attributes["appBundleID"] = AnyCodable(.string(bundleID))
            }
            add(.tableRow, line, path: [entry.domain, entry.relativePath], attributes: attributes)
            emitted += 1
        }

        if manifest.fileCount > emitted {
            warnings.append(ParserWarning(severity: .warning, code: "extraction.file_cap",
                message: "\(manifest.fileCount - emitted) of \(manifest.fileCount) files have no "
                       + "individual inventory entry (cap \(Self.fileBlockCap)). Domain coverage "
                       + "above still counts every file."))
        }
        let empties = manifest.entries.filter { $0.kind == .file && $0.size == 0 }.count
        if empties > 0 {
            warnings.append(ParserWarning(severity: .warning, code: "extraction.empty_files",
                message: "\(empties) file(s) are listed with zero bytes, which can mean a "
                       + "truncated or partial extraction rather than genuinely empty files."))
        }
        for problem in manifest.problems {
            warnings.append(ParserWarning(severity: .warning, code: "extraction.partial",
                                          message: problem))
        }

        return document(warnings.isEmpty ? .complete : .partial)
    }

    private nonisolated static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
