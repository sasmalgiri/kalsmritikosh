//
//  RegistryHiveStructuralParser.swift
//  Kalsmritikosh
//
//  HOST-2 — turns a Windows registry hive into typed, citable evidence blocks.
//  A hive is the single richest host artifact on a Windows machine: who had
//  accounts, what software was installed and when, which USB devices were
//  attached, what was typed into Explorer's address bar, the machine's name and
//  time zone. Each key carries a last-written time, which is what puts those
//  facts on a timeline rather than leaving them as trivia.
//
//  Citation model follows the SQLite and plist parsers: a `.sectionHeading` per
//  key (with its last-written time) and a `.tableRow` per value, located by the
//  full registry path — so an answer can cite
//  "SOFTWARE → Microsoft\Windows\CurrentVersion\Run → Updater".
//
//  Read-only, deterministic, offline. Never throws for empty/corrupt input; a
//  hive that will not decode is reported as such.
//

import Foundation
import CryptoKit

public struct RegistryHiveStructuralParser: StructuralParser {
    public nonisolated var supportedTypes: Set<SourceType> { [.registryHive] }
    public nonisolated var parserName: String { "windows-registry-regf" }
    public nonisolated var parserVersion: String { "1" }

    public nonisolated init() {}

    public func parse(
        data: Data, filename: String, type: SourceType,
        logicalSourceID: UUID, sourceVersionID: UUID
    ) async throws -> ParsedDocument {
        let documentID = UUID()
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let hiveName = (filename as NSString).lastPathComponent
        var blocks: [EvidenceBlock] = []
        var warnings: [ParserWarning] = []

        func add(_ kind: EvidenceBlockKind, _ raw: String,
                 path: [String], attributes extra: [String: AnyCodable] = [:]) {
            var attrs = extra
            attrs["registryPath"] = AnyCodable(.string(path.joined(separator: "\\")))
            blocks.append(EvidenceBlock(
                documentID: documentID, sourceVersionID: sourceVersionID,
                ordinal: blocks.count, kind: kind, rawText: raw,
                locator: SourceLocator(sectionPath: [hiveName] + path),
                attributes: attrs))
        }

        guard !data.isEmpty else {
            warnings.append(ParserWarning(severity: .warning, code: "registry.empty",
                                          message: "File is zero bytes."))
            return Self.document(documentID, logicalSourceID, sourceVersionID, filename,
                                 hash, blocks, warnings, .empty)
        }

        var reader: RegistryHiveReader
        let keys: [RegistryHiveReader.Key]
        do {
            reader = try RegistryHiveReader(data: data)
            keys = try reader.keys()
        } catch {
            let code: String
            switch error {
            case RegistryHiveReader.ReaderError.notAHive:      code = "registry.not_regf"
            case RegistryHiveReader.ReaderError.truncated:     code = "registry.truncated"
            case RegistryHiveReader.ReaderError.rootUnreadable: code = "registry.root_unreadable"
            default:                                            code = "registry.unreadable"
            }
            warnings.append(ParserWarning(severity: .error, code: code, message: "\(error)"))
            return Self.document(documentID, logicalSourceID, sourceVersionID, filename,
                                 hash, blocks, warnings, .corrupt)
        }

        // Hive identity first: which hive this is, when it was last written, and
        // the path it occupied on the original machine. That last one is how a
        // hive recovered from an extraction gets attributed to a user account.
        var header = "Windows registry hive \"\(hiveName)\""
        if !reader.embeddedName.isEmpty { header += ", recorded as \"\(reader.embeddedName)\"" }
        header += " (format \(reader.majorVersion).\(reader.minorVersion))"
        if let when = reader.lastWritten { header += ", last written \(Self.iso8601.string(from: when))" }
        add(.documentHeader, header, path: [], attributes: [
            "embeddedName": AnyCodable(.string(reader.embeddedName)),
            "hiveLastWritten": AnyCodable(.string(reader.lastWritten.map(Self.iso8601.string(from:)) ?? ""))
        ])

        var valueCount = 0
        for key in keys {
            let components = key.path.split(separator: "\\").map(String.init)
            var line = key.path.isEmpty ? "(root)" : key.path
            if let when = key.lastWritten { line += "  [last written \(Self.iso8601.string(from: when))]" }
            add(.sectionHeading, line, path: components, attributes: [
                "lastWritten": AnyCodable(.string(key.lastWritten.map(Self.iso8601.string(from:)) ?? "")),
                "valueCount": AnyCodable(.int(Int64(key.values.count)))
            ])
            for value in key.values {
                add(.tableRow, "\(key.path)\\\(value.name) = \(value.rendered)  (\(value.type.label))",
                    path: components + [value.name], attributes: [
                        "valueName": AnyCodable(.string(value.name)),
                        "valueType": AnyCodable(.string(value.type.label)),
                        "byteCount": AnyCodable(.int(Int64(value.byteCount)))
                    ])
                valueCount += 1
            }
        }

        // Everything the reader could not follow is stated, so a thin result is
        // visibly thin rather than looking like a clean empty hive.
        for problem in reader.problems {
            warnings.append(ParserWarning(severity: .warning, code: "registry.partial", message: problem))
        }
        if keys.isEmpty {
            warnings.append(ParserWarning(severity: .warning, code: "registry.no_keys",
                                          message: "Hive decoded but contains no reachable keys."))
        }

        let status: ExtractionStatus = keys.isEmpty
            ? .empty
            : (warnings.isEmpty ? .complete : .partial)
        return Self.document(documentID, logicalSourceID, sourceVersionID, filename,
                             hash, blocks, warnings, status)
    }

    private nonisolated static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private nonisolated static func document(
        _ id: UUID, _ logicalSourceID: UUID, _ sourceVersionID: UUID, _ filename: String,
        _ hash: String, _ blocks: [EvidenceBlock], _ warnings: [ParserWarning],
        _ status: ExtractionStatus
    ) -> ParsedDocument {
        ParsedDocument(
            id: id, logicalSourceID: logicalSourceID, sourceVersionID: sourceVersionID,
            filename: filename, detectedType: .registryHive,
            mimeType: "application/x-ms-registry", contentHash: hash,
            blocks: blocks, warnings: warnings, extractionStatus: status)
    }
}
