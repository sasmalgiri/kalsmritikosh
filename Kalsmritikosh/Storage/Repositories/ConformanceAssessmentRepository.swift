//
//  ConformanceAssessmentRepository.swift
//  Kalsmritikosh
//
//  Conformance roadmap 1.0.x-A — Level 1 persistence (v107). Each recorded
//  assessment is one append-only row carrying the FROZEN Sutra snapshot
//  (canonical JSON + SHA-256), every rule evaluation, the fail-closed status,
//  and the optional signed seal. Old runs reopen against their stored
//  snapshot — never against the live SutraCompiler value. Recording again
//  inserts a new revision; nothing is updated in place.
//

import Foundation

/// A recorded assessment as stored: the assessment value plus its identity row.
public nonisolated struct StoredConformanceAssessment: Sendable, Identifiable {
    public let id: UUID
    public let caseID: UUID
    public let runRevision: Int
    public let assessment: ConformanceAssessment
    public let seal: SealedConformance?
    public let createdAt: Date

    public init(id: UUID = UUID(), caseID: UUID, runRevision: Int,
                assessment: ConformanceAssessment, seal: SealedConformance?, createdAt: Date) {
        self.id = id; self.caseID = caseID; self.runRevision = runRevision
        self.assessment = assessment; self.seal = seal; self.createdAt = createdAt
    }
}

public actor ConformanceAssessmentRepository {
    private let database: Database

    public init(database: Database) {
        self.database = database
    }

    /// Append a recorded assessment (new revision = 1 + latest stored for the case).
    /// Returns the stored record including its assigned revision.
    @discardableResult
    public func record(caseID: UUID, assessment: ConformanceAssessment,
                       seal: SealedConformance?, at now: Date) async throws -> StoredConformanceAssessment {
        let evaluationsJSON = String(data: try ConformanceCanonical.data(of: assessment.evaluations), encoding: .utf8) ?? "[]"
        let sealJSON = try seal.map { String(data: try ConformanceCanonical.data(of: $0), encoding: .utf8) ?? "" }
        let factsJSON = try assessment.facts.map {
            String(data: try ConformanceCanonical.data(of: $0), encoding: .utf8) ?? ""
        }
        let revision = try await latestRevision(caseID: caseID) + 1
        let record = StoredConformanceAssessment(caseID: caseID, runRevision: revision,
                                                 assessment: assessment, seal: seal, createdAt: now)
        try await database.exec("""
        INSERT INTO conformance_assessments
            (id, case_id, run_revision, sutra_citation, sutra_sha256, sutra_snapshot_json,
             evaluations_json, status, seal_json, assessed_at, created_at,
             run_id, run_state_sha256, facts_json)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """, [
            .uuid(record.id),
            .uuid(caseID),
            .integer(Int64(revision)),
            .text(assessment.sutraCitation),
            .text(assessment.sutraSHA256),
            .text(assessment.sutraSnapshotJSON),
            .text(evaluationsJSON),
            .text(assessment.status.rawValue),
            .optionalText(sealJSON),
            .date(assessment.assessedAt),
            .date(now),
            assessment.runID.map { SQLValue.uuid($0) } ?? .null,
            .optionalText(assessment.runStateSHA256),
            .optionalText(factsJSON)
        ])
        return record
    }

    /// The most recently recorded assessment for a case, decoded against its
    /// OWN stored snapshot — the reopen path for old runs.
    public func latest(caseID: UUID) async throws -> StoredConformanceAssessment? {
        let rows = try await database.query("""
        SELECT id, run_revision, sutra_citation, sutra_sha256, sutra_snapshot_json,
               evaluations_json, seal_json, assessed_at, created_at,
               run_id, run_state_sha256, facts_json
        FROM conformance_assessments WHERE case_id = ?
        ORDER BY created_at DESC, run_revision DESC LIMIT 1;
        """, [.uuid(caseID)])
        guard let r = rows.first else { return nil }
        return try Self.decode(row: r, caseID: caseID)
    }

    /// Every recorded assessment for a case, oldest first (the audit trail).
    public func list(caseID: UUID) async throws -> [StoredConformanceAssessment] {
        let rows = try await database.query("""
        SELECT id, run_revision, sutra_citation, sutra_sha256, sutra_snapshot_json,
               evaluations_json, seal_json, assessed_at, created_at,
               run_id, run_state_sha256, facts_json
        FROM conformance_assessments WHERE case_id = ?
        ORDER BY created_at ASC, run_revision ASC;
        """, [.uuid(caseID)])
        return try rows.map { try Self.decode(row: $0, caseID: caseID) }
    }

    private func latestRevision(caseID: UUID) async throws -> Int {
        let rows = try await database.query(
            "SELECT COALESCE(MAX(run_revision), 0) FROM conformance_assessments WHERE case_id = ?;",
            [.uuid(caseID)])
        return Int(rows.first?.int(0) ?? 0)
    }

    private nonisolated static func decode(row r: SQLRow, caseID: UUID) throws -> StoredConformanceAssessment {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let evaluations = try decoder.decode([RuleEvaluation].self,
                                             from: Data((r.string(5) ?? "[]").utf8))
        let seal: SealedConformance? = try r.string(6).map {
            try decoder.decode(SealedConformance.self, from: Data($0.utf8))
        }
        var assessment = ConformanceAssessment(
            sutraCitation: r.string(2) ?? "",
            sutraSnapshotJSON: r.string(4) ?? "",
            sutraSHA256: r.string(3) ?? "",
            evaluations: evaluations,
            assessedAt: r.date(7) ?? Date(timeIntervalSince1970: 0))
        assessment.runID = r.uuid(9)
        assessment.runStateSHA256 = r.string(10)
        assessment.facts = r.string(11).flatMap {
            try? decoder.decode(ConformanceFacts.self, from: Data($0.utf8))
        }
        return StoredConformanceAssessment(
            id: r.uuid(0) ?? UUID(),
            caseID: caseID,
            runRevision: Int(r.int(1) ?? 1),
            assessment: assessment,
            seal: seal,
            createdAt: r.date(8) ?? Date(timeIntervalSince1970: 0))
    }
}
