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
            // HISTORY Phase A.5 — date came from the structured email
            // header (dateConfidence == 0.95 in EventExtractor's
            // header path) → T1. Otherwise the date was inferred
            // from content / mtime and the event drops to T2.
            let headerDerived = dateConfidence >= 0.9
            events.append(.init(
                kind: .emailReceived,
                date: primaryDate,
                title: object.metadata["subject"].flatMap(stringValue) ?? "Email",
                summary: nil,
                entityIDs: entityIDs,
                sourceObjectID: object.id,
                confidence: .high,
                dateConfidence: dateConfidence,
                qualityTier: headerDerived ? .t1 : .t2
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
                    dateConfidence: dateConfidence,
                    qualityTier: .t2 // Body-text rule match — Phase A.5
                ))
                break
            }
        }

        // Forensic email-archive PDFs (GDPR exports, mailin investigation
        // reports, takeout summaries) carry explicit dated email entries
        // but never hit the rule markers above. Per the "keep all data"
        // directive, we infer one emailReceived event per recognized
        // date + email-address co-occurrence so the Timeline isn't blind
        // to them. Confidence is 0.85 (below the 0.95 for real
        // header-derived events) so the brain can demote them when real
        // events are available.
        //
        // Guard: only emit if the raw VALUE of the date entity contains
        // an explicit YYYY — time-only fragments would normalize to
        // today and pollute the timeline with fake "today" events.
        if object.sourceType.category != .email {
            let dateEntities = entities.filter { $0.kind == .date }
            let emailEntities = entities.filter { $0.kind == .emailAddress }
            if dateEntities.count >= 3 && emailEntities.count >= 2 {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime]
                let yearRegex = try? NSRegularExpression(pattern: #"\b(19|20)\d{2}\b"#)
                var emitted = 0
                let fileName = object.sourceFile.lastPathComponent
                for dateEntity in dateEntities {
                    let rawValue = dateEntity.value
                    guard let yr = yearRegex,
                          yr.firstMatch(
                            in: rawValue,
                            range: NSRange(location: 0, length: (rawValue as NSString).length)
                          ) != nil
                    else { continue }
                    guard emitted < 50,
                          let iso = dateEntity.normalizedValue,
                          let parsed = formatter.date(from: iso.uppercased())
                            ?? ISO8601DateFormatter().date(from: iso.uppercased())
                    else { continue }
                    // Use the source filename as the title so the brain can
                    // tell these apart from real header-derived events
                    // (which use the actual email subject).
                    events.append(.init(
                        kind: .emailReceived,
                        date: parsed,
                        title: "Archived entry — \(fileName)",
                        summary: rawValue,
                        entityIDs: entityIDs,
                        sourceObjectID: object.id,
                        confidence: .medium,
                        dateConfidence: 0.85,
                        // Body-inferred event (not from the structured
                        // header). Real proper-noun signal but not as
                        // trustworthy as T1. Phase A.5.
                        qualityTier: .t2
                    ))
                    emitted += 1
                }
            }
        }

        // G2-COMMITMENTS-REFRESH — chatmind-style commitment detection.
        // Adds taskAssigned events for explicit intentions ("I will…",
        // "we plan to…", "action item:…") and lifts the date OUT of the
        // commitment phrase when "by <date>" is present, rather than
        // pinning everything to the KO's primaryDate.
        //
        // CAP REVISED from 5 → 2 per KO and ONLY when no domain event
        // (delivery / contract / invoice / meeting) is already present:
        // the Fast Eval after the original 5-cap showed M1 multihop
        // keyword-hit collapsed 0.50 → 0.00 because commitment phrases
        // ("Maria to share the invoice by tomorrow", "I plan to …")
        // flooded ProjectExpert.claims and displaced the "Supplier ABC
        // reported a delay" narrative from the rendered answerText.
        // A doc that already produces strong typed events shouldn't get
        // its answer hijacked by chatty mid-thread commitments.
        let domainEventPresent = events.contains { ev in
            ev.kind != .taskAssigned && ev.kind != .emailReceived
        }
        let commitmentCap = domainEventPresent ? 1 : 2
        let nsContent = object.content as NSString
        let fullRange = NSRange(location: 0, length: nsContent.length)
        var commitmentEvents = 0
        for (rx, label) in Self.commitmentPatterns {
            guard let rx else { continue }
            for m in rx.matches(in: object.content, range: fullRange) {
                if commitmentEvents >= commitmentCap { break }
                if m.numberOfRanges < 2 { continue }
                let phrase = nsContent.substring(with: m.range(at: 1))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard phrase.count >= 5 else { continue }

                let (phraseDate, dueConfidence) = Self.extractDueDate(
                    from: phrase,
                    base: primaryDate
                )
                events.append(.init(
                    kind: .taskAssigned,
                    date: phraseDate ?? primaryDate,
                    title: "Commitment: \(label)",
                    summary: phrase,
                    entityIDs: entityIDs,
                    sourceObjectID: object.id,
                    confidence: .medium,
                    dateConfidence: dueConfidence ?? (dateConfidence * 0.8),
                    qualityTier: .t2 // Commitment phrase detection — Phase A.5
                ))
                commitmentEvents += 1
            }
            if commitmentEvents >= commitmentCap { break }
        }

        return events
    }

    // MARK: - G2-COMMITMENTS-REFRESH helpers

    /// Intention / action patterns ported from chatmind-pipeline's
    /// `commitment_extract.py`. Capturing group 1 is the commitment
    /// content; the label classifies the speaker-stance.
    private static let commitmentPatterns: [(NSRegularExpression?, String)] = [
        (try? NSRegularExpression(
            pattern: #"\b(?:i\s+will|we\s+will|i'll|we'll)\s+([^.!?\n]{5,160})"#,
            options: [.caseInsensitive]
        ), "stated intent"),
        (try? NSRegularExpression(
            pattern: #"\b(?:i'm|i\s+am|we're|we\s+are)\s+(?:going|planning)\s+to\s+([^.!?\n]{5,160})"#,
            options: [.caseInsensitive]
        ), "near-term plan"),
        (try? NSRegularExpression(
            pattern: #"\b(?:i\s+plan\s+to|we\s+plan\s+to|i\s+intend\s+to|we\s+need\s+to|i\s+propose|we\s+propose)\s+([^.!?\n]{5,160})"#,
            options: [.caseInsensitive]
        ), "plan"),
        (try? NSRegularExpression(
            pattern: #"(?:^|\n)\s*(?:action\s*item|owner|todo|action|next\s*step)s?\s*[:\-]\s*([^.!?\n]{5,160})"#,
            options: [.caseInsensitive]
        ), "action item")
    ]

    /// Pull a "by <date>" or "by <weekday> at <time>" sub-phrase out of
    /// a commitment string. Returns (extractedDate, confidence) — the
    /// confidence is 0.75 for explicit due-date matches, falling back to
    /// nil when no due-by phrase fires.
    ///
    /// Group 1 deliberately drops a leading weekday ("Friday") via a
    /// non-capturing prefix so the slot we feed to DateGrammar is the
    /// resolvable date portion ("March 6, 2026"). DateGrammar doesn't
    /// know how to anchor a bare weekday to a calendar date, so passing
    /// it through would return nil and cost us the 0.75 confidence on a
    /// fully-specified due-by phrase.
    private static let dueByRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"\bby\s+(?:(?:Mon|Tues|Wednes|Thurs|Fri|Satur|Sun)day\s+)?([A-Za-z]+\s+\d{1,2}(?:[,\s]+\d{4})?|\d{4}-\d{2}-\d{2}|next\s+\w+|tomorrow|today|end\s+of\s+(?:week|month|quarter))\b"#,
        options: [.caseInsensitive]
    )

    private static func extractDueDate(
        from phrase: String,
        base: Date
    ) -> (Date?, Double?) {
        guard let rx = dueByRegex else { return (nil, nil) }
        let ns = phrase as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let m = rx.firstMatch(in: phrase, range: range),
              m.numberOfRanges >= 2
        else { return (nil, nil) }
        let dueText = ns.substring(with: m.range(at: 1))
        if let match = DateGrammar.parse(dueText, baseDate: base) {
            return (match.timeframe.start, 0.75)
        }
        return (nil, nil)
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
