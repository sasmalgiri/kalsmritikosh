//
//  MetaDownloadMapper.swift
//  Kalsmritikosh
//
//  DISC-4 — maps a Meta "Download Your Information" export (Messenger,
//  Instagram, Facebook) into DiscussionRecords.
//
//  This is the richest artifact in the discussion lane and the first one with
//  REAL attribution: unlike a Discord package or Reddit's own-content CSVs, a
//  Messenger or Instagram thread names every participant and stamps each message
//  with its sender. A multi-party conversation comes out as a conversation.
//
//    messages/inbox/<thread>/message_1.json
//    your_instagram_activity/messages/inbox/<thread>/message_1.json
//        {"participants":[{"name":"…"}], "title":"…", "thread_path":"…",
//         "messages":[{"sender_name":"…","timestamp_ms":1773480413000,
//                      "content":"…","photos":[…],"share":{…}}]}
//
//  TWO FORMAT TRAPS, both silent if unhandled:
//
//  1. MOJIBAKE. Meta writes UTF-8 bytes but escapes them as if they were
//     Latin-1, so "é" arrives as "Ã©" and an emoji as "ð\u{9F}\u{98}". A name or
//     message run through that looks plausibly foreign rather than broken, so it
//     would never be questioned — while search for the real name silently fails.
//     Repaired by re-encoding each scalar as a byte and decoding as UTF-8.
//  2. timestamp_ms is MILLISECONDS. Treating it as seconds dates 2026 messages
//     to 1970, which quietly destroys every timeline this lane exists to build.
//

import Foundation

public struct MetaDownloadMapper: DiscussionExportMapper {
    public nonisolated var platform: String { "Meta" }
    public nonisolated var mapperVersion: String { "1" }

    public nonisolated init() {}

    public nonisolated func claims(filename: String, sample: Data) -> Bool {
        guard let text = String(data: sample, encoding: .utf8) else { return false }
        let leading = text.drop(while: { $0.isWhitespace })
        guard leading.first == "{" else { return false }
        // A thread file always has a messages array whose entries carry
        // sender_name; no other export in this lane uses that key.
        return text.contains("\"messages\"") && text.contains("\"sender_name\"")
    }

    public nonisolated func map(data: Data, filename: String) -> DiscussionExport {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let messages = root["messages"] as? [[String: Any]] else {
            return DiscussionExport(platform: platform, artifact: filename, records: [],
                warnings: [ParserWarning(severity: .error, code: "meta.bad_json",
                    message: "Not a Meta thread file (expected an object with a messages array).")])
        }

        let title = Self.repair(root["title"] as? String)
        let threadPath = root["thread_path"] as? String
        let participants = (root["participants"] as? [[String: Any]])?
            .compactMap { Self.repair($0["name"] as? String) } ?? []

        // Instagram exports live under your_instagram_activity; Messenger under
        // messages/inbox. Naming the surface matters because the same person's
        // Instagram and Messenger threads are different evidence.
        let surface: String = {
            let lower = filename.lowercased()
            if lower.contains("instagram") { return "Instagram" }
            if lower.contains("inbox") || lower.contains("messages") { return "Messenger" }
            return "Meta"
        }()

        var records: [DiscussionRecord] = []
        var skipped = 0
        for (index, message) in messages.enumerated() {
            let sender = Self.repair(message["sender_name"] as? String)
            var body = Self.repair(message["content"] as? String) ?? ""

            // A message whose payload is a photo, a video, a shared link or a
            // sticker has no `content`. Dropping those loses the message entirely
            // — and in a conversation, a missing message changes what the
            // surrounding ones mean.
            var attachments: [String] = []
            for key in ["photos", "videos", "audio_files", "files", "gifs"] {
                if let items = message[key] as? [[String: Any]] {
                    for item in items {
                        if let uri = item["uri"] as? String {
                            attachments.append("\(key.dropLast()): \(uri)")
                        }
                    }
                }
            }
            if let share = message["share"] as? [String: Any],
               let link = share["link"] as? String {
                attachments.append("shared link: \(link)")
            }
            if let sticker = message["sticker"] as? [String: Any],
               let uri = sticker["uri"] as? String {
                attachments.append("sticker: \(uri)")
            }
            if !attachments.isEmpty {
                let described = "[" + attachments.joined(separator: "; ") + "]"
                body = body.isEmpty ? described : body + "\n" + described
            }
            // A genuine unsend leaves an entry with neither content nor payload.
            if body.isEmpty { skipped += 1; continue }

            let timestamp: Date? = {
                guard let ms = (message["timestamp_ms"] as? NSNumber)?.doubleValue else { return nil }
                return Date(timeIntervalSince1970: ms / 1000.0)   // MILLISECONDS
            }()

            records.append(DiscussionRecord(
                platform: surface,
                kind: .directMessage,
                // DYI gives messages no id, so position within the thread file is
                // the only stable identity available. Prefixed with the thread so
                // it cannot collide across files.
                recordID: "\(threadPath ?? title ?? filename)#\(index)",
                parentID: nil,
                threadID: threadPath ?? title,
                threadTitle: {
                    guard let title else { return threadPath }
                    return participants.count > 2
                        ? "\(title) (\(participants.count) participants)"
                        : title
                }(),
                authorHandle: sender,          // a REAL name, not a marker
                authorID: nil,
                timestamp: timestamp,
                body: body,
                permalink: nil))
        }

        var warnings: [ParserWarning] = []
        if skipped > 0 {
            warnings.append(ParserWarning(severity: .warning, code: "meta.messages_skipped",
                message: "\(skipped) message(s) had no content and no attachment "
                       + "(typically unsent) and were not indexed."))
        }
        if participants.isEmpty {
            warnings.append(ParserWarning(severity: .warning, code: "meta.no_participants",
                message: "Thread file lists no participants; senders are still recorded per message."))
        }
        return DiscussionExport(platform: surface, artifact: filename,
                                records: records, warnings: warnings)
    }

    /// Undoes Meta's Latin-1-escaped UTF-8. Every scalar below U+0100 is one
    /// original byte; re-assembling those bytes and decoding as UTF-8 recovers the
    /// real text. Returns the input unchanged when it is not mojibake, so correct
    /// text is never mangled by the repair.
    nonisolated static func repair(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        // Only strings made entirely of Latin-1-range scalars can be mojibake.
        guard text.unicodeScalars.allSatisfy({ $0.value < 0x100 }) else { return text }
        let bytes = text.unicodeScalars.map { UInt8($0.value) }
        guard let decoded = String(bytes: bytes, encoding: .utf8) else { return text }
        // If the reinterpretation changed nothing, it was plain ASCII already.
        return decoded
    }
}
