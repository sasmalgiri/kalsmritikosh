//
//  SourceReliabilityAssessmentRepository.swift
//  Kalsmritikosh
//
//  OPS-006 — persistence layer for source_reliability_assessments (v74).
//
//  Guarantees:
//  • assess() is SAVEPOINT-atomic: supersede all active rows then insert the new one.
//  • Reassessment is append-only: the prior row's superseded_by_id is set to the new ID;
//    the prior row is never deleted. Full history is always recoverable.
//  • Canonical source_versions rows are never created, modified, or deleted by this repo.
//  • deleteAssessments() removes all assessment rows for a source version (workflow cleanup);
//    source_versions rows are never touched.
//

import Foundation
import OSLog

public actor SourceReliabilityAssessmentRepository {
    private let database: Database

    public init(database: Database) { self.database = database }

    // MARK: - Write

    /// Create (or supersede-and-replace) the reliability assessment for `sourceVersionID`.
    /// If an active (non-superseded) assessment already exists for this source version,
    /// it is linked forward to the new row via superseded_by_id within the same SAVEPOINT.
    @discardableResult
    public func assess(
        sourceVersionID: UUID,
        reliability: ReliabilityRating,
        independence: IndependenceStatus,
        rationale: String? = nil,
        assessedBy: String? = nil,
        at date: Date = Date()
    ) async throws -> SourceReliabilityAssessment {
        let newID = UUID()
        let sp = "sra_\(newID.uuidString.replacingOccurrences(of: "-", with: ""))"
        do {
            try await database.exec("SAVEPOINT \(sp);")
            // Forward any currently active assessments to the new row.
            try await database.exec("""
            UPDATE source_reliability_assessments
               SET superseded_by_id = ?
             WHERE source_version_id = ? AND superseded_by_id IS NULL;
            """, [.text(newID.uuidString), .text(sourceVersionID.uuidString)])
            // Insert the new active assessment.
            try await database.exec("""
            INSERT INTO source_reliability_assessments
                (id, source_version_id, reliability, independence,
                 rationale, assessed_by, assessed_at, created_at, superseded_by_id)
            VALUES (?,?,?,?,?,?,?,?,NULL);
            """, [
                .text(newID.uuidString),
                .text(sourceVersionID.uuidString),
                .text(reliability.rawValue),
                .text(independence.rawValue),
                rationale.map { .text($0) } ?? .null,
                assessedBy.map { .text($0) } ?? .null,
                .real(date.timeIntervalSince1970),
                .real(date.timeIntervalSince1970)
            ])
            try await database.exec("RELEASE \(sp);")
            KalsmritikoshLog.storage.debug(
                "SourceReliabilityAssessmentRepository: assessed \(sourceVersionID, privacy: .public)")
        } catch {
            try? await database.exec("ROLLBACK TO \(sp);")
            try? await database.exec("RELEASE \(sp);")
            KalsmritikoshLog.storage.error(
                "SourceReliabilityAssessmentRepository assess failed: \(String(describing: error), privacy: .public)")
            throw error
        }
        return SourceReliabilityAssessment(
            id:              newID,
            sourceVersionID: sourceVersionID,
            reliability:     reliability,
            independence:    independence,
            rationale:       rationale,
            assessedBy:      assessedBy,
            assessedAt:      date,
            createdAt:       date,
            supersededByID:  nil
        )
    }

    /// Delete all assessment rows for the given source version.
    /// Source_versions rows are never touched.
    public func deleteAssessments(forSourceVersion svID: UUID) async throws {
        try await database.exec(
            "DELETE FROM source_reliability_assessments WHERE source_version_id = ?;",
            [.text(svID.uuidString)])
    }

    // MARK: - Read

    /// The current (non-superseded) assessment for a source version, or nil if none exists.
    public func effective(forSourceVersion svID: UUID) async throws -> SourceReliabilityAssessment? {
        let rows = try await database.query("""
        SELECT id, source_version_id, reliability, independence,
               rationale, assessed_by, assessed_at, created_at, superseded_by_id
          FROM source_reliability_assessments
         WHERE source_version_id = ? AND superseded_by_id IS NULL
         ORDER BY created_at DESC
         LIMIT 1;
        """, [.text(svID.uuidString)])
        return rows.compactMap { decodeRow($0) }.first
    }

    /// Full assessment history for a source version, oldest first.
    public func history(forSourceVersion svID: UUID) async throws -> [SourceReliabilityAssessment] {
        let rows = try await database.query("""
        SELECT id, source_version_id, reliability, independence,
               rationale, assessed_by, assessed_at, created_at, superseded_by_id
          FROM source_reliability_assessments
         WHERE source_version_id = ?
         ORDER BY created_at ASC, rowid ASC;
        """, [.text(svID.uuidString)])
        return rows.compactMap { decodeRow($0) }
    }

    /// Batch lookup: returns the effective (active) assessment keyed by source version ID.
    /// Source versions with no assessment are absent from the result.
    public func assessments(
        forSourceVersionIDs svIDs: [UUID]
    ) async throws -> [UUID: SourceReliabilityAssessment] {
        guard !svIDs.isEmpty else { return [:] }
        let placeholders = svIDs.map { _ in "?" }.joined(separator: ",")
        let bindings: [SQLValue] = svIDs.map { .text($0.uuidString) }
        let rows = try await database.query("""
        SELECT id, source_version_id, reliability, independence,
               rationale, assessed_by, assessed_at, created_at, superseded_by_id
          FROM source_reliability_assessments
         WHERE source_version_id IN (\(placeholders))
           AND superseded_by_id IS NULL;
        """, bindings)
        var result: [UUID: SourceReliabilityAssessment] = [:]
        for row in rows {
            if let a = decodeRow(row) { result[a.sourceVersionID] = a }
        }
        return result
    }

    /// Count of all assessment rows (including superseded) for a source version.
    public func count(forSourceVersion svID: UUID) async throws -> Int {
        let rows = try await database.query(
            "SELECT COUNT(*) FROM source_reliability_assessments WHERE source_version_id = ?;",
            [.text(svID.uuidString)])
        return Int(rows.first?.int(0) ?? 0)
    }

    // MARK: - Row decoder

    private func decodeRow(_ row: SQLRow) -> SourceReliabilityAssessment? {
        guard let id      = row.uuid(0),
              let svID    = row.uuid(1),
              let relStr  = row.string(2),
              let rel     = ReliabilityRating(rawValue: relStr),
              let indStr  = row.string(3),
              let ind     = IndependenceStatus(rawValue: indStr) else { return nil }
        let rationale   = row.string(4)
        let assessedBy  = row.string(5)
        let assessedAt  = row.date(6) ?? Date()
        let createdAt   = row.date(7) ?? Date()
        let supersededBy = row.uuid(8)
        return SourceReliabilityAssessment(
            id:              id,
            sourceVersionID: svID,
            reliability:     rel,
            independence:    ind,
            rationale:       rationale,
            assessedBy:      assessedBy,
            assessedAt:      assessedAt,
            createdAt:       createdAt,
            supersededByID:  supersededBy
        )
    }
}
