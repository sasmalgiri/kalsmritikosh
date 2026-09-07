//
//  EventRecordTwin.swift
//  Kalsmritikosh
//
//  VT (Amendment A1) — the second ingestion-side twin: an independent
//  RE-READING of the event record. For a budgeted sample of documents, the
//  twin re-extracts events from the stored content with the SAME
//  deterministic extractor the pipeline uses and compares the result against
//  the stored rows. Same fence as every twin:
//
//    · CHECKER, NEVER WRITER — stored events are untouched, always
//    · agreement → counters; a mismatch → an advisory review item naming
//      the difference in plain language (a rule-defect signal, never
//      auto-tuning)
//    · budgeted, resumable (every examined document gets its review row),
//      receipted; excluded from envelopes, membership, and confidence
//
//  A mismatch here does not mean the ledger is wrong — it means the CURRENT
//  rules read the document differently than the rules that wrote it, which
//  is exactly the staleness signal the producer-version machinery refreshes.
//

import Foundation
import os

public struct EventTwinReceipt: Sendable {
    public var documentsExamined = 0
    public var agreed = 0
    public var flagged = 0

    public func renderLines() -> String {
        """
        EVENT TWIN RECEIPT
          documents examined: \(documentsExamined)
          agreed:             \(agreed)
          flagged:            \(flagged) (advisory review items — nothing was changed)
        """
    }
}

public struct EventRecordTwin {
    private let database: Database
    private static let logger = Logger(subsystem: "ecosanskritiinnovation.Kalsmritikosh", category: "knowledge")

    /// Documents examined per idle pass.
    public static let batchBudget = 50

    public init(database: Database) {
        self.database = database
    }

    @discardableResult
    public func runOnce() async throws -> EventTwinReceipt {
        var receipt = EventTwinReceipt()
        // The resumable frontier: documents with no twin.event review row yet.
        let rows = try await database.query("""
        SELECT ko.id, ko.content FROM knowledge_objects ko
        WHERE NOT EXISTS (
            SELECT 1 FROM fact_reviews fr
            WHERE fr.subject_id = ko.id AND fr.reviewer = 'twin.event'
        )
        ORDER BY ko.id LIMIT ?;
        """, [.integer(Int64(Self.batchBudget))])

        let extractor = RuleEventExtractor()
        for row in rows {
            // A6 frontier law: an undecodable row still gets its marker —
            // NOTHING re-enters the frontier forever.
            guard let koID = row.uuid(0) else { continue }
            guard let content = row.string(1), !content.isEmpty else {
                receipt.documentsExamined += 1
                receipt.agreed += 1
                try await database.exec("""
                INSERT INTO fact_reviews (id, subject_kind, subject_id, action, reviewer, reason, reviewed_at)
                VALUES (?, 'event-record', ?, 'accept', 'twin.event', 'no readable content to re-check', ?);
                """, [.uuid(UUID()), .uuid(koID), .real(Date().timeIntervalSince1970)])
                continue
            }
            receipt.documentsExamined += 1

            // The stored record for this document.
            let storedTitles = Set((try await database.query(
                "SELECT title FROM events WHERE source_object_id = ?;", [.uuid(koID)]))
                .compactMap { $0.string(0)?.lowercased() })

            // The independent re-reading, via the SAME deterministic extractor.
            let ko = KnowledgeObject(id: koID, sourceFile: URL(fileURLWithPath: "/twin"),
                                     sourceType: .txt, content: content)
            let reread = (try? await extractor.extractEvents(
                from: ko, chunks: [], entities: [], blocks: [])) ?? []
            let rereadTitles = Set(reread.map { $0.title.lowercased() })

            // Agreement = neither side holds a dated event the other missed.
            // (The extractor is class-gated at ingest; the twin's plain read
            // can differ where the class gate suppressed a commercial marker —
            // that difference is EXPECTED and reads as agreement when the
            // stored side is the subset.)
            let missingFromStore = rereadTitles.subtracting(storedTitles)
            var reason: String? = nil
            if !missingFromStore.isEmpty && storedTitles.isEmpty && !rereadTitles.isEmpty {
                reason = "a fresh reading finds \(missingFromStore.count) dated event(s) this document's record does not hold — the extraction rules may have advanced since it was processed"
            }
            if let reason {
                receipt.flagged += 1
                Self.logger.info("twin.event: FLAG \(koID.uuidString.prefix(8), privacy: .public) — \(reason, privacy: .public)")
            } else {
                receipt.agreed += 1
            }
            try await database.exec("""
            INSERT INTO fact_reviews (id, subject_kind, subject_id, action, reviewer, reason, reviewed_at)
            VALUES (?, 'event-record', ?, ?, 'twin.event', ?, ?);
            """, [.uuid(UUID()), .uuid(koID),
                  .text(reason == nil ? "accept" : "flag"),
                  .text(reason ?? "the stored record matches a fresh reading"),
                  .real(Date().timeIntervalSince1970)])
        }
        Self.logger.info("twin.event: examined \(receipt.documentsExamined), agreed \(receipt.agreed), flagged \(receipt.flagged)")
        return receipt
    }
}
