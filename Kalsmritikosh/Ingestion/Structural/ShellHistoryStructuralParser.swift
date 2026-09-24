//
//  ShellHistoryStructuralParser.swift
//  Kalsmritikosh
//
//  HOST-4b — shell and REPL history: what was actually TYPED on a machine.
//
//  These files already parsed as plain text, so the commands were searchable.
//  What was missing is the part that matters most in an investigation: WHEN.
//  Three of the four flavours carry per-command timestamps and none of them
//  looked like a date to a text reader —
//
//    bash (HISTTIMEFORMAT set):  #1773480413          on its own line, then the command
//    zsh  (EXTENDED_HISTORY):    : 1773480413:12;command      (epoch:elapsed;command)
//    fish:                       - cmd: command  /  when: 1773480413
//    bare:                       command                       (no time anywhere)
//
//  So a dated history becomes dated evidence, and an UNDATED one says so
//  explicitly rather than leaving a reader to assume the dates are simply
//  missing from the display. In an undated file the ORDER is the evidence, and
//  it is preserved by sequence number — the same ruling reached for chat exports
//  with an unresolvable date order.
//
//  Two things this deliberately does NOT do:
//   - It does not de-duplicate. A command repeated forty times is a fact about
//     what someone was doing, and collapsing it would erase that.
//   - It does not classify commands as suspicious. That is analysis, not
//     extraction, and a wrong label carried next to real evidence reads as if
//     the file had said it.
//
//  Read-only, deterministic, offline. Never throws.
//

import Foundation
import CryptoKit

public struct ShellHistoryStructuralParser: StructuralParser {
    public nonisolated var supportedTypes: Set<SourceType> { [.shellHistory] }
    public nonisolated var parserName: String { "shell-history" }
    public nonisolated var parserVersion: String { "1" }

    public nonisolated init() {}

    /// How this file records time. Decided from CONTENT, not from the filename:
    /// a history copied out of one shell into a file named for another is
    /// routine, and the syntax is unambiguous.
    public enum Flavour: String, Sendable {
        case zshExtended        // ": <epoch>:<elapsed>;command"
        case bashTimestamped    // "#<epoch>" line before each command
        case fish               // "- cmd:" / "  when:" blocks
        case undated            // bare command lines — no time recorded anywhere

        var describedAs: String {
            switch self {
            case .zshExtended: return "zsh with EXTENDED_HISTORY (each command timestamped, with how long it ran)"
            case .bashTimestamped: return "bash with HISTTIMEFORMAT (each command timestamped)"
            case .fish: return "fish (each command timestamped)"
            case .undated: return "no timestamps recorded"
            }
        }
    }

    public struct Command: Sendable, Equatable {
        public let sequence: Int
        public let text: String
        public let time: Date?
        /// How long the command ran, when the shell recorded it (zsh only).
        public let elapsedSeconds: Int?
        /// 1-based line where the command starts, so it is citable in the file.
        public let line: Int
    }

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
                filename: filename, detectedType: .shellHistory,
                mimeType: "text/plain", contentHash: hash,
                blocks: blocks, warnings: warnings, extractionStatus: status)
        }

        guard !data.isEmpty else {
            warnings.append(ParserWarning(severity: .warning, code: "shellhistory.empty",
                                          message: "File is zero bytes."))
            return document(.empty)
        }

        // Decoding: UTF-8, else Latin-1. A shell history can hold raw bytes —
        // zsh writes its own escaped encoding for non-ASCII — and the honest
        // handling is to keep every byte readable and SAY the encoding was not
        // UTF-8, rather than guess at an unescaping that could corrupt a command.
        let content: String
        if let utf8 = String(data: data, encoding: .utf8) {
            content = utf8
        } else {
            warnings.append(ParserWarning(severity: .warning, code: "shellhistory.not_utf8",
                message: "The file contains bytes that are not valid UTF-8 (zsh writes its own "
                       + "escaped encoding for non-ASCII characters). It was read byte-for-byte "
                       + "as Latin-1, so a command containing non-ASCII text may show escape "
                       + "bytes rather than the original characters."))
            // Latin-1: every byte maps to the code point of the same value, so
            // nothing is lost and nothing is invented. It cannot fail.
            content = String(data: data, encoding: .isoLatin1) ?? ""

        }

        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let flavour = Self.detectFlavour(lines: lines)
        let commands = Self.commands(in: lines, flavour: flavour)

        guard !commands.isEmpty else {
            warnings.append(ParserWarning(severity: .warning, code: "shellhistory.no_commands",
                message: "No commands: the file is present but holds no command lines."))
            return document(.empty)
        }

        let dates = commands.compactMap(\.time)
        var header = "Shell history \"\(shortName)\": \(commands.count) command(s), \(flavour.describedAs)"
        if let earliest = dates.min(), let latest = dates.max() {
            header += ", \(Self.iso8601.string(from: earliest)) to \(Self.iso8601.string(from: latest))"
        }
        header += "."
        add(.documentHeader, header, path: [], attributes: [
            "commandCount": AnyCodable(.int(Int64(commands.count))),
            "flavour": AnyCodable(.string(flavour.rawValue)),
            "datedCommandCount": AnyCodable(.int(Int64(dates.count)))
        ])

        // An undated history is a different kind of evidence from a dated one,
        // and the difference must be stated IN the document: an answer that
        // placed these commands at a time would be inventing it.
        if flavour == .undated {
            add(.paragraph,
                "These commands carry NO timestamps: this shell was not configured to record "
                + "them (bash needs HISTTIMEFORMAT, zsh needs EXTENDED_HISTORY). The commands "
                + "cannot be placed at a time or matched against events elsewhere. What the file "
                + "does establish is ORDER — each command below keeps its position in the file — "
                + "and that the account ran them at some point before the file was captured.",
                path: ["limitations"], attributes: [
                    "limitation": AnyCodable(.string("no-command-timestamps"))
                ])
        } else if dates.count < commands.count {
            // Partial dating is normal: the setting was turned on part-way
            // through the file's life. Both halves are real, and which is which
            // matters.
            warnings.append(ParserWarning(severity: .warning, code: "shellhistory.partially_dated",
                message: "\(commands.count - dates.count) of \(commands.count) command(s) carry no "
                       + "timestamp — timestamping was enabled part-way through this file's life. "
                       + "The undated commands come first, in order."))
        }

        for command in commands {
            var line = "Command \(command.sequence): \(command.text)"
            if let time = command.time {
                line += " — run at \(Self.iso8601.string(from: time))"
                if let elapsed = command.elapsedSeconds, elapsed > 0 {
                    line += ", took \(elapsed)s"
                }
            } else {
                line += " — no time recorded"
            }

            var attributes: [String: AnyCodable] = [
                "command": AnyCodable(.string(command.text)),
                "sequence": AnyCodable(.int(Int64(command.sequence))),
                "line": AnyCodable(.int(Int64(command.line)))
            ]
            if let time = command.time {
                attributes["timestamp"] = AnyCodable(.string(Self.iso8601.string(from: time)))
            }
            if let elapsed = command.elapsedSeconds {
                attributes["elapsedSeconds"] = AnyCodable(.int(Int64(elapsed)))
            }
            add(.logRecord, line, path: ["commands", String(command.sequence)],
                attributes: attributes)
        }

        return document(.complete)
    }

    // MARK: - Flavour

    nonisolated static func detectFlavour(lines: [String]) -> Flavour {
        // Scan a window rather than only the first line: a history file's first
        // lines are routinely bare commands from before the setting was enabled.
        for line in lines.prefix(400) {
            if parseZshPrefix(line) != nil { return .zshExtended }
            if bashEpoch(line) != nil { return .bashTimestamped }
            if line.hasPrefix("- cmd: ") { return .fish }
        }
        return .undated
    }

    /// `: <epoch>:<elapsed>;command` → (time, elapsed, command).
    nonisolated static func parseZshPrefix(_ line: String) -> (Date, Int, String)? {
        guard line.hasPrefix(": ") else { return nil }
        let afterColon = line.dropFirst(2)
        guard let semicolon = afterColon.firstIndex(of: ";") else { return nil }
        let stamps = afterColon[afterColon.startIndex..<semicolon].split(separator: ":")
        guard stamps.count == 2,
              let epoch = Int(stamps[0]), let elapsed = Int(stamps[1]),
              epoch > 0 else { return nil }
        let command = String(afterColon[afterColon.index(after: semicolon)...])
        return (Date(timeIntervalSince1970: Double(epoch)), elapsed, command)
    }

    /// A bash timestamp line: `#` then nothing but digits. A typed comment
    /// (`# deploy the thing`) does not match, and neither does `#42`: an epoch
    /// is at least 9 digits, so a short number stays a comment.
    nonisolated static func bashEpoch(_ line: String) -> Date? {
        guard line.hasPrefix("#") else { return nil }
        let digits = line.dropFirst()
        guard digits.count >= 9, digits.count <= 12,
              digits.allSatisfy(\.isNumber), let epoch = Int(digits) else { return nil }
        return Date(timeIntervalSince1970: Double(epoch))
    }

    // MARK: - Commands

    nonisolated static func commands(in lines: [String], flavour: Flavour) -> [Command] {
        switch flavour {
        case .zshExtended: return zshCommands(lines)
        case .bashTimestamped: return bashCommands(lines)
        case .fish: return fishCommands(lines)
        case .undated: return bareCommands(lines)
        }
    }

    private nonisolated static func zshCommands(_ lines: [String]) -> [Command] {
        var out: [Command] = []
        // Continuation lines are COLLECTED and joined once. See `bareCommands`
        // for the measurement that made this necessary.
        var parts: [String] = []
        var meta: (time: Date?, elapsed: Int?, line: Int)?

        func flush() {
            defer { parts.removeAll(keepingCapacity: true); meta = nil }
            guard let meta else { return }
            let text = parts.joined(separator: "\n")
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            out.append(Command(sequence: out.count + 1, text: text, time: meta.time,
                               elapsedSeconds: meta.elapsed, line: meta.line))
        }

        for (index, line) in lines.enumerated() {
            if let (time, elapsed, command) = parseZshPrefix(line) {
                flush()
                parts = [command]
                meta = (time, elapsed, index + 1)
            } else if meta != nil {
                // A multi-line command: zsh writes the newlines literally, so a
                // line without the timestamp prefix continues the command above.
                // Dropping it would silently truncate what was actually run.
                parts.append(line)
            } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                // Commands from before EXTENDED_HISTORY was enabled: real, and
                // genuinely undated.
                out.append(Command(sequence: out.count + 1, text: line, time: nil,
                                   elapsedSeconds: nil, line: index + 1))
            }
        }
        flush()
        return out.map(Self.trimmingTrailingNewlines)
    }

    private nonisolated static func bashCommands(_ lines: [String]) -> [Command] {
        var out: [Command] = []
        var pendingTime: Date?
        var parts: [String] = []
        var meta: (time: Date?, line: Int)?
        // Whether a `#epoch` marker has been seen yet. Before the first one, the
        // file is in its UNDATED region — timestamping was switched on part-way
        // through the file's life, which is the normal case — and there each
        // line is its own command.
        //
        // This distinction is load-bearing. bash marks EVERY dated command, so
        // unmarked lines *after* a marker are the continuation of a multi-line
        // command and must be joined. Applying that rule before the first marker
        // would fuse a whole history of separate commands into one giant command
        // that nobody ever ran.
        var seenAMarker = false

        func flush() {
            defer { parts.removeAll(keepingCapacity: true); meta = nil }
            guard let meta else { return }
            let text = parts.joined(separator: "\n")
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            out.append(Command(sequence: out.count + 1, text: text, time: meta.time,
                               elapsedSeconds: nil, line: meta.line))
        }

        for (index, line) in lines.enumerated() {
            if let time = bashEpoch(line) {
                flush()
                pendingTime = time
                seenAMarker = true
            } else if meta != nil, seenAMarker {
                // Collected, not concatenated — see `bareCommands`.
                parts.append(line)
            } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                flush()
                parts = [line]
                meta = (pendingTime, index + 1)
                pendingTime = nil
                if !seenAMarker { flush() }
            }
        }
        flush()
        return out.map(Self.trimmingTrailingNewlines)
    }

    private nonisolated static func fishCommands(_ lines: [String]) -> [Command] {
        var out: [Command] = []
        var command: String?
        var line = 0
        var time: Date?

        func flush() {
            defer { command = nil; time = nil }
            guard let text = command, !text.isEmpty else { return }
            out.append(Command(sequence: out.count + 1, text: text, time: time,
                               elapsedSeconds: nil, line: line))
        }

        for (index, raw) in lines.enumerated() {
            if raw.hasPrefix("- cmd: ") {
                flush()
                command = String(raw.dropFirst("- cmd: ".count))
                line = index + 1
            } else if raw.hasPrefix("  when: "), command != nil {
                let value = raw.dropFirst("  when: ".count).trimmingCharacters(in: .whitespaces)
                if let epoch = Int(value), epoch > 0 {
                    time = Date(timeIntervalSince1970: Double(epoch))
                }
            }
            // `  paths:` entries and their list items are fish's own bookkeeping,
            // not part of the command.
        }
        flush()
        return out
    }

    /// Lines are accumulated in an ARRAY and joined once. Appending to a String
    /// inside the continuation loop is O(n²) in the number of continued lines:
    /// a 20 000-line history where every line ends in a backslash measured at
    /// 23.8 SECONDS before this change.
    private nonisolated static func bareCommands(_ lines: [String]) -> [Command] {
        var out: [Command] = []
        var parts: [String] = []
        var startLine = 0

        func flush() {
            defer { parts.removeAll(keepingCapacity: true) }
            let text = parts.joined(separator: "\n")
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            out.append(Command(sequence: out.count + 1, text: text, time: nil,
                               elapsedSeconds: nil, line: startLine))
        }

        for (index, line) in lines.enumerated() {
            if !parts.isEmpty {
                // The previous line ended in a backslash, which the shell reads
                // as a continuation; drop the backslash and keep going.
                parts[parts.count - 1] = String(parts[parts.count - 1].dropLast())
                parts.append(line)
                if !line.hasSuffix("\\") { flush() }
                continue
            }
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            parts = [line]
            startLine = index + 1
            if !line.hasSuffix("\\") { flush() }
        }
        flush()
        return out
    }

    /// A multi-line command picks up the file's trailing blank line; the command
    /// itself did not contain it.
    private nonisolated static func trimmingTrailingNewlines(_ command: Command) -> Command {
        var text = command.text
        while text.hasSuffix("\n") { text.removeLast() }
        guard text != command.text else { return command }
        return Command(sequence: command.sequence, text: text, time: command.time,
                       elapsedSeconds: command.elapsedSeconds, line: command.line)
    }

    private nonisolated static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
