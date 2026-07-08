//
//  LLMSlotExtractor.swift
//  Kalsmritikosh
//
//  G3.14 — LLM-assisted slot filler. Wraps the `.extraction` capability
//  to populate slots the rule-based `SlotExtractor` couldn't derive
//  from already-extracted fields. Examples:
//
//    - Email.sender_person      — names a Person, but the loader
//      knows only an email address. Convert "alice@supplier.com" +
//      "Alice Wong" mentioned in the body → sender_person="Alice Wong".
//    - Contract.party_a_org     — needs to read the contract text to
//      identify which org signed first.
//    - Invoice.for_project      — surfaces a "Project Delta" mention
//      in the invoice body even when no project entity was extracted.
//
//  CLAUDE.md / capability discipline: no model name appears here. The
//  registry picks the provider; on macOS 26+ Apple FoundationModels
//  win, on older OS Ollama wins, never both at once.
//
//  Strategy: a SINGLE structured-output prompt per fact carrying:
//    - the fact type's slot schema (slot name, type, hint)
//    - the source text the slot extractor already saw
//    - the slots that are still empty
//
//  The model replies with a JSON object mapping slot names to values.
//  We merge that into the rule-based map, re-run the validator, and
//  the caller persists.
//
//  Failure modes are non-fatal — a slow / unavailable / malformed LLM
//  response leaves the map unchanged. Slot writes still happen with
//  whatever the rule-based extractor produced.
//

import Foundation
import OSLog

public actor LLMSlotExtractor {
    private let capabilities: CapabilityRegistry
    /// JSON encoder/decoder for the structured-output round-trip.
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(capabilities: CapabilityRegistry) {
        self.capabilities = capabilities
    }

    /// Try to fill missing slots for an entity. Returns a (possibly
    /// unchanged) slot map. Existing values are never overwritten.
    public func fillMissing(
        entity: Entity,
        factType: FactType,
        existing: [String: AnyCodable.AnySendable],
        sourceText: String
    ) async -> [String: AnyCodable.AnySendable] {
        guard let schema = Ontology.schema(for: factType) else { return existing }
        let missing = missingSlots(in: schema.slots, existing: existing)
        guard !missing.isEmpty else { return existing }
        let context = "Entity name: \(entity.value)"
        let filled = await callModel(
            factType: factType,
            slots: missing,
            context: context,
            sourceText: sourceText
        )
        return merge(existing, with: filled)
    }

    /// Try to fill missing slots for an event.
    public func fillMissing(
        event: Event,
        factType: FactType,
        existing: [String: AnyCodable.AnySendable],
        sourceText: String
    ) async -> [String: AnyCodable.AnySendable] {
        guard let schema = Ontology.schema(for: factType) else { return existing }
        let missing = missingSlots(in: schema.slots, existing: existing)
        guard !missing.isEmpty else { return existing }
        var contextParts: [String] = ["Event title: \(event.title)"]
        if let summary = event.summary, !summary.isEmpty {
            contextParts.append("Summary: \(summary)")
        }
        let context = contextParts.joined(separator: "\n")
        let filled = await callModel(
            factType: factType,
            slots: missing,
            context: context,
            sourceText: sourceText
        )
        return merge(existing, with: filled)
    }

    // MARK: - Internals

    private func missingSlots(
        in slots: [FactSlot],
        existing: [String: AnyCodable.AnySendable]
    ) -> [FactSlot] {
        slots.filter { slot in
            guard let v = existing[slot.name] else { return true }
            if case .null = v { return true }
            if case .string(let s) = v, s.isEmpty { return true }
            return false
        }
    }

    /// Build the prompt, call the model, parse the JSON reply. Any
    /// failure path returns an empty map (caller's existing slots
    /// stay untouched).
    private func callModel(
        factType: FactType,
        slots: [FactSlot],
        context: String,
        sourceText: String
    ) async -> [String: AnyCodable.AnySendable] {
        let spec = CapabilitySpec(
            requires: [.textGeneration, .extraction],
            prefers: [.structuredOutput, .longContext],
            maxLatency: .background,
            privacy: .localNetwork,
            estimatedContextTokens: 4_000,
            purpose: "knowledge.slots"
        )
        guard let provider = try? await capabilities.resolve(spec),
              await provider.isAvailable() else {
            return [:]
        }
        let schemaLines = slots.map { s -> String in
            let hint = s.extractorHint.map { " — \($0)" } ?? ""
            return "- \(s.name): \(describe(s.type))\(hint)"
        }.joined(separator: "\n")
        // G3 — type-routed extraction. Invoice / contract / email
        // threads each carry their own conventions (amounts, parties,
        // action items); the generic prompt under-fills slots that
        // a typed prompt could anchor more confidently.
        let typedHints = Self.typedReaderHints(for: factType)
        let prompt = """
        Extract values for the following slots of a \(factType.displayName).
        \(typedHints)
        Slots to fill:
        \(schemaLines)

        Reply with a single JSON object whose keys are the slot names and
        whose values are the extracted values. Use null for slots you can't
        confidently fill. Do not invent values.

        \(context)
        Source text:
        \(sourceText.prefix(2_400))

        JSON:
        """
        let options = GenerationOptions(
            maxTokens: 320,
            temperature: 0.1,
            systemPrompt: "You extract typed slot values from text. Reply with one JSON object only."
        )
        do {
            let response = try await provider.generate(prompt: prompt, options: options)
            return parseJSON(response)
        } catch {
            KalsmritikoshLog.knowledge.error("LLMSlotExtractor: provider call failed — \(String(describing: error), privacy: .public)")
            return [:]
        }
    }

    private func describe(_ type: SlotType) -> String {
        switch type {
        case .string: return "string"
        case .integer: return "integer"
        case .decimal: return "decimal"
        case .date: return "date (ISO8601)"
        case .bool: return "bool"
        case .reference(let ft): return "reference to a \(ft.displayName) (its name)"
        }
    }

    /// G3 — domain-specific reading guidance prepended to the slot
    /// extraction prompt. Generic extraction ("read every slot
    /// equally") under-fills typed fields that a domain-anchored
    /// prompt could nail. The hints are short on purpose — most of
    /// the prompt budget should still go to the source text.
    private static func typedReaderHints(for factType: FactType) -> String {
        switch factType {
        case .invoice:
            return """

            This is an INVOICE. Look for: invoice number / reference,
            issued and due dates, total amount with currency, line-item
            subtotal vs tax vs grand total, the payee (who's billing)
            and payer (who pays). When you see a currency symbol or ISO
            code, capture both the number and the currency.

            """
        case .contract:
            return """

            This is a CONTRACT. Look for: the two (or more) named
            parties and which is buyer / seller, the effective date and
            termination date, governing-law jurisdiction, contract
            value, signatures and signature dates. Distinguish
            preamble dates ("dated as of") from execution dates.

            """
        case .amendment:
            return """

            This is a CONTRACT AMENDMENT. Look for: the parent
            contract this amends (by name or reference), the effective
            date of the amendment, which clauses are modified vs added
            vs deleted, and any change in contract value or term.

            """
        case .email:
            return """

            This is an EMAIL or message thread. Look for: the From
            address, primary To recipients, Cc recipients, message
            send date (header trumps body), subject line, and any
            explicit action items or decisions. A "thread" may carry
            multiple sub-messages — extract slots from the outermost
            (most recent) unless the slot context says otherwise.

            """
        case .meeting:
            return """

            This is a MEETING record. Look for: meeting date and
            duration, attendees (with role when stated), agenda items,
            decisions made, action items with owners, follow-up dates.
            Calendar-export shapes vary; verbatim minutes carry more
            signal than calendar metadata.

            """
        case .delivery:
            return """

            This is a DELIVERY / SHIPMENT record. Look for: tracking
            or shipment number, ship / pickup date, delivery date
            (promised vs actual), carrier, origin and destination
            addresses, contents reference (PO or invoice number).

            """
        case .decision:
            return """

            This is a DECISION record. Look for: the decision itself
            (one short imperative sentence), who decided (role and
            name), when, what alternatives were considered, and what
            triggers a reversal.

            """
        case .person, .organization, .project:
            // These are simpler subject types — the schema lines
            // alone are enough guidance; injecting a paragraph of
            // hints would actually crowd out source text.
            return ""
        }
    }

    /// Pull the first balanced `{ … }` object out of the model's reply
    /// and decode each leaf into AnySendable. Tolerates code fences and
    /// trailing prose.
    private func parseJSON(_ response: String) -> [String: AnyCodable.AnySendable] {
        guard let start = response.firstIndex(of: "{") else { return [:] }
        var depth = 0
        var end = start
        var cursor = start
        while cursor < response.endIndex {
            let c = response[cursor]
            if c == "{" { depth += 1 }
            if c == "}" {
                depth -= 1
                if depth == 0 {
                    end = response.index(after: cursor)
                    break
                }
            }
            cursor = response.index(after: cursor)
        }
        guard end > start else { return [:] }
        let payload = String(response[start..<end])
        guard let data = payload.data(using: .utf8),
              let decoded = try? decoder.decode([String: AnyCodable].self, from: data) else {
            return [:]
        }
        var out: [String: AnyCodable.AnySendable] = [:]
        for (k, v) in decoded {
            if case .null = v.value { continue }
            out[k] = v.value
        }
        return out
    }

    /// Existing values win — the LLM cannot overwrite what the rule-
    /// based extractor already produced. Keeps the deterministic
    /// extractor as ground truth.
    private func merge(
        _ existing: [String: AnyCodable.AnySendable],
        with llm: [String: AnyCodable.AnySendable]
    ) -> [String: AnyCodable.AnySendable] {
        var out = existing
        for (k, v) in llm where out[k] == nil {
            out[k] = v
        }
        return out
    }
}
