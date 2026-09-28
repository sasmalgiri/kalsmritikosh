//
//  TwitchChatMapper.swift
//  Kalsmritikosh
//
//  DISC-7 — Twitch VOD chat, as the downloader tools export it.
//
//  A VOD chat log is a conversation with one unusual property: its timestamps
//  are OFFSETS INTO A VIDEO, not wall-clock times. `content_offset_seconds`
//  says "3714.2 seconds into the stream", which is what lets a message be
//  matched to what was on screen — and `created_at` carries the absolute time.
//  Both are kept: the offset is the only thing that places a message inside the
//  recording, and the absolute time is the only thing that places it on the
//  archive's timeline.
//
//  Unlike the other platforms here, a Twitch chat log names EVERY participant
//  per message, because it is a public channel rather than one account's own
//  export. So attribution is real for every record, with no account-holder
//  marker needed.
//
//  Collection is someone else's step, as everywhere in this lane: this reads a
//  file a downloader produced.
//

import Foundation

public struct TwitchChatMapper: DiscussionExportMapper {
    public nonisolated var platform: String { "Twitch" }
    public nonisolated var mapperVersion: String { "1" }

    public nonisolated init() {}

    /// Claimed by CONTENT. The fingerprint is the pair that no other export in
    /// this lane carries: a `comments` array whose entries have both a
    /// `content_offset_seconds` and a `commenter`.
    public nonisolated func claims(filename: String, sample: Data) -> Bool {
        guard let text = String(data: sample, encoding: .utf8) else { return false }
        guard text.contains("\"content_offset_seconds\"") else { return false }
        return text.contains("\"commenter\"") || text.contains("\"comments\"")
    }

    public nonisolated func map(data: Data, filename: String) -> DiscussionExport {
        var warnings: [ParserWarning] = []
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            warnings.append(ParserWarning(severity: .error, code: "twitch.unreadable",
                message: "This Twitch chat export is not readable JSON."))
            return DiscussionExport(platform: platform, artifact: filename,
                                    records: [], warnings: warnings)
        }
        guard let comments = root["comments"] as? [[String: Any]] else {
            warnings.append(ParserWarning(severity: .warning, code: "twitch.no_comments",
                message: "This file has Twitch chat fields but no `comments` array, so it holds "
                       + "no messages."))
            return DiscussionExport(platform: platform, artifact: filename,
                                    records: [], warnings: warnings)
        }

        // Video identity, when the export carries it: the thread every message
        // belongs to.
        let video = root["video"] as? [String: Any]
        let videoID = (video?["id"] as? String)
            ?? (video?["id"] as? Int).map(String.init)
            ?? (root["video_id"] as? String)
        let videoTitle = video?["title"] as? String
            ?? (video?["description"] as? String)

        var records: [DiscussionRecord] = []
        var undatedCount = 0

        for (index, comment) in comments.enumerated() {
            let message = comment["message"] as? [String: Any]
            let body = (message?["body"] as? String)
                ?? (comment["message"] as? String)
                ?? ""
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let commenter = comment["commenter"] as? [String: Any]
            let handle = (commenter?["display_name"] as? String)
                ?? (commenter?["name"] as? String)
            let authorID = (commenter?["_id"] as? String)
                ?? (commenter?["id"] as? String)
                ?? (commenter?["_id"] as? Int).map(String.init)

            let absolute = Self.date(fromISO8601: comment["created_at"] as? String)
            if absolute == nil { undatedCount += 1 }
            let offset = Self.seconds(comment["content_offset_seconds"])

            // The offset goes INTO the body, the way the media lane puts
            // timecodes into a transcript, so a retrieved answer can cite
            // "at 1:01:54 in the stream" from the text it quotes.
            var text = trimmed
            if let offset {
                text = "[\(Self.timecode(offset))] \(trimmed)"
            }

            let recordID = (comment["_id"] as? String)
                ?? (comment["id"] as? String)
                // No platform id: fall back to a position, zero-padded so the
                // ORDER survives sorting. Never a random id, which would break
                // dedup across re-ingests.
                ?? String(format: "%@#%08d", videoID ?? "vod", index + 1)

            records.append(DiscussionRecord(
                platform: platform, kind: .liveChat, recordID: recordID,
                threadID: videoID, threadTitle: videoTitle,
                authorHandle: handle, authorID: authorID,
                timestamp: absolute, body: text,
                permalink: videoID.map { id in
                    offset.map { "https://www.twitch.tv/videos/\(id)?t=\(Int($0))s" }
                        ?? "https://www.twitch.tv/videos/\(id)"
                }))
        }

        if comments.isEmpty {
            // A chat log with an empty `comments` array is a real state — a VOD
            // with chat disabled, or an export that captured nothing — and
            // saying so is a finding rather than silence.
            warnings.append(ParserWarning(severity: .warning, code: "twitch.no_messages",
                message: "This Twitch chat export contains no messages: the `comments` array is "
                       + "empty. The VOD may have had chat disabled, or the export captured "
                       + "nothing."))
        } else if records.isEmpty {
            warnings.append(ParserWarning(severity: .warning, code: "twitch.no_bodies",
                message: "\(comments.count) chat entr(y/ies) carried no message text, so none "
                       + "became a record."))
        }
        if undatedCount > 0 {
            // A VOD offset is not a date. Saying "undated" here prevents an
            // answer treating the offset as a wall-clock time.
            warnings.append(ParserWarning(severity: .warning, code: "twitch.offset_only",
                message: "\(undatedCount) message(s) carry only a position in the video "
                       + "(content_offset_seconds) and no absolute time, so they can be placed "
                       + "within the recording but not on the archive's timeline."))
        }
        return DiscussionExport(platform: platform, artifact: filename,
                                records: records, warnings: warnings)
    }

    // MARK: - Fields

    /// Offsets arrive as a JSON number or, from some tools, a string.
    nonisolated static func seconds(_ raw: Any?) -> Double? {
        switch raw {
        case let value as Double: return value >= 0 ? value : nil
        case let value as Int: return value >= 0 ? Double(value) : nil
        case let value as String: return Double(value).flatMap { $0 >= 0 ? $0 : nil }
        default: return nil
        }
    }

    /// `h:mm:ss` — how a viewer refers to a position in a stream.
    nonisolated static func timecode(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
        return String(format: "%d:%02d", minutes, secs)
    }

    nonisolated static func date(fromISO8601 raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        // Twitch writes fractional seconds; some tools drop them.
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}
