//
//  RedditExportMapper.swift
//  Kalsmritikosh
//
//  DISC-3 — maps a Reddit data export into DiscussionRecords. Three artifacts,
//  distinguished by their column sets rather than their filenames (Reddit's
//  `comments.csv` collides by name with YouTube's, so content decides):
//
//    comments.csv  id, permalink, date, ip, subreddit, gildings, link, parent, body
//                  `parent` is the real reply graph: t1_xxx = a comment,
//                  t3_xxx = the post itself. That distinction is what lets an
//                  answer say whether someone replied to a person or to a thread.
//    posts.csv     id, permalink, date, ip, subreddit, gildings, title, url, body
//    messages.csv  id, permalink, thread_id, date, ip, from, to, subject, body
//                  the ONLY Reddit artifact that names the other party.
//
//  As with Discord, comments.csv and posts.csv contain only the requesting
//  account's own content, so those are attributed to the account holder and never
//  to an invented username. messages.csv carries `from`, so it gets a real one.
//

import Foundation

public struct RedditExportMapper: DiscussionExportMapper {
    public nonisolated var platform: String { "Reddit" }
    public nonisolated var mapperVersion: String { "1" }

    public nonisolated static let accountHolder = "(export account holder)"

    public nonisolated init() {}

    nonisolated enum Artifact { case comments, posts, messages }

    nonisolated static func artifact(in sample: Data) -> Artifact? {
        guard let text = String(data: sample, encoding: .utf8) else { return nil }
        let headerLine = text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        let header = DiscussionCSV.Header(DiscussionCSV.parse(headerLine).first ?? [])
        // Reddit rows always carry a permalink; the discriminating column then
        // says which artifact it is. Checked most-specific first.
        guard header.has("id", "permalink") else { return nil }
        if header.has("from", "to") { return .messages }
        if header.has("subreddit", "parent") { return .comments }
        if header.has("subreddit", "title") { return .posts }
        return nil
    }

    public nonisolated func claims(filename: String, sample: Data) -> Bool {
        Self.artifact(in: sample) != nil
    }

    public nonisolated func map(data: Data, filename: String) -> DiscussionExport {
        guard let kind = Self.artifact(in: data.prefix(DiscussionExportRegistry.sampleSize)) else {
            return DiscussionExport(
                platform: platform, artifact: filename, records: [],
                warnings: [ParserWarning(severity: .warning, code: "reddit.unrecognized_artifact",
                                         message: "Not a recognized Reddit export.")])
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return DiscussionExport(platform: platform, artifact: filename, records: [],
                warnings: [ParserWarning(severity: .error, code: "reddit.undecodable",
                                         message: "File is not valid UTF-8.")])
        }
        let rows = DiscussionCSV.parse(text)
        guard let headerRow = rows.first else {
            return DiscussionExport(platform: platform, artifact: filename, records: [],
                warnings: [ParserWarning(severity: .warning, code: "reddit.empty",
                                         message: "No rows in export.")])
        }
        let header = DiscussionCSV.Header(headerRow)
        let idIdx = header.index("id")
        let dateIdx = header.index("date")
        let bodyIdx = header.index("body")
        let permalinkIdx = header.index("permalink")
        let subredditIdx = header.index("subreddit")
        let parentIdx = header.index("parent")
        let linkIdx = header.index("link")
        let titleIdx = header.index("title")
        let fromIdx = header.index("from")
        let toIdx = header.index("to")
        let threadIdx = header.index("thread_id")
        let subjectIdx = header.index("subject")

        var records: [DiscussionRecord] = []
        var skipped = 0
        for row in rows.dropFirst() {
            func field(_ i: Int?) -> String? { DiscussionCSV.field(row, i) }
            guard let id = field(idIdx) else { skipped += 1; continue }

            // A post's evidence is its title even when the body is empty (a link
            // post has no body at all), so title and body are combined rather
            // than requiring body alone.
            let title = field(titleIdx)
            let bodyText = field(bodyIdx)
            var body: String
            switch kind {
            case .posts:
                var parts = [title, bodyText].compactMap { $0 }
                // A LINK post's target is the post's substance — "where did they
                // point people" is often the whole question. Reddit reuses the
                // `url` column for self posts, where it repeats the permalink and
                // would only add noise, so it is recorded only when it differs.
                if let url = field(header.index("url")), url != field(permalinkIdx) {
                    parts.append("link: \(url)")
                }
                body = parts.joined(separator: "\n")
            case .messages:
                let subject = field(subjectIdx)
                body = [subject.map { "Subject: \($0)" }, bodyText]
                    .compactMap { $0 }.joined(separator: "\n")
            case .comments:
                body = bodyText ?? ""
            }
            guard !body.isEmpty else { skipped += 1; continue }

            let subreddit = field(subredditIdx)
            let parent = field(parentIdx)
            let threadID: String? = {
                switch kind {
                case .messages: return field(threadIdx) ?? id
                case .posts:    return subreddit.map { "r/\($0)" }
                case .comments:
                    // Group a comment under the POST it belongs to when the export
                    // names it, so an exchange reads as one thread. `link` is the
                    // post; falling back to the subreddit keeps it grouped somewhere
                    // real rather than stranding it.
                    return field(linkIdx) ?? subreddit.map { "r/\($0)" }
                }
            }()

            records.append(DiscussionRecord(
                platform: platform,
                kind: {
                    switch kind {
                    case .posts:    return .post
                    case .messages: return .directMessage
                    case .comments:
                        // t1_ = replying to a comment, t3_ = a top-level comment on
                        // the post. Only the former is a reply to a person.
                        return (parent?.hasPrefix("t1_") ?? false) ? .reply : .comment
                    }
                }(),
                recordID: id,
                parentID: (parent?.hasPrefix("t1_") ?? false) ? parent : nil,
                threadID: threadID,
                threadTitle: {
                    switch kind {
                    case .messages: return "Reddit message thread"
                    default:        return subreddit.map { "r/\($0)" } ?? threadID
                    }
                }(),
                authorHandle: kind == .messages ? field(fromIdx) : Self.accountHolder,
                authorID: nil,
                timestamp: field(dateIdx).flatMap(Self.parseTimestamp),
                body: {
                    // The recipient is part of a message's meaning; a message with
                    // no stated recipient must not silently look like a broadcast.
                    if kind == .messages, let to = field(toIdx) {
                        return "to \(to): \(body)"
                    }
                    return body
                }(),
                permalink: field(permalinkIdx)))
        }

        var warnings: [ParserWarning] = []
        if skipped > 0 {
            warnings.append(ParserWarning(severity: .warning, code: "reddit.rows_skipped",
                message: "\(skipped) row(s) had no id or no content and were not indexed."))
        }
        return DiscussionExport(platform: platform, artifact: filename,
                                records: records, warnings: warnings)
    }

    /// Reddit writes `2026-03-14 09:26:53 UTC`; some exports use RFC 3339.
    /// Anything else yields nil rather than a guessed date.
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
        for format in ["yyyy-MM-dd HH:mm:ss zzz", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm"] {
            formatter.dateFormat = format
            if let d = formatter.date(from: trimmed) { return d }
        }
        return nil
    }
}
