//
//  QueryAIParser.swift
//  Kalsmritikosh
//
//  OPTIONAL on-device AI for the "Describe it" bar. It does NOT write SQL and it
//  does NOT get a free hand: it fills the SAME safe slot the deterministic
//  QueryNaturalParser fills — a subject id + a list of filters chosen strictly
//  from LedgerQueryCatalog. The model returns JSON; we then validate every
//  subject / field / operator / choice value against the catalog whitelist and
//  DROP anything that isn't there. The result flows through the identical
//  read-only, parameterized compiler. So the AI can only ever produce a query a
//  human could have built by clicking — it cannot reach a table, column, or
//  operation the builder doesn't already expose.
//
//  Routing is capability-based (no model names here, per the architecture
//  invariants): we ask the CapabilityRegistry for a reasoning capability. If
//  none is available (Lightning mode / older OS / no model), interpret() returns
//  nil and the caller falls back to the deterministic parser — which always works.
//

import Foundation

public enum QueryAIParser {

    /// Ask an on-device reasoning model to fill the safe builder. Returns nil on
    /// any failure (no provider, bad JSON, unknown subject) so the caller can
    /// fall back to QueryNaturalParser. Never throws.
    public static func interpret(_ raw: String,
                                 capabilities: CapabilityRegistry) async -> QueryNaturalParser.Parsed? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2 else { return nil }

        let spec = CapabilitySpec.reasoning(contextTokens: 1_200, purpose: "query.nlParse")
        guard let provider = try? await capabilities.resolve(spec),
              await provider.isAvailable() else { return nil }

        let options = GenerationOptions(
            maxTokens: 350,
            temperature: 0.0,
            systemPrompt: Self.systemPrompt
        )
        guard let response = try? await provider.generate(prompt: userPrompt(text), options: options) else {
            return nil
        }
        return decode(response)
    }

    /// The model's raw text → a validated Parsed, or nil. Split out from
    /// interpret() so the safety-critical validation (whitelist every subject /
    /// field / operator / choice value) is unit-testable without a live model.
    static func decode(_ response: String) -> QueryNaturalParser.Parsed? {
        guard let json = extractJSONObject(from: response),
              let dto = try? JSONDecoder().decode(AIQuery.self, from: Data(json.utf8)) else { return nil }
        return build(from: dto)
    }

    // MARK: - Prompt (built from the live catalog so it can never drift)

    private static let systemPrompt =
        "You translate a person's plain-language request into a small JSON object that selects rows " +
        "from a fixed catalog. You may ONLY use the subjects, fields, operators and choice values given. " +
        "Never invent names. Reply with ONE minified JSON object and nothing else — no prose, no code fences."

    private static func userPrompt(_ text: String) -> String {
        var lines: [String] = []
        lines.append("SUBJECTS (pick exactly one \"subject\"):")
        for s in LedgerQueryCatalog.subjects {
            lines.append("- \(s.id): \(s.label)")
            for f in s.fields where f.filterable {
                let ops = QueryOperator.operators(for: f.kind).map(\.rawValue).joined(separator: "|")
                var line = "    field \(f.key) (\(f.kind.rawValue)) ops=[\(ops)]"
                if f.kind == .choice { line += " values=[\(f.options.joined(separator: "|"))]" }
                lines.append(line)
            }
        }
        lines.append("")
        lines.append("""
        Output JSON shape:
        {"subject":"<id>","filters":[{"field":"<key>","op":"<op>","value":"<text>","value2":"<only for between>"}],"sort":"<field key or omit>","descending":true,"limit":100}
        Rules: value is a plain string; for date fields use yyyy-MM-dd; for choice fields value MUST be one of the listed values; only use "value2" when op is "between"; omit anything you're unsure about; limit is 1..1000.
        """)
        lines.append("")
        lines.append("REQUEST: \(text)")
        lines.append("JSON:")
        return lines.joined(separator: "\n")
    }

    // MARK: - Decode DTO

    private struct AIQuery: Decodable {
        let subject: String
        var filters: [AIFilter]?
        var sort: String?
        var descending: Bool?
        var limit: Int?
    }
    private struct AIFilter: Decodable {
        let field: String
        let op: String
        var value: String?
        var value2: String?
    }

    // MARK: - Validate against the catalog whitelist, then build

    private static func build(from dto: AIQuery) -> QueryNaturalParser.Parsed? {
        guard let subject = LedgerQueryCatalog.subject(dto.subject) else { return nil }

        var filters: [QueryFilter] = []
        var parts: [String] = []
        for raw in dto.filters ?? [] {
            guard let field = subject.field(raw.field), field.filterable,
                  let op = QueryOperator(rawValue: raw.op),
                  QueryOperator.operators(for: field.kind).contains(op) else { continue }

            let value = (raw.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let value2 = (raw.value2 ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

            // Choice values must be one of the field's known options.
            if field.kind == .choice, !field.options.contains(value) { continue }
            // Numbers must actually parse (the compiler drops non-numbers, but keep the summary honest).
            if field.kind == .number, Double(value) == nil { continue }
            if op == .between, value2.isEmpty { continue }
            if value.isEmpty { continue }

            filters.append(QueryFilter(fieldKey: field.key, op: op, value: value, value2: value2))
            var part = "\(field.label.lowercased()) \(op.label) \(value)"
            if op == .between { part += " and \(value2)" }
            parts.append(part)
        }

        // Sort must be a real, selectable field on this subject.
        var sortKey: String? = nil
        if let s = dto.sort, let f = subject.field(s), f.selectable { sortKey = f.key }
        let descending = dto.descending ?? subject.defaultSortDescending
        let limit = min(1000, max(1, dto.limit ?? 100))

        let summary = parts.isEmpty ? subject.label : "\(subject.label) · " + parts.joined(separator: ", ")
        let query = LedgerQuery(subjectID: subject.id, filters: filters,
                                sortFieldKey: sortKey, sortDescending: descending, limit: limit)
        return QueryNaturalParser.Parsed(query: query, summary: summary)
    }

    // MARK: - JSON extraction (tolerate code fences / stray prose)

    private static func extractJSONObject(from response: String) -> String? {
        guard let open = response.firstIndex(of: "{"),
              let close = response.lastIndex(of: "}"), open < close else { return nil }
        return String(response[open...close])
    }
}
