//
//  XArchiveMapper.swift
//  Kalsmritikosh
//
//  DISC-4 — maps an X (Twitter) account archive into DiscussionRecords.
//
//  The archive's data files are JavaScript, not JSON: each begins
//  `window.YTD.<name>.part0 = ` followed by a JSON array. Stripping that
//  assignment is the whole trick, and it is why these files defeat a plain JSON
//  reader and arrive as `.js`.
//
//    data/tweets.js            [{"tweet": {id_str, created_at, full_text,
//                              in_reply_to_status_id_str, in_reply_to_screen_name}}]
//    data/direct-messages.js   [{"dmConversation": {conversationId,
//                              messages: [{"messageCreate": {id, senderId,
//                              recipientId, text, createdAt}}]}}]
//    data/note-tweet.js        long-form posts
//
//  Tweets are the account holder's own, so they carry the account-holder marker —
//  but `in_reply_to_screen_name` DOES name the person replied to, and that is
//  recorded, because "who were they arguing with" is usually the question. DMs
//  carry real numeric sender ids, so those become authorIDs.
//

import Foundation

public struct XArchiveMapper: DiscussionExportMapper {
    public nonisolated var platform: String { "X" }
    public nonisolated var mapperVersion: String { "1" }

    public nonisolated static let accountHolder = "(export account holder)"

    public nonisolated init() {}

    nonisolated enum Artifact { case tweets, directMessages }

    nonisolated static func artifact(in sample: Data) -> Artifact? {
        guard let text = String(data: sample, encoding: .utf8) else { return nil }
        guard text.contains("window.YTD.") else { return nil }
        if text.contains("window.YTD.direct_messages") || text.contains("\"dmConversation\"") {
            return .directMessages
        }
        if text.contains("window.YTD.tweets") || text.contains("window.YTD.note_tweet")
            || text.contains("\"tweet\"") {
            return .tweets
        }
        return nil
    }

    public nonisolated func claims(filename: String, sample: Data) -> Bool {
        Self.artifact(in: sample) != nil
    }

    public nonisolated func map(data: Data, filename: String) -> DiscussionExport {
        guard let kind = Self.artifact(in: data.prefix(DiscussionExportRegistry.sampleSize)) else {
            return DiscussionExport(
                platform: platform, artifact: filename, records: [],
                warnings: [ParserWarning(severity: .warning, code: "x.unrecognized_artifact",
                                         message: "Not a recognized X archive file.")])
        }
        guard let entries = Self.jsonArray(in: data) else {
            return DiscussionExport(platform: platform, artifact: filename, records: [],
                warnings: [ParserWarning(severity: .error, code: "x.bad_payload",
                    message: "Could not read the JSON array after the window.YTD assignment.")])
        }

        var records: [DiscussionRecord] = []
        var skipped = 0
        switch kind {
        case .tweets:
            for entry in entries {
                // Newer archives nest under "tweet"; some older ones are flat.
                let tweet = (entry["tweet"] as? [String: Any]) ?? entry
                guard let id = Self.string(tweet["id_str"]),
                      let text = Self.string(tweet["full_text"]) ?? Self.string(tweet["text"])
                else { skipped += 1; continue }

                let replyToID = Self.string(tweet["in_reply_to_status_id_str"])
                let replyToName = Self.string(tweet["in_reply_to_screen_name"])
                // conversation_id_str groups a whole exchange; without it, the
                // thread is the post being replied to, else the post itself.
                let conversation = Self.string(tweet["conversation_id_str"]) ?? replyToID ?? id
                var body = text
                if let replyToName { body = "replying to @\(replyToName): " + body }

                records.append(DiscussionRecord(
                    platform: platform,
                    kind: replyToID == nil ? .post : .reply,
                    recordID: id,
                    parentID: replyToID,
                    threadID: conversation,
                    threadTitle: "X conversation \(conversation)",
                    authorHandle: Self.accountHolder,
                    authorID: nil,
                    timestamp: Self.string(tweet["created_at"]).flatMap(Self.parseTweetDate),
                    body: body,
                    permalink: "https://x.com/i/web/status/\(id)"))
            }

        case .directMessages:
            for entry in entries {
                guard let conversation = entry["dmConversation"] as? [String: Any] else {
                    skipped += 1; continue
                }
                let conversationID = Self.string(conversation["conversationId"])
                let messages = (conversation["messages"] as? [[String: Any]]) ?? []
                for wrapper in messages {
                    guard let message = wrapper["messageCreate"] as? [String: Any],
                          let id = Self.string(message["id"]),
                          let text = Self.string(message["text"])
                    else { skipped += 1; continue }
                    let sender = Self.string(message["senderId"])
                    let recipient = Self.string(message["recipientId"])
                    records.append(DiscussionRecord(
                        platform: platform,
                        kind: .directMessage,
                        recordID: id,
                        threadID: conversationID,
                        threadTitle: conversationID.map { "X direct messages \($0)" },
                        // A numeric account id is not a display name, but it IS a
                        // real, stable identifier — so it goes in authorID, where
                        // the entity layer can unify it, and never in authorHandle.
                        authorHandle: nil,
                        authorID: sender,
                        timestamp: Self.string(message["createdAt"]).flatMap(Self.parseISO),
                        body: recipient.map { "to \($0): \(text)" } ?? text,
                        permalink: nil))
                }
            }
        }

        var warnings: [ParserWarning] = []
        if skipped > 0 {
            warnings.append(ParserWarning(severity: .warning, code: "x.entries_skipped",
                message: "\(skipped) entr(ies) had no id or no text and were not indexed."))
        }
        return DiscussionExport(platform: platform, artifact: filename,
                                records: records, warnings: warnings)
    }

    // MARK: - Payload extraction

    /// Strips the `window.YTD.<name>.partN = ` assignment and parses the array
    /// that follows. Locating the first `[` is enough and survives the variations
    /// in whitespace and part numbering across archive vintages.
    nonisolated static func jsonArray(in data: Data) -> [[String: Any]]? {
        guard let text = String(data: data, encoding: .utf8),
              let start = text.firstIndex(of: "[") else { return nil }
        let payload = Data(text[start...].utf8)
        return (try? JSONSerialization.jsonObject(with: payload)) as? [[String: Any]]
    }

    /// X's legacy tweet date: `Tue Mar 14 09:26:53 +0000 2026`. Parsed with a
    /// fixed POSIX locale so the examiner's region cannot change the result.
    nonisolated static func parseTweetDate(_ raw: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE MMM dd HH:mm:ss Z yyyy"
        if let d = formatter.date(from: raw.trimmingCharacters(in: .whitespaces)) { return d }
        return parseISO(raw)
    }

    nonisolated static func parseISO(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: trimmed) { return d }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: trimmed)
    }

    private nonisolated static func string(_ value: Any?) -> String? {
        if let s = value as? String { return s.isEmpty ? nil : s }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }
}
