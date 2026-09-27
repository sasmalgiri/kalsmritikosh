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
import CryptoKit

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

    // MARK: - P4.2 stable identity

    /// The same event, with an id DERIVED from what it is (source · kind ·
    /// title · day · summary) instead of a fresh random one. The drain's
    /// milestone pass deletes and rebuilds every milestone on every boot; with
    /// random ids each boot replaced all of them (the owner copy's fixed-point
    /// check: 479 events, identities changed) and every claim projected from a
    /// milestone was orphaned and swept. Stable ids make the rebuild a no-op.
    /// Apply AFTER `collapse` — it leaves one event per such key per source.
    public nonisolated static func withStableID(_ e: Event) -> Event {
        let day = Int((e.date.timeIntervalSince1970 / 86_400).rounded(.down))
        let key = [e.sourceObjectID.uuidString, e.kind.rawValue, e.title, String(day), e.summary ?? ""]
            .joined(separator: "\u{1F}")
        var bytes = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50   // name-based (v5-style) UUID
        bytes[8] = (bytes[8] & 0x3F) | 0x80   // RFC 4122 variant
        let id = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                             bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        return Event(id: id, kind: e.kind, date: e.date, endDate: e.endDate,
                     title: e.title, summary: e.summary, entityIDs: e.entityIDs,
                     sourceObjectID: e.sourceObjectID, sourceRange: e.sourceRange,
                     confidence: e.confidence, dateConfidence: e.dateConfidence,
                     attributes: e.attributes, qualityTier: e.qualityTier,
                     datePrecision: e.datePrecision, status: e.status)
    }
}
