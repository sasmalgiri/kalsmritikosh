//
//  EVTXStructuralParser.swift
//  Kalsmritikosh
//
//  HOST-3 — turns a Windows event log into dated, citable records.
//
//  Every record carries a written FILETIME and a record id, which is what puts a
//  machine's own account of itself on the timeline: when it was on, when someone
//  logged in, when a service was installed. Those two facts come from the
//  container and are exact.
//
//  WHAT THIS DOES NOT DO, said in the evidence itself and not only in a comment:
//  BinXML TEMPLATES are not resolved, so a record's structured field names —
//  EventID, Provider, Channel, the named Data elements — are not recovered. The
//  UTF-16 strings the record carries ARE recovered, unlabelled. So this log
//  becomes searchable and dated ("a record at 09:26:53 mentioning EVIDENCE-01 and
//  riyaz") but it cannot yet answer "show me every 4624". The parser reports
//  `.partial` with that limitation named, because a reader who assumed otherwise
//  would draw a wrong conclusion from a thin result.
//
//  Read-only, deterministic, offline. Never throws.
//

import Foundation
import CryptoKit

public struct EVTXStructuralParser: StructuralParser {
    public nonisolated var supportedTypes: Set<SourceType> { [.eventLog] }
    public nonisolated var parserName: String { "windows-eventlog-evtx" }
    public nonisolated var parserVersion: String { "1" }

    public nonisolated init() {}

    public func parse(
        data: Data, filename: String, type: SourceType,
        logicalSourceID: UUID, sourceVersionID: UUID
    ) async throws -> ParsedDocument {
        let documentID = UUID()
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let logName = (filename as NSString).lastPathComponent
        var blocks: [EvidenceBlock] = []
        var warnings: [ParserWarning] = []

        func add(_ kind: EvidenceBlockKind, _ raw: String, path: [String],
                 attributes: [String: AnyCodable] = [:]) {
            blocks.append(EvidenceBlock(
                documentID: documentID, sourceVersionID: sourceVersionID,
                ordinal: blocks.count, kind: kind, rawText: raw,
                locator: SourceLocator(sectionPath: [logName] + path),
                attributes: attributes))
        }
        func document(_ status: ExtractionStatus) -> ParsedDocument {
            ParsedDocument(
                id: documentID, logicalSourceID: logicalSourceID, sourceVersionID: sourceVersionID,
                filename: filename, detectedType: .eventLog,
                mimeType: "application/x-ms-evtx", contentHash: hash,
                blocks: blocks, warnings: warnings, extractionStatus: status)
        }

        guard !data.isEmpty else {
            warnings.append(ParserWarning(severity: .warning, code: "evtx.empty",
                                          message: "File is zero bytes."))
            return document(.empty)
        }

        var reader: EVTXReader
        do {
            reader = try EVTXReader(data: data)
        } catch EVTXReader.ReaderError.notAnEventLog {
            warnings.append(ParserWarning(severity: .error, code: "evtx.not_evtx",
                message: "No ElfFile signature: this is not a Windows event log."))
            return document(.corrupt)
        } catch {
            warnings.append(ParserWarning(severity: .error, code: "evtx.truncated",
                message: "File is shorter than an event-log header. \(error)"))
            return document(.corrupt)
        }

        let records = reader.records()
        guard !records.isEmpty else {
            for problem in reader.problems {
                warnings.append(ParserWarning(severity: .warning, code: "evtx.partial",
                                              message: problem))
            }
            return document(.empty)
        }

        let dates = records.compactMap(\.written)
        var header = "Windows event log \"\(logName)\": \(records.count) record(s)"
        if let first = records.first, let last = records.last {
            header += ", ids \(first.recordID)–\(last.recordID)"
        }
        if let earliest = dates.min(), let latest = dates.max() {
            header += ", \(Self.iso8601.string(from: earliest)) to \(Self.iso8601.string(from: latest))"
        }
        header += " (format \(reader.majorVersion).\(reader.minorVersion))"
        add(.documentHeader, header, path: [], attributes: [
            "recordCount": AnyCodable(.int(Int64(records.count))),
            "declaredChunkCount": AnyCodable(.int(Int64(reader.declaredChunkCount))),
            "isDirty": AnyCodable(.bool(reader.isDirty))
        ])

        // The limitation is EVIDENCE, not a footnote. A reader who took a thin
        // result for a complete one would draw a wrong conclusion, so the gap is
        // stated in the document itself.
        add(.paragraph,
            "Record CONTENT is not interpreted: BinXML template resolution is not implemented, "
            + "so field names (EventID, Provider, Channel, named Data elements) are not "
            + "recovered. Each record below carries its exact written time and record id, plus "
            + "the text strings it contains. This log can be searched and placed on a timeline; "
            + "it cannot yet be filtered by event id.",
            path: ["limitations"], attributes: [
                "limitation": AnyCodable(.string("binxml-templates-unresolved"))
            ])

        for record in records {
            var line = "Record \(record.recordID)"
            if let written = record.written {
                line += " written \(Self.iso8601.string(from: written))"
            } else {
                // A record with no time is a different fact from a dated one.
                line += " (no written time recorded)"
            }
            if record.strings.isEmpty {
                line += " — no text recovered"
            } else {
                line += ": " + record.strings.joined(separator: " · ")
            }

            var attributes: [String: AnyCodable] = [
                "recordID": AnyCodable(.int(Int64(bitPattern: record.recordID))),
                "fileOffset": AnyCodable(.int(Int64(record.fileOffset))),
                "stringCount": AnyCodable(.int(Int64(record.strings.count)))
            ]
            if let written = record.written {
                attributes["timestamp"] = AnyCodable(.string(Self.iso8601.string(from: written)))
            }
            add(.logRecord, line, path: ["records", String(record.recordID)],
                attributes: attributes)
        }

        // Always partial: the container is exact, the content is not interpreted.
        warnings.append(ParserWarning(severity: .warning, code: "evtx.binxml_unresolved",
            message: "\(records.count) record(s) read with exact times and ids, but BinXML "
                   + "template resolution is not implemented, so structured field names are "
                   + "not recovered. Strings are harvested unlabelled."))
        for problem in reader.problems {
            warnings.append(ParserWarning(severity: .warning, code: "evtx.partial",
                                          message: problem))
        }
        return document(.partial)
    }

    private nonisolated static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
