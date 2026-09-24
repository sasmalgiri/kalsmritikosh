//
//  DerivationFailureRepository.swift
//  Kalsmritikosh
//
//  P1.2 — where a TOLERATED ingest failure goes, so it stops being silent.
//
//  WHY THIS EXISTS. The ingest path carried 11 `try? await <persist>` sites.
//  Each converted a real database or extractor failure into an absence: the row
//  simply was not there afterwards, which reads exactly like "there was nothing
//  to write". Three of those absences are actively misleading in a tool whose
//  product is evidence:
//
//    - a ZIP member / iOS-backup file / email attachment that failed to ingest
//      looked identical to one that was never in the container;
//    - a chunk whose embedding failed looked identical to one not yet drained,
//      so coverage could never be honest about failed vs pending;
//    - a block that failed to link to its KnowledgeObject produced facts citing
//      evidence that cannot resolve — the claim-evidence contract, broken
//      quietly.
//
//  THE SPLIT THIS ENFORCES. A failure is one of two kinds, and they must not be
//  treated alike:
//
//    CORRUPTING  — continuing produces WRONG data (the entity-insert cascade:
//                  an empty canonical mapping makes the next stage write events
//                  whose entity references were never canonicalised). These
//                  PROPAGATE. They are not recorded here, because the unit of
//                  work does not complete at all.
//    LOSSY       — continuing produces LESS data, but nothing false (a
//                  relationship edge, an embedding, one container member).
//                  These record here and carry on, so the Ingestion Report can
//                  state what was lost and why instead of reporting a smaller
//                  number with no explanation.
//
//  Derived and ADVISORY: never sealed, never gates an answer. The no-delete law
//  protects sources and evidence; this is a diagnostic ledger about them.
//

import Foundation
import os

/// One tolerated failure during derivation.
public struct DerivationFailure: Sendable, Equatable {
    public let id: UUID
    /// The producer that failed, as a stable id: "entities.insert",
    /// "evidence.linkBlocks", "embeddings.upsert", "member.ingest", …
    /// Stable because the report groups by it.
    public let stage: String
    /// The error's description. Truncated at the writer — a reason nobody can
    /// read is no better than no reason, and an unbounded error string from a
    /// driver can be enormous.
    public let reason: String
    public let sourceVersionID: UUID?
    public let knowledgeObjectID: UUID?
    /// Kept so the report can group losses BY FORMAT, which is the grouping
    /// that makes a gap actionable: "31 .pdf failed to link blocks" is a
    /// defect, "310 .heic skipped" is by design.
    public let filePath: String?
    public let detectedType: String?
    public let occurredAt: Date

    public nonisolated init(
        id: UUID = UUID(),
        stage: String,
        reason: String,
        sourceVersionID: UUID? = nil,
        knowledgeObjectID: UUID? = nil,
        filePath: String? = nil,
        detectedType: String? = nil,
        occurredAt: Date = Date()
    ) {
        self.id = id
        self.stage = stage
        self.reason = String(reason.prefix(Self.maximumReasonLength))
        self.sourceVersionID = sourceVersionID
        self.knowledgeObjectID = knowledgeObjectID
        self.filePath = filePath
        self.detectedType = detectedType
        self.occurredAt = occurredAt
    }

    /// Long enough to carry a SQLite message plus context, short enough that a
    /// pathological driver string cannot bloat the table.
    public nonisolated static let maximumReasonLength = 500
}

public actor DerivationFailureRepository {
    private let database: Database

    public init(database: Database) {
        self.database = database
    }

    /// Record a tolerated failure. **Never throws.** A failure-recorder that
    /// can itself fail loudly would turn a tolerated loss into a lost ingest —
    /// exactly the cure being worse than the disease. If this cannot write, it
    /// logs and returns; the OSLog line is the last line of defence.
    public func record(_ failure: DerivationFailure) async {
        do {
            try await database.exec("""
            INSERT OR REPLACE INTO derivation_failures
                (id, source_version_id, knowledge_object_id, file_path,
                 detected_type, stage, reason, occurred_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?);
            """, [
                .uuid(failure.id),
                failure.sourceVersionID.map { SQLValue.uuid($0) } ?? .null,
                failure.knowledgeObjectID.map { SQLValue.uuid($0) } ?? .null,
                failure.filePath.map { SQLValue.text($0) } ?? .null,
                failure.detectedType.map { SQLValue.text($0) } ?? .null,
                .text(failure.stage),
                .text(failure.reason),
                .real(failure.occurredAt.timeIntervalSince1970)
            ])
        } catch {
            KalsmritikoshLog.ingestion.error(
                "derivation_failures write failed for stage \(failure.stage, privacy: .public): \(String(describing: error), privacy: .public) — original reason: \(failure.reason, privacy: .public)")
        }
    }

    /// Convenience for the call sites: build and record in one step.
    public func record(
        stage: String,
        error: Error,
        sourceVersionID: UUID? = nil,
        knowledgeObjectID: UUID? = nil,
        filePath: String? = nil,
        detectedType: String? = nil
    ) async {
        await record(DerivationFailure(
            stage: stage, reason: String(describing: error),
            sourceVersionID: sourceVersionID, knowledgeObjectID: knowledgeObjectID,
            filePath: filePath, detectedType: detectedType))
    }

    /// Record a failure with no `Error` value — the `try?` sites that discarded
    /// the error before we could see it, and the "returned nil" cases.
    public func record(
        stage: String,
        reason: String,
        sourceVersionID: UUID? = nil,
        knowledgeObjectID: UUID? = nil,
        filePath: String? = nil,
        detectedType: String? = nil
    ) async {
        await record(DerivationFailure(
            stage: stage, reason: reason,
            sourceVersionID: sourceVersionID, knowledgeObjectID: knowledgeObjectID,
            filePath: filePath, detectedType: detectedType))
    }

    // MARK: - Reads (the Ingestion Report's input, P4.2)

    public func count() async throws -> Int {
        Int((try await database.query("SELECT COUNT(*) FROM derivation_failures;", []))
            .first?.int(0) ?? 0)
    }

    /// Failures grouped by (stage, detected_type) — the shape the report needs,
    /// because a loss is only actionable once you know WHICH FORMAT lost it.
    /// Deterministic order: most failures first, then stage, then type.
    public func tally() async throws -> [(stage: String, detectedType: String?, count: Int)] {
        let rows = try await database.query("""
        SELECT stage, detected_type, COUNT(*) AS n
        FROM derivation_failures
        GROUP BY stage, detected_type
        ORDER BY n DESC, stage ASC, detected_type ASC;
        """, [])
        return rows.compactMap { r in
            guard let stage = r.string(0) else { return nil }
            return (stage: stage, detectedType: r.string(1), count: Int(r.int(2) ?? 0))
        }
    }

    /// A bounded sample of reasons for one stage, so the report can show WHY
    /// rather than only how many. Distinct reasons, most recent first.
    public func reasons(forStage stage: String, limit: Int = 5) async throws -> [String] {
        let rows = try await database.query("""
        SELECT DISTINCT reason FROM derivation_failures
        WHERE stage = ? ORDER BY occurred_at DESC LIMIT ?;
        """, [.text(stage), .integer(Int64(limit))])
        return rows.compactMap { $0.string(0) }
    }

    /// Every failure for one source version — the per-file drill-down.
    public func failures(forSourceVersion id: UUID) async throws -> [DerivationFailure] {
        let rows = try await database.query("""
        SELECT id, source_version_id, knowledge_object_id, file_path,
               detected_type, stage, reason, occurred_at
        FROM derivation_failures WHERE source_version_id = ?
        ORDER BY occurred_at ASC;
        """, [.uuid(id)])
        return rows.compactMap { r in
            guard let fid = r.uuid(0), let stage = r.string(5), let reason = r.string(6)
            else { return nil }
            return DerivationFailure(
                id: fid, stage: stage, reason: reason,
                sourceVersionID: r.uuid(1), knowledgeObjectID: r.uuid(2),
                filePath: r.string(3), detectedType: r.string(4),
                occurredAt: Date(timeIntervalSince1970: r.double(7) ?? 0))
        }
    }

    /// V5-drain style cleanup: this is a DERIVED diagnostic ledger, so clearing
    /// it before a fresh run is legitimate (the no-delete law protects sources
    /// and evidence, not diagnostics about them). Called by erase.
    public func deleteAll() async throws {
        try await database.exec("DELETE FROM derivation_failures;", [])
    }
}
