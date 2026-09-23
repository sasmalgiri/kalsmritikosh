//
//  DiscordPackageMapper.swift
//  Kalsmritikosh
//
//  DISC-2 — maps a Discord data package into DiscussionRecords.
//
//  Layout: messages/index.json lists channels; messages/c<id>/channel.json
//  describes one channel (its guild, or its DM recipients); messages/c<id>/
//  messages.json — or messages.csv in newer packages — holds that channel's
//  messages as {ID, Timestamp, Contents, Attachments}. Both forms are handled.
//
//  ONE PROPERTY OF THIS FORMAT DRIVES THE WHOLE MAPPER, and getting it wrong
//  would be the worst kind of error here: a Discord package contains ONLY the
//  requesting account's own messages. The other side of a conversation is NOT in
//  it. So every record is attributed to the export's account holder, and the
//  channel's other participants are recorded as thread context — never as
//  authors. An examiner reading "what did X say to Y" must not be handed Y's
//  half of a conversation that the export never contained.
//

import Foundation

public struct DiscordPackageMapper: DiscussionExportMapper {
    public nonisolated var platform: String { "Discord" }
    public nonisolated var mapperVersion: String { "1" }

    /// Stands in for the account whose export this is. A marker, not a guess: the
    /// format guarantees the authorship, but the package's own account/user.json
    /// is a different file, so the display name is not available here.
    public nonisolated static let accountHolder = "(export account holder)"

    public nonisolated init() {}

    nonisolated enum Artifact { case messagesJSON, messagesCSV, channelJSON }

    nonisolated static func artifact(in sample: Data) -> Artifact? {
        guard let text = String(data: sample, encoding: .utf8) else { return nil }
        let leading = text.drop(while: { $0.isWhitespace })

        // messages.json: an array whose entries carry Discord's capitalised keys.
        if leading.first == "[", text.contains("\"ID\""), text.contains("\"Timestamp\""),
           text.contains("\"Contents\"") {
            return .messagesJSON
        }
        // channel.json: an object with an id and either a guild or DM recipients.
        if leading.first == "{", text.contains("\"id\""),
           text.contains("\"guild\"") || text.contains("\"recipients\"") {
            return .channelJSON
        }
        // messages.csv: the same four columns as the JSON form.
        let header = text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        let columns = DiscussionCSV.Header(DiscussionCSV.parse(header).first ?? [])
        if columns.has("ID", "Timestamp", "Contents") { return .messagesCSV }
        return nil
    }

    public nonisolated func claims(filename: String, sample: Data) -> Bool {
        // channel.json is metadata, not messages; claiming it would produce an
        // export with zero records and look like an empty conversation.
        switch Self.artifact(in: sample) {
        case .messagesJSON, .messagesCSV: return true
        case .channelJSON, nil: return false
        }
    }

    public nonisolated func map(data: Data, filename: String) -> DiscussionExport {
        // The channel id is in the DIRECTORY name (messages/c1234567890/…), which
        // is all the thread identity a single-file mapper can recover.
        let channelID = Self.channelID(fromPath: filename)
        switch Self.artifact(in: data.prefix(DiscussionExportRegistry.sampleSize)) {
        case .messagesJSON:
            return mapJSON(data, filename: filename, channelID: channelID)
        case .messagesCSV:
            return mapCSV(data, filename: filename, channelID: channelID)
        case .channelJSON, nil:
            return DiscussionExport(
                platform: platform, artifact: filename, records: [],
                warnings: [ParserWarning(severity: .warning, code: "discord.unrecognized_artifact",
                                         message: "Not a recognized Discord messages export.")])
        }
    }

    // MARK: - Artifacts

    private nonisolated func mapJSON(_ data: Data, filename: String, channelID: String?) -> DiscussionExport {
        guard let entries = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return DiscussionExport(platform: platform, artifact: filename, records: [],
                warnings: [ParserWarning(severity: .error, code: "discord.bad_json",
                                         message: "messages.json is not a JSON array of messages.")])
        }
        var records: [DiscussionRecord] = []
        var skipped = 0
        for entry in entries {
            let id = Self.string(entry["ID"])
            let contents = Self.string(entry["Contents"]) ?? ""
            let attachments = Self.string(entry["Attachments"])
            // A message with no text but WITH an attachment is real evidence — the
            // attachment is the message. Only an entry with neither is skipped.
            var body = contents
            if let attachments, !attachments.isEmpty {
                body = body.isEmpty ? "[attachment: \(attachments)]"
                                    : body + "\n[attachment: \(attachments)]"
            }
            guard let id, !body.isEmpty else { skipped += 1; continue }
            records.append(record(id: id, body: body,
                                  timestamp: Self.string(entry["Timestamp"]),
                                  channelID: channelID))
        }
        return DiscussionExport(platform: platform, artifact: filename, records: records,
                                warnings: Self.skipWarning(skipped))
    }

    private nonisolated func mapCSV(_ data: Data, filename: String, channelID: String?) -> DiscussionExport {
        guard let text = String(data: data, encoding: .utf8) else {
            return DiscussionExport(platform: platform, artifact: filename, records: [],
                warnings: [ParserWarning(severity: .error, code: "discord.undecodable",
                                         message: "File is not valid UTF-8.")])
        }
        let rows = DiscussionCSV.parse(text)
        guard let headerRow = rows.first else {
            return DiscussionExport(platform: platform, artifact: filename, records: [],
                warnings: [ParserWarning(severity: .warning, code: "discord.empty",
                                         message: "No rows in export.")])
        }
        let header = DiscussionCSV.Header(headerRow)
        let idIdx = header.index("ID")
        let timeIdx = header.index("Timestamp")
        let bodyIdx = header.index("Contents")
        let attachIdx = header.index("Attachments")

        var records: [DiscussionRecord] = []
        var skipped = 0
        for row in rows.dropFirst() {
            let id = DiscussionCSV.field(row, idIdx)
            var body = DiscussionCSV.field(row, bodyIdx) ?? ""
            if let attachments = DiscussionCSV.field(row, attachIdx) {
                body = body.isEmpty ? "[attachment: \(attachments)]"
                                    : body + "\n[attachment: \(attachments)]"
            }
            guard let id, !body.isEmpty else { skipped += 1; continue }
            records.append(record(id: id, body: body,
                                  timestamp: DiscussionCSV.field(row, timeIdx),
                                  channelID: channelID))
        }
        return DiscussionExport(platform: platform, artifact: filename, records: records,
                                warnings: Self.skipWarning(skipped))
    }

    private nonisolated func record(id: String, body: String,
                                    timestamp: String?, channelID: String?) -> DiscussionRecord {
        DiscussionRecord(
            platform: platform,
            // Not `.reply`: the package records no parent message id, so claiming a
            // reply relationship would be an invention. Not `.directMessage`
            // either — whether a channel is a DM lives in channel.json, a file this
            // mapper is deliberately not given.
            kind: .post,
            recordID: id,
            threadID: channelID,
            threadTitle: channelID.map { "Discord channel \($0)" },
            authorHandle: Self.accountHolder,
            authorID: nil,
            timestamp: timestamp.flatMap(Self.parseTimestamp),
            body: body,
            permalink: channelID.map { "https://discord.com/channels/@me/\($0)/\(id)" })
    }

    // MARK: - Field decoding

    /// `messages/c1234567890/messages.json` → `1234567890`. Returns nil when the
    /// path carries no channel directory rather than inventing a thread id.
    nonisolated static func channelID(fromPath path: String) -> String? {
        for component in path.split(separator: "/").reversed() {
            guard component.hasPrefix("c"), component.count > 1 else { continue }
            let digits = component.dropFirst()
            if digits.allSatisfy(\.isNumber) { return String(digits) }
        }
        return nil
    }

    /// Discord writes `2026-03-14 09:26:53` (UTC, space-separated) in older
    /// packages and RFC 3339 in newer ones. Both are read; anything else yields
    /// nil rather than a guessed date.
    nonisolated static func parseTimestamp(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: trimmed) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: trimmed) { return d }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in ["yyyy-MM-dd HH:mm:ss.SSSSSS", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm"] {
            formatter.dateFormat = format
            if let d = formatter.date(from: trimmed) { return d }
        }
        return nil
    }

    private nonisolated static func string(_ value: Any?) -> String? {
        if let s = value as? String { return s.isEmpty ? nil : s }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }

    private nonisolated static func skipWarning(_ count: Int) -> [ParserWarning] {
        guard count > 0 else { return [] }
        return [ParserWarning(severity: .warning, code: "discord.rows_skipped",
            message: "\(count) message(s) had no id, or neither text nor attachment, "
                   + "and were not indexed.")]
    }
}
