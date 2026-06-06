//
//  EventExtractor.swift
//  Kalsmritikosh
//
//  Rule-based event detection: tries to attach the strongest detected
//  date to each rule hit. Returns Event rows with the 10 Phase-6 kinds.
//  M3 layers an LLM extractor on top for harder cases.
//

import Foundation

public struct RuleEventExtractor: EventExtractor {
    public init() {}

    public func extractEvents(
        from object: KnowledgeObject,
        chunks: [Chunk],
        entities: [Entity]
    ) async throws -> [Event] {
        let content = object.content.lowercased()

        // T9 — temporal anchor with per-tier confidence:
        //   0.95 — email Date: header (high signal, parsed by EmailLoader)
        //   0.70 — content-extracted date entity (medium)
        //   0.30 — file mtime / KO createdAt fallback (low; mtime lies)
        var primaryDate: Date
        var dateConfidence: Double

        let headerDate: Date? = {
            guard object.sourceType.category == .email,
                  let headerString = object.metadata["date"].flatMap(stringValue)
            else { return nil }
            return parseRFC2822Date(headerString) ?? ISO8601DateFormatter().date(from: headerString)
        }()

        let contentDates = entities.compactMap { e -> Date? in
            guard e.kind == .date,
                  let iso = e.normalizedValue,
                  let date = ISO8601DateFormatter().date(from: iso)
            else { return nil }
            return date
        }
        let fileModified: Date? = {
            let attrs = try? FileManager.default.attributesOfItem(atPath: object.sourceFile.path)
            return attrs?[.modificationDate] as? Date
        }()

        if let header = headerDate {
            primaryDate = header
            dateConfidence = 0.95
        } else if let contentDate = contentDates.min() {
            primaryDate = contentDate
            dateConfidence = 0.70
        } else if let mtime = fileModified {
            primaryDate = mtime
            dateConfidence = 0.30
        } else {
            primaryDate = object.createdAt
            dateConfidence = 0.30
        }

        let entityIDs = entities.map(\.id)
        var events: [Event] = []

        if object.sourceType.category == .email {
            events.append(.init(
                kind: .emailReceived,
                date: primaryDate,
                title: object.metadata["subject"].flatMap(stringValue) ?? "Email",
                summary: nil,
                entityIDs: entityIDs,
                sourceObjectID: object.id,
                confidence: .high,
                dateConfidence: dateConfidence
            ))
        }

        let rules: [(Event.Kind, [String])] = [
            (.contractSigned, ["signed this agreement", "executed on", "signature page"]),
            (.contractModified, ["amendment to", "amended on", "addendum"]),
            (.invoiceIssued, ["invoice issued", "invoice dated", "invoice number"]),
            (.invoicePaid, ["payment received", "paid in full", "payment confirmed"]),
            (.meetingHeld, ["minutes of meeting", "we met on", "kickoff meeting"]),
            (.taskAssigned, ["assigned to", "action item:", "owner:"]),
            (.deliveryDelayed, ["delivery delayed", "shipment delay", "behind schedule"]),
            (.deliveryCompleted, ["delivery completed", "delivered on", "shipment received"])
        ]

        for (kind, markers) in rules {
            for marker in markers where content.contains(marker) {
                events.append(.init(
                    kind: kind,
                    date: primaryDate,
                    title: titleForKind(kind),
                    summary: marker,
                    entityIDs: entityIDs,
                    sourceObjectID: object.id,
                    confidence: .medium,
                    dateConfidence: dateConfidence
                ))
                break
            }
        }

        return events
    }

    /// RFC 2822 / 5322 date parser for "Date:" headers.
    private func parseRFC2822Date(_ s: String) -> Date? {
        let formats = [
            "EEE, d MMM yyyy HH:mm:ss Z",
            "d MMM yyyy HH:mm:ss Z",
            "EEE, d MMM yyyy HH:mm:ss zzz"
        ]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for f in formats {
            formatter.dateFormat = f
            if let date = formatter.date(from: s) { return date }
        }
        return nil
    }

    private func stringValue(_ codable: AnyCodable) -> String? {
        if case .string(let s) = codable.value { return s }
        return nil
    }

    private func titleForKind(_ kind: Event.Kind) -> String {
        switch kind {
        case .contractSigned: return "Contract signed"
        case .contractModified: return "Contract modified"
        case .invoiceIssued: return "Invoice issued"
        case .invoicePaid: return "Invoice paid"
        case .meetingHeld: return "Meeting held"
        case .taskAssigned: return "Task assigned"
        case .deliveryDelayed: return "Delivery delayed"
        case .deliveryCompleted: return "Delivery completed"
        case .emailReceived: return "Email received"
        case .emailSent: return "Email sent"
        case .other: return "Event"
        }
    }
}
