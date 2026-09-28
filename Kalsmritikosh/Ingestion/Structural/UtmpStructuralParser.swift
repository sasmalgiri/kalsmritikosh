//
//  UtmpStructuralParser.swift
//  Kalsmritikosh
//
//  HOST-4 — turns Linux login accounting into dated, citable evidence.
//
//  This answers the question an investigation asks first about a machine: who
//  was on it, from where, and when. Unlike a Windows event log (HOST-3, whose
//  BinXML content stays uninterpreted), this format is read COMPLETELY — every
//  field of every record — so the status here is `.complete`, not `.partial`.
//
//  THE ONE THING THAT MUST NOT GO WRONG: `utmp`, `wtmp` and `btmp` share a
//  single record layout and mean three different things, and the meaning exists
//  only in the filename. A `btmp` record is a REJECTED sign-in. Rendering it
//  with the same words as a `wtmp` record would turn a failed break-in into
//  evidence that someone was logged in — the exact inversion that would send an
//  investigation the wrong way. So every block states which file it came from.
//
//  Sessions (login paired with logout) are emitted as DERIVED blocks, marked as
//  inferred, because the file stores two independent records and only the
//  terminal name links them.
//
//  Read-only, deterministic, offline. Never throws.
//

import Foundation
import CryptoKit

public struct UtmpStructuralParser: StructuralParser {
    public nonisolated var supportedTypes: Set<SourceType> { [.loginRecord] }
    public nonisolated var parserName: String { "linux-login-accounting-utmp" }
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
                filename: filename, detectedType: .loginRecord,
                mimeType: "application/octet-stream", contentHash: hash,
                blocks: blocks, warnings: warnings, extractionStatus: status)
        }

        guard !data.isEmpty else {
            warnings.append(ParserWarning(severity: .warning, code: "utmp.empty",
                                          message: "File is zero bytes."))
            return document(.empty)
        }

        var reader: UtmpReader
        do {
            reader = try UtmpReader(data: data, filename: filename)
        } catch UtmpReader.ReaderError.notLoginRecords {
            warnings.append(ParserWarning(severity: .error, code: "utmp.not_utmp",
                message: "These bytes do not decode as Linux login accounting in either byte "
                       + "order: no reading produces valid record types and plausible dates."))
            return document(.corrupt)
        } catch {
            warnings.append(ParserWarning(severity: .error, code: "utmp.unreadable",
                                          message: "Unreadable login-accounting file. \(error)"))
            return document(.corrupt)
        }

        let records = reader.records()
        guard !records.isEmpty else {
            for problem in reader.problems {
                warnings.append(ParserWarning(severity: .warning, code: "utmp.partial",
                                              message: problem))
            }
            warnings.append(ParserWarning(severity: .warning, code: "utmp.no_records",
                message: "No records: the file is present but holds no login accounting."))
            return document(.empty)
        }

        // A file of nothing but empty slots is a real state — a cleared or
        // freshly-rotated log — and saying so is a finding, not a gap.
        let meaningful = records.filter { $0.kind != .empty }
        let dates = meaningful.compactMap(\.time)

        var header = "Linux login accounting \"\(shortName)\" — \(reader.file.whatTheFileIs). "
            + "\(records.count) record(s)"
        if meaningful.count != records.count {
            header += " (\(records.count - meaningful.count) empty slot(s))"
        }
        if let earliest = dates.min(), let latest = dates.max() {
            header += ", \(Self.iso8601.string(from: earliest)) to \(Self.iso8601.string(from: latest))"
        }
        header += "."
        add(.documentHeader, header, path: [], attributes: [
            "recordCount": AnyCodable(.int(Int64(records.count))),
            "accountingFile": AnyCodable(.string(Self.fileKey(reader.file))),
            "byteOrder": AnyCodable(.string(reader.isBigEndian ? "big-endian" : "little-endian"))
        ])

        // MARK: Derived sessions — stated as inferred

        let sessions = UtmpReader.sessions(from: records)
        if reader.file != .failedAttempts, !sessions.isEmpty {
            for session in sessions {
                var line = "\(session.user.isEmpty ? "(no account recorded)" : session.user) "
                    + "signed in at \(Self.iso8601.string(from: session.start))"
                if !session.line.isEmpty { line += " on \(session.line)" }
                if !session.host.isEmpty { line += " from \(session.host)" }
                if let end = session.end {
                    line += ", until \(Self.iso8601.string(from: end))"
                    line += " (\(Self.duration(from: session.start, to: end)))"
                } else {
                    // Not zero-length, and not unknown-therefore-omitted: the
                    // absence of an end record is itself the finding.
                    line += ", with no end recorded in this file — the session was still open "
                        + "when the log ended."
                }
                var attributes: [String: AnyCodable] = [
                    "user": AnyCodable(.string(session.user)),
                    "terminal": AnyCodable(.string(session.line)),
                    "start": AnyCodable(.string(Self.iso8601.string(from: session.start))),
                    "fileOffset": AnyCodable(.int(Int64(session.startOffset))),
                    // The pairing is an inference, and a consumer must be able to
                    // tell it apart from a value the file stated.
                    "derived": AnyCodable(.bool(true))
                ]
                if !session.host.isEmpty { attributes["remoteHost"] = AnyCodable(.string(session.host)) }
                if let end = session.end {
                    attributes["end"] = AnyCodable(.string(Self.iso8601.string(from: end)))
                    attributes["durationSeconds"] = AnyCodable(.int(Int64(end.timeIntervalSince(session.start))))
                }
                add(.logRecord, line, path: ["sessions", session.user.isEmpty ? "unknown" : session.user],
                    attributes: attributes)
            }
        }

        // MARK: The records themselves

        for record in records where record.kind != .empty {
            var line: String
            switch (reader.file, record.kind) {
            case (.failedAttempts, _):
                // Never the word "signed in" for a btmp record.
                line = "FAILED sign-in attempt"
                if !record.user.isEmpty { line += " for account \(record.user)" }
            case (_, .bootTime):
                line = "System booted"
            case (_, .runLevel):
                line = "Runlevel change / shutdown"
                if !record.user.isEmpty { line += " (\(record.user))" }
            case (_, .userProcess):
                line = "Session opened"
                if !record.user.isEmpty { line += " by \(record.user)" }
            case (_, .deadProcess):
                line = "Session ended"
                if !record.user.isEmpty { line += " (\(record.user))" }
            case (_, let kind):
                line = kind.label.capitalized
                if !record.user.isEmpty { line += " — \(record.user)" }
            }
            if !record.line.isEmpty { line += " on \(record.line)" }
            if !record.host.isEmpty { line += " from \(record.host)" }
            if let address = record.address, address != record.host {
                line += " (\(address))"
            }
            if let time = record.time {
                line += " at \(Self.iso8601.string(from: time))"
            } else {
                line += " with no time recorded"
            }
            if record.pid != 0 { line += ", pid \(record.pid)" }

            var attributes: [String: AnyCodable] = [
                "recordKind": AnyCodable(.string(String(describing: record.kind))),
                "accountingFile": AnyCodable(.string(Self.fileKey(reader.file))),
                "fileOffset": AnyCodable(.int(Int64(record.fileOffset)))
            ]
            if !record.user.isEmpty { attributes["user"] = AnyCodable(.string(record.user)) }
            if !record.line.isEmpty { attributes["terminal"] = AnyCodable(.string(record.line)) }
            if !record.host.isEmpty { attributes["remoteHost"] = AnyCodable(.string(record.host)) }
            if let address = record.address { attributes["remoteAddress"] = AnyCodable(.string(address)) }
            if let time = record.time {
                attributes["timestamp"] = AnyCodable(.string(Self.iso8601.string(from: time)))
            }
            add(.logRecord, line, path: ["records", String(record.fileOffset)],
                attributes: attributes)
        }

        for problem in reader.problems {
            warnings.append(ParserWarning(severity: .warning, code: "utmp.partial",
                                          message: problem))
        }
        // Every field of every record is decoded, so this is COMPLETE — unless
        // the file itself was short, which the reader reports as a problem.
        let truncated = data.count % UtmpReader.recordSize != 0
        return document(truncated ? .partial : .complete)
    }

    private nonisolated static func fileKey(_ file: UtmpReader.UtmpFile) -> String {
        switch file {
        case .currentlyLoggedIn: return "utmp"
        case .loginHistory: return "wtmp"
        case .failedAttempts: return "btmp"
        }
    }

    /// Human duration. A session length is the fact an investigator reads, and
    /// "4980 seconds" is not it.
    private nonisolated static func duration(from start: Date, to end: Date) -> String {
        let seconds = Int(end.timeIntervalSince(start).rounded())
        guard seconds > 0 else {
            // A logout stamped at or before its login is a clock change, not a
            // negative session. Saying so is better than printing "-2m".
            return "no measurable duration — the end is not later than the start, which happens "
                 + "when the clock was changed during the session"
        }
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m \(seconds % 60)s" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h \(minutes % 60)m" }
        return "\(hours / 24)d \(hours % 24)h"
    }

    private nonisolated static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
