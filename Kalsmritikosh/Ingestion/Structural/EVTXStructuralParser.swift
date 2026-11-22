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
//  Unified path SRC-12 (owner 2026-11-22, round 2) — not tested yet. BinXML templates are now
//  resolved (EVTXBinXMLResolver): each record block names its EventID, provider, channel,
//  computer, level and named Data, and carries `eventID` as an attribute so a log can be
//  filtered by event id. The limitation block and `.partial` remain only for records that did
//  not resolve. The paragraph above is the earlier position.
//
//  Read-only, deterministic, offline. Never throws.
//

import Foundation
import CryptoKit

public nonisolated struct EVTXStructuralParser: StructuralParser {
    public nonisolated var supportedTypes: Set<SourceType> { [.eventLog] }
    public nonisolated var parserName: String { "windows-eventlog-evtx" }
    public nonisolated var parserVersion: String { "2" }   // Unified path SRC-12 (owner 2026-11-22, round 2) — not tested yet.

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

        // Unified path SRC-12 (owner 2026-11-22, round 2) — not tested yet. The limitation is stated only
        // when some records did not resolve.
        let unresolved = records.filter { $0.event == nil }.count
        if unresolved > 0 {
        add(.paragraph,
            "\(unresolved) of \(records.count) record(s) could not be interpreted (their BinXML did not "
            + "resolve), so for those records the field names (EventID, Provider, Channel, named Data) "
            + "are not recovered: each carries its exact written time and record id plus the text "
            + "strings it contains, and it cannot be found by event id.",
            path: ["limitations"], attributes: [
                "limitation": AnyCodable(.string("binxml-templates-unresolved")),
                "unresolvedRecords": AnyCodable(.int(Int64(unresolved)))
            ])
        }

        for record in records {
            var line = "Record \(record.recordID)"
            if let written = record.written {
                line += " written \(Self.iso8601.string(from: written))"
            } else {
                // A record with no time is a different fact from a dated one.
                line += " (no written time recorded)"
            }
            if let ev = record.event {
                // Unified path SRC-12 (owner 2026-11-22, round 2) — not tested yet.
                line += " — Event \(ev.eventID.map(String.init) ?? "?")"
                if let provider = ev.provider, !provider.isEmpty { line += " from \(provider)" }
                if let channel = ev.channel, !channel.isEmpty { line += " (\(channel) log)" }
                if let computer = ev.computer, !computer.isEmpty { line += " on \(computer)" }
                let named = ev.data.filter { !$0.value.isEmpty && $0.value != "-" }.prefix(40)
                if !named.isEmpty { line += ": " + named.map { "\($0.name)=\($0.value)" }.joined(separator: " · ") }
            } else if record.strings.isEmpty {
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
            if let ev = record.event {   // Unified path SRC-12 (owner 2026-11-22, round 2) — not tested yet.
                if let id = ev.eventID { attributes["eventID"] = AnyCodable(.int(Int64(id))) }
                if let v = ev.provider { attributes["provider"] = AnyCodable(.string(v)) }
                if let v = ev.channel { attributes["channel"] = AnyCodable(.string(v)) }
                if let v = ev.computer { attributes["computer"] = AnyCodable(.string(v)) }
                if let v = ev.level { attributes["level"] = AnyCodable(.int(Int64(v))) }
            }
            add(.logRecord, line, path: ["records", String(record.recordID)],
                attributes: attributes)
        }

        // Unified path SRC-12 (owner 2026-11-22, round 2) — not tested yet. Partial only when records did not resolve.
        if unresolved > 0 {
            warnings.append(ParserWarning(severity: .warning, code: "evtx.binxml_unresolved",
                message: "\(unresolved) of \(records.count) record(s) could not be interpreted; their "
                       + "strings are harvested unlabelled."))
        }
        for problem in reader.problems {
            warnings.append(ParserWarning(severity: .warning, code: "evtx.partial",
                                          message: problem))
        }
        return document(unresolved > 0 || !reader.problems.isEmpty ? .partial : .complete)
    }

    private nonisolated static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
