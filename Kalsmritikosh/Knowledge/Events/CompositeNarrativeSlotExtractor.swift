//
//  CompositeNarrativeSlotExtractor.swift
//  Kalsmritikosh
//
//  L4 (module .eventSlotFill) — the rule extractor runs first (unchanged); then,
//  ONLY when the module is on and a reasoning model is available, the on-device
//  model fills the 5W+H slots the rules left EMPTY (why / where / how — the ones
//  free prose carries but headers don't). Fact-preserving guard: a model phrase
//  is accepted only if every content word already appears in the event's own
//  source text, so the fill can surface a grounded phrase but can never invent a
//  name, number, place, or motive. No model, or module off ⇒ the rule slots
//  stand unchanged (minimum-LLM contract preserved on the inline ingest path;
//  this composite is used by the background backfiller only).
//

import Foundation

public struct CompositeNarrativeSlotExtractor: NarrativeSlotExtractor {

    /// Injected so tests can stub the model. Returns nil when no model is up.
    public typealias Reasoner = @Sendable (_ prompt: String) async -> String?

    private let base: NarrativeSlotExtractor
    private let reason: Reasoner?

    public init(base: NarrativeSlotExtractor = RuleNarrativeSlotExtractor(), reason: Reasoner?) {
        self.base = base
        self.reason = reason
    }

    public func extract(
        event: Event,
        object: KnowledgeObject,
        entities: [Entity],
        canonicalMapping: [Entity.ID: Entity.ID],
        emailParticipants: NarrativeSlotEmailParticipants?
    ) async -> EventNarrativeSlots {
        var slots = await base.extract(
            event: event, object: object, entities: entities,
            canonicalMapping: canonicalMapping, emailParticipants: emailParticipants)

        guard KnowledgeModuleFlags.isEnabled(.eventSlotFill), let reason else { return slots }

        // Only fill the narrative slots the rules commonly miss and that are empty.
        let targets: [NarrativeSlot] = [.why, .where, .how].filter { slots.values(for: $0).isEmpty }
        guard !targets.isEmpty else { return slots }

        let source = ([event.title, event.summary ?? "", String(object.content.prefix(1500))])
            .joined(separator: " ")
        guard let raw = await reason(Self.prompt(source: source, targets: targets)) else {
            return slots
        }
        let sourceTerms = PassageAnswerSelector().contentTerms(source)
        for (slot, phrase) in Self.parse(raw, targets: targets) {
            // Fact-preserving guard: every content word must already be in the source.
            let phraseTerms = PassageAnswerSelector().contentTerms(phrase)
            guard !phraseTerms.isEmpty, phraseTerms.isSubset(of: sourceTerms) else { continue }
            slots.add(NarrativeSlotValue(
                text: phrase, confidence: 0.5, provenance: .llmExtractor,
                sourceObjectIDs: [object.id]), to: slot)
        }
        return slots
    }

    // MARK: - Pure helpers (unit-tested)

    nonisolated static func prompt(source: String, targets: [NarrativeSlot]) -> String {
        let want = targets.map(\.rawValue).joined(separator: ", ")
        return """
        From the passage below, fill ONLY these missing detail slots: \(want). Reply with one \
        line per slot as `slot: phrase`. Use ONLY words that appear in the passage — do not add \
        any name, number, place, or motive that is not written there. If a slot has no answer in \
        the passage, omit that line.

        Passage:
        \(source)
        """
    }

    /// Parse `slot: phrase` lines, keeping only the requested target slots.
    nonisolated static func parse(_ raw: String, targets: [NarrativeSlot]) -> [(NarrativeSlot, String)] {
        let byName: [String: NarrativeSlot] = Dictionary(
            uniqueKeysWithValues: targets.map { ($0.rawValue.lowercased(), $0) })
        var out: [(NarrativeSlot, String)] = []
        for line in raw.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard let slot = byName[key], !value.isEmpty else { continue }
            out.append((slot, value))
        }
        return out
    }
}
