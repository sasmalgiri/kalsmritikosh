//
//  PairCommunicationTimeline.swift
//  Kalsmritikosh
//
//  A-9 — the communication timeline between two people (or organisations): every email one sent the
//  other (email_participant_occurrences: from → to/cc, the same rows the N-2 communication analysis
//  uses, dated by each email's own Date header) and every dated ledger event both take part in
//  (event_entities), in date order, each carrying the knowledge object it came from so it can be
//  opened. Entities merged into either canonical entity count as that entity. Read-only.
//

import Foundation
import os

public nonisolated struct PairTimelineItem: Hashable, Sendable, Identifiable {
    public enum Kind: String, Sendable, Hashable { case email, event }
    public let id: String
    public let kind: Kind
    /// nil when the source's own date could not be read (the item is listed after the dated ones).
    public let date: Date?
    public let title: String
    public let detail: String?
    /// For emails: true when the first party of the pair sent it.
    public let fromFirst: Bool?
    public let sourceObjectID: UUID?

    public init(id: String, kind: Kind, date: Date?, title: String, detail: String?, fromFirst: Bool?, sourceObjectID: UUID?) {
        self.id = id; self.kind = kind; self.date = date; self.title = title; self.detail = detail
        self.fromFirst = fromFirst; self.sourceObjectID = sourceObjectID
    }
}

public nonisolated enum PairTimeline {

    /// Merge emails and events into one list by date (undated last). An event read from the same
    /// email on the same day is the same communication, so only the email is kept.
    public static func merge(emails: [PairTimelineItem], events: [PairTimelineItem]) -> [PairTimelineItem] {
        let cal = Calendar(identifier: .gregorian)
        var emailDays = Set<String>()
        for e in emails {
            guard let src = e.sourceObjectID else { continue }
            emailDays.insert(src.uuidString + "|" + (e.date.map { dayKey($0, cal) } ?? "-"))
        }
        let keptEvents = events.filter { ev in
            guard let src = ev.sourceObjectID, let d = ev.date else { return true }
            return !emailDays.contains(src.uuidString + "|" + dayKey(d, cal))
        }
        var seen = Set<String>()
        let all = (emails + keptEvents).filter { seen.insert($0.id).inserted }
        return all.sorted { a, b in
            switch (a.date, b.date) {
            case let (x?, y?): return x != y ? x < y : a.id < b.id
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return a.id < b.id
            }
        }
    }

    /// An email's own Date header ("Tue, 3 Mar 2020 10:15:00 +0000 (UTC)"), the trailing comment removed.
    public static func emailDate(_ raw: String?) -> Date? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let cleaned = raw.replacingOccurrences(of: #"\s*\([^)]*\)\s*$"#, with: "", options: .regularExpression)
        if let d = EmailLoader.parseRFC2822Date(cleaned) { return d }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["EEE, d MMM yyyy HH:mm Z", "d MMM yyyy HH:mm Z", "yyyy-MM-dd HH:mm:ss Z", "yyyy-MM-dd"] {
            f.dateFormat = fmt
            if let d = f.date(from: cleaned) { return d }
        }
        return nil
    }

    private static func dayKey(_ d: Date, _ cal: Calendar) -> String {
        let c = cal.dateComponents(in: TimeZone(identifier: "UTC") ?? .current, from: d)
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }

    // MARK: - Ledger read

    public static func load(_ database: Database, between a: UUID, and b: UUID, limit: Int = 500) async throws -> [PairTimelineItem] {
        let ids: [SQLValue] = [.uuid(a), .uuid(b), .integer(Int64(limit))]
        let emailRows = try await database.query("""
            WITH ida(id) AS (SELECT ?1 UNION SELECT id FROM entities WHERE merged_into = ?1),
                 idb(id) AS (SELECT ?2 UNION SELECT id FROM entities WHERE merged_into = ?2)
            SELECT f.source_ko_id,
                   MAX(CASE WHEN f.entity_id IN (SELECT id FROM ida) THEN 1 ELSE 0 END),
                   json_extract(ko.metadata_json, '$.date'), json_extract(ko.metadata_json, '$.subject')
            FROM email_participant_occurrences f
            JOIN email_participant_occurrences t ON t.source_ko_id = f.source_ko_id AND t.role IN ('to','cc')
            JOIN knowledge_objects ko ON ko.id = f.source_ko_id
            WHERE f.role = 'from'
              AND ((f.entity_id IN (SELECT id FROM ida) AND t.entity_id IN (SELECT id FROM idb))
                OR (f.entity_id IN (SELECT id FROM idb) AND t.entity_id IN (SELECT id FROM ida)))
            GROUP BY f.source_ko_id
            LIMIT ?3;
            """, ids)
        let emails = emailRows.compactMap { r -> PairTimelineItem? in
            guard let ko = r.string(0) else { return nil }
            let trimmed = (r.string(3) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let subject: String? = trimmed.isEmpty ? nil : trimmed
            return PairTimelineItem(id: "email|\(ko)", kind: .email, date: emailDate(r.string(2)),
                                    title: subject ?? "(no subject)",
                                    detail: r.string(2), fromFirst: r.int(1) == 1, sourceObjectID: UUID(uuidString: ko))
        }
        let eventRows = try await database.query("""
            WITH ida(id) AS (SELECT ?1 UNION SELECT id FROM entities WHERE merged_into = ?1),
                 idb(id) AS (SELECT ?2 UNION SELECT id FROM entities WHERE merged_into = ?2)
            SELECT e.id, e.date, e.title, e.summary, e.source_object_id, e.kind FROM events e
            WHERE e.id IN (SELECT event_id FROM event_entities WHERE entity_id IN (SELECT id FROM ida))
              AND e.id IN (SELECT event_id FROM event_entities WHERE entity_id IN (SELECT id FROM idb))
              AND (e.review_status IS NULL OR e.review_status != 'rejected')
            ORDER BY e.date
            LIMIT ?3;
            """, ids)
        let events = eventRows.compactMap { r -> PairTimelineItem? in
            guard let id = r.string(0), let title = r.string(2) else { return nil }
            return PairTimelineItem(id: "event|\(id)", kind: .event, date: r.date(1), title: title,
                                    detail: r.string(3) ?? r.string(5), fromFirst: nil,
                                    sourceObjectID: r.string(4).flatMap(UUID.init(uuidString:)))
        }
        return merge(emails: emails, events: events)
    }
}
