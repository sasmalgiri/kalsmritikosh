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

/// Carries the canonical entity ids the IngestCoordinator has
/// already resolved for the email's sender + recipients. The slot
/// extractor reads display labels straight from
/// `object.metadata["from"|"to"|"cc"]` and zips them positionally
/// with the IDs to build WHO entries with both a readable label and
/// a click-through entity id.
public nonisolated struct NarrativeSlotEmailParticipants: Sendable {
    public let senderID: Entity.ID
    public let recipientIDs: [Entity.ID]

    public init(senderID: Entity.ID, recipientIDs: [Entity.ID]) {
        self.senderID = senderID
        self.recipientIDs = recipientIDs
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
        //
        // Real-data discovery (2026-06-28 production audit): emails
        // were stamping WHEN as `ruleBased` even when the date came
        // from a Date: header, because event.dateConfidence wasn't
        // always >= 0.9. For email-category KOs with ANY parseable
        // header date (object.metadata["date"] present), promote to
        // structuredHeader regardless of the event's own
        // dateConfidence — the header IS the structured source.
        let isEmailWithHeaderDate = object.sourceType.category == .email
            && Self.stringValue(object.metadata["date"])?.isEmpty == false
        let provenance: SlotProvenance = (event.dateConfidence >= 0.9 || isEmailWithHeaderDate)
            ? .structuredHeader : .ruleBased
        let whenConfidence = isEmailWithHeaderDate ? max(0.9, event.dateConfidence) : event.dateConfidence
        let whenValue = NarrativeSlotValue(
            text: Self.formatWhen(event.date),
            confidence: whenConfidence,
            provenance: provenance,
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
            // WHO sender: prefer the display string straight from the
            // From: header (which preserves "Name <addr@host>" form);
            // attach the canonical entity id when known.
            let fromHeader = Self.stringValue(object.metadata["from"]) ?? ""
            let toHeader = Self.stringValue(object.metadata["to"]) ?? ""
            let ccHeader = Self.stringValue(object.metadata["cc"]) ?? ""

            if !fromHeader.isEmpty {
                slots.add(
                    NarrativeSlotValue(
                        text: fromHeader.trimmingCharacters(in: .whitespacesAndNewlines),
                        confidence: 0.95,
                        provenance: .structuredHeader,
                        sourceObjectIDs: src,
                        entityID: emailParticipants?.senderID
                    ),
                    to: .who
                )
            }
            // Recipients: split the To/Cc strings on comma/semicolon
            // and emit one WHO per address. If we have canonical IDs
            // for them, zip positionally — strict positional match
            // is good enough because the IngestCoordinator builds
            // recipientIDs from the same split.
            let recipientStrings: [String] = (Self.splitRecipients(toHeader) + Self.splitRecipients(ccHeader))
            let recipientIDs = emailParticipants?.recipientIDs ?? []
            for (idx, raw) in recipientStrings.enumerated() {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let id: Entity.ID? = idx < recipientIDs.count ? recipientIDs[idx] : nil
                slots.add(
                    NarrativeSlotValue(
                        text: trimmed,
                        confidence: 0.9,
                        provenance: .structuredHeader,
                        sourceObjectIDs: src,
                        entityID: id
                    ),
                    to: .who
                )
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
            // Real-data discovery (2026-06-28 production audit): 256
            // of 828 events came from forensic GDPR-export PDFs.
            // These have lots of `.emailAddress` entities but few
            // `.person` ones — the original WHO filter excluded
            // emailAddress, so WHO stayed empty and the composer
            // had nothing to anchor on. Including .emailAddress
            // turns "(no who)" into "sasmalgiri@gmail.com" — a real
            // name the composer can write a sentence around.
            let candidates = entities.filter { entity in
                guard canonicalIDs.contains(canonicalMapping[entity.id] ?? entity.id) else { return false }
                return entity.kind == .person
                    || entity.kind == .organization
                    || entity.kind == .vendor
                    || entity.kind == .client
                    || entity.kind == .emailAddress
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

            // HISTORY follow-on — enrich non-email slots from
            // entity kinds the WHO loop above didn't claim:
            //   - .project / .deliverable → WHAT
            //   - .address / .city / .country / .location → WHERE
            //   - .money / .invoiceNumber / .paymentID → WHAT (the
            //     event is "about" this money / invoice)
            //   - .deadline / .milestone → WHY (the event was
            //     prompted by this deadline / milestone)
            for entity in entities {
                guard canonicalIDs.contains(canonicalMapping[entity.id] ?? entity.id) else { continue }
                let canon = canonicalMapping[entity.id] ?? entity.id
                let conf = min(0.8, entity.confidence.value)
                switch entity.kind {
                case .project, .deliverable:
                    slots.add(
                        NarrativeSlotValue(
                            text: entity.value,
                            confidence: conf,
                            provenance: .ruleBased,
                            sourceObjectIDs: src,
                            entityID: canon
                        ),
                        to: .what
                    )
                case .address, .city, .country, .location:
                    slots.add(
                        NarrativeSlotValue(
                            text: entity.value,
                            confidence: conf,
                            provenance: .ruleBased,
                            sourceObjectIDs: src,
                            entityID: canon
                        ),
                        to: .where
                    )
                case .money, .invoiceNumber, .paymentID:
                    slots.add(
                        NarrativeSlotValue(
                            text: entity.value,
                            confidence: conf,
                            provenance: .ruleBased,
                            sourceObjectIDs: src,
                            entityID: canon
                        ),
                        to: .what
                    )
                case .deadline, .milestone:
                    slots.add(
                        NarrativeSlotValue(
                            text: entity.value,
                            confidence: conf,
                            provenance: .ruleBased,
                            sourceObjectIDs: src,
                            entityID: canon
                        ),
                        to: .why
                    )
                default:
                    continue
                }
            }

            // WHY heuristic — when the event has an explicit
            // commitment / cause phrase in `summary` (the rule
            // extractor in EventExtractor stamps this for
            // taskAssigned / contractSigned / amendment / delivery
            // events), surface it as a WHY value.
            if let phrase = event.summary,
               !phrase.isEmpty,
               phrase.lowercased() != event.title.lowercased(),
               slots.why.isEmpty {
                slots.add(
                    NarrativeSlotValue(
                        text: phrase,
                        confidence: event.confidence.value,
                        provenance: .ruleBased,
                        sourceObjectIDs: src
                    ),
                    to: .why
                )
            }
        }

        // ── WHERE for non-email: KO source type as channel. ──────
        if object.sourceType.category != .email {
            let channel: String? = {
                switch object.sourceType.category {
                case .document:     return "document"
                case .spreadsheet:  return "spreadsheet"
                case .presentation: return "presentation"
                case .image:        return "image"
                case .audio:        return "recording"
                case .video:        return "video"
                case .email:        return nil
                case .archive:      return "archive"
                case .unknown:      return nil
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
        case .emailSent:           return "email"
        case .emailReceived:       return "email"
        case .meetingHeld:         return "meeting"
        case .contractSigned:      return "signed agreement"
        case .contractModified:    return "amendment"
        case .invoiceIssued:       return "invoice"
        case .invoicePaid:         return "payment"
        case .taskAssigned:        return "assignment"
        case .deliveryDelayed:     return "delivery (delayed)"
        case .deliveryCompleted:   return "delivery"
        case .other:               return nil
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

    /// Split an RFC 5322-style address list on commas / semicolons,
    /// keeping the display-name + address pairs together. Naive
    /// split is fine here — the strings round-trip into WHO text
    /// only, and the canonical entity id is attached separately.
    private static func splitRecipients(_ header: String) -> [String] {
        guard !header.isEmpty else { return [] }
        let parts = header
            .replacingOccurrences(of: ";", with: ",")
            .split(separator: ",", omittingEmptySubsequences: true)
        return parts.map { String($0) }
    }
}
