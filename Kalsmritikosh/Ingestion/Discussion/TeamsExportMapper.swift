//
//  TeamsExportMapper.swift
//  Kalsmritikosh
//
//  E-6 — maps the Microsoft Teams personal/consumer "Export your data" archive
//  (its `messages.json`) into DiscussionRecords. Read-only analysis of a file the
//  account holder already downloaded: no acquisition, no sign-in, no network.
//
//  Shapes accepted, all tolerant of missing fields:
//    • `{"userId":…,"exportDate":…,"conversations":[ …conversation… ]}` — the export
//    • `[ …conversation… ]` — an array of conversation objects carrying `MessageList`
//    • a single conversation object at the root
//  A conversation is `{id, displayName, threadProperties:{topic}, MessageList:[…]}`
//  and a message is `{id, displayName, originalarrivaltime, messagetype, content, from}`.
//
//  THREE THINGS this mapper is careful about:
//
//  1. `content` is HTML (`<p>`, `<div>`, `<at>` mentions, `&amp;` entities). It is
//     reduced to plain text — tags stripped, block ends kept as line breaks,
//     entities decoded — so "Q3 &amp; Q4" is cited as "Q3 & Q4", not as markup.
//  2. Not every entry is speech. Call events, member adds, topic changes, cards and
//     media carry a non-text `messagetype`; they are SKIPPED and COUNTED per type in
//     a warning, so the omission is visible instead of silent.
//  3. `displayName` is the sender as it appeared and `from` is the stable account
//     id (`8:live:…`, `8:orgid:…`, sometimes as a contacts URL). Both are kept, so
//     the entity layer can unify one person without trusting a changeable name.
//
//  The consumer Teams export inherits Skype's export schema; a Skype
//  `messages.json` therefore reads through this mapper too and is labelled with
//  this mapper's platform name. That is stated here rather than guessed around:
//  the two files are not distinguishable by structure.
//

import Foundation

public struct TeamsExportMapper: DiscussionExportMapper {
    public nonisolated var platform: String { "Microsoft Teams" }
    public nonisolated var mapperVersion: String { "1" }

    public nonisolated init() {}

    /// The export's own file name. Used by intake to route a loose `messages.json`
    /// (which otherwise reads as plain JSON) — always together with `claims`.
    public nonisolated static let exportFileName = "messages.json"

    /// `messagetype` values that are speech. Anything else is an event or a card.
    nonisolated static let textMessageTypes: Set<String> = ["text", "richtext", "richtext/html"]

    /// Claimed by CONTENT. `MessageList` and `originalarrivaltime` are this
    /// schema's own keys; the `conversations` + `exportDate`/`userId` header covers
    /// an export whose first conversation's properties push those past the sample.
    public nonisolated func claims(filename: String, sample: Data) -> Bool {
        guard let text = String(data: sample, encoding: .utf8) else { return false }
        let leading = text.drop(while: { $0.isWhitespace || $0 == "\u{FEFF}" })
        guard let first = leading.first, first == "{" || first == "[" else { return false }
        if text.contains("\"MessageList\"") || text.contains("\"originalarrivaltime\"") { return true }
        return text.contains("\"conversations\"")
            && (text.contains("\"exportDate\"") || text.contains("\"userId\""))
    }

    public nonisolated func map(data: Data, filename: String) -> DiscussionExport {
        guard let root = try? JSONSerialization.jsonObject(with: data) else {
            return DiscussionExport(platform: platform, artifact: filename, records: [],
                warnings: [ParserWarning(severity: .error, code: "teams.bad_json",
                                         message: "messages.json is not readable JSON.")])
        }

        let conversations: [[String: Any]] = {
            if let object = root as? [String: Any] {
                if let list = object["conversations"] as? [[String: Any]] { return list }
                if object["MessageList"] is [Any] { return [object] }
                return []
            }
            if let array = root as? [[String: Any]] {
                return array.filter { $0["MessageList"] is [Any] }
            }
            return []
        }()
        guard !conversations.isEmpty else {
            return DiscussionExport(platform: platform, artifact: filename, records: [],
                warnings: [ParserWarning(severity: .warning, code: "teams.no_conversations",
                    message: "Export decoded but contains no conversation with a MessageList.")])
        }

        var records: [DiscussionRecord] = []
        var skippedByType: [String: Int] = [:]
        var emptyBodies = 0
        var undated = 0
        var positionalIDs = 0

        for (conversationIndex, conversation) in conversations.enumerated() {
            let conversationID = Self.string(conversation["id"])
            let topic = Self.string((conversation["threadProperties"] as? [String: Any])?["topic"])
            let displayName = Self.string(conversation["displayName"])
            let threadID = conversationID ?? "conversation-\(conversationIndex + 1)"
            let threadTitle = topic ?? displayName ?? conversationID ?? "Teams conversation \(conversationIndex + 1)"

            let messages = (conversation["MessageList"] as? [[String: Any]]) ?? []
            for (messageIndex, message) in messages.enumerated() {
                let type = Self.string(message["messagetype"])?.lowercased()
                // A missing messagetype with real content is read as text: being
                // tolerant of an absent field must not drop the message it labels.
                if let type, !Self.textMessageTypes.contains(type) {
                    skippedByType[Self.string(message["messagetype"]) ?? type, default: 0] += 1
                    continue
                }
                let body = Self.plainText(fromHTML: Self.string(message["content"]) ?? "")
                guard !body.isEmpty else { emptyBodies += 1; continue }

                let nativeID = Self.string(message["id"]) ?? Self.string(message["clientmessageid"])
                if nativeID == nil { positionalIDs += 1 }
                let messageID = nativeID ?? "pos\(messageIndex + 1)"

                let timestamp = (Self.string(message["originalarrivaltime"])
                                 ?? Self.string(message["composetime"]))
                    .flatMap(Self.parseTimestamp)
                if timestamp == nil { undated += 1 }

                records.append(DiscussionRecord(
                    platform: platform,
                    kind: .directMessage,
                    recordID: "\(threadID)#\(messageID)",
                    threadID: threadID,
                    threadTitle: threadTitle,
                    authorHandle: Self.string(message["displayName"]),
                    authorID: Self.string(message["from"]).map(Self.accountID),
                    timestamp: timestamp,
                    body: body,
                    permalink: nil))
            }
        }

        var warnings: [ParserWarning] = []
        if !skippedByType.isEmpty {
            let total = skippedByType.values.reduce(0, +)
            let breakdown = skippedByType.sorted { $0.key < $1.key }
                .map { "\($0.key) ×\($0.value)" }.joined(separator: ", ")
            warnings.append(ParserWarning(severity: .info, code: "teams.non_text_skipped",
                message: "\(total) non-text entr(ies) — calls, membership changes, cards or media — "
                       + "were not indexed as messages: \(breakdown)."))
        }
        if emptyBodies > 0 {
            warnings.append(ParserWarning(severity: .warning, code: "teams.empty_messages",
                message: "\(emptyBodies) text message(s) had no readable content and were not indexed."))
        }
        if undated > 0 {
            warnings.append(ParserWarning(severity: .warning, code: "teams.no_time",
                message: "\(undated) message(s) carried no readable `originalarrivaltime`; they are "
                       + "recorded WITHOUT a timestamp rather than with a guessed one."))
        }
        if positionalIDs > 0 {
            warnings.append(ParserWarning(severity: .warning, code: "teams.positional_ids",
                message: "\(positionalIDs) message(s) had no `id`; they are identified by their "
                       + "position in the conversation, which is stable only for this file."))
        }
        return DiscussionExport(platform: platform, artifact: filename,
                                records: records, warnings: warnings)
    }

    // MARK: - Field decoding

    /// `https://…/v1/users/ME/contacts/8:live:alice` → `8:live:alice`. A bare id
    /// is returned unchanged.
    nonisolated static func accountID(_ raw: String) -> String {
        guard raw.contains("/contacts/"), let last = raw.split(separator: "/").last else { return raw }
        return String(last)
    }

    /// ISO-8601 with or without fractional seconds. A time with no zone is NOT
    /// assumed to be UTC — it yields nil, which the caller reports.
    nonisolated static func parseTimestamp(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: trimmed) { return date }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: trimmed)
    }

    /// Teams/Skype message HTML → plain text: block ends and `<br>` become line
    /// breaks, every other tag is removed, entities are decoded, whitespace runs
    /// collapse. Not an HTML renderer — a citation-grade reduction of chat markup.
    nonisolated static func plainText(fromHTML html: String) -> String {
        guard html.contains("<") || html.contains("&") else {
            return html.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let lineBreakTags: Set<String> = ["br", "/p", "/div", "/li", "/tr", "/h1", "/h2", "/h3", "/blockquote", "/quote"]
        var out = ""
        var index = html.startIndex
        while index < html.endIndex {
            let character = html[index]
            if character == "<", let close = html[index...].firstIndex(of: ">") {
                let inner = html[html.index(after: index)..<close]
                var name = Substring(inner.trimmingCharacters(in: .whitespaces).lowercased())
                let isClosing = name.hasPrefix("/")
                if isClosing { name = name.dropFirst() }
                let tag = (isClosing ? "/" : "") + String(name.prefix { $0.isLetter || $0.isNumber })
                if lineBreakTags.contains(tag) { out.append("\n") }
                index = html.index(after: close)
                continue
            }
            out.append(character)
            index = html.index(after: index)
        }
        let decoded = decodeEntities(out)
        let lines = decoded.components(separatedBy: "\n").map { line in
            line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\u{00A0}" })
                .joined(separator: " ")
        }
        var collapsed: [String] = []
        for line in lines where !(line.isEmpty && (collapsed.last?.isEmpty ?? true)) {
            collapsed.append(line)
        }
        return collapsed.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Named (the common HTML set) and numeric entities. Unknown entities are left
    /// as written rather than dropped.
    nonisolated static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let named: [String: String] = [
            "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
            "ndash": "–", "mdash": "—", "hellip": "…", "lsquo": "‘", "rsquo": "’",
            "ldquo": "“", "rdquo": "”", "copy": "©", "reg": "®", "trade": "™", "euro": "€"
        ]
        var out = ""
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index] == "&", let semi = text[index...].firstIndex(of: ";"),
                  text.distance(from: index, to: semi) <= 10 else {
                out.append(text[index]); index = text.index(after: index); continue
            }
            let name = text[text.index(after: index)..<semi]
            var replacement: String?
            if name.hasPrefix("#x") || name.hasPrefix("#X") {
                replacement = UInt32(name.dropFirst(2), radix: 16)
                    .flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else if name.hasPrefix("#") {
                replacement = UInt32(name.dropFirst())
                    .flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else {
                replacement = named[String(name)]
            }
            if let replacement {
                out += replacement; index = text.index(after: semi)
            } else {
                out.append(text[index]); index = text.index(after: index)
            }
        }
        return out
    }

    private nonisolated static func string(_ value: Any?) -> String? {
        if let s = value as? String {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : s
        }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }
}
