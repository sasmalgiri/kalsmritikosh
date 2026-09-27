//
//  LedgerContractCheck.swift
//  Kalsmritikosh
//
//  L4 (P1.11, 2026-09-27) — the ledger's CONTRACT, checked. Each rule is one
//  invariant every correct ledger satisfies on any archive, whatever its
//  formats or domain. Every defect fixed in L1–L3 is here as a rule, so it
//  cannot silently come back: CI runs the check over a freshly ingested
//  mixed corpus (LedgerContractTests), and the same check can run in the
//  app's health panel over the user's own ledger.
//
//  Read-only: the check never repairs — it counts violations and names a
//  sample, so a failure is diagnosable, not just red.
//

import Foundation

public struct LedgerContractCheck: Sendable {

    public struct Rule: Sendable {
        public let id: String
        public let law: String
        /// SQL returning the violating rows' identifying text (one column).
        let violationsSQL: String
    }

    public struct Violation: Sendable, Equatable {
        public let ruleID: String
        public let count: Int
        public let sample: [String]
    }

    private let database: Database
    public init(database: Database) { self.database = database }

    /// The contract. Rules are universal: none names a format or a domain.
    public nonisolated static let rules: [Rule] = [
        Rule(id: "fact.subject",
             law: "Every fact names its subject.",
             violationsSQL: """
             SELECT id FROM generic_facts WHERE TRIM(COALESCE(subject_label, '')) = '' AND subject_id IS NULL
             """),
        Rule(id: "fact.evidence",
             law: "Every fact cites at least one evidence block that exists.",
             violationsSQL: """
             SELECT f.id FROM generic_facts f
             WHERE COALESCE(json_array_length(f.source_blocks_json), 0) = 0
                OR NOT EXISTS (SELECT 1 FROM json_each(f.source_blocks_json) j
                               JOIN evidence_blocks b ON b.id = j.value)
             """),
        Rule(id: "fact.era",
             law: "Every fact is at the current facts era (the drain converged).",
             violationsSQL: """
             SELECT id FROM generic_facts WHERE COALESCE(producer_version, 0) != \(DerivedProducerVersions.facts)
             """),
        Rule(id: "fact.plumbing",
             law: "No fact value is transport, style or markup plumbing.",
             violationsSQL: """
             SELECT field || '=' || value FROM generic_facts
             WHERE lower(value) GLOB '*content-type:*' OR lower(value) GLOB '*boundary=*'
                OR lower(value) GLOB '*dkim-signature*' OR lower(value) GLOB '*arc-seal*'
                OR lower(value) GLOB '*font-family:*' OR lower(value) GLOB '*background-color:*'
                OR value GLOB '*&nbsp;*' OR value GLOB '*____*'
             """),
        Rule(id: "event.unique",
             law: "One document states one happening once (no same-source repeats).",
             violationsSQL: """
             SELECT source_object_id || ' ' || kind || ' ' || lower(title) FROM events
             GROUP BY source_object_id, kind, lower(trim(title)), date(date, 'unixepoch')
             HAVING COUNT(*) > 1
             """),
        Rule(id: "event.source",
             law: "Every event's source document exists.",
             violationsSQL: """
             SELECT e.id FROM events e WHERE NOT EXISTS (SELECT 1 FROM knowledge_objects k WHERE k.id = e.source_object_id)
             """),
        Rule(id: "claim.lineage",
             law: "Every live claim projects at least one source that still exists.",
             violationsSQL: """
             SELECT c.id FROM claims c
             WHERE c.availability_status != 'missingEvidence'
               AND NOT EXISTS (
                 SELECT 1 FROM claim_lineage l WHERE l.claim_id = c.id AND (
                      (l.source_kind = 'event'         AND EXISTS (SELECT 1 FROM events e WHERE e.id = l.source_id))
                   OR (l.source_kind = 'genericFact'   AND EXISTS (SELECT 1 FROM generic_facts f WHERE f.id = l.source_id))
                   OR (l.source_kind = 'assertion'     AND EXISTS (SELECT 1 FROM assertions a WHERE a.id = l.source_id))
                   OR (l.source_kind = 'temporalClaim' AND EXISTS (SELECT 1 FROM temporal_claims t WHERE t.id = l.source_id))
                   OR l.source_kind NOT IN ('event', 'genericFact', 'assertion', 'temporalClaim')))
             """),
        Rule(id: "chunk.lineage",
             law: "Every chunk of a document that owns evidence blocks names the blocks it came from.",
             violationsSQL: """
             SELECT c.id FROM chunks c
             WHERE c.evidence_block_id IS NULL
               AND NOT EXISTS (SELECT 1 FROM chunk_blocks cb WHERE cb.chunk_id = c.id)
               AND EXISTS (SELECT 1 FROM evidence_block_objects o WHERE o.knowledge_object_id = c.object_id)
             """),
        Rule(id: "community.attributes",
             law: "Attributes (dates, amounts, phones, places) are never topic-community members.",
             violationsSQL: """
             SELECT e.value FROM entity_communities ec JOIN entities e ON e.id = ec.entity_id
             WHERE e.kind IN ('date', 'deadline', 'milestone', 'money', 'currency', 'phoneNumber', 'location')
             """),
        Rule(id: "history.current",
             law: "At most one current history per subject and request shape.",
             violationsSQL: """
             SELECT anchor_key || ' ' || request_shape FROM history_artifacts
             WHERE superseded_by IS NULL GROUP BY anchor_key, request_shape HAVING COUNT(*) > 1
             """),
        Rule(id: "entity.phoneShape",
             law: "A live phone entity is phone-shaped.",
             violationsSQL: """
             SELECT value FROM entities
             WHERE kind = 'phoneNumber' AND merged_into IS NULL AND COALESCE(review_status, '') != 'rejected'
               AND (length(replace(replace(replace(replace(replace(value, ' ', ''), '-', ''), '+', ''), '(', ''), ')', '')) NOT BETWEEN 7 AND 15)
             """),
    ]

    /// Run every rule. Empty result = the contract holds.
    public func violations(sampleSize: Int = 3) async throws -> [Violation] {
        var out: [Violation] = []
        for rule in Self.rules {
            let rows = try await database.query(rule.violationsSQL + ";", [])
            guard !rows.isEmpty else { continue }
            out.append(Violation(ruleID: rule.id, count: rows.count,
                                 sample: rows.prefix(sampleSize).map { $0.string(0) ?? "?" }))
        }
        return out
    }

    /// A human-readable report — for logs, the health panel, and CI output.
    public nonisolated static func render(_ violations: [Violation]) -> String {
        guard !violations.isEmpty else { return "Ledger contract: all \(rules.count) rules hold." }
        var lines = ["Ledger contract: \(violations.count) of \(rules.count) rules violated"]
        for v in violations {
            let law = rules.first(where: { $0.id == v.ruleID })?.law ?? ""
            lines.append("  ✗ \(v.ruleID) ×\(v.count) — \(law) e.g. \(v.sample.joined(separator: " | "))")
        }
        return lines.joined(separator: "\n")
    }
}
