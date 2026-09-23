//
//  YouTubeTakeoutMapper.swift
//  Kalsmritikosh
//
//  DISC-1 — maps a Google Takeout "YouTube and YouTube Music" export into
//  DiscussionRecords. Three artifacts, all of which an examiner receives from the
//  account holder or under a lawful order:
//
//    comments/comments.csv      the discussion evidence itself. Columns:
//                               Comment ID, Channel ID, Comment Create Timestamp,
//                               Price, Parent Comment ID, Video ID, Comment Text.
//                               Newer exports wrap the text as JSON
//                               {"takeoutSegments":[{"text":"…"}]}; older ones
//                               store it plainly. Both are handled.
//    live chats/live-chats.csv  same shape, live-chat lines.
//    history/watch-history.json and search-history.json
//                               activity, not speech: each entry is
//                               {header, title, titleUrl, subtitles, time}
//                               where title reads "Watched X" / "Searched for X".
//
//  The reply graph is real here: Parent Comment ID lets a cited answer show who
//  was replying to whom, not merely who posted.
//

import Foundation

public struct YouTubeTakeoutMapper: DiscussionExportMapper {
    public nonisolated var platform: String { "YouTube" }
    public nonisolated var mapperVersion: String { "1" }

    public nonisolated init() {}

    // MARK: - Claiming

    /// Which Takeout artifact a file is. Decided from CONTENT, never the
    /// extension: an examiner routinely renames evidence, and a hive or export
    /// pulled out of an extraction may arrive with no extension at all. The
    /// filename is used only to distinguish live chat from comments, which are
    /// structurally identical and differ solely in what they are.
    nonisolated enum Artifact { case commentsCSV, activityJSON }

    nonisolated static func artifact(in sample: Data) -> Artifact? {
        guard let text = String(data: sample, encoding: .utf8)
                ?? String(data: sample, encoding: .isoLatin1) else { return nil }
        // The CSV header is an unambiguous fingerprint; no other artifact has
        // both of these columns.
        let header = text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        if header.contains("Comment ID") && header.contains("Video ID") { return .commentsCSV }
        // Activity JSON: an array of entries carrying YouTube's own header value.
        let leading = text.drop(while: { $0.isWhitespace })
        if leading.first == "[", text.contains("\"header\""),
           text.contains("\"YouTube\"") || text.contains("YouTube Music") {
            return .activityJSON
        }
        return nil
    }

    public nonisolated func claims(filename: String, sample: Data) -> Bool {
        Self.artifact(in: sample) != nil
    }

    // MARK: - Mapping

    public nonisolated func map(data: Data, filename: String) -> DiscussionExport {
        switch Self.artifact(in: data.prefix(DiscussionExportRegistry.sampleSize)) {
        case .commentsCSV:  return mapCSV(data, filename: filename)
        case .activityJSON: return mapActivityJSON(data, filename: filename)
        case nil:
            return DiscussionExport(
                platform: platform, artifact: filename, records: [],
                warnings: [ParserWarning(severity: .warning, code: "youtube.unrecognized_artifact",
                                         message: "Not a recognized YouTube Takeout artifact.")])
        }
    }

    private nonisolated func mapCSV(_ data: Data, filename: String) -> DiscussionExport {
        var warnings: [ParserWarning] = []
        guard let text = String(data: data, encoding: .utf8) else {
            return DiscussionExport(platform: platform, artifact: filename, records: [],
                warnings: [ParserWarning(severity: .error, code: "youtube.undecodable",
                                         message: "File is not valid UTF-8.")])
        }
        let rows = Self.parseCSV(text)
        guard let header = rows.first else {
            return DiscussionExport(platform: platform, artifact: filename, records: [],
                warnings: [ParserWarning(severity: .warning, code: "youtube.empty",
                                         message: "No rows in export.")])
        }
        func index(_ column: String) -> Int? { header.firstIndex(of: column) }
        let idIdx = index("Comment ID")
        let channelIdx = index("Channel ID")
        let timeIdx = index("Comment Create Timestamp")
        let parentIdx = index("Parent Comment ID")
        let videoIdx = index("Video ID")
        let textIdx = index("Comment Text")

        guard let idIdx, let textIdx else {
            return DiscussionExport(platform: platform, artifact: filename, records: [],
                warnings: [ParserWarning(severity: .error, code: "youtube.unexpected_columns",
                    message: "Export is missing Comment ID / Comment Text; columns were "
                           + header.joined(separator: ", "))])
        }

        let isLiveChat = filename.lowercased().contains("live-chat")
        var records: [DiscussionRecord] = []
        var skipped = 0
        for row in rows.dropFirst() {
            guard row.count > max(idIdx, textIdx) else { skipped += 1; continue }
            let body = Self.commentText(row[textIdx])
            let recordID = row[idIdx]
            guard !recordID.isEmpty, !body.isEmpty else { skipped += 1; continue }

            func field(_ i: Int?) -> String? {
                guard let i, i < row.count, !row[i].isEmpty else { return nil }
                return row[i]
            }
            let parent = field(parentIdx)
            let video = field(videoIdx)
            records.append(DiscussionRecord(
                platform: platform,
                // A comment WITH a parent is a reply — the distinction is what lets
                // an answer describe an exchange rather than a list of remarks.
                kind: isLiveChat ? .liveChat : (parent == nil ? .comment : .reply),
                recordID: recordID,
                parentID: parent,
                threadID: video,
                threadTitle: video.map { "YouTube video \($0)" },
                // Takeout gives the commenter's channel id, not a display name.
                // Reporting the id is correct; inventing a name would not be.
                authorHandle: nil,
                authorID: field(channelIdx),
                timestamp: field(timeIdx).flatMap(Self.parseTimestamp),
                body: body,
                permalink: video.map { v in
                    "https://www.youtube.com/watch?v=\(v)&lc=\(recordID)"
                }))
        }
        if skipped > 0 {
            warnings.append(ParserWarning(severity: .warning, code: "youtube.rows_skipped",
                message: "\(skipped) row(s) had no comment id or empty text and were not indexed."))
        }
        return DiscussionExport(platform: platform, artifact: filename,
                                records: records, warnings: warnings)
    }

    private nonisolated func mapActivityJSON(_ data: Data, filename: String) -> DiscussionExport {
        var warnings: [ParserWarning] = []
        guard let root = try? JSONSerialization.jsonObject(with: data),
              let entries = root as? [[String: Any]] else {
            return DiscussionExport(platform: platform, artifact: filename, records: [],
                warnings: [ParserWarning(severity: .error, code: "youtube.bad_activity_json",
                                         message: "Activity export is not a JSON array of entries.")])
        }
        var records: [DiscussionRecord] = []
        var skipped = 0
        for (i, entry) in entries.enumerated() {
            guard let title = entry["title"] as? String, !title.isEmpty else { skipped += 1; continue }
            let time = (entry["time"] as? String).flatMap(Self.parseTimestamp)
            let url = entry["titleUrl"] as? String
            // "subtitles" names the channel for a watch entry.
            let channel = (entry["subtitles"] as? [[String: Any]])?
                .compactMap { $0["name"] as? String }.first
            records.append(DiscussionRecord(
                platform: platform,
                // Watching and searching are ACTIVITY, not speech. Keeping them a
                // distinct kind stops "what did they say" from returning a search box.
                kind: .activity,
                recordID: "\(filename)#\(i)",
                threadID: channel,
                threadTitle: channel,
                timestamp: time,
                body: channel.map { "\(title) — channel: \($0)" } ?? title,
                permalink: url))
        }
        if skipped > 0 {
            warnings.append(ParserWarning(severity: .warning, code: "youtube.entries_skipped",
                message: "\(skipped) activity entr(ies) had no title and were not indexed."))
        }
        return DiscussionExport(platform: platform, artifact: filename,
                                records: records, warnings: warnings)
    }

    // MARK: - Field decoding

    /// Newer Takeout wraps comment text as `{"takeoutSegments":[{"text":"…"}]}`.
    /// Older exports store it plainly. Returning the JSON verbatim would put
    /// machine scaffolding into the evidence, so segments are joined.
    nonisolated static func commentText(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let segments = object["takeoutSegments"] as? [[String: Any]] else {
            return trimmed
        }
        let joined = segments.compactMap { $0["text"] as? String }.joined()
        return joined.isEmpty ? trimmed : joined
    }

    /// Takeout timestamps are RFC 3339, sometimes with fractional seconds and
    /// sometimes without. Both are accepted; anything else yields nil rather than
    /// a guessed date.
    nonisolated static func parseTimestamp(_ raw: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: raw) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }

    /// Delegates to the shared RFC 4180 reader (DISC-2). Kept as a named entry
    /// point because this mapper's tests pin CSV fidelity through it.
    nonisolated static func parseCSV(_ text: String) -> [[String]] {
        DiscussionCSV.parse(text)
    }
}
