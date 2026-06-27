//
//  EventNarrativeSlots.swift
//  Kalsmritikosh
//
//  HISTORY Phase C.1 — the 5W+H slot schema that turns an Event
//  from a bullet ("Email received, 2023-03-14") into a narrative
//  sentence ("On 2023-03-14, Khurana sent the patent draft to
//  Shabana for review of claim 4").
//
//  Why a SECOND slot vocabulary on top of FactSchema?
//    FactSchema (Knowledge/Ontology) carries TYPED slots for the
//    knowledge-graph walk: Email.sender_person, Invoice.amount,
//    Contract.party_a_org. Those slots are deterministic and bond-
//    walkable, but they don't carry the surface forms or motivation
//    a narrative chapter needs.
//
//    The 5W+H form is the SAME shape regardless of FactType:
//      WHO   — actor / subject (a named person, org, or system)
//      WHAT  — the action or object of the action
//      WHEN  — observed time phrase (cross-references event.date)
//      WHERE — location, channel, medium, or scope
//      WHY   — motivation, trigger, or referenced cause
//      HOW   — mechanism, instrument, or means
//
//  Each slot may carry MULTIPLE values (an email has several WHOs:
//  one sender, several recipients) — they're stored as a list, not
//  a singleton.
//
//  Each value carries provenance — source KO + chunk IDs and an
//  extractor tag (structured header vs rule-based vs LLM). The
//  narrative composer (Phase D) cites these IDs in the answer card.
//
//  Persistence: encoded as one JSON object per Event in the
//  `events.narrative_slots_json` column (schema v21). Default '{}'.
//
//  Quality-or-nothing: if no extractor produced a value, the slot
//  stays empty. The composer omits an empty slot rather than
//  hallucinating one.
//

import Foundation

/// The six named slots a narrative event carries.
public nonisolated enum NarrativeSlot: String, Codable, Sendable, Hashable, CaseIterable {
    case who
    case what
    case when
    case `where`
    case why
    case how

    public var displayName: String {
        switch self {
        case .who:   return "Who"
        case .what:  return "What"
        case .when:  return "When"
        case .where: return "Where"
        case .why:   return "Why"
        case .how:   return "How"
        }
    }
}

/// Where the slot value came from. Drives both UI surfacing ("from
/// the email header" vs "inferred by the model") and the composer's
/// confidence math — header-derived values get full trust, LLM-only
/// values get downgraded if no other slot in the chapter corroborates.
public nonisolated enum SlotProvenance: String, Codable, Sendable, Hashable {
    /// Parsed from structured metadata (email From/Date/To, EXIF, ID3).
    case structuredHeader
    /// Rule-based regex / pattern extractor in the ingest pipeline.
    case ruleBased
    /// Output of an `.extraction` capability LLM call.
    case llmExtractor
    /// Carried over from a typed FactSchema slot (e.g. Email.sender_person
    /// → WHO). Lossless re-projection; trust matches the source slot.
    case fromFactSlot
    /// Inferred from neighbouring events or community context. Lowest
    /// trust tier among populated slots.
    case inferred
}

/// One value of one slot on one event. The narrative composer (Phase
/// D) cites `sourceObjectIDs` + `sourceChunkIDs` when it uses this
/// value in a sentence.
public nonisolated struct NarrativeSlotValue: Codable, Sendable, Hashable {
    public let text: String
    public let confidence: Double
    public let provenance: SlotProvenance
    /// Source KO IDs that evidence this value. Empty list means the
    /// value was carried over from another slot and inherits its
    /// provenance — the composer should still gate it on the parent
    /// event's source.
    public let sourceObjectIDs: [UUID]
    /// Optional chunk-level provenance. Empty when only object-level
    /// provenance is available (e.g. parsed header has no chunk).
    public let sourceChunkIDs: [UUID]
    /// Optional pointer to the entity ID this value resolves to. WHO
    /// slots that name a known Person carry the entity ID so the
    /// composer can link to the dossier without re-searching.
    public let entityID: UUID?

    public init(
        text: String,
        confidence: Double,
        provenance: SlotProvenance,
        sourceObjectIDs: [UUID] = [],
        sourceChunkIDs: [UUID] = [],
        entityID: UUID? = nil
    ) {
        self.text = text
        self.confidence = max(0.0, min(1.0, confidence))
        self.provenance = provenance
        self.sourceObjectIDs = sourceObjectIDs
        self.sourceChunkIDs = sourceChunkIDs
        self.entityID = entityID
    }
}

/// The 5W+H bundle for a single Event. Each slot is a list — events
/// frequently have multiple WHOs (sender + recipients), WHATs (a
/// sent draft + a referenced patent), and so on. Empty lists are
/// allowed and indicate the extractor pipeline never filled the slot.
public nonisolated struct EventNarrativeSlots: Codable, Sendable, Hashable {
    public var who: [NarrativeSlotValue]
    public var what: [NarrativeSlotValue]
    public var when: [NarrativeSlotValue]
    /// `where` is a Swift reserved word as a property name; the JSON
    /// key still says "where".
    public var whereAt: [NarrativeSlotValue]
    public var why: [NarrativeSlotValue]
    public var how: [NarrativeSlotValue]

    public init(
        who: [NarrativeSlotValue] = [],
        what: [NarrativeSlotValue] = [],
        when: [NarrativeSlotValue] = [],
        whereAt: [NarrativeSlotValue] = [],
        why: [NarrativeSlotValue] = [],
        how: [NarrativeSlotValue] = []
    ) {
        self.who = who
        self.what = what
        self.when = when
        self.whereAt = whereAt
        self.why = why
        self.how = how
    }

    /// Sentinel for the "no slots filled" case. Persisted as "{}".
    public static let empty = EventNarrativeSlots()

    /// True when every slot is empty. The composer's `omitIfEmpty`
    /// gate keys off this so we don't render empty 5W+H pills.
    public var isEmpty: Bool {
        who.isEmpty && what.isEmpty && when.isEmpty
            && whereAt.isEmpty && why.isEmpty && how.isEmpty
    }

    /// How many of the six slots have at least one value. Used by
    /// the composer's chapter-density gate ("only summarize chapters
    /// where ≥3 slots are populated").
    public var filledSlotCount: Int {
        var n = 0
        if !who.isEmpty     { n += 1 }
        if !what.isEmpty    { n += 1 }
        if !when.isEmpty    { n += 1 }
        if !whereAt.isEmpty { n += 1 }
        if !why.isEmpty     { n += 1 }
        if !how.isEmpty     { n += 1 }
        return n
    }

    /// Read accessor that takes a `NarrativeSlot` enum case. Used by
    /// the Phase C.4 retrieval boost so it can iterate slot kinds
    /// without hard-coding property names.
    public func values(for slot: NarrativeSlot) -> [NarrativeSlotValue] {
        switch slot {
        case .who:   return who
        case .what:  return what
        case .when:  return when
        case .where: return whereAt
        case .why:   return why
        case .how:   return how
        }
    }

    /// Append a value to the named slot. De-dupes by case-insensitive
    /// text match so an LLM re-run doesn't double-stamp the same
    /// observation.
    public mutating func add(_ value: NarrativeSlotValue, to slot: NarrativeSlot) {
        let normalized = value.text.lowercased()
        func contains(_ list: [NarrativeSlotValue]) -> Bool {
            list.contains(where: { $0.text.lowercased() == normalized })
        }
        switch slot {
        case .who:
            if !contains(who) { who.append(value) }
        case .what:
            if !contains(what) { what.append(value) }
        case .when:
            if !contains(when) { when.append(value) }
        case .where:
            if !contains(whereAt) { whereAt.append(value) }
        case .why:
            if !contains(why) { why.append(value) }
        case .how:
            if !contains(how) { how.append(value) }
        }
    }

    /// All source KO IDs cited by any slot value. The narrative
    /// composer uses this set as the evidence pool for the chapter
    /// the event belongs to.
    public var allCitedObjectIDs: Set<UUID> {
        var set: Set<UUID> = []
        for slot in NarrativeSlot.allCases {
            for value in values(for: slot) {
                set.formUnion(value.sourceObjectIDs)
            }
        }
        return set
    }

    // MARK: - JSON round-trip

    /// Encode to the JSON string the `events.narrative_slots_json`
    /// column holds. Empty bundles encode as "{}" so the default
    /// column value round-trips cleanly.
    public func encodedJSON() -> String {
        if isEmpty { return "{}" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self),
              let s = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return s
    }

    /// Decode from the column's JSON. Returns `.empty` on malformed
    /// or missing input — the column has a NOT NULL DEFAULT '{}' so
    /// the input is never nil at the DB layer.
    public static func decoded(from json: String) -> EventNarrativeSlots {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "{}" else { return .empty }
        guard let data = trimmed.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(EventNarrativeSlots.self, from: data) else {
            return .empty
        }
        return decoded
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case who
        case what
        case when
        case whereAt = "where"
        case why
        case how
    }
}
