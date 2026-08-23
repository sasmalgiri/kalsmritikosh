//
//  EmailThreadingService.swift
//  Kalsmritikosh
//
//  Deduplicate and thread a pile of ingested email messages — the journalist /
//  investigator / legal pain of a huge, redundant email dump (the same message
//  appearing many times, replies scattered out of order).
//
//  Dedup is exact: messages whose source file shares a content hash are the
//  same bytes, so only the first is kept. Threading is heuristic and labelled
//  as such: the ledger doesn't persist RFC message-id / in-reply-to, so threads
//  are grouped by normalized subject (reply/forward prefixes stripped) and
//  ordered by date. It's honest about being subject-based, not header-based.
//

import Foundation

public struct EmailThread: Identifiable, Sendable {
    public let id: String            // normalized subject key (stable)
    public let displaySubject: String
    public let messages: [EmailDigestRow]  // chronological; undated last
    public let participants: [String]
    public let earliest: Date?
    public let latest: Date?
    public var count: Int { messages.count }
}

public struct EmailThreadingResult: Sendable {
    public let threads: [EmailThread]
    public let totalMessages: Int      // after dedup
    public let duplicatesRemoved: Int
}

public enum EmailThreadingService {

    public static func organize(_ rows: [EmailDigestRow]) -> EmailThreadingResult {
        // 1) Exact-duplicate removal by content hash (empty hash = keep all).
        var seenHashes = Set<String>()
        var deduped: [EmailDigestRow] = []
        var duplicates = 0
        for row in rows {
            if row.contentHash.isEmpty {
                deduped.append(row)
            } else if seenHashes.contains(row.contentHash) {
                duplicates += 1
            } else {
                seenHashes.insert(row.contentHash)
                deduped.append(row)
            }
        }

        // 2) Group by normalized subject.
        var groups: [String: [EmailDigestRow]] = [:]
        for row in deduped {
            groups[normalizeSubject(row.subject), default: []].append(row)
        }

        // 3) Build threads: chronological messages, unique participants, range.
        var threads: [EmailThread] = []
        for (key, msgs) in groups {
            let sorted = msgs.sorted { a, b in
                switch (a.date, b.date) {
                case let (x?, y?): return x < y
                case (nil, _?):    return false
                case (_?, nil):    return true
                default:           return a.createdAt < b.createdAt
                }
            }
            let dates = sorted.compactMap { $0.date }
            let participants = orderedUnique(sorted.map { $0.from }.filter { !$0.isEmpty })
            let display = sorted.first(where: { !$0.subject.trimmingCharacters(in: .whitespaces).isEmpty })?.subject
                ?? "(no subject)"
            threads.append(EmailThread(
                id: key,
                displaySubject: display,
                messages: sorted,
                participants: participants,
                earliest: dates.min(),
                latest: dates.max()))
        }

        // 4) Most-recently-active threads first; then largest; stable by subject.
        threads.sort { a, b in
            switch (a.latest, b.latest) {
            case let (x?, y?) where x != y: return x > y
            case (nil, _?): return false
            case (_?, nil): return true
            default: break
            }
            if a.count != b.count { return a.count > b.count }
            return a.displaySubject.lowercased() < b.displaySubject.lowercased()
        }

        return EmailThreadingResult(
            threads: threads,
            totalMessages: deduped.count,
            duplicatesRemoved: duplicates)
    }

    /// Lower-case the subject and strip any run of leading reply/forward
    /// prefixes (Re:, Fwd:, Fw:, AW:, RV:) and bracketed list tags.
    static func normalizeSubject(_ subject: String) -> String {
        var s = subject.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.isEmpty { return "(no subject)" }
        let prefixPattern = "^\\s*(re|fwd|fw|aw|rv|antwort)\\s*:\\s*"
        while let range = s.range(of: prefixPattern, options: [.regularExpression]) {
            s.removeSubrange(range)
            s = s.trimmingCharacters(in: .whitespaces)
        }
        // Drop leading [list-tag] markers.
        while let range = s.range(of: "^\\s*\\[[^\\]]+\\]\\s*", options: [.regularExpression]) {
            s.removeSubrange(range)
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? "(no subject)" : s
    }

    private static func orderedUnique(_ items: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for i in items where !seen.contains(i) { seen.insert(i); out.append(i) }
        return out
    }
}
