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
        entities: [Entity],
        blocks: [EvidenceBlock]
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

        // PERF.3 — do NOT attach every document entity to every event. Attaching
        // the whole set inflated the relationship graph (O(n²) co-occurrence) and
        // produced false links + noisy dossiers. Scope events to the meaningful
        // ACTORS — people / organizations / parties / correspondents — capped and
        // highest-confidence first. Dates, amounts, misc tokens and boilerplate
        // no longer become event participants. (Location is carried separately in
        // attributes["location"].)
        let actorKinds: Set<Entity.Kind> = [.person, .organization, .vendor, .client, .emailAddress, .project]
        let entityIDs = Array(
            entities
                .filter { actorKinds.contains($0.kind) }
                .sorted { $0.confidence.value > $1.confidence.value }
                .prefix(12)
                .map(\.id)
        )
        // A5.6 (location) — the document's primary place entity, in priority
        // order. Attached to location-bearing events (meetings / deliveries /
        // signings) so two sources placing the "same" event differently can be
        // detected as a location contradiction. NER already produces these — no
        // new extraction.
        let primaryLocation: Entity? = {
            let priority: [Entity.Kind] = [.address, .city, .location, .country]
            for kind in priority {
                if let hit = entities.first(where: { $0.kind == kind }) { return hit }
            }
            return nil
        }()
        var events: [Event] = []

        if object.sourceType.category == .email {
            // HISTORY Phase A.5 — date came from the structured email
            // header (dateConfidence == 0.95 in EventExtractor's
            // header path) → T1. Otherwise the date was inferred
            // from content / mtime and the event drops to T2.
            //
            // Phase G.1 — precision: header-derived dates are .instant
            // (the RFC 2822 Date header carries minute resolution at
            // minimum). Content-extracted dates are .day. Mtime
            // fallback is .day. The composer reads this to render
            // "On Mar 14, 2025 at 09:12 UTC" vs "On Mar 14, 2025"
            // instead of falsely claiming a time when it doesn't know.
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
                qualityTier: headerDerived ? .t1 : .t2,
                datePrecision: headerDerived ? .instant : .day
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
                // A5.3 — event-specific attributes. Financial events carry the
                // monetary amount + currency parsed from the source text so the
                // ledger stores a comparable quantity (this is the data the
                // A5.6 amount-contradiction detector needs; without it there is
                // nothing to compare). The verbatim match is kept as amountRaw
                // for provenance.
                var attributes: [String: AnyCodable] = [:]
                if kind == .invoiceIssued || kind == .invoicePaid,
                   let money = Self.extractAmount(from: object.content) {
                    attributes["amount"] = AnyCodable(.double(money.value))
                    attributes["currency"] = AnyCodable(.string(money.currency))
                    attributes["amountRaw"] = AnyCodable(.string(money.raw))
                }
                // A5.6 (location) — attach the document's place to events that
                // plausibly happen somewhere; the value fuels the location
                // contradiction detector.
                let locationBearing: Set<Event.Kind> = [.meetingHeld, .deliveryCompleted, .deliveryDelayed, .contractSigned]
                if locationBearing.contains(kind), let loc = primaryLocation {
                    attributes["location"] = AnyCodable(.string(loc.normalizedValue ?? loc.value))
                }
                // A5.6 (signature) — capture who signed, for the signature
                // contradiction detector (same contract, different signatory).
                if kind == .contractSigned, let who = Self.extractSignatory(from: object.content) {
                    attributes["signatory"] = AnyCodable(.string(who))
                }
                events.append(.init(
                    kind: kind,
                    date: primaryDate,
                    title: titleForKind(kind),
                    summary: marker,
                    entityIDs: entityIDs,
                    sourceObjectID: object.id,
                    confidence: .medium,
                    dateConfidence: dateConfidence,
                    attributes: attributes,
                    qualityTier: .t2, // Body-text rule match — Phase A.5
                    datePrecision: .day // Body-text dates: day precision; the marker phrase rarely carries time
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
                        qualityTier: .t2,
                        // Phase G.1 — forensic-PDF dates are typically
                        // day-precision (the export shows "21 May 2026
                        // at 10:45 AM" but the source isn't a true
                        // header — the time can be drift / TZ-confused,
                        // so we mark as .day to avoid claiming a time
                        // we can't fully trust).
                        datePrecision: .day
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
                    qualityTier: .t2, // Commitment phrase detection — Phase A.5
                    // Phase G.1 — "by tomorrow"/"end of week" phrases
                    // are inherently day-precision at best; some are
                    // month or unknown. Stay conservative at .day.
                    datePrecision: phraseDate != nil ? .day : .month
                ))
                commitmentEvents += 1
            }
            if commitmentEvents >= commitmentCap { break }
        }

        // A5.3 — link each event to the specific structural block(s) that
        // evidence it, so events carry event-specific source provenance rather
        // than the whole document. We match a block when its normalized text
        // contains the event's marker/summary phrase (the exact substring the
        // rule fired on). No blocks wired → events are returned unchanged.
        return Self.attachSourceBlocks(to: events, blocks: blocks)
    }

    /// Attach `sourceBlockIDs` (up to 5) to each event by matching its summary
    /// marker against block normalized text. Pure; returns events unchanged when
    /// no blocks are supplied or no match is found. `static` so it's testable.
    static func attachSourceBlocks(to events: [Event], blocks: [EvidenceBlock]) -> [Event] {
        guard !blocks.isEmpty else { return events }
        let normalized = blocks.map { (id: $0.id, text: $0.normalizedText.lowercased()) }
        return events.map { event in
            guard let marker = event.summary?.lowercased(),
                  marker.count >= 4 else { return event }
            let matches = normalized.filter { $0.text.contains(marker) }.prefix(5).map(\.id)
            guard !matches.isEmpty else { return event }
            return event.addingAttributes([
                "sourceBlockIDs": AnyCodable(.array(matches.map { .string($0.uuidString) }))
            ])
        }
    }

    // MARK: - A5.3 amount extraction

    private static let symbolToCode: [String: String] = [
        "$": "USD", "€": "EUR", "£": "GBP", "¥": "JPY", "₹": "INR"
    ]
    private static let currencyCodes = ["USD", "EUR", "GBP", "JPY", "INR", "CAD", "AUD", "CHF", "CNY"]

    // Symbol-prefixed ($1,200.50), code-prefixed (USD 1,200), code-suffixed
    // (1,200 USD). Amount group allows thousands separators + optional cents.
    private static let amountSymbolRegex = try? NSRegularExpression(
        pattern: #"([$€£¥₹])\s?([0-9]{1,3}(?:,[0-9]{3})*(?:\.[0-9]{1,2})?|[0-9]+(?:\.[0-9]{1,2})?)"#
    )
    private static let amountCodePrefixRegex = try? NSRegularExpression(
        pattern: #"\b(USD|EUR|GBP|JPY|INR|CAD|AUD|CHF|CNY)\s?([0-9]{1,3}(?:,[0-9]{3})*(?:\.[0-9]{1,2})?|[0-9]+(?:\.[0-9]{1,2})?)"#,
        options: [.caseInsensitive]
    )
    private static let amountCodeSuffixRegex = try? NSRegularExpression(
        pattern: #"\b([0-9]{1,3}(?:,[0-9]{3})*(?:\.[0-9]{1,2})?|[0-9]+(?:\.[0-9]{1,2})?)\s?(USD|EUR|GBP|JPY|INR|CAD|AUD|CHF|CNY)\b"#,
        options: [.caseInsensitive]
    )

    /// Parse the first monetary amount in the text. Returns the numeric value
    /// (thousands separators removed), the ISO currency code, and the verbatim
    /// matched string. Deterministic; nil when no amount is present.
    static func extractAmount(from text: String) -> (value: Double, currency: String, raw: String)? {
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)

        func numeric(_ s: String) -> Double? {
            Double(s.replacingOccurrences(of: ",", with: ""))
        }

        // Take whichever form matches earliest in the text so the "first
        // amount" is stable regardless of notation.
        var best: (loc: Int, value: Double, currency: String, raw: String)?
        func consider(_ loc: Int, _ value: Double, _ currency: String, _ raw: String) {
            if best == nil || loc < best!.loc {
                best = (loc, value, currency, raw)
            }
        }

        if let rx = amountSymbolRegex, let m = rx.firstMatch(in: text, range: range),
           let value = numeric(ns.substring(with: m.range(at: 2))) {
            let sym = ns.substring(with: m.range(at: 1))
            consider(m.range.location, value, symbolToCode[sym] ?? "USD", ns.substring(with: m.range))
        }
        if let rx = amountCodePrefixRegex, let m = rx.firstMatch(in: text, range: range),
           let value = numeric(ns.substring(with: m.range(at: 2))) {
            let code = ns.substring(with: m.range(at: 1)).uppercased()
            consider(m.range.location, value, code, ns.substring(with: m.range))
        }
        if let rx = amountCodeSuffixRegex, let m = rx.firstMatch(in: text, range: range),
           let value = numeric(ns.substring(with: m.range(at: 1))) {
            let code = ns.substring(with: m.range(at: 2)).uppercased()
            consider(m.range.location, value, code, ns.substring(with: m.range))
        }
        guard let best else { return nil }
        return (best.value, best.currency, best.raw)
    }

    // MARK: - A5.6 signatory extraction

    // "signed by <Name>", "executed by <Name>", "/s/ <Name>". Captures 1-4
    // capitalized words (a personal name) after the marker.
    // The TRIGGER is case-insensitive (inline (?i:…)), but the NAME capture stays
    // case-sensitive so it stops at a lowercase word — "signed by Alice Martin on Tuesday"
    // captures "Alice Martin", not "Alice Martin on Tuesday" (a global .caseInsensitive made
    // [A-Z] match "on"/"tuesday" and over-captured).
    private static let signatoryRegex = try? NSRegularExpression(
        pattern: #"(?:(?i:signed\s+by|executed\s+by)|/s/)\s+([A-Z][A-Za-z.'-]+(?:\s+[A-Z][A-Za-z.'-]+){0,3})"#,
        options: []
    )

    /// The first named signatory in the text (normalized, lowercased), or nil.
    static func extractSignatory(from text: String) -> String? {
        guard let rx = signatoryRegex else { return nil }
        let ns = text as NSString
        guard let m = rx.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1 else { return nil }
        let name = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.count >= 2 ? name.lowercased() : nil
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
