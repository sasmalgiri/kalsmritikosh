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
        /// The named case does not exist (eleventh audit — FK-backed).
        case caseNotFound(UUID)
        /// The supplied case revision is not the case's CURRENT revision —
        /// the scope changed between producing the artifact and recording
        /// the observation; refuse rather than bind stale evidence.
        case caseRevisionStale(supplied: Int, current: Int)
        /// The artifact is already bound to a DIFFERENT case — one artifact
        /// is phase evidence for exactly one case, never two.
        case artifactAlreadyBound(artifactID: UUID, boundCaseID: UUID)
    }

    @discardableResult
    public func record(caseID: UUID, caseRevision: Int, scopeFingerprint: CaseScopeFingerprint,
                       phase: PersonaJobKind, artifactID: UUID,
                       detail: String, at date: Date) async throws -> UUID {
        // ELEVENTH AUDIT — an observation is bound to the EXACT case state:
        // the case must exist (also FK-enforced), the supplied revision must
        // be the case's CURRENT revision, and the INV-01-C4 scope
        // fingerprint is stored immutably so a later scope change is
        // detectable as staleness. One artifact serves ONE case.
        let caseRows = try await database.query(
            "SELECT revision FROM investigation_cases WHERE id = ? LIMIT 1;", [.uuid(caseID)])
        guard let current = caseRows.first?.int(0) else {
            throw CasePhaseArtifactError.caseNotFound(caseID)
        }
        guard Int(current) == caseRevision else {
            throw CasePhaseArtifactError.caseRevisionStale(supplied: caseRevision, current: Int(current))
        }
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
        // One artifact → one case (backed by UNIQUE(phase_kind, artifact_id)):
        // re-recording for the SAME case is idempotent; for another, refused.
        let bound = try await database.query(
            "SELECT id, case_id FROM case_phase_artifacts WHERE phase_kind = ? AND artifact_id = ? LIMIT 1;",
            [.text(phase.rawValue), .uuid(artifactID)])
        if let row = bound.first, let existingID = row.uuid(0), let boundCase = row.uuid(1) {
            guard boundCase == caseID else {
                throw CasePhaseArtifactError.artifactAlreadyBound(artifactID: artifactID, boundCaseID: boundCase)
            }
            return existingID
        }
        let id = UUID()
        try await database.exec("""
        INSERT INTO case_phase_artifacts
            (id, case_id, case_revision, scope_fingerprint, phase_kind, artifact_id, detail, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?);
        """, [.uuid(id), .uuid(caseID), .integer(Int64(caseRevision)), .text(scopeFingerprint.value),
              .text(phase.rawValue), .uuid(artifactID),
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
