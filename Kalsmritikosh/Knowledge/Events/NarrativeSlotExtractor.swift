//
//  NarrativeSlotExtractor.swift
//  Kalsmritikosh
//
//  HISTORY Phase C.2 — rule-based 5W+H slot extractor that runs at
//  ingest time after EventExtractor inserts the row. Pulls the slot
//  values from material the pipeline has already computed:
//
//    - the Event itself                 (date → WHEN, title → WHAT)
//    - the source KnowledgeObject's     (subject, from/to/cc/date
//      headers and content origin       → WHO, WHAT, WHERE, HOW)
//    - the canonical entity list +      (resolves WHO entity IDs so
//      mapping                            the composer can link to
//                                         dossiers)
//    - email participant resolution     (sender + recipients as
//                                         canonical entity IDs)
//
//  Provenance is always the source KO id (and, when known, chunk ids
//  via the Event's sourceObjectID linkage). The values carry one of
//  three SlotProvenance tiers:
//    .structuredHeader — from `metadata["from"|"to"|"cc"|"subject"|"date"]`
//    .ruleBased        — from kind + EventExtractor's marker phrase
//    .fromFactSlot     — projected from a typed FactSchema slot
//
//  Quality-or-nothing: if the pipeline didn't produce a value, the
//  slot stays empty. The Phase D narrative composer omits empty
//  slots rather than guessing.
//
//  LLM augmentation runs separately in a background pass (later
//  iteration) — this file is pure on-device rule code so it can run
//  inline in the ingest critical path without blocking on model
//  availability.
//

import Foundation

public protocol NarrativeSlotExtractor: Sendable {
    func extract(
        event: Event,
        object: KnowledgeObject,
        entities: [Entity],
        canonicalMapping: [Entity.ID: Entity.ID],
        emailParticipants: NarrativeSlotEmailParticipants?
    ) async -> EventNarrativeSlots
}

/// Mirror of `Tier1RelationshipExtractor.EmailParticipants` kept here
/// so the slot extractor doesn't import the Tier1 module just for
/// the type. The IngestCoordinator translates between them.
public nonisolated struct NarrativeSlotEmailParticipants: Sendable {
    public let senderID: Entity.ID
    public let senderAddress: String?
    public let senderName: String?
    public let recipientIDs: [Entity.ID]
    public let recipientLabels: [String]

    public init(
        senderID: Entity.ID,
        senderAddress: String?,
        senderName: String?,
        recipientIDs: [Entity.ID],
        recipientLabels: [String]
    ) {
        self.senderID = senderID
        self.senderAddress = senderAddress
        self.senderName = senderName
        self.recipientIDs = recipientIDs
        self.recipientLabels = recipientLabels
    }
}

public struct RuleNarrativeSlotExtractor: NarrativeSlotExtractor {
    public init() {}

    public func extract(
        event: Event,
        object: KnowledgeObject,
        entities: [Entity],
        canonicalMapping: [Entity.ID: Entity.ID],
        emailParticipants: NarrativeSlotEmailParticipants?
    ) async -> EventNarrativeSlots {
        var slots = EventNarrativeSlots.empty
        let src = [object.id]

        // ── WHEN ─────────────────────────────────────────────────
        // The event's primary date is always present. Trust matches
        // dateConfidence so the composer can render "around" vs
        // exact phrasings later.
        let whenValue = NarrativeSlotValue(
            text: Self.formatWhen(event.date),
            confidence: event.dateConfidence,
            provenance: event.dateConfidence >= 0.9 ? .structuredHeader : .ruleBased,
            sourceObjectIDs: src
        )
        slots.add(whenValue, to: .when)

        // ── WHAT (always populated by event.title; rule-derived
        //         events also carry the marker phrase in summary.) ──
        let whatValue = NarrativeSlotValue(
            text: event.title,
            confidence: event.confidence.value,
            provenance: .ruleBased,
            sourceObjectIDs: src
        )
        slots.add(whatValue, to: .what)
        if let summary = event.summary,
           !summary.isEmpty,
           summary.lowercased() != event.title.lowercased() {
            slots.add(
                NarrativeSlotValue(
                    text: summary,
                    confidence: event.confidence.value,
                    provenance: .ruleBased,
                    sourceObjectIDs: src
                ),
                to: .what
            )
        }

        // ── HOW (medium / mechanism — kind-driven). ──────────────
        if let how = Self.howForKind(event.kind) {
            slots.add(
                NarrativeSlotValue(
                    text: how,
                    confidence: 0.9,
                    provenance: .ruleBased,
                    sourceObjectIDs: src
                ),
                to: .how
            )
        }

        // ── Email-specific slot fills ────────────────────────────
        if object.sourceType.category == .email {
            // WHO sender
            if let participants = emailParticipants {
                let senderText: String = {
                    if let name = participants.senderName, !name.isEmpty {
                        if let addr = participants.senderAddress, !addr.isEmpty {
                            return "\(name) <\(addr)>"
                        }
                        return name
                    }
                    return participants.senderAddress ?? "(unknown sender)"
                }()
                slots.add(
                    NarrativeSlotValue(
                        text: senderText,
                        confidence: 0.95,
                        provenance: .structuredHeader,
                        sourceObjectIDs: src,
                        entityID: participants.senderID
                    ),
                    to: .who
                )
                // WHO recipients
                let recipientLabels = participants.recipientLabels
                for (idx, recID) in participants.recipientIDs.enumerated() {
                    let label = idx < recipientLabels.count ? recipientLabels[idx] : nil
                    let recValue = label ?? "(recipient)"
                    slots.add(
                        NarrativeSlotValue(
                            text: recValue,
                            confidence: 0.9,
                            provenance: .structuredHeader,
                            sourceObjectIDs: src,
                            entityID: recID
                        ),
                        to: .who
                    )
                }
            }
            // WHERE: the channel ("email") for the composer's
            // "exchanged over email" phrasing.
            slots.add(
                NarrativeSlotValue(
                    text: "email",
                    confidence: 1.0,
                    provenance: .structuredHeader,
                    sourceObjectIDs: src
                ),
                to: .where
            )
            // Subject already drives event.title; the header value
            // is the structured-header source so re-record with
            // higher provenance trust.
            if let subj = Self.stringValue(object.metadata["subject"]),
               !subj.isEmpty,
               subj.lowercased() == event.title.lowercased() {
                slots.what.removeAll { $0.text.lowercased() == subj.lowercased() }
                slots.add(
                    NarrativeSlotValue(
                        text: subj,
                        confidence: 0.95,
                        provenance: .structuredHeader,
                        sourceObjectIDs: src
                    ),
                    to: .what
                )
            }
        } else {
            // Non-email WHO: the entities that participate in this
            // event. We pull person + organization mentions and
            // attach the canonical entity id so the composer can
            // link to the dossier.
            let canonicalIDs = Set(event.entityIDs.compactMap { canonicalMapping[$0] ?? $0 })
            let candidates = entities.filter { entity in
                guard canonicalIDs.contains(canonicalMapping[entity.id] ?? entity.id) else { return false }
                return entity.kind == .person
                    || entity.kind == .organization
                    || entity.kind == .vendor
                    || entity.kind == .client
            }
            // Cap to avoid flooding the WHO slot with every entity.
            // The composer doesn't need every dim co-mention; 6 is
            // enough for "Khurana, Shabana, IIPRD, and 3 others".
            for entity in candidates.prefix(6) {
                slots.add(
                    NarrativeSlotValue(
                        text: entity.value,
                        confidence: min(0.85, entity.confidence.value),
                        provenance: .ruleBased,
                        sourceObjectIDs: src,
                        entityID: canonicalMapping[entity.id] ?? entity.id
                    ),
                    to: .who
                )
            }
        }

        // ── WHERE for non-email: KO source type as channel. ──────
        if object.sourceType.category != .email {
            let channel: String? = {
                switch object.sourceType.category {
                case .document:    return "document"
                case .spreadsheet: return "spreadsheet"
                case .image:       return "image"
                case .audio:       return "recording"
                case .video:       return "video"
                case .email:       return nil
                case .calendar:    return "calendar"
                case .archive:     return "archive"
                case .other:       return nil
                }
            }()
            if let channel {
                slots.add(
                    NarrativeSlotValue(
                        text: channel,
                        confidence: 1.0,
                        provenance: .structuredHeader,
                        sourceObjectIDs: src
                    ),
                    to: .where
                )
            }
        }

        return slots
    }

    // MARK: - Per-kind HOW phrasing

    private static func howForKind(_ kind: Event.Kind) -> String? {
        switch kind {
        case .emailReceived:       return "email"
        case .meetingHeld:         return "meeting"
        case .contractSigned:      return "signed agreement"
        case .contractModified:    return "amendment"
        case .invoiceIssued:       return "invoice"
        case .invoicePaid:         return "payment"
        case .taskAssigned:        return "assignment"
        case .deliveryDelayed:     return "delivery (delayed)"
        case .deliveryCompleted:   return "delivery"
        @unknown default:          return nil
        }
    }

    // MARK: - WHEN formatting

    private static let whenFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f
    }()

    private static func formatWhen(_ date: Date) -> String {
        whenFormatter.string(from: date)
    }

    // MARK: - metadata helpers

    private static func stringValue(_ value: AnyCodable?) -> String? {
        guard let value else { return nil }
        if case .string(let s) = value.value { return s }
        return nil
    }
}
