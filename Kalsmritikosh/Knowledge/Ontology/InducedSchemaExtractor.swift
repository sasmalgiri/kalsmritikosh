//
//  InducedSchemaExtractor.swift
//  Kalsmritikosh
//
//  P3.3 — SCHEMA INDUCTION. The last universality unit, and the only one that
//  calls the model. It is deliberately last: the deterministic lanes (P3.1 open
//  fields, P3.2 derived types, P3.4 open asking) had to exist underneath it, so
//  that this handles only what they genuinely cannot.
//
//  THE GAP IT CLOSES. P3.1 reads `Label: value` from any document — but only
//  where a separator exists. A document whose fields are implied by prose or
//  layout ("The holder of this policy is Asha Rao. Cover begins on 1 April
//  2024.") has fields a human reads instantly and no rule in this codebase can
//  see. Eleven packs cannot anticipate every document kind a person owns; that
//  is the whole premise of the universality work.
//
//  WHY IT IS SAFE TO LET A MODEL NEAR THE LEDGER — the four structural gates,
//  in the order they bind:
//
//  1. CANDIDATES ARE DOCUMENTS THAT PRODUCED NOTHING. Induction runs only when
//     deterministic extraction yielded ZERO facts for the document. It can
//     therefore never perturb, reorder, outrank or contradict a rule-derived
//     fact — there are none to perturb. The ADD-NEVER-PERTURB guarantee that
//     P3.1 got from `reservedFields` this one gets from arithmetic.
//
//  2. THE MODEL PROPOSES FIELD NAMES; IT DOES NOT GET TO ASSERT VALUES. Every
//     returned value must be found VERBATIM in the document's own block text,
//     and the fact is grounded on the block(s) where it was actually found —
//     not where the model said it was. A fabricated value cannot be located, so
//     it cannot be written. This is the difference between an evidence-bound
//     extractor and a generator: the model's role is to notice that "policy
//     holder" is a field of this document, and nothing more.
//
//  3. PACK FIELDS ARE OFF LIMITS. An induced field that collided with a pack's
//     own field would let a model-proposed value masquerade as a
//     rule-extracted one. `OpenFieldExtractor.reservedFields` is reused rather
//     than re-listed, so the two lanes cannot drift apart.
//
//  4. IT IS BUDGETED, AND THE BUDGET IS THE CALLER'S. Per document the field
//     cap is low; across a pass the document cap belongs to the backfill, which
//     knows the archive size. Runs in `OntologyBackfill` off the ingest path,
//     re-deriving from STORED evidence blocks — so nothing here requires a
//     re-ingest to take effect.
//
//  CONFIDENCE IS ORDERED, NOT GUESSED. `inducedConfidence` (0.40) sits BELOW
//  every confidence `OpenFieldExtractor.confidence(for:)` can return (0.55
//  paragraph … 0.75 table). So an induced fact can never outrank a
//  deterministically extracted one anywhere that sorts by confidence. That is a
//  checkable ordering property, not a vibe — `inducedConfidenceIsLowest`
//  asserts it against the real function.
//
//  AND IT NEVER PRETENDS. A missing or unavailable provider produces
//  `.declined(reason)`, never an empty success — an empty result reads as "this
//  document has no fields", which is exactly the claim this failed to check.
//
//  Capability discipline (CLAUDE.md): no model name appears here. The registry
//  resolves `.extraction`; which provider wins is not this file's business.
//

import Foundation
import os

public actor InducedSchemaExtractor {

    private let capabilities: CapabilityRegistry
    private let decoder = JSONDecoder()

    public init(capabilities: CapabilityRegistry) {
        self.capabilities = capabilities
    }

    // MARK: - Bounds

    /// Fields accepted from ONE document. Far below the deterministic
    /// extractor's 60: that cap guards against a page of label-like lines,
    /// while this bounds how much a single model reply may assert. A document
    /// that genuinely carries more than a dozen induced fields is better served
    /// by someone adding a domain pack for its kind.
    public nonisolated static let maximumInducedFieldsPerDocument = 12

    /// Characters of document text sent in one call. Bounded for cost and
    /// because a value quoted from page 40 cannot be verified against a
    /// prompt that was truncated at page 3 — the verbatim gate would reject it
    /// anyway, so sending more would buy rejections, not facts.
    public nonisolated static let maximumPromptCharacters = 6_000

    /// Below every value `OpenFieldExtractor.confidence(for:)` returns.
    public nonisolated static let inducedConfidence = 0.40

    /// Proof of the ordering claim in this file's header, computed from the
    /// real function rather than a copied-out number. Used by the guard test.
    public nonisolated static var inducedConfidenceIsLowest: Bool {
        let deterministic = EvidenceBlockKind.allCases
            .compactMap { OpenFieldExtractor.confidence(for: $0) }
        guard let lowest = deterministic.min() else { return false }
        return inducedConfidence < lowest
    }

    // MARK: - Result

    /// Why a pass produced nothing. Stated, never collapsed into an empty list.
    public enum Decline: Sendable, Equatable {
        case moduleDisabled
        case documentAlreadyYieldedFacts(Int)
        case noEligibleBlocks
        case providerUnavailable
        case providerFailed(String)
        case emptyReply
        /// The model replied, and every pair it proposed failed a gate.
        case allProposalsRejected(RejectionTally)

        public var explanation: String {
            switch self {
            case .moduleDisabled:
                return "Schema induction is switched off."
            case .documentAlreadyYieldedFacts(let n):
                return "Not attempted — the document already yielded \(n) fact(s) by rule, and "
                     + "induction runs only where deterministic extraction found nothing."
            case .noEligibleBlocks:
                return "No block in this document can carry a field (headers, footers and "
                     + "boilerplate are excluded)."
            case .providerUnavailable:
                return "No on-device extraction model was available, so nothing was attempted. "
                     + "This is not a statement that the document has no fields."
            case .providerFailed(let why):
                return "The extraction model call failed: \(why)."
            case .emptyReply:
                return "The extraction model returned nothing usable."
            case .allProposalsRejected(let tally):
                return "Every proposal was rejected — \(tally.summary)."
            }
        }
    }

    /// Per-gate rejection counts. The point of keeping these SEPARATE is that
    /// they mean different things: `valueNotFoundInDocument` climbing means the
    /// model is fabricating, while `reservedField` climbing means it keeps
    /// proposing fields a pack already owns. One is a trust problem and the
    /// other is a prompt problem, and a single "rejected: 9" could not tell
    /// them apart.
    public struct RejectionTally: Sendable, Equatable {
        public var valueNotFoundInDocument = 0
        public var reservedField = 0
        public var placeholderValue = 0
        public var unusableFieldName = 0
        public var duplicate = 0
        public var overBudget = 0

        public var total: Int {
            valueNotFoundInDocument + reservedField + placeholderValue
                + unusableFieldName + duplicate + overBudget
        }

        public var summary: String {
            var parts: [String] = []
            if valueNotFoundInDocument > 0 {
                parts.append("\(valueNotFoundInDocument) value(s) not found in the document")
            }
            if reservedField > 0 { parts.append("\(reservedField) already owned by a built-in reader") }
            if placeholderValue > 0 { parts.append("\(placeholderValue) placeholder(s)") }
            if unusableFieldName > 0 { parts.append("\(unusableFieldName) unusable field name(s)") }
            if duplicate > 0 { parts.append("\(duplicate) duplicate(s)") }
            if overBudget > 0 { parts.append("\(overBudget) past the per-document limit") }
            return parts.isEmpty ? "no proposals" : parts.joined(separator: ", ")
        }
    }

    public struct Outcome: Sendable {
        public let facts: [GenericFact]
        public let rejected: RejectionTally
        /// Set when NO facts were produced. Never set alongside facts.
        public let declined: Decline?

        public var producedNothing: Bool { facts.isEmpty }
    }

    // MARK: - Entry point

    /// Induce fields for ONE document from its stored blocks.
    ///
    /// - Parameters:
    ///   - blocks: the document's evidence blocks, in document order.
    ///   - subjectLabel: the subject the facts attach to (same contract as
    ///     `OpenFieldExtractor.extractFacts`).
    ///   - existingFactCount: how many facts the document already has by rule.
    ///     NON-ZERO MEANS NOT A CANDIDATE — see gate 1. Passed in rather than
    ///     queried here because this type owns no storage (experts and
    ///     extractors are stateless; the ledger is read by its repositories).
    public func induce(
        blocks: [(id: UUID, text: String, kind: EvidenceBlockKind)],
        subjectLabel: String,
        existingFactCount: Int
    ) async -> Outcome {
        guard KnowledgeModuleFlags.isEnabled(.inducedSchema) else {
            return Outcome(facts: [], rejected: RejectionTally(), declined: .moduleDisabled)
        }
        guard existingFactCount == 0 else {
            return Outcome(facts: [], rejected: RejectionTally(),
                           declined: .documentAlreadyYieldedFacts(existingFactCount))
        }
        // Only blocks that can carry a field at all. Reusing the deterministic
        // lane's own judgement means furniture is excluded by ONE rule, not two
        // that can disagree — a page footer is not a document fact here for the
        // same reason it is not one there.
        let eligible = blocks.filter { OpenFieldExtractor.confidence(for: $0.kind) != nil }
        guard !eligible.isEmpty else {
            return Outcome(facts: [], rejected: RejectionTally(), declined: .noEligibleBlocks)
        }

        let proposals: [InducedPair]
        switch await propose(blocks: eligible) {
        case .failure(let decline):
            return Outcome(facts: [], rejected: RejectionTally(), declined: decline)
        case .success(let p):
            proposals = p
        }
        guard !proposals.isEmpty else {
            return Outcome(facts: [], rejected: RejectionTally(), declined: .emptyReply)
        }

        var tally = RejectionTally()
        var facts: [GenericFact] = []
        var seen = Set<String>()

        for pair in proposals {
            guard facts.count < Self.maximumInducedFieldsPerDocument else {
                tally.overBudget += 1
                continue
            }
            guard let fieldID = Self.usableFieldID(pair.field) else {
                tally.unusableFieldName += 1
                continue
            }
            guard !OpenFieldExtractor.reservedFields.contains(fieldID) else {
                tally.reservedField += 1
                continue
            }
            let value = pair.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard Self.isUsableValue(value) else {
                tally.placeholderValue += 1
                continue
            }
            // GATE 2 — the value must exist in the document. Grounded on the
            // blocks where it was FOUND, never where the model claimed.
            let hosting = eligible.filter { Self.contains(value, in: $0.text) }
            guard !hosting.isEmpty else {
                tally.valueNotFoundInDocument += 1
                continue
            }
            guard seen.insert(fieldID + "|" + value.lowercased()).inserted else {
                tally.duplicate += 1
                continue
            }
            facts.append(GenericFact(
                subjectLabel: subjectLabel,
                field: fieldID,
                value: value,
                status: .sourceAsserted,
                confidence: Self.inducedConfidence,
                sourceBlockIDs: hosting.map(\.id),
                producerVersion: DerivedProducerVersions.facts,
                // The receipt records the field name AS THE MODEL PHRASED IT,
                // so a reader can see that "policyholder" came from a proposal
                // and judge the naming themselves — the same courtesy the
                // deterministic lane extends by keeping the written label.
                rawMatch: "\(pair.field): \(value)",
                sourceCount: hosting.count,
                derivation: .llmInduced))
        }

        if facts.isEmpty {
            return Outcome(facts: [], rejected: tally, declined: .allProposalsRejected(tally))
        }
        return Outcome(facts: facts, rejected: tally, declined: nil)
    }

    // MARK: - Field / value admissibility

    /// Normalize and admit a proposed field name, or refuse it.
    nonisolated static func usableFieldID(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 40 else { return nil }
        // A field name must NAME something. A pure number or punctuation run is
        // a value that arrived in the wrong slot.
        guard trimmed.rangeOfCharacter(from: .letters) != nil else { return nil }
        let id = FactSchemaRegistry.normalizeField(trimmed)
        guard !id.isEmpty, id.count >= 2 else { return nil }
        // A field named for the document rather than for the datum tells a
        // reader nothing: "document", "file", "text", "value", "field", "data"
        // are labels for the container, not for what it holds.
        guard !containerWords.contains(id) else { return nil }
        return id
    }

    nonisolated static let containerWords: Set<String> = [
        "document", "file", "text", "value", "field", "data", "content",
        "contents", "page", "info", "information", "detail", "details",
        "note", "notes", "other", "misc", "miscellaneous", "type", "kind",
    ]

    nonisolated static func isUsableValue(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 300 else { return false }
        // Reuses the deterministic lane's placeholder list: a form's empty
        // field says "N/A", and storing that asserts a value the document
        // explicitly denies.
        guard !OpenFieldExtractor.placeholderValues.contains(value.lowercased()) else { return false }
        return value.rangeOfCharacter(from: .alphanumerics) != nil
    }

    /// Whitespace-insensitive, case-insensitive containment.
    ///
    /// The tolerance is deliberately narrow: a model that copies a value from a
    /// PDF will differ in RUN OF WHITESPACE (a line wrap becomes a space) and
    /// often in case, and rejecting those would reject correct extractions from
    /// the majority of real documents. It will NOT differ by a changed digit or
    /// a dropped word, and this comparison still catches those — which is the
    /// class the gate exists for. Normalizing anything further (punctuation,
    /// diacritics) would start admitting values the document does not contain.
    nonisolated static func contains(_ value: String, in text: String) -> Bool {
        let needle = collapseWhitespace(value).lowercased()
        guard !needle.isEmpty else { return false }
        return collapseWhitespace(text).lowercased().contains(needle)
    }

    nonisolated static func collapseWhitespace(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    // MARK: - The single model call

    struct InducedPair: Decodable, Sendable {
        let field: String
        let value: String
    }

    private enum ProposalResult {
        case success([InducedPair])
        case failure(Decline)
    }

    private func propose(
        blocks: [(id: UUID, text: String, kind: EvidenceBlockKind)]
    ) async -> ProposalResult {
        let spec = CapabilitySpec(
            requires: [.textGeneration, .extraction],
            prefers: [.structuredOutput, .longContext],
            maxLatency: .background,
            privacy: .localNetwork,
            estimatedContextTokens: 4_000,
            purpose: "knowledge.schema-induction"
        )
        guard let provider = try? await capabilities.resolve(spec),
              await provider.isAvailable() else {
            return .failure(.providerUnavailable)
        }

        var body = ""
        for block in blocks {
            let piece = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty else { continue }
            if body.count + piece.count > Self.maximumPromptCharacters { break }
            body += piece + "\n"
        }
        guard !body.isEmpty else { return .failure(.noEligibleBlocks) }

        // The instruction that matters is "copy the value exactly". The verbatim
        // gate enforces it regardless, but asking for it turns a rejection into
        // a fact rather than into a discarded proposal.
        let prompt = """
        Below is the text of one document. Identify the FIELDS this document \
        records — the things a reader would consider its named details — and the \
        value of each.

        Rules:
        - Copy each value EXACTLY as it appears in the text. Do not reformat \
        dates, numbers, names or amounts.
        - Name each field for the DATUM, not for the document (\u{201C}policy holder\u{201D}, \
        not \u{201C}document\u{201D}).
        - Only include a field whose value is actually written in the text. If \
        the document does not state something, leave it out entirely.
        - At most \(Self.maximumInducedFieldsPerDocument) fields, most important first.

        Reply with a JSON array only:
        [{"field": "...", "value": "..."}]

        Document:
        \(body)

        JSON:
        """
        let options = GenerationOptions(
            maxTokens: 600,
            temperature: 0.1,
            systemPrompt: "You identify the named fields of a document and copy their values "
                        + "verbatim. Reply with one JSON array only."
        )
        do {
            let response = try await provider.generate(prompt: prompt, options: options)
            return .success(Self.parseArray(response, decoder: decoder))
        } catch {
            KalsmritikoshLog.knowledge.error(
                "InducedSchemaExtractor: provider call failed — \(String(describing: error), privacy: .public)")
            return .failure(.providerFailed(String(describing: error)))
        }
    }

    /// Pull the first balanced `[ … ]` out of the reply. Tolerates code fences
    /// and trailing prose, like the slot extractor's object parser.
    nonisolated static func parseArray(_ response: String, decoder: JSONDecoder) -> [InducedPair] {
        guard let start = response.firstIndex(of: "[") else { return [] }
        var depth = 0
        var end: String.Index?
        var cursor = start
        while cursor < response.endIndex {
            let c = response[cursor]
            if c == "[" { depth += 1 }
            if c == "]" {
                depth -= 1
                if depth == 0 {
                    end = response.index(after: cursor)
                    break
                }
            }
            cursor = response.index(after: cursor)
        }
        guard let end, end > start,
              let data = String(response[start..<end]).data(using: .utf8),
              let pairs = try? decoder.decode([InducedPair].self, from: data) else {
            return []
        }
        return pairs
    }
}
