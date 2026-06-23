//
//  SlotExtractor.swift
//  Kalsmritikosh
//
//  G3.13 — derive slot values for a classified fact from data we
//  already have. Pure, deterministic, no LLM. Returns an
//  `[String: AnyCodable.AnySendable]` map that the caller hands to
//  `OntologyValidator.validate` before persisting via
//  `setSlotValues(_:forEntityID:)` / `setSlotValues(_:forEventID:)`.
//
//  Strategy:
//  - Required-cardinality `.one` slots are always derivable from a
//    single canonical surface (entity.value, event.title/summary)
//    so the validator passes for the common case.
//  - Optional scalars (subject, dates, status) come from event
//    metadata or attributes.
//  - Reference slots (sender_person, party_a_org, for_project, …) are
//    left empty in v1 — they require either bond-graph joins or
//    G3.14 LLM extraction. Marking them `.zeroOrOne / .zeroOrMore`
//    in the ontology means the validator accepts the gap.
//
//  Idempotency: re-running over the same row produces the same map.
//

import Foundation

public struct SlotExtractor: Sendable {
    public nonisolated init() {}

    // MARK: - Entity → slot map

    public nonisolated func extract(
        entity: Entity,
        factType: FactType
    ) -> [String: AnyCodable.AnySendable] {
        var slots: [String: AnyCodable.AnySendable] = [:]
        switch factType {
        case .person:
            slots["name"] = .string(entity.value)
            if let email = attributeString(entity, "email") {
                slots["email"] = .string(email)
            }
            if let role = attributeString(entity, "role") {
                slots["role"] = .string(role)
            }
        case .organization:
            slots["name"] = .string(entity.value)
            switch entity.kind {
            case .vendor:
                slots["kind"] = .string("supplier")
            case .client:
                slots["kind"] = .string("client")
            default:
                break
            }
            if let domain = attributeString(entity, "domain") {
                slots["domain"] = .string(domain)
            }
        case .project:
            slots["name"] = .string(entity.value)
            if let status = attributeString(entity, "status") {
                slots["status"] = .string(status)
            }
        case .delivery:
            // Entity-level Delivery comes from Entity.kind=.deliverable.
            // No required slots — leave optional ones for the event path.
            break
        case .contract, .amendment, .invoice, .email, .meeting, .decision:
            // These FactTypes live on events. Entity-level classification
            // is unexpected; return empty and let the validator decide.
            break
        }
        return slots
    }

    // MARK: - Event → slot map

    public nonisolated func extract(
        event: Event,
        factType: FactType
    ) -> [String: AnyCodable.AnySendable] {
        var slots: [String: AnyCodable.AnySendable] = [:]
        switch factType {
        case .contract:
            slots["title"] = .string(event.title)
            slots["effective_date"] = .string(isoDate(event.date))
            if let end = event.endDate {
                slots["expiry_date"] = .string(isoDate(end))
            }
        case .amendment:
            slots["effective_date"] = .string(isoDate(event.date))
            if let summary = event.summary ?? Optional(event.title) {
                slots["summary"] = .string(summary)
            }
            // amends_contract is required (.one) per the ontology but
            // requires a bond-graph join. Leaving it absent here will
            // make the validator return .reject — which is the desired
            // signal to the OntologyBackfill: skip the write until the
            // bond engine lands a Contract↔Amendment edge (G3.14
            // follow-on or LLM-assisted extractor).
            break
        case .invoice:
            slots["number"] = .string(invoiceNumber(from: event))
            slots["due_date"] = .string(isoDate(event.date))
            switch event.kind {
            case .invoiceIssued:
                slots["status"] = .string("issued")
            case .invoicePaid:
                slots["status"] = .string("paid")
            default:
                break
            }
            if let amount = attributeDouble(event, "amount") {
                slots["amount"] = .double(amount)
            }
        case .delivery:
            slots["actual_date"] = .string(isoDate(event.date))
            switch event.kind {
            case .deliveryDelayed:
                slots["status"] = .string("delayed")
            case .deliveryCompleted:
                slots["status"] = .string("completed")
            default:
                break
            }
        case .email:
            slots["sent_at"] = .string(isoDate(event.date))
            if !event.title.isEmpty {
                slots["subject"] = .string(event.title)
            }
        case .meeting:
            if !event.title.isEmpty {
                slots["topic"] = .string(event.title)
            }
            slots["date"] = .string(isoDate(event.date))
        case .decision:
            // Required (.one) — summary. Fall back to title if absent.
            let summary = event.summary?.isEmpty == false
                ? event.summary!
                : event.title
            slots["summary"] = .string(summary)
            slots["decided_at"] = .string(isoDate(event.date))
        case .person, .organization, .project:
            // Event-level classification of these is unexpected.
            break
        }
        return slots
    }

    // MARK: - Helpers

    private nonisolated func attributeString(_ entity: Entity, _ key: String) -> String? {
        guard let v = entity.attributes[key] else { return nil }
        if case .string(let s) = v.value, !s.isEmpty { return s }
        return nil
    }

    private nonisolated func attributeString(_ event: Event, _ key: String) -> String? {
        guard let v = event.attributes[key] else { return nil }
        if case .string(let s) = v.value, !s.isEmpty { return s }
        return nil
    }

    private nonisolated func attributeDouble(_ event: Event, _ key: String) -> Double? {
        guard let v = event.attributes[key] else { return nil }
        switch v.value {
        case .double(let d): return d
        case .int(let i): return Double(i)
        default: return nil
        }
    }

    /// Invoice number: prefer explicit attribute, then mine event.title
    /// for an INV-like token, else fall back to title verbatim. The
    /// ontology requires `one` so we always return something.
    private nonisolated func invoiceNumber(from event: Event) -> String {
        if let n = attributeString(event, "number") { return n }
        if let n = attributeString(event, "invoice_number") { return n }
        // Mine "INV-401" / "Invoice 401" patterns from the title.
        let lower = event.title.lowercased()
        if let range = event.title.range(of: #"INV[-\s]?\d+"#, options: .regularExpression) {
            return String(event.title[range])
        }
        if lower.contains("invoice") {
            if let range = event.title.range(of: #"\d+"#, options: .regularExpression) {
                return "INV-\(event.title[range])"
            }
        }
        return event.title
    }

    private nonisolated func isoDate(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}
