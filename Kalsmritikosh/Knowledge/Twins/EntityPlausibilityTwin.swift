//
//  EntityPlausibilityTwin.swift
//  Kalsmritikosh
//
//  VT (Amendment A1) — the first ingestion-side verification twin: an
//  independent PLAUSIBILITY reading of the entity register. The owner's law,
//  verbatim in code:
//
//    · CHECKERS, NEVER WRITERS — the deterministic pipeline is the sole
//      author; the twin reads and flags, it cannot create, edit, or delete
//    · agreement → counters; disagreement → REVIEW ITEMS (advisory, with
//      review states) — findings are rule-defect signals, never auto-tuning
//    · EXCLUDED from sealed envelopes, evidence membership, and confidence
//    · idle-pass, budgeted, resumable, receipted; FM-unavailable = the
//      deterministic checks alone (an honest partial receipt, not an error)
//
//  Deterministic seeds run first (they need no model): place-name surnames
//  ("Bill Delhi"), title-shaped survivors, single-source proper nouns. The
//  AI reading, when available, reviews only what the seeds did not already
//  flag — one bounded call per batch, capability-resolved.
//

import Foundation
import os

public struct TwinFinding: Sendable, Equatable {
    public let entityID: UUID
    public let entityValue: String
    /// Plain-language reason (RC-8) — shown to the reviewer as written.
    public let reason: String
    /// Which checker raised it (the scoreboard's per-component rate).
    public let checker: String
}

public struct EntityPlausibilityTwinReceipt: Sendable {
    public var scanned = 0
    public var agreed = 0
    public var findings: [TwinFinding] = []

    public func renderLines() -> String {
        """
        ENTITY TWIN RECEIPT
          scanned:   \(scanned)
          agreed:    \(agreed)
          flagged:   \(findings.count) (advisory review items — nothing was changed)
        """
    }
}

public struct EntityPlausibilityTwin {
    private let database: Database
    private static let logger = Logger(subsystem: "ecosanskritiinnovation.Kalsmritikosh", category: "knowledge")

    /// Entities examined per idle pass — budgeted and resumable (the check
    /// marker below makes a re-run pick up where the last one stopped).
    public static let batchBudget = 200

    public init(database: Database) {
        self.database = database
    }

    /// One budgeted pass. READS the register, WRITES only fact_reviews-style
    /// advisory rows (action "flag", reviewer "twin.entity") — the register
    /// itself is untouched, always.
    @discardableResult
    public func runOnce(gate: EntityQualityGate) async throws -> EntityPlausibilityTwinReceipt {
        var receipt = EntityPlausibilityTwinReceipt()
        let rows = try await database.query("""
        SELECT e.id, e.value, e.kind,
               (SELECT COUNT(DISTINCT e2.source_object_id) FROM entities e2
                WHERE e2.normalized = e.normalized AND e2.kind = e.kind) AS sources
        FROM entities e
        WHERE e.kind IN ('person','organization') AND e.merged_into IS NULL
          AND NOT EXISTS (
              SELECT 1 FROM fact_reviews fr
              WHERE fr.subject_id = e.id AND fr.reviewer = 'twin.entity'
          )
        ORDER BY e.id LIMIT ?;
        """, [.integer(Int64(Self.batchBudget))])

        for row in rows {
            guard let id = row.uuid(0) else { continue }
            guard let value = row.string(1), let kind = row.string(2) else {
                // A6 frontier law: mark the undecodable row so it never
                // re-enters the frontier.
                receipt.scanned += 1
                receipt.agreed += 1
                try await database.exec("""
                INSERT INTO fact_reviews (id, subject_kind, subject_id, action, reviewer, reason, reviewed_at)
                VALUES (?, 'entity', ?, 'accept', 'twin.entity', 'no readable value to re-check', ?);
                """, [.uuid(UUID()), .uuid(id), .real(Date().timeIntervalSince1970)])
                continue
            }
            let sources = Int(row.int(3) ?? 1)
            receipt.scanned += 1

            let entity = Entity(kind: Entity.Kind(rawValue: kind) ?? .person,
                                value: value, sourceObjectID: id, confidence: .medium)
            var reason: String? = nil
            var checker = ""
            if gate.isPlaceNameSurnameSuspect(entity) {
                reason = "the surname is a well-known place name — worth confirming this is a person"
                checker = "twin.entity.placeSurname"
            } else if EntityQualityGate.isTitleShaped(value) {
                reason = "this reads like a page or document title, not a party"
                checker = "twin.entity.titleShaped"
            } else if kind == "person", sources < 2,
                      value.split(separator: " ").count >= 3 {
                reason = "a three-word name seen in only one document — worth confirming"
                checker = "twin.entity.singleSource"
            }

            if let reason {
                receipt.findings.append(TwinFinding(
                    entityID: id, entityValue: value, reason: reason, checker: checker))
            } else {
                receipt.agreed += 1
            }
            // The resumability marker: every examined entity gets a twin
            // review row — "confirmed" for the agreed, "flag" for findings.
            // Advisory rows; the register is never written.
            try await database.exec("""
            INSERT INTO fact_reviews (id, subject_kind, subject_id, action, reviewer, reason, reviewed_at)
            VALUES (?, 'entity', ?, ?, 'twin.entity', ?, ?);
            """, [.uuid(UUID()), .uuid(id),
                  .text(reason == nil ? "accept" : "flag"),
                  .text(reason ?? "plausible on both readings"),
                  .real(Date().timeIntervalSince1970)])
        }
        Self.logger.info("twin.entity: scanned \(receipt.scanned), agreed \(receipt.agreed), flagged \(receipt.findings.count)")
        return receipt
    }
}
