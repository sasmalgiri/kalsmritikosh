//
//  TelegramExportMapper.swift
//  Kalsmritikosh
//
//  DISC-5 — maps a Telegram Desktop JSON export into DiscussionRecords. Handles
//  both shapes the client produces: a full export
//  (`{"chats":{"list":[ …chats… ]}}`) and a single-chat export, where the chat
//  object is the root.
//
//  Telegram names senders (`from`, `from_id`), so like Meta this is real
//  attribution rather than an account-holder marker, and `reply_to_message_id`
//  gives a true reply graph.
//
//  TWO TRAPS, both silent if unhandled:
//
//  1. `text` is NOT always a string. When a message contains a link, mention,
//     bold run or code span, Telegram emits an ARRAY mixing plain strings with
//     {"type":…,"text":…} objects. Reading it as a string yields nothing and the
//     message silently disappears — exactly the messages that contain links,
//     which are often the ones that matter.
//  2. `date` has NO TIME ZONE ("2026-03-14T09:26:53"); it is the exporting
//     machine's local time. `date_unixtime` sits beside it and is absolute, so it
//     is preferred. Parsing `date` as if it were UTC shifts every message by the
//     exporter's offset — up to 14 hours, enough to reorder a day's events and
//     to put a message on the wrong side of midnight.
//
//  Service entries (a call, someone joining, a pinned message) are kept as
//  `.activity` rather than speech, so "what did they say" cannot return "Andre
//  joined the group".
//

import Foundation

public struct TelegramExportMapper: DiscussionExportMapper {
    public nonisolated var platform: String { "Telegram" }
    public nonisolated var mapperVersion: String { "1" }

    public nonisolated init() {}

    public nonisolated func claims(filename: String, sample: Data) -> Bool {
        guard let text = String(data: sample, encoding: .utf8) else { return false }
        let leading = text.drop(while: { $0.isWhitespace })
        guard leading.first == "{" else { return false }
        // Telegram's own markers. `date_unixtime` and `text_entities` are unique to
        // this export among the platforms in this lane; `from_id` plus a messages
        // array covers a single-chat export whose head does not reach either.
        return text.contains("\"date_unixtime\"")
            || text.contains("\"text_entities\"")
            || (text.contains("\"messages\"") && text.contains("\"from_id\""))
    }

    public nonisolated func map(data: Data, filename: String) -> DiscussionExport {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return DiscussionExport(platform: platform, artifact: filename, records: [],
                warnings: [ParserWarning(severity: .error, code: "telegram.bad_json",
                                         message: "Not a JSON object.")])
        }

        // Full export, or a single chat at the root.
        let chats: [[String: Any]] = {
            if let list = (root["chats"] as? [String: Any])?["list"] as? [[String: Any]] {
                return list
            }
            if root["messages"] is [[String: Any]] { return [root] }
            return []
        }()
        guard !chats.isEmpty else {
            return DiscussionExport(platform: platform, artifact: filename, records: [],
                warnings: [ParserWarning(severity: .warning, code: "telegram.no_chats",
                    message: "Export decoded but contains no chat with messages.")])
        }

        var records: [DiscussionRecord] = []
        var skipped = 0
        var undatedByLocalOnly = 0

        for chat in chats {
            let chatName = chat["name"] as? String
            let chatID = Self.string(chat["id"])
            let chatType = chat["type"] as? String
            let threadID = chatID ?? chatName
            let threadTitle: String? = {
                guard let chatName else { return threadID.map { "Telegram chat \($0)" } }
                guard let chatType, chatType != "personal_chat" else { return chatName }
                return "\(chatName) (\(chatType.replacingOccurrences(of: "_", with: " ")))"
            }()

            for message in (chat["messages"] as? [[String: Any]]) ?? [] {
                guard let id = Self.string(message["id"]) else { skipped += 1; continue }
                let isService = (message["type"] as? String) == "service"

                var body = Self.flatten(message["text"])
                // Media-only messages carry a file/photo path instead of text.
                // Dropping them would lose every image and document sent.
                for key in ["photo", "file", "sticker_emoji", "location_information"] {
                    if let value = message[key] {
                        let described = Self.describe(key: key, value: value)
                        if !described.isEmpty {
                            body = body.isEmpty ? described : body + "\n" + described
                        }
                    }
                }
                if isService, body.isEmpty, let action = message["action"] as? String {
                    let actor = message["actor"] as? String
                    body = actor.map { "\($0): \(action.replacingOccurrences(of: "_", with: " "))" }
                        ?? action.replacingOccurrences(of: "_", with: " ")
                }
                guard !body.isEmpty else { skipped += 1; continue }

                // Absolute time wins. `date` alone carries no zone, so using it
                // would silently apply the exporter's offset to every message.
                var timestamp: Date?
                if let unix = Self.string(message["date_unixtime"]), let seconds = Double(unix) {
                    timestamp = Date(timeIntervalSince1970: seconds)
                } else if message["date"] is String {
                    // Recorded as undated rather than guessed at: a wrong time is
                    // worse than a missing one on a timeline.
                    undatedByLocalOnly += 1
                }

                let replyTo = Self.string(message["reply_to_message_id"])
                records.append(DiscussionRecord(
                    platform: platform,
                    kind: isService ? .activity : (replyTo == nil ? .post : .reply),
                    recordID: threadID.map { "\($0)#\(id)" } ?? id,
                    parentID: replyTo,
                    threadID: threadID,
                    threadTitle: threadTitle,
                    authorHandle: (message["from"] as? String)
                        ?? (message["actor"] as? String),
                    authorID: Self.string(message["from_id"])
                        ?? Self.string(message["actor_id"]),
                    timestamp: timestamp,
                    body: body,
                    permalink: nil))
            }
        }

        var warnings: [ParserWarning] = []
        if skipped > 0 {
            warnings.append(ParserWarning(severity: .warning, code: "telegram.messages_skipped",
                message: "\(skipped) message(s) had no id or no readable content "
                       + "and were not indexed."))
        }
        if undatedByLocalOnly > 0 {
            warnings.append(ParserWarning(severity: .warning, code: "telegram.no_absolute_time",
                message: "\(undatedByLocalOnly) message(s) carried only a local-time `date` with "
                       + "no time zone and no `date_unixtime`; they are recorded WITHOUT a "
                       + "timestamp rather than assuming a zone."))
        }
        return DiscussionExport(platform: platform, artifact: filename,
                                records: records, warnings: warnings)
    }

    // MARK: - Field decoding

    /// Telegram's `text`: a plain string, or an ARRAY mixing strings with
    /// {"type":…,"text":…} entity objects. Both collapse to the message as read.
    nonisolated static func flatten(_ value: Any?) -> String {
        if let text = value as? String { return text }
        guard let parts = value as? [Any] else { return "" }
        return parts.map { part -> String in
            if let text = part as? String { return text }
            if let object = part as? [String: Any] {
                // A link entity's href is the evidence when its display text is
                // something like "here"; both are kept when they differ.
                let text = object["text"] as? String ?? ""
                if let href = object["href"] as? String, href != text, !href.isEmpty {
                    return text.isEmpty ? href : "\(text) <\(href)>"
                }
                return text
            }
            return ""
        }.joined()
    }

    private nonisolated static func describe(key: String, value: Any) -> String {
        switch key {
        case "photo":
            return "[photo: \(value as? String ?? "attached")]"
        case "file":
            return "[file: \(value as? String ?? "attached")]"
        case "sticker_emoji":
            return "[sticker: \(value as? String ?? "")]"
        case "location_information":
            guard let location = value as? [String: Any],
                  let lat = (location["latitude"] as? NSNumber)?.doubleValue,
                  let lon = (location["longitude"] as? NSNumber)?.doubleValue else { return "" }
            return "[location: \(lat), \(lon)]"
        default:
            return ""
        }
    }

    private nonisolated static func string(_ value: Any?) -> String? {
        if let s = value as? String { return s.isEmpty ? nil : s }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }
}
