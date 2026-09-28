//
//  AmcacheStructuralParser.swift
//  Kalsmritikosh
//
//  HOST-6c — turns Amcache into citable facts about executables that were on
//  the machine.
//
//  The load-bearing sentence, emitted as EVIDENCE and not as a footnote: an
//  Amcache entry proves a file EXISTED at a path, not that it RAN. The inventory
//  task walks the filesystem on a schedule. Reading this artifact as a list of
//  programs that executed is a common and consequential mistake, and an answer
//  built from these blocks must be able to quote the distinction.
//
//  What it does establish is strong: the executable's full path, its publisher
//  and product, its size, its PE link date, and its SHA-1 — a hash that
//  identifies exactly which binary was there, matchable against a hash set long
//  after the file is gone.
//
//  Read-only, deterministic, offline. Never throws.
//

import Foundation
import CryptoKit

public struct AmcacheStructuralParser: StructuralParser {
    public nonisolated var supportedTypes: Set<SourceType> { [.amcache] }
    public nonisolated var parserName: String { "windows-amcache" }
    public nonisolated var parserVersion: String { "1" }

    public nonisolated init() {}

    public func parse(
        data: Data, filename: String, type: SourceType,
        logicalSourceID: UUID, sourceVersionID: UUID
    ) async throws -> ParsedDocument {
        let documentID = UUID()
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let shortName = (filename as NSString).lastPathComponent
        var blocks: [EvidenceBlock] = []
        var warnings: [ParserWarning] = []

        func add(_ kind: EvidenceBlockKind, _ raw: String, path: [String],
                 attributes: [String: AnyCodable] = [:]) {
            blocks.append(EvidenceBlock(
                documentID: documentID, sourceVersionID: sourceVersionID,
                ordinal: blocks.count, kind: kind, rawText: raw,
                locator: SourceLocator(sectionPath: [shortName] + path),
                attributes: attributes))
        }
        func document(_ status: ExtractionStatus) -> ParsedDocument {
            ParsedDocument(
                id: documentID, logicalSourceID: logicalSourceID, sourceVersionID: sourceVersionID,
                filename: filename, detectedType: .amcache,
                mimeType: "application/octet-stream", contentHash: hash,
                blocks: blocks, warnings: warnings, extractionStatus: status)
        }

        guard !data.isEmpty else {
            warnings.append(ParserWarning(severity: .warning, code: "amcache.empty",
                                          message: "File is zero bytes."))
            return document(.empty)
        }

        var hive: RegistryHiveReader
        do {
            hive = try RegistryHiveReader(data: data)
        } catch RegistryHiveReader.ReaderError.notAHive {
            warnings.append(ParserWarning(severity: .error, code: "amcache.not_a_hive",
                message: "No \"regf\" signature: this is not a registry hive, so it is not an "
                       + "Amcache file."))
            return document(.corrupt)
        } catch {
            warnings.append(ParserWarning(severity: .error, code: "amcache.unreadable",
                                          message: "Unreadable registry hive. \(error)"))
            return document(.corrupt)
        }

        let keys: [RegistryHiveReader.Key]
        do { keys = try hive.keys() }
        catch {
            warnings.append(ParserWarning(severity: .error, code: "amcache.unreadable",
                                          message: "The hive's key tree could not be walked. \(error)"))
            return document(.corrupt)
        }
        for problem in hive.problems {
            warnings.append(ParserWarning(severity: .warning, code: "amcache.partial", message: problem))
        }

        let amcache = AmcacheReader(keys: keys, hiveLastWritten: hive.lastWritten)
        for problem in amcache.problems {
            warnings.append(ParserWarning(severity: .warning, code: "amcache.partial", message: problem))
        }

        guard !amcache.files.isEmpty || !amcache.programs.isEmpty
                || amcache.legacyFileKeyCount > 0 else {
            // A readable hive with no inventory is a real state — the wrong hive,
            // or one from a machine where the inventory task never ran.
            warnings.append(ParserWarning(severity: .warning, code: "amcache.no_inventory",
                message: "This hive holds no Amcache inventory keys (\(keys.count) key(s) read). "
                       + "It is a readable registry hive, but not an Amcache file."))
            return document(.empty)
        }

        var header = "Windows Amcache \"\(shortName)\": \(amcache.files.count) executable(s) "
            + "inventoried, \(amcache.programs.count) installed application(s)"
        if amcache.legacyFileKeyCount > 0 {
            header += ", plus \(amcache.legacyFileKeyCount) legacy-schema entr(y/ies) not interpreted"
        }
        header += "."
        add(.documentHeader, header, path: [], attributes: [
            "fileCount": AnyCodable(.int(Int64(amcache.files.count))),
            "programCount": AnyCodable(.int(Int64(amcache.programs.count)))
        ])

        // THE disclosure. First-class evidence, because every block below could
        // otherwise be read as proof that something ran.
        add(.paragraph,
            "An Amcache entry records that a file was PRESENT on this machine — it is NOT "
            + "evidence that the program was EXECUTED. Windows populates this inventory from a "
            + "scheduled task that walks the filesystem, so an entry means the executable "
            + "existed at that path when the task ran. Execution has to be established from a "
            + "different artifact. The key's last-written time below is a property of the "
            + "RECORD, not of the file.",
            path: ["limitations"], attributes: [
                "limitation": AnyCodable(.string("presence-not-execution"))
            ])

        for entry in amcache.files {
            var line = "Executable present: \(entry.path ?? entry.name ?? "(unnamed)")"
            if let name = entry.name, entry.path != nil { line += " (\(name))" }
            if let publisher = entry.publisher { line += ", published by \(publisher)" }
            if let product = entry.productName { line += ", product \(product)" }
            if let version = entry.version { line += " version \(version)" }
            if let size = entry.sizeBytes { line += ", size \(size) bytes" }
            if let sha1 = entry.sha1 { line += ", SHA-1 \(sha1)" }
            if let link = entry.linkDate { line += ", compiled \(link)" }
            if let binary = entry.binaryType { line += " [\(binary)]" }
            if entry.isOSComponent == true { line += " — a Windows operating-system component" }
            if let written = entry.keyLastWritten {
                line += ". Inventory record last written \(Self.iso8601.string(from: written))"
            }
            line += "."

            var attributes: [String: AnyCodable] = [
                "keyPath": AnyCodable(.string(entry.keyPath)),
                // Repeated per block on purpose: a retrieved answer quotes a
                // block, so the caveat has to travel with the fact.
                "evidenceOf": AnyCodable(.string("file-presence"))
            ]
            if let path = entry.path { attributes["executablePath"] = AnyCodable(.string(path)) }
            if let name = entry.name { attributes["executableName"] = AnyCodable(.string(name)) }
            if let sha1 = entry.sha1 { attributes["sha1"] = AnyCodable(.string(sha1)) }
            if let publisher = entry.publisher { attributes["publisher"] = AnyCodable(.string(publisher)) }
            if let written = entry.keyLastWritten {
                attributes["timestamp"] = AnyCodable(.string(Self.iso8601.string(from: written)))
            }
            add(.logRecord, line, path: ["files", entry.name ?? entry.keyPath],
                attributes: attributes)
        }

        for program in amcache.programs {
            var line = "Installed application: \(program.name ?? program.programID ?? "(unnamed)")"
            if let publisher = program.publisher { line += ", published by \(publisher)" }
            if let version = program.version { line += " version \(version)" }
            if let installed = program.installDate { line += ", installed \(installed)" }
            if let root = program.rootDirectory { line += ", in \(root)" }
            if let source = program.source { line += ", recorded from \(source)" }
            line += "."
            var attributes: [String: AnyCodable] = [
                "keyPath": AnyCodable(.string(program.keyPath)),
                "evidenceOf": AnyCodable(.string("application-installed"))
            ]
            if let name = program.name { attributes["applicationName"] = AnyCodable(.string(name)) }
            if let id = program.programID { attributes["programID"] = AnyCodable(.string(id)) }
            add(.logRecord, line, path: ["programs", program.name ?? program.keyPath],
                attributes: attributes)
        }

        return document(.complete)
    }

    private nonisolated static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
