//
//  EventClaimStatementRenderer.swift
//  Kalsmritikosh
//
//  PA-EXT-001A — deterministic, evidence-aware Event Claim statements. Every Event Claim used to
//  read `statement = event.title` (so a whole class of emails projected as the bare word "Email").
//  This renderer turns an Event + its already-persisted 5W+H `EventNarrativeSlots` into a
//  human-readable sentence, using ONLY evidence-derived values in a fixed priority order. It is
//  pure, synchronous, deterministic, LLM-free and repository-free — it renders what ingestion
//  already extracted; it never guesses, and it never invents an email sender/recipient role.
//

import Foundation

/// The subject participant of an entity-scoped Event Claim: a canonical entity, its readable
/// label, and its kind. Nil at the call site means a participant-less (source-scoped) Event.
public struct EventClaimParticipant: Sendable, Equatable, Hashable {
    public let entityID: Entity.ID
    public let displayLabel: String
    public let kind: Entity.Kind
    public nonisolated init(entityID: Entity.ID, displayLabel: String, kind: Entity.Kind) {
        self.entityID = entityID
        self.displayLabel = displayLabel
        self.kind = kind
    }
}

/// The claim-projection-specific hydration of one Event: the event (WITH attributes), its
/// participants (canonical labels, deterministic order) and its persisted 5W+H narrative slots.
/// A dedicated DTO so Claim production reads exactly what it needs without overloading the
/// timeline / warm-up event APIs.
public struct EventClaimProjectionSource: Sendable {
    public let event: Event
    public let participants: [EventClaimParticipant]
    public let narrativeSlots: EventNarrativeSlots
    public nonisolated init(event: Event, participants: [EventClaimParticipant], narrativeSlots: EventNarrativeSlots) {
        self.event = event
        self.participants = participants
        self.narrativeSlots = narrativeSlots
    }
}

/// The rendered statement plus the subject label to stamp on the Claim and the exact Event block
/// ids the producer should prefer as reopenable evidence.
public struct EventClaimStatement: Sendable, Equatable {
    public let text: String
    public let subjectLabel: String
    public let preferredBlockIDs: [EvidenceBlock.ID]
    public nonisolated init(text: String, subjectLabel: String, preferredBlockIDs: [EvidenceBlock.ID]) {
        self.text = text
        self.subjectLabel = subjectLabel
        self.preferredBlockIDs = preferredBlockIDs
    }
}

public enum EventClaimStatementRenderer {
    /// Deterministic max statement length (characters). A longer statement is trimmed on a word
    /// boundary and suffixed with a single ellipsis.
    static let maxStatementLength = 300
    /// Deterministic max length for an email topic (the quoted subject / body sentence).
    static let maxTopicLength = 160

    public nonisolated static func render(
        event: Event,
        narrativeSlots: EventNarrativeSlots,
        participant: EventClaimParticipant?
    ) -> EventClaimStatement {
        let blockIDs = preferredBlockIDs(from: event)
        // The subject label is the participant's canonical readable label for an entity-scoped
        // claim; for a participant-less Event it is a neutral, evidence-derived event label.
        let subjectLabel = participant?.displayLabel ?? neutralSubjectLabel(event: event, slots: narrativeSlots)
        let text = statementText(event: event, slots: narrativeSlots)
        return EventClaimStatement(text: capped(text, at: maxStatementLength),
                                   subjectLabel: subjectLabel, preferredBlockIDs: blockIDs)
    }

    // MARK: - Statement text per kind

    private nonisolated static func statementText(event: Event, slots: EventNarrativeSlots) -> String {
        switch event.kind {
        case .emailSent, .emailReceived:
            return emailStatement(event: event, slots: slots)
        case .contractSigned:
            if let who = attributeString(event, "signatory") { return "Contract signed by \(who)." }
            return meaningfulTitleOrSummary(event) ?? "Contract signed."
        case .contractModified:
            return meaningfulTitleOrSummary(event) ?? "Contract amendment recorded."
        case .invoiceIssued:
            if let amount = amountPhrase(event) { return "Invoice issued: \(amount)." }
            return meaningfulTitleOrSummary(event) ?? "Invoice issued."
        case .invoicePaid:
            if let amount = amountPhrase(event) { return "Invoice paid: \(amount)." }
            return meaningfulTitleOrSummary(event) ?? "Invoice paid."
        case .meetingHeld:
            if let place = location(event: event, slots: slots) { return "Meeting held at \(place)." }
            return meaningfulTitleOrSummary(event) ?? "Meeting held."
        case .taskAssigned:
            if let commitment = commitmentPhrase(event: event, slots: slots) {
                return "A commitment was recorded to \(commitment)."
            }
            return meaningfulTitleOrSummary(event) ?? "A task was assigned."
        case .deliveryDelayed:
            if let reason = reasonPhrase(event: event, slots: slots) {
                return "Delivery was delayed because of \(reason)."
            }
            return meaningfulTitleOrSummary(event) ?? "Delivery was delayed."
        case .deliveryCompleted:
            return meaningfulTitleOrSummary(event) ?? "Delivery completed."
        case .other:
            return meaningfulTitleOrSummary(event) ?? "An event was recorded in the source."
        }
    }

    // MARK: - Email

    private nonisolated static func emailStatement(event: Event, slots: EventNarrativeSlots) -> String {
        // Participant display names come from the WHO slot values (structured From/To/Cc headers).
        // We intentionally do NOT assign sender/recipient roles: the ledger encodes the role only
        // by array order, which is not a safe signal. So the statement is the neutral
        // "correspondence involving …" form, which never claims who sent the message.
        let participants = emailParticipantLabels(slots)
        let topic = emailTopic(event: event, slots: slots)

        switch (participants.isEmpty, topic) {
        case (false, let t?):
            return "Email correspondence involving \(joinNames(participants)) about \(quoted(t))."
        case (false, nil):
            return "Email correspondence involving \(joinNames(participants))."
        case (true, let t?):
            return "Email correspondence about \(quoted(t))."
        case (true, nil):
            return "Email correspondence recorded in the source."
        }
    }

    /// WHO display labels for an email, cleaned to readable names ("Name <addr>" → "Name"),
    /// de-duplicated case-insensitively, then SORTED alphabetically so no ordering can be read as
    /// a sender/recipient role.
    private nonisolated static func emailParticipantLabels(_ slots: EventNarrativeSlots) -> [String] {
        var seen = Set<String>()
        var names: [String] = []
        for value in slots.who where value.provenance == .structuredHeader || value.provenance == .ruleBased {
            let name = cleanDisplayName(value.text)
            let key = name.lowercased()
            guard !name.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key); names.append(name)
        }
        return names.sorted()
    }

    /// The email's topic: the structured Subject (recorded as a structured-header WHAT value), or a
    /// meaningful Event title, with Re:/Fwd: display prefixes trimmed. Never fabricated.
    private nonisolated static func emailTopic(event: Event, slots: EventNarrativeSlots) -> String? {
        let headerSubjects = slots.what
            .filter { $0.provenance == .structuredHeader }
            .map(\.text)
        for candidate in headerSubjects + [event.title] {
            if let topic = meaningfulTopic(candidate) { return capped(topic, at: maxTopicLength) }
        }
        // A rule-based WHAT sentence (Commit B body-topic fallback) is the last resort.
        for value in slots.what where value.provenance == .ruleBased {
            if let topic = meaningfulTopic(value.text) { return capped(topic, at: maxTopicLength) }
        }
        return nil
    }

    // MARK: - Value extraction (guarded — only persisted values)

    private nonisolated static func attributeString(_ event: Event, _ key: String) -> String? {
        guard case .string(let s)? = event.attributes[key]?.value else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// "INR 3,800" from persisted `amount` + `currency`. Nil when no amount is stored. Accepts an
    /// int OR double value — an integer-valued double round-trips through JSON as an Int64.
    private nonisolated static func amountPhrase(_ event: Event) -> String? {
        let value: Double
        switch event.attributes["amount"]?.value {
        case .double(let d): value = d
        case .int(let i):    value = Double(i)
        default:             return nil
        }
        let currency = attributeString(event, "currency")
        let number = formatAmount(value)
        return currency.map { "\($0) \(number)" } ?? number
    }

    /// A location from a persisted `location` attribute, else a WHERE slot value that is a real
    /// place (not the "email"/channel sentinel).
    private nonisolated static func location(event: Event, slots: EventNarrativeSlots) -> String? {
        if let loc = attributeString(event, "location") { return loc }
        let channels: Set<String> = ["email", "document", "spreadsheet", "presentation", "image",
                                     "recording", "video", "archive", "chat", "browser"]
        for value in slots.whereAt where value.provenance == .structuredHeader || value.provenance == .ruleBased {
            let t = value.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty, !channels.contains(t.lowercased()) { return t }
        }
        return nil
    }

    /// The commitment phrase for a taskAssigned event: a WHY slot value or a meaningful summary.
    private nonisolated static func commitmentPhrase(event: Event, slots: EventNarrativeSlots) -> String? {
        if let why = ruleOrHeaderValue(slots.why) { return trimmedSentence(why) }
        if let summary = meaningfulSummary(event) { return trimmedSentence(summary) }
        return nil
    }

    /// The reason phrase for a delivery delay: a WHY slot value or a meaningful summary.
    private nonisolated static func reasonPhrase(event: Event, slots: EventNarrativeSlots) -> String? {
        if let why = ruleOrHeaderValue(slots.why) { return trimmedSentence(why) }
        if let summary = meaningfulSummary(event) { return trimmedSentence(summary) }
        return nil
    }

    private nonisolated static func ruleOrHeaderValue(_ values: [NarrativeSlotValue]) -> String? {
        for v in values where v.provenance == .structuredHeader || v.provenance == .ruleBased {
            let t = v.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        return nil
    }

    // MARK: - Titles / summaries

    private nonisolated static func meaningfulTitleOrSummary(_ event: Event) -> String? {
        if let title = meaningfulTopic(event.title) { return title }
        if let summary = meaningfulSummary(event) { return summary }
        return nil
    }

    private nonisolated static func meaningfulSummary(_ event: Event) -> String? {
        guard let s = event.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    /// A neutral, evidence-derived subject label for a participant-less Event. Prefers a meaningful
    /// email topic, else a meaningful title, else a kind-level label — never a fabricated subject.
    private nonisolated static func neutralSubjectLabel(event: Event, slots: EventNarrativeSlots) -> String {
        if event.kind == .emailSent || event.kind == .emailReceived {
            if let topic = emailTopic(event: event, slots: slots) { return topic }
            return "Email correspondence"
        }
        if let title = meaningfulTopic(event.title) { return title }
        return kindLabel(event.kind)
    }

    private nonisolated static func kindLabel(_ kind: Event.Kind) -> String {
        switch kind {
        case .emailSent, .emailReceived: return "Email correspondence"
        case .contractSigned:            return "Contract"
        case .contractModified:          return "Contract amendment"
        case .invoiceIssued:             return "Invoice"
        case .invoicePaid:               return "Invoice payment"
        case .meetingHeld:               return "Meeting"
        case .taskAssigned:              return "Task"
        case .deliveryDelayed:           return "Delivery"
        case .deliveryCompleted:         return "Delivery"
        case .other:                     return "Event"
        }
    }

    // MARK: - Preferred evidence blocks

    /// The exact Event block ids persisted in `attributes["sourceBlockIDs"]` (A5.3). Deterministic
    /// order, de-duplicated. Empty when the event carries no block provenance.
    private nonisolated static func preferredBlockIDs(from event: Event) -> [EvidenceBlock.ID] {
        guard case .array(let raw)? = event.attributes["sourceBlockIDs"]?.value else { return [] }
        var seen = Set<UUID>()
        var out: [UUID] = []
        for item in raw {
            guard case .string(let s) = item, let id = UUID(uuidString: s), seen.insert(id).inserted else { continue }
            out.append(id)
        }
        return out
    }

    // MARK: - Text helpers (pure, deterministic)

    /// A "meaningful" topic: non-empty, not a bare generic placeholder, after trimming Re:/Fwd:
    /// display prefixes. Preserves the meaningful words; returns nil when nothing meaningful remains.
    private nonisolated static func meaningfulTopic(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let stripped = strippingReplyPrefixes(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stripped.isEmpty else { return nil }
        let generic: Set<String> = ["email", "(no subject)", "no subject", "subject", "fwd", "re", "fw"]
        if generic.contains(stripped.lowercased()) { return nil }
        return normalizeWhitespace(stripped)
    }

    /// Remove leading "Re:", "Fwd:", "FW:" markers (possibly repeated) for DISPLAY only, preserving
    /// the meaningful remainder.
    static func strippingReplyPrefixes(_ s: String) -> String {
        var result = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let markers = ["re:", "fwd:", "fw:", "re :", "fwd :", "fw :"]
        var changed = true
        while changed {
            changed = false
            for m in markers where result.lowercased().hasPrefix(m) {
                result = String(result.dropFirst(m.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                changed = true
            }
        }
        return result
    }

    private nonisolated static func cleanDisplayName(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // "Name <addr@host>" → "Name"; a bare "<addr>" → "addr".
        if let lt = s.firstIndex(of: "<") {
            let namePart = String(s[s.startIndex..<lt]).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            if !namePart.isEmpty {
                s = namePart
            } else if let gt = s.firstIndex(of: ">") {
                s = String(s[s.index(after: lt)..<gt]).trimmingCharacters(in: .whitespaces)
            }
        }
        return normalizeWhitespace(s)
    }

    private nonisolated static func trimmedSentence(_ s: String) -> String {
        normalizeWhitespace(s.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private nonisolated static func normalizeWhitespace(_ s: String) -> String {
        s.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
            .joined(separator: " ")
    }

    private nonisolated static func quoted(_ s: String) -> String { "“\(s)”" }

    /// Deterministic English list join: "A", "A and B", "A, B and C", capping at 4 named plus
    /// "and N others" so a large recipient list stays readable and stable.
    private nonisolated static func joinNames(_ names: [String]) -> String {
        let maxNamed = 4
        if names.count <= maxNamed {
            switch names.count {
            case 0: return ""
            case 1: return names[0]
            case 2: return "\(names[0]) and \(names[1])"
            default: return "\(names.dropLast().joined(separator: ", ")) and \(names.last!)"
            }
        }
        let named = names.prefix(maxNamed).joined(separator: ", ")
        let others = names.count - maxNamed
        return "\(named) and \(others) other\(others == 1 ? "" : "s")"
    }

    private nonisolated static func formatAmount(_ value: Double) -> String {
        // Integer amounts drop the decimals; grouped in thousands with commas, deterministically.
        let isInteger = value.rounded() == value
        let intPart = Int(value.rounded(.towardZero))
        let grouped = groupThousands(abs(intPart))
        let sign = value < 0 ? "-" : ""
        if isInteger { return "\(sign)\(grouped)" }
        let fraction = Int((abs(value) - Double(abs(intPart))) * 100.0 + 0.5)
        return "\(sign)\(grouped).\(String(format: "%02d", fraction))"
    }

    private nonisolated static func groupThousands(_ n: Int) -> String {
        let digits = String(n)
        guard digits.count > 3 else { return digits }
        var out = ""
        var count = 0
        for ch in digits.reversed() {
            if count != 0 && count % 3 == 0 { out.append(",") }
            out.append(ch); count += 1
        }
        return String(out.reversed())
    }

    /// Trim to `limit` characters on a word boundary, appending a single ellipsis when truncated.
    static func capped(_ s: String, at limit: Int) -> String {
        guard s.count > limit else { return s }
        let slice = s.prefix(limit)
        if let lastSpace = slice.lastIndex(of: " ") {
            return slice[slice.startIndex..<lastSpace].trimmingCharacters(in: .whitespaces) + "…"
        }
        return slice + "…"
    }
}
