//
//  InducedSchemaAttemptRepository.swift
//  Kalsmritikosh
//
//  P3.3 — the attempt ledger (schema v132). See the v132 migration comment for
//  why this table exists at all: it is what lets a NON-DETERMINISTIC pass live
//  inside a coordinator whose stated law is "a second run is a no-op by
//  construction". The attempt is this pass's `producer_version`.
//
//  Two jobs, and they are separate on purpose:
//
//  1. `attemptedVersionIDs` is the resume marker. The drain asks it ONCE per
//     run and skips every source version already present, so induction is
//     attempted at most once per version of a file — and a new version of a
//     file is new content, which deserves a fresh attempt.
//
//  2. `record` keeps WHY an attempt produced nothing. A document with no facts
//     is otherwise mute about its own history: never tried, tried with no model
//     available, and tried with every proposal rejected are three completely
//     different facts, and the ledger showed the same empty result for all
//     three.
//

import Foundation
import os

public struct InducedSchemaAttempt: Sendable, Equatable {
    public let sourceVersionID: UUID
    public let knowledgeObjectID: UUID?
    public let attemptedAt: Date
    public let fieldsWritten: Int
    /// nil when the attempt SUCCEEDED. Never both nil and zero fields — that
    /// combination is the unexplained emptiness this table exists to prevent.
    public let declineReason: String?
    public let rejectedNotFound: Int
    public let rejectedReserved: Int
    public let rejectedOther: Int

    public nonisolated init(
        sourceVersionID: UUID,
        knowledgeObjectID: UUID?,
        attemptedAt: Date = Date(),
        fieldsWritten: Int,
        declineReason: String?,
        rejectedNotFound: Int = 0,
        rejectedReserved: Int = 0,
        rejectedOther: Int = 0
    ) {
        self.sourceVersionID = sourceVersionID
        self.knowledgeObjectID = knowledgeObjectID
        self.attemptedAt = attemptedAt
        self.fieldsWritten = fieldsWritten
        self.declineReason = declineReason.map { String($0.prefix(Self.maximumReasonLength)) }
        self.rejectedNotFound = rejectedNotFound
        self.rejectedReserved = rejectedReserved
        self.rejectedOther = rejectedOther
    }

    public nonisolated static let maximumReasonLength = 300
}

public actor InducedSchemaAttemptRepository {
    private let database: Database

    public init(database: Database) {
        self.database = database
    }

    /// Every source version induction has already been attempted for.
    ///
    /// Read once per drain rather than queried per document: the set is small
    /// (one row per attempted version, and only zero-fact documents are ever
    /// attempted) and a per-document round trip inside the drain loop would be
    /// the dominant cost of a pass that is supposed to be cheap when idle.
    public func attemptedVersionIDs() async -> Set<UUID> {
        do {
            let rows = try await database.query(
                "SELECT source_version_id FROM induced_schema_attempts;", [])
            var out = Set<UUID>()
            for r in rows {
                if let s = r.string(0), let id = UUID(uuidString: s) { out.insert(id) }
            }
            return out
        } catch {
            // Returning an empty set here would mean "nothing has been
            // attempted", which would re-attempt the whole archive and pay
            // every model call again. Returning the error to the caller is not
            // an option either — the drain's other passes must still run. So
            // the failure is logged and the caller is told nothing is known, via
            // `attemptsReadable`, and it then SKIPS induction for that run
            // rather than guessing.
            KalsmritikoshLog.storage.error(
                "InducedSchemaAttemptRepository: attempt read failed — \(String(describing: error), privacy: .public)")
            attemptsReadable = false
            return []
        }
    }

    /// False when the last `attemptedVersionIDs` call failed. The drain refuses
    /// to induce in that case: without the marker there is no idempotence, and
    /// re-running a non-deterministic writer blind is worse than skipping it.
    public private(set) var attemptsReadable = true

    /// Record an attempt. **Never throws** — the same reasoning as
    /// `DerivationFailureRepository.record`: a bookkeeping write that can fail
    /// loudly would turn a tolerated outcome into a failed drain.
    ///
    /// NOT gated on the module flag. The module decides whether induction RUNS;
    /// once it has run, the attempt is a historical fact and suppressing the
    /// record would make the pass non-idempotent the moment the switch moved.
    public func record(_ attempt: InducedSchemaAttempt) async {
        do {
            try await database.exec("""
            INSERT OR REPLACE INTO induced_schema_attempts
                (source_version_id, knowledge_object_id, attempted_at,
                 fields_written, decline_reason, rejected_not_found,
                 rejected_reserved, rejected_other)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?);
            """, [
                .uuid(attempt.sourceVersionID),
                attempt.knowledgeObjectID.map { SQLValue.uuid($0) } ?? .null,
                .date(attempt.attemptedAt),
                .integer(Int64(attempt.fieldsWritten)),
                attempt.declineReason.map { SQLValue.text($0) } ?? .null,
                .integer(Int64(attempt.rejectedNotFound)),
                .integer(Int64(attempt.rejectedReserved)),
                .integer(Int64(attempt.rejectedOther)),
            ])
        } catch {
            KalsmritikoshLog.storage.error(
                "InducedSchemaAttemptRepository: record failed — \(String(describing: error), privacy: .public)")
        }
    }

    /// Counts for the Ingestion Report (P4).
    public func summary() async -> (attempted: Int, produced: Int, declined: Int) {
        do {
            let rows = try await database.query("""
            SELECT COUNT(*),
                   SUM(CASE WHEN fields_written > 0 THEN 1 ELSE 0 END),
                   SUM(CASE WHEN fields_written = 0 THEN 1 ELSE 0 END)
            FROM induced_schema_attempts;
            """, [])
            guard let r = rows.first else { return (0, 0, 0) }
            return (Int(r.int(0) ?? 0), Int(r.int(1) ?? 0), Int(r.int(2) ?? 0))
        } catch {
            KalsmritikoshLog.storage.error(
                "InducedSchemaAttemptRepository: summary failed — \(String(describing: error), privacy: .public)")
            return (0, 0, 0)
        }
    }
}
