//
//  TextChatExportMapper.swift
//  Kalsmritikosh
//
//  DISC-6 — turns WhatsApp / Signal / Slack TEXT exports into DiscussionRecords.
//  This is not a new platform: ChatExportLoader has read these files since Phase
//  K, but it produced ONE KnowledgeObject holding a normalized text blob. Sender
//  and time were present as characters and absent as facts, so no message had an
//  author the entity layer could unify or a date the timeline could use. For the
//  most-used messaging platform in the world, that is a real gap.
//
//  The three line shapes are reused verbatim from ChatExportLoader, which already
//  scores them against the file's opening lines. What is added is meaning:
//  per-message records, real sender names, parsed dates, and two corrections.
//
//  CORRECTION 1 — system notices were attributed to people. A WhatsApp export
//  contains lines like `[3/14/25, 9:12 AM] Messages and calls are end-to-end
//  encrypted.` — a bracketed timestamp with NO `sender:`. The old normalizer
//  appended any non-matching line to the previous message, so platform text and
//  group-membership notices were glued onto whatever a human last said. Those are
//  now their own `.activity` records.
//
//  CORRECTION 2 — the date order was never resolved. WhatsApp writes `3/4/25`
//  with no indication whether that is 3 April or 4 March, and the order depends
//  on the exporting phone's locale. Guessing moves a message by up to eleven
//  months. Resolved from the whole file: a component above 12 is decisive, and
//  failing that, a chat export is chronological, so the interpretation that
//  yields a non-decreasing sequence is the right one. When neither settles it the
//  messages are recorded WITHOUT dates and the ambiguity is stated — line order
//  still holds, because record ids are sequence-numbered.
//

import Foundation

public struct TextChatExportMapper: DiscussionExportMapper {
    public nonisolated var platform: String { "Chat export" }
    public nonisolated var mapperVersion: String { "1" }

    public nonisolated init() {}

    /// Which line shape the file uses, and therefore which app wrote it.
    nonisolated enum Shape: String {
        case whatsapp = "WhatsApp", signal = "Signal", slack = "Slack"

        var regex: NSRegularExpression {
            switch self {
            case .whatsapp: return ChatExportLoader.whatsappRegex
            case .signal:   return ChatExportLoader.signalRegex
            case .slack:    return ChatExportLoader.slackRegex
            }
        }
    }

    /// Minimum matching lines before committing to a shape — the same floor
    /// ChatExportLoader uses, so detection cannot disagree between the two.
    public nonisolated static let minimumMatches = 3

    nonisolated static func shape(of text: String) -> Shape? {
        let probe = text.split(separator: "\n").prefix(50).map(String.init)
        let scored = [Shape.whatsapp, .signal, .slack].map { shape -> (Shape, Int) in
            let count = probe.filter { line in
                let range = NSRange(line.startIndex..<line.endIndex, in: line)
                return shape.regex.firstMatch(in: line, options: [], range: range) != nil
            }.count
            return (shape, count)
        }
        guard let best = scored.max(by: { $0.1 < $1.1 }), best.1 >= minimumMatches else { return nil }
        return best.0
    }

    public nonisolated func claims(filename: String, sample: Data) -> Bool {
        guard let text = String(data: sample, encoding: .utf8) else { return false }
        return Self.shape(of: text) != nil
    }

    public nonisolated func map(data: Data, filename: String) -> DiscussionExport {
        guard let text = String(data: data, encoding: .utf8) else {
            return DiscussionExport(platform: platform, artifact: filename, records: [],
                warnings: [ParserWarning(severity: .error, code: "chatexport.undecodable",
                                         message: "File is not valid UTF-8.")])
        }
        guard let shape = Self.shape(of: text) else {
            return DiscussionExport(platform: platform, artifact: filename, records: [],
                warnings: [ParserWarning(severity: .warning, code: "chatexport.unrecognized_shape",
                    message: "No WhatsApp / Signal / Slack line shape matched at least "
                           + "\(Self.minimumMatches) of the opening lines.")])
        }

        // Pass 1: split into raw entries. A line that matches the shape starts a
        // new entry; anything else continues the one before it, because chat apps
        // write a multi-line message as literal newlines.
        struct Entry { var stamp: String; var sender: String?; var body: String }
        var entries: [Entry] = []
        var leadingNoise: [String] = []

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            if let match = shape.regex.firstMatch(in: line, options: [], range: range),
               match.numberOfRanges >= 4 {
                func group(_ i: Int) -> String {
                    guard let r = Range(match.range(at: i), in: line) else { return "" }
                    return String(line[r]).trimmingCharacters(in: .whitespaces)
                }
                entries.append(Entry(stamp: group(1), sender: group(2), body: group(3)))
            } else if let stamp = Self.systemNoticeStamp(line, shape: shape) {
                // CORRECTION 1: a stamped line with no sender is the platform
                // speaking, not a person. Its own entry, never appended to a human.
                entries.append(Entry(stamp: stamp.timestamp, sender: nil, body: stamp.body))
            } else if !entries.isEmpty {
                entries[entries.count - 1].body += "\n" + line
            } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                leadingNoise.append(line)
            }
        }
        guard !entries.isEmpty else {
            return DiscussionExport(platform: shape.rawValue, artifact: filename, records: [],
                warnings: [ParserWarning(severity: .warning, code: "chatexport.no_messages",
                                         message: "No messages found.")])
        }

        // Pass 2: resolve the date order across the WHOLE file before dating
        // anything, because the answer is a property of the file, not of a line.
        let resolution = ChatTimestampResolver.resolve(entries.map(\.stamp), shape: shape)

        let threadTitle = Self.threadTitle(filename: filename, shape: shape)
        var records: [DiscussionRecord] = []
        let width = String(entries.count).count
        for (index, entry) in entries.enumerated() {
            let body = entry.body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            // Zero-padded so lexical order IS chronological order even when no
            // date could be resolved — the sequence is still evidence.
            let sequence = String(format: "%0\(width)d", index + 1)
            records.append(DiscussionRecord(
                platform: shape.rawValue,
                kind: entry.sender == nil ? .activity : .post,
                recordID: "\(threadTitle)#\(sequence)",
                parentID: nil,
                threadID: threadTitle,
                threadTitle: threadTitle,
                authorHandle: entry.sender,
                authorID: nil,
                timestamp: resolution.dates[index],
                body: body,
                permalink: nil))
        }

        var warnings: [ParserWarning] = []
        if let ambiguity = resolution.warning { warnings.append(ambiguity) }
        if !leadingNoise.isEmpty {
            warnings.append(ParserWarning(severity: .warning, code: "chatexport.preamble_ignored",
                message: "\(leadingNoise.count) line(s) before the first message were not "
                       + "attributed to any sender and are not indexed."))
        }
        return DiscussionExport(platform: shape.rawValue, artifact: filename,
                                records: records, warnings: warnings)
    }

    // MARK: - System notices

    /// A stamped line carrying no `sender:` — WhatsApp's encryption notice, group
    /// membership changes, "You deleted this message". Returns the stamp and the
    /// notice text, or nil when the line is not stamped at all.
    nonisolated static func systemNoticeStamp(_ line: String, shape: Shape)
        -> (timestamp: String, body: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        switch shape {
        case .whatsapp, .slack:
            guard trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") else { return nil }
            let stamp = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
            let body = String(trimmed[trimmed.index(after: close)...])
                .trimmingCharacters(in: .whitespaces)
            // Must look like a timestamp, or an ordinary line beginning with "["
            // would be misread as a notice.
            guard stamp.contains(":"), stamp.rangeOfCharacter(from: .decimalDigits) != nil,
                  !body.isEmpty else { return nil }
            return (stamp, body)
        case .signal:
            // `2026-03-14 09:12:34 - Alice joined` (a dash, then no `sender:`).
            let pattern = #"^(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}(?::\d{2})?)\s*-\s*(.+)$"#
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(
                    in: trimmed, options: [],
                    range: NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)),
                  match.numberOfRanges >= 3,
                  let stampRange = Range(match.range(at: 1), in: trimmed),
                  let bodyRange = Range(match.range(at: 2), in: trimmed) else { return nil }
            return (String(trimmed[stampRange]), String(trimmed[bodyRange]))
        }
    }

    /// The conversation's name. WhatsApp names the export after the other party
    /// ("WhatsApp Chat with André Müller.txt"); Slack after the channel. Falls
    /// back to the filename so a thread always has an identity.
    nonisolated static func threadTitle(filename: String, shape: Shape) -> String {
        var name = (filename as NSString).lastPathComponent
        for suffix in [".txt", ".text"] where name.lowercased().hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
        }
        for prefix in ["WhatsApp Chat with ", "WhatsApp Chat - ", "WhatsApp Chat "] {
            if name.lowercased().hasPrefix(prefix.lowercased()) {
                return String(name.dropFirst(prefix.count))
            }
        }
        if name == "_chat" { return "\(shape.rawValue) chat" }
        return name.isEmpty ? "\(shape.rawValue) chat" : name
    }
}
