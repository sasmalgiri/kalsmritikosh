//
//  MFTStructuralParser.swift
//  Kalsmritikosh
//
//  HOST-5 — turns the NTFS Master File Table into dated, citable evidence about
//  files, INCLUDING files that were deleted.
//
//  What this establishes that nothing else in an extraction can: the name, size,
//  parent directory and four timestamps of a file whose contents are gone. A
//  deleted record keeps all of it until the slot is reused. For small files the
//  entire content is inside the record and comes back with it.
//
//  THREE THINGS IT STATES RATHER THAN ASSUMES:
//
//  1. DELETED is reported as deleted. A record that is not in use describes a
//     file that was removed; presenting it beside live files without that word
//     would put a deleted file on the timeline as though it were still there.
//  2. A PATH CAN BE STALE. Paths are rebuilt by walking parent references, and a
//     parent whose sequence number no longer matches has had its record reused
//     by a different directory. The path is then what the record says, not where
//     the file was, and it is labelled so.
//  3. NTFS stores the four timestamps TWICE — in $STANDARD_INFORMATION and in
//     $FILE_NAME. When the two disagree that is recorded as a factual
//     discrepancy with both values. It is NOT called timestomping: tools,
//     installers and archive extraction all produce differences, and naming a
//     cause is analysis rather than extraction.
//
//  Read-only, deterministic, offline. Never throws.
//

import Foundation
import CryptoKit

public struct MFTStructuralParser: StructuralParser {
    public nonisolated var supportedTypes: Set<SourceType> { [.masterFileTable] }
    public nonisolated var parserName: String { "ntfs-master-file-table" }
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
                filename: filename, detectedType: .masterFileTable,
                mimeType: "application/octet-stream", contentHash: hash,
                blocks: blocks, warnings: warnings, extractionStatus: status)
        }

        guard !data.isEmpty else {
            warnings.append(ParserWarning(severity: .warning, code: "mft.empty",
                                          message: "File is zero bytes."))
            return document(.empty)
        }

        var reader: MFTReader
        do {
            reader = try MFTReader(data: data)
        } catch MFTReader.ReaderError.notAnMFT {
            warnings.append(ParserWarning(severity: .error, code: "mft.not_an_mft",
                message: "No \"FILE\" record signature at the start: this is not an NTFS master "
                       + "file table."))
            return document(.corrupt)
        } catch {
            warnings.append(ParserWarning(severity: .error, code: "mft.truncated",
                message: "The file is shorter than one MFT record. \(error)"))
            return document(.corrupt)
        }

        let records = reader.records()
        guard !records.isEmpty else {
            for problem in reader.problems {
                warnings.append(ParserWarning(severity: .warning, code: "mft.partial", message: problem))
            }
            return document(.empty)
        }

        // Records that only EXTEND another carry no name of their own; their
        // names belong to the base record and reporting them separately would
        // double-count files.
        let named = records.filter { $0.baseRecordNumber == 0 && $0.primaryName != nil }
        let paths = MFTReader.paths(for: records)
        let deleted = named.filter(\.isDeleted)
        let allDates = named.flatMap { record -> [Date] in
            guard let times = record.standardInformation else { return [] }
            return [times.created, times.modified, times.accessed].compactMap { $0 }
        }

        var header = "NTFS master file table \"\(shortName)\": \(named.count) named record(s), "
            + "\(deleted.count) of them DELETED, \(records.count) record slot(s) read "
            + "(\(reader.recordSize)-byte records)"
        if let earliest = allDates.min(), let latest = allDates.max() {
            header += ", \(Self.iso8601.string(from: earliest)) to \(Self.iso8601.string(from: latest))"
        }
        header += "."
        add(.documentHeader, header, path: [], attributes: [
            "recordCount": AnyCodable(.int(Int64(records.count))),
            "namedRecordCount": AnyCodable(.int(Int64(named.count))),
            "deletedRecordCount": AnyCodable(.int(Int64(deleted.count)))
        ])

        add(.paragraph,
            "An MFT record survives the file it describes: when a file is deleted the record is "
            + "only marked not-in-use, so its name, size, parent and timestamps remain until the "
            + "slot is reused. Records below are marked DELETED where that applies. Timestamps "
            + "are recorded TWICE by NTFS — in $STANDARD_INFORMATION and in $FILE_NAME — and "
            + "where the two disagree both values are shown as a discrepancy. A discrepancy has "
            + "many ordinary causes (installers, archive extraction, copying tools) and is "
            + "reported as a fact about the record, not as a conclusion about anyone's actions.",
            path: ["limitations"], attributes: [
                "limitation": AnyCodable(.string("mft-record-semantics"))
            ])

        for record in named {
            guard let name = record.primaryName else { continue }
            let pathResult = paths[record.recordNumber]

            var line = record.isDeleted ? "DELETED " : ""
            line += record.isDirectory ? "folder" : "file"
            line += " \(name)"
            if let path = pathResult?.path, !path.isEmpty, path != "\\" + name {
                line += " at \(path)"
            }
            switch pathResult?.certainty {
            case .parentReused:
                line += " — NOTE: a directory in this path has since been reused by a different "
                    + "folder, so the path is what the record states, not necessarily where the "
                    + "file was"
            case .parentMissing:
                line += " — its parent directory's record is not in this extraction, so the path "
                    + "above is incomplete"
            case .cycle:
                line += " — the parent chain refers back to itself, so no path could be built"
            case .certain, .none:
                break
            }
            if let size = record.dataSizeBytes, size > 0 {
                line += ", \(size) bytes"
            }
            if record.hardLinkCount > 1 {
                line += ", \(record.hardLinkCount) hard links"
            }
            if record.isBAAD {
                line += ". NTFS marked this record BAD, so its fields are reported as found and "
                    + "should not be relied on"
            }

            let times = record.standardInformation
            if let times, !times.isEmpty {
                var parts: [String] = []
                if let created = times.created { parts.append("created \(Self.iso8601.string(from: created))") }
                if let modified = times.modified { parts.append("modified \(Self.iso8601.string(from: modified))") }
                if let accessed = times.accessed { parts.append("accessed \(Self.iso8601.string(from: accessed))") }
                if let changed = times.recordChanged { parts.append("record changed \(Self.iso8601.string(from: changed))") }
                if !parts.isEmpty { line += ". " + parts.joined(separator: ", ") }
            } else {
                line += ". No timestamps recorded in this record"
            }
            line += "."

            var attributes: [String: AnyCodable] = [
                "recordNumber": AnyCodable(.int(Int64(bitPattern: record.recordNumber))),
                "fileName": AnyCodable(.string(name)),
                "isDeleted": AnyCodable(.bool(record.isDeleted)),
                "isDirectory": AnyCodable(.bool(record.isDirectory)),
                "fileOffset": AnyCodable(.int(Int64(record.fileOffset)))
            ]
            if let path = pathResult?.path { attributes["fullPath"] = AnyCodable(.string(path)) }
            if let certainty = pathResult?.certainty {
                attributes["pathCertainty"] = AnyCodable(.string(certainty.rawValue))
            }
            if let size = record.dataSizeBytes { attributes["sizeBytes"] = AnyCodable(.int(Int64(size))) }
            if let modified = times?.modified {
                attributes["timestamp"] = AnyCodable(.string(Self.iso8601.string(from: modified)))
            }
            add(.logRecord, line, path: ["records", String(record.recordNumber)],
                attributes: attributes)

            // The two timestamp sets, when they disagree.
            if let standard = times,
               let nameEntry = record.names.first(where: { !$0.isDOSOnly }) ?? record.names.first,
               !nameEntry.timestamps.isEmpty,
               nameEntry.timestamps != standard {
                let differing = Self.describeDiscrepancy(standard: standard,
                                                         fileName: nameEntry.timestamps)
                if !differing.isEmpty {
                    add(.logRecord,
                        "\(name): the two independent timestamp sets in this record DISAGREE — "
                        + differing
                        + ". NTFS writes both, and ordinary operations (installers, archive "
                        + "extraction, file-copying tools) can produce a difference, so this is "
                        + "recorded as a property of the record and not as a conclusion.",
                        path: ["records", String(record.recordNumber), "timestampDiscrepancy"],
                        attributes: [
                            "fileName": AnyCodable(.string(name)),
                            "recordNumber": AnyCodable(.int(Int64(bitPattern: record.recordNumber))),
                            "observation": AnyCodable(.string("timestamp-sets-disagree"))
                        ])
                }
            }

            // Resident content: the whole small file, out of the MFT itself.
            if let resident = record.residentData, !record.isBAAD,
               let text = Self.readableText(resident) {
                add(.paragraph,
                    "Content of \(name), recovered in full from its MFT record "
                    + "(\(resident.count) bytes, stored inside the record because the file is "
                    + "small): \(text)",
                    path: ["records", String(record.recordNumber), "content"],
                    attributes: [
                        "fileName": AnyCodable(.string(name)),
                        "residentBytes": AnyCodable(.int(Int64(resident.count)))
                    ])
            }
        }

        for problem in reader.problems {
            warnings.append(ParserWarning(severity: .warning, code: "mft.partial", message: problem))
        }
        return document(.complete)
    }

    /// Which of the four times differ, with both values. Naming the field and
    /// showing both is the whole value: "they differ" alone is not evidence.
    nonisolated static func describeDiscrepancy(standard: MFTReader.Timestamps,
                                                fileName: MFTReader.Timestamps) -> String {
        var parts: [String] = []
        func compare(_ label: String, _ a: Date?, _ b: Date?) {
            guard a != b else { return }
            let left = a.map { Self.iso8601.string(from: $0) } ?? "none"
            let right = b.map { Self.iso8601.string(from: $0) } ?? "none"
            parts.append("\(label) is \(left) in $STANDARD_INFORMATION but \(right) in $FILE_NAME")
        }
        compare("created", standard.created, fileName.created)
        compare("modified", standard.modified, fileName.modified)
        compare("accessed", standard.accessed, fileName.accessed)
        compare("record changed", standard.recordChanged, fileName.recordChanged)
        return parts.joined(separator: "; ")
    }

    /// Resident content as text, when it IS text. Binary content is not rendered
    /// as mojibake that would pollute a search index and look like recovered
    /// words; its presence is still recorded by the size in the record's block.
    nonisolated static func readableText(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .utf16LittleEndian) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Mostly-printable, or it is not text that was meant to be read.
        let printable = trimmed.unicodeScalars.filter {
            !$0.properties.isDefaultIgnorableCodePoint && ($0.value >= 0x20 || $0 == "\n" || $0 == "\t")
        }
        guard printable.count * 10 >= trimmed.unicodeScalars.count * 9 else { return nil }
        return trimmed
    }

    private nonisolated static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
