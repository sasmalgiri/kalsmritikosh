//
//  CasePhaseArtifactRepository.swift
//  Kalsmritikosh
//
//  PHASE B-2 (v115) — the generic case-phase artifact ledger that makes the
//  last two attestation-only phases machine-observable: the case-scoped Ask
//  records one row per verified answer (a question HASH only — never the
//  question text), and DataLab records one row per prepared dataset. The
//  artifacts themselves live in their own authorities; this ledger only
//  records THAT a phase produced one, so the conformance assessor can
//  observe the phase without a second source of truth for content.
//

import Foundation
import CryptoKit

public actor CasePhaseArtifactRepository {
    private let database: Database

    public init(database: Database) {
        self.database = database
    }

    /// The privacy-preserving digest recorded for an ask artifact — the
    /// question TEXT never persists, only 16 hex chars of its SHA-256.
    public nonisolated static func questionDigest(_ question: String) -> String {
        String(SHA256.hash(data: Data(question.utf8))
            .map { String(format: "%02x", $0) }.joined().prefix(16))
    }

    public enum CasePhaseArtifactError: Error, Equatable {
        /// The named artifact does not exist in its authority — an
        /// observation row must never point at nothing (ninth audit).
        case artifactMissing(UUID)
    }

    @discardableResult
    public func record(caseID: UUID, phase: PersonaJobKind, artifactID: UUID,
                       detail: String, at date: Date) async throws -> UUID {
        // NINTH/TENTH AUDIT — referential truth per phase kind: an
        // observation row must never point at nothing. A dataLab artifact
        // must be a REAL dataset row; an ask artifact must be a REAL answer
        // in the append-only answer ledger with a recorded verifiedFinal
        // lifecycle event (the durable commit). Arbitrary UUIDs are refused.
        switch phase {
        case .dataLab:
            let exists = try await database.query(
                "SELECT 1 FROM workbench_datasets WHERE id = ? LIMIT 1;", [.uuid(artifactID)])
            guard !exists.isEmpty else { throw CasePhaseArtifactError.artifactMissing(artifactID) }
        case .ask:
            let exists = try await database.query("""
            SELECT 1 FROM answer_revision_events
            WHERE answer_id = ? AND state = 'verifiedFinal' LIMIT 1;
            """, [.uuid(artifactID)])
            guard !exists.isEmpty else { throw CasePhaseArtifactError.artifactMissing(artifactID) }
        default:
            break
        }
        let id = UUID()
        try await database.exec("""
        INSERT INTO case_phase_artifacts (id, case_id, phase_kind, artifact_id, detail, created_at)
        VALUES (?, ?, ?, ?, ?, ?);
        """, [.uuid(id), .uuid(caseID), .text(phase.rawValue), .uuid(artifactID),
              .text(detail), .real(date.timeIntervalSince1970)])
        return id
    }

    /// Per-phase artifact counts for a case (the observation input).
    public func phaseCounts(caseID: UUID) async throws -> [(phase: PersonaJobKind, count: Int)] {
        let rows = try await database.query("""
        SELECT phase_kind, COUNT(*) FROM case_phase_artifacts
        WHERE case_id = ? GROUP BY phase_kind;
        """, [.uuid(caseID)])
        return rows.compactMap { r in
            guard let raw = r.string(0), let phase = PersonaJobKind(rawValue: raw),
                  let count = r.int(1) else { return nil }
            return (phase, Int(count))
        }
    }
}
