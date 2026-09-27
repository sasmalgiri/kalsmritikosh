//
//  EventDeduper.swift
//  Kalsmritikosh
//
//  P1.10 (2026-09-27) — one document states one happening once. Extraction
//  emitted the SAME event several times from one source: on the owner's copy
//  121 of 595 events were same-source repeats (a GDPR export listing seven
//  archived emails became seven identical "Archived entry" events per day),
//  and every repeat fanned out into claims (5,718 claim rows, 276 distinct).
//
//  Identity = (source document, kind, normalised title, calendar day). The
//  survivor is the highest-confidence member (ties: earliest id); it carries
//  the UNION of participants and an `occurrences` count, so nothing the
//  source said is lost — only the repetition. Events from DIFFERENT sources
//  are never merged here: two emails on one day are two happenings.
//
//  Pure and deterministic; applied before insert, so no downstream stage can
//  hold a reference to a dropped id.
//

import Foundation

public enum EventDeduper {

    struct Key: Hashable {
        let source: UUID
        let kind: String
        let title: String
        let day: String
    }

    nonisolated static func key(_ e: Event) -> Key {
        let title = e.title.lowercased()
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        let c = cal.dateComponents([.year, .month, .day], from: e.date)
        return Key(source: e.sourceObjectID, kind: e.kind.rawValue, title: title,
                   day: "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)")
    }

    /// Collapse same-source repeats, preserving first-seen order.
    public nonisolated static func collapse(_ events: [Event]) -> [Event] {
        guard events.count > 1 else { return events }
        var groups: [Key: [Event]] = [:]
        var order: [Key] = []
        for e in events {
            let k = key(e)
            if groups[k] == nil { order.append(k) }
            groups[k, default: []].append(e)
        }
        guard order.count < events.count else { return events }
        return order.compactMap { k in
            guard let members = groups[k], let lead = members.max(by: {
                $0.confidence.value != $1.confidence.value
                    ? $0.confidence.value < $1.confidence.value
                    : $0.id.uuidString > $1.id.uuidString
            }) else { return nil }
            guard members.count > 1 else { return lead }
            var participants: [Entity.ID] = []
            var seen = Set<Entity.ID>()
            for m in members { for id in m.entityIDs where seen.insert(id).inserted { participants.append(id) } }
            var attributes = lead.attributes
            attributes["occurrences"] = AnyCodable(.int(Int64(members.count)))
            return Event(id: lead.id, kind: lead.kind, date: lead.date, endDate: lead.endDate,
                         title: lead.title, summary: lead.summary, entityIDs: participants,
                         sourceObjectID: lead.sourceObjectID, sourceRange: lead.sourceRange,
                         confidence: lead.confidence, dateConfidence: lead.dateConfidence,
                         attributes: attributes, qualityTier: lead.qualityTier,
                         datePrecision: lead.datePrecision, status: lead.status)
        }
    }
}
