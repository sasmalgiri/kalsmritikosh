//
//  PromptTemplates.swift
//  Kalsmritikosh
//
//  Per-domain prompt builders. Each takes a UserIntent + RetrievalResult
//  and emits a `PromptFrame` carrying the prompt text plus the evidence
//  map the expert needs to resolve E-ids back to real object/event/entity
//  IDs after the LLM responds.
//
//  Templates never name a model.
//

import Foundation

/// Citation a single retrieved item contributes when the LLM cites its
/// E-id. Merged into the claim's three supporting-ID arrays at parse time.
public struct EvidenceCitation: Sendable, Hashable {
    public let supportingObjectIDs: [KnowledgeObject.ID]
    public let supportingEventIDs: [Event.ID]
    public let supportingEntityIDs: [Entity.ID]

    public init(
        supportingObjectIDs: [KnowledgeObject.ID] = [],
        supportingEventIDs: [Event.ID] = [],
        supportingEntityIDs: [Entity.ID] = []
    ) {
        self.supportingObjectIDs = supportingObjectIDs
        self.supportingEventIDs = supportingEventIDs
        self.supportingEntityIDs = supportingEntityIDs
    }
}

/// Prompt text plus the map an expert needs to translate the LLM's
/// cited E-ids back into real IDs.
public struct PromptFrame: Sendable {
    public let prompt: String
    public let evidenceMap: [String: EvidenceCitation]

    public init(prompt: String, evidenceMap: [String: EvidenceCitation]) {
        self.prompt = prompt
        self.evidenceMap = evidenceMap
    }

    /// Total enumerated retrieval items the prompt showed the LLM.
    public var retrievalSize: Int { evidenceMap.count }
}

public enum PromptTemplates {

    private static let jsonContract = """

    Respond with ONE JSON object and nothing else (no prose, no code fences):
    {"claims":[{"text":"...","evidence":["E1","E3"]}]}

    Rules:
    - Every claim's `evidence` MUST be a non-empty subset of the E-ids above.
    - Each E-id refers to ONLY the matching numbered line — do not invent E-ids.
    - Claims with empty or unresolved evidence will be discarded.
    """

    // MARK: - Email

    public static func emailAnalysis(intent: UserIntent, retrieval: RetrievalResult) -> PromptFrame {
        let events = retrieval.events.filter {
            $0.kind == .emailSent || $0.kind == .emailReceived
        }.prefix(20)
        var lines: [String] = []
        var map: [String: EvidenceCitation] = [:]
        for (i, event) in events.enumerated() {
            let tag = "E\(i + 1)"
            lines.append("[\(tag)] [\(event.date.formatted(date: .abbreviated, time: .shortened))] \(event.title)")
            map[tag] = EvidenceCitation(
                supportingObjectIDs: [event.sourceObjectID],
                supportingEventIDs: [event.id],
                supportingEntityIDs: event.entityIDs
            )
        }
        let evidenceBlock = lines.isEmpty ? "(no events found)" : lines.joined(separator: "\n")
        let prompt = """
        Task: Analyze the email evidence below for the question:
        "\(intent.rawQuestion)"

        Identify:
        - Who corresponded with whom and when
        - Notable thread shifts (delays, escalations, decisions)

        Email events (cite by E-id):
        \(evidenceBlock)
        \(jsonContract)
        """
        return PromptFrame(prompt: prompt, evidenceMap: map)
    }

    // MARK: - Financial

    public static func financialAnalysis(intent: UserIntent, retrieval: RetrievalResult) -> PromptFrame {
        let events = retrieval.events.filter {
            $0.kind == .invoiceIssued || $0.kind == .invoicePaid
        }.prefix(20)
        var lines: [String] = []
        var map: [String: EvidenceCitation] = [:]
        for (i, event) in events.enumerated() {
            let tag = "E\(i + 1)"
            lines.append("[\(tag)] [\(event.date.formatted(date: .abbreviated, time: .omitted))] \(event.title)")
            map[tag] = EvidenceCitation(
                supportingObjectIDs: [event.sourceObjectID],
                supportingEventIDs: [event.id],
                supportingEntityIDs: event.entityIDs
            )
        }
        let evidenceBlock = lines.isEmpty ? "(no events found)" : lines.joined(separator: "\n")
        let prompt = """
        Task: Summarize the financial signal below for the question:
        "\(intent.rawQuestion)"

        Note invoices issued vs paid, outstanding amounts, and overdue items.

        Financial events (cite by E-id):
        \(evidenceBlock)
        \(jsonContract)
        """
        return PromptFrame(prompt: prompt, evidenceMap: map)
    }

    // MARK: - Legal

    public static func legalAnalysis(intent: UserIntent, retrieval: RetrievalResult) -> PromptFrame {
        let events = retrieval.events.filter {
            $0.kind == .contractSigned || $0.kind == .contractModified
        }.prefix(10)
        var lines: [String] = []
        var map: [String: EvidenceCitation] = [:]
        for (i, event) in events.enumerated() {
            let tag = "E\(i + 1)"
            lines.append("[\(tag)] [\(event.date.formatted(date: .abbreviated, time: .omitted))] \(event.title)")
            map[tag] = EvidenceCitation(
                supportingObjectIDs: [event.sourceObjectID],
                supportingEventIDs: [event.id],
                supportingEntityIDs: event.entityIDs
            )
        }
        let evidenceBlock = lines.isEmpty ? "(no events found)" : lines.joined(separator: "\n")
        let prompt = """
        Task: Identify contractual signals for the question:
        "\(intent.rawQuestion)"

        Call out signings, amendments, obligations, and risks.

        Contract events (cite by E-id):
        \(evidenceBlock)
        \(jsonContract)
        """
        return PromptFrame(prompt: prompt, evidenceMap: map)
    }

    // MARK: - Project

    public static func projectAnalysis(intent: UserIntent, retrieval: RetrievalResult) -> PromptFrame {
        let events = retrieval.events.prefix(20)
        var lines: [String] = []
        var map: [String: EvidenceCitation] = [:]
        var index = 1
        for event in events {
            let tag = "E\(index)"
            lines.append("[\(tag)] [\(event.date.formatted(date: .abbreviated, time: .omitted))] \(event.kind.rawValue): \(event.title)")
            map[tag] = EvidenceCitation(
                supportingObjectIDs: [event.sourceObjectID],
                supportingEventIDs: [event.id],
                supportingEntityIDs: event.entityIDs
            )
            index += 1
        }
        // Also include strong stakeholders as cite-able entities so claims
        // about "who" can carry specific evidence.
        let stakeholders = retrieval.entities
            .filter { $0.kind == .person || $0.kind == .organization }
            .prefix(8)
        for entity in stakeholders {
            let tag = "E\(index)"
            lines.append("[\(tag)] (\(entity.kind.rawValue)) \(entity.value)")
            map[tag] = EvidenceCitation(supportingEntityIDs: [entity.id])
            index += 1
        }
        let evidenceBlock = lines.isEmpty ? "(no evidence found)" : lines.joined(separator: "\n")
        let prompt = """
        Task: Reconstruct the project's state from the evidence below.
        Question: "\(intent.rawQuestion)"

        Cover milestones, blockers, risks, and stakeholders.

        Evidence (cite by E-id):
        \(evidenceBlock)
        \(jsonContract)
        """
        return PromptFrame(prompt: prompt, evidenceMap: map)
    }

    // MARK: - Timeline

    public static func timelineAnalysis(intent: UserIntent, retrieval: RetrievalResult) -> PromptFrame {
        let events = retrieval.events.prefix(25)
        var lines: [String] = []
        var map: [String: EvidenceCitation] = [:]
        for (i, event) in events.enumerated() {
            let tag = "E\(i + 1)"
            lines.append("[\(tag)] \(event.date.formatted(date: .abbreviated, time: .omitted)): \(event.title)")
            map[tag] = EvidenceCitation(
                supportingObjectIDs: [event.sourceObjectID],
                supportingEventIDs: [event.id],
                supportingEntityIDs: event.entityIDs
            )
        }
        let evidenceBlock = lines.isEmpty ? "(no events found)" : lines.joined(separator: "\n")
        let prompt = """
        Task: Produce a chronological reconstruction for the question:
        "\(intent.rawQuestion)"

        Events (cite by E-id):
        \(evidenceBlock)
        \(jsonContract)
        """
        return PromptFrame(prompt: prompt, evidenceMap: map)
    }

    // MARK: - Research

    public static func researchAnalysis(intent: UserIntent, retrieval: RetrievalResult) -> PromptFrame {
        let hits = retrieval.chunks.prefix(6)
        var lines: [String] = []
        var map: [String: EvidenceCitation] = [:]
        for (i, hit) in hits.enumerated() {
            let tag = "E\(i + 1)"
            let snippet = String(hit.chunk.text.prefix(240))
                .replacingOccurrences(of: "\n", with: " ")
            lines.append("[\(tag)] (\(hit.viaLayer.rawValue)) \(snippet)")
            map[tag] = EvidenceCitation(supportingObjectIDs: [hit.chunk.objectID])
        }
        let evidenceBlock = lines.isEmpty ? "(no snippets)" : lines.joined(separator: "\n")
        let prompt = """
        Task: From the literature snippets below, extract the key citations
        and findings relevant to:
        "\(intent.rawQuestion)"

        Snippets (cite by E-id):
        \(evidenceBlock)
        \(jsonContract)
        """
        return PromptFrame(prompt: prompt, evidenceMap: map)
    }
}

// MARK: - Findings parsing

public enum ExpertResponseParser {
    /// Splits an LLM response into individual bullet findings. Kept for
    /// legacy/heuristic call sites; the JSON contract uses `parseClaims`.
    public static func bullets(from response: String) -> [String] {
        response
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .compactMap { line -> String? in
                guard !line.isEmpty else { return nil }
                let stripped = line.hasPrefix("-")
                    ? String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                    : line.hasPrefix("\u{2022}")
                        ? String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                        : line
                return stripped.isEmpty ? nil : stripped
            }
    }

    /// Result of parsing an LLM response against the evidence map for a
    /// PromptFrame. `claims` carry per-claim, validated evidence; `dropped`
    /// is the number of LLM-output claims discarded because their cited
    /// E-ids didn't resolve to anything in the retrieval set.
    public struct ParsedClaims: Sendable {
        public let claims: [ParsedClaim]
        public let dropped: Int
    }

    public struct ParsedClaim: Sendable {
        public let text: String
        public let citation: EvidenceCitation
    }

    /// Parses a strict-JSON envelope of the form
    /// `{"claims":[{"text":"...","evidence":["E1","E3"]}]}`.
    /// Strips common wrappers (code fences, surrounding prose), validates
    /// that each claim's evidence is a non-empty subset of `evidenceMap`,
    /// merges the resolved E-ids into a single EvidenceCitation per claim,
    /// and counts dropped claims.
    public static func parseClaims(
        from response: String,
        evidenceMap: [String: EvidenceCitation]
    ) -> ParsedClaims {
        guard let data = extractJSONObject(from: response).data(using: .utf8) else {
            return ParsedClaims(claims: [], dropped: 0)
        }
        struct Envelope: Decodable {
            struct Claim: Decodable {
                let text: String
                let evidence: [String]
            }
            let claims: [Claim]
        }
        guard let env = try? JSONDecoder().decode(Envelope.self, from: data) else {
            return ParsedClaims(claims: [], dropped: 0)
        }
        var out: [ParsedClaim] = []
        var dropped = 0
        for claim in env.claims {
            let text = claim.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolved = claim.evidence.compactMap { evidenceMap[$0] }
            guard !text.isEmpty, !resolved.isEmpty else {
                dropped += 1
                continue
            }
            var objectIDs: [KnowledgeObject.ID] = []
            var eventIDs: [Event.ID] = []
            var entityIDs: [Entity.ID] = []
            for citation in resolved {
                objectIDs.append(contentsOf: citation.supportingObjectIDs)
                eventIDs.append(contentsOf: citation.supportingEventIDs)
                entityIDs.append(contentsOf: citation.supportingEntityIDs)
            }
            out.append(ParsedClaim(
                text: text,
                citation: EvidenceCitation(
                    supportingObjectIDs: Array(Set(objectIDs)),
                    supportingEventIDs: Array(Set(eventIDs)),
                    supportingEntityIDs: Array(Set(entityIDs))
                )
            ))
        }
        return ParsedClaims(claims: out, dropped: dropped)
    }

    /// Extracts the JSON object substring from an LLM response that may
    /// be wrapped in code fences or surrounded by prose. Falls back to
    /// the trimmed response if no braces are found.
    private static func extractJSONObject(from response: String) -> String {
        var s = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            if let firstNewline = s.firstIndex(of: "\n") {
                s = String(s[s.index(after: firstNewline)...])
            } else {
                s = String(s.dropFirst(3))
            }
        }
        if s.hasSuffix("```") {
            s = String(s.dropLast(3))
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = s.firstIndex(of: "{"),
           let last = s.lastIndex(of: "}"),
           first < last {
            return String(s[first...last])
        }
        return s
    }
}
