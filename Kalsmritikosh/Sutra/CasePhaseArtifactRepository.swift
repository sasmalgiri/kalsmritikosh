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
    /// THIRTEENTH AUDIT — the repository resolves the case's CURRENT
    /// authoritative scope ITSELF (case record → resolved authorized
    /// versions → the ONE fingerprinter) over the same single ledger. A
    /// caller-supplied scope is treated as a CLAIM about the state the
    /// artifact was produced under; it is verified against this authority
    /// and refused on mismatch — it can never substitute for it.
    private var authority: (cases: InvestigationCaseRepository, resolver: CaseRetrievalScopeResolver)?

    public init(database: Database) {
        self.database = database
    }

    /// The case's CURRENT authoritative scope state, resolved from the case
    /// record and the live source-version authority — never from a caller.
    /// nil when the case does not exist. (Collaborators are built lazily on
    /// the main actor — their initializers are MainActor-isolated — over the
    /// SAME single Database actor, so there is no second ledger.)
    private func currentAuthoritativeState(caseID: UUID) async throws
        -> (revision: Int, fingerprint: CaseScopeFingerprint)? {
        if authority == nil {
            let db = database
            authority = await MainActor.run {
                (InvestigationCaseRepository(database: db),
                 CaseRetrievalScopeResolver(evidence: EvidenceStore(database: db)))
            }
        }
        guard let authority else { return nil }
        guard let record = try await authority.cases.fetch(caseID: caseID) else { return nil }
        let scope = try await authority.resolver.scope(for: record)
        let fingerprint = CaseScopeFingerprinter.fingerprint(
            caseID: caseID, caseRevision: record.caseHeader.revision, scope: scope)
        return (record.caseHeader.revision, fingerprint)
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
        /// The artifact's recorded ORIGIN is not this case (twelfth audit):
        /// an answer produced under case A (or globally, with no origin) can
        /// never become case-B phase evidence, regardless of binding order.
        case artifactOriginMismatch(artifactID: UUID)
        /// A same-case re-record arrived with a DIFFERENT case state than
        /// the stored binding — bindings are immutable (twelfth audit).
        case bindingStateMismatch(artifactID: UUID)
        /// The caller-resolved scope is not the case's CURRENT authoritative
        /// scope (thirteenth audit): the underlying source-version set moved
        /// (e.g. a logical source gained a newer current version) even though
        /// the case revision did not. Refuse rather than bind stale evidence.
        case caseScopeNotCurrent(supplied: String, current: String)
    }

    @discardableResult
    public func record(caseID: UUID, caseRevision: Int, scope: RetrievalSourceScope,
                       phase: PersonaJobKind, artifactID: UUID,
                       detail: String, at date: Date) async throws -> UUID {
        // TWELFTH AUDIT — the fingerprint is COMPUTED here from the supplied
        // scope with the one shared fingerprinter; callers can no longer
        // hand in an arbitrary well-shaped value.
        let fingerprint = CaseScopeFingerprinter.fingerprint(
            caseID: caseID, caseRevision: caseRevision, scope: scope)
        // ELEVENTH/THIRTEENTH AUDIT — an observation is bound to the EXACT
        // CURRENT case state, established by THIS repository's own authority
        // (never the caller): the case must exist, the supplied revision must
        // be the case's CURRENT revision, and the fingerprint computed from
        // the caller's scope must equal the fingerprint of the case's CURRENT
        // authoritative resolved scope — so a moved source-version set is
        // refused even when the case revision did not change.
        guard let authority = try await currentAuthoritativeState(caseID: caseID) else {
            throw CasePhaseArtifactError.caseNotFound(caseID)
        }
        guard authority.revision == caseRevision else {
            throw CasePhaseArtifactError.caseRevisionStale(supplied: caseRevision, current: authority.revision)
        }
        guard authority.fingerprint == fingerprint else {
            throw CasePhaseArtifactError.caseScopeNotCurrent(
                supplied: fingerprint.value, current: authority.fingerprint.value)
        }
        // NINTH/TENTH/TWELFTH/THIRTEENTH AUDIT — referential truth AND ORIGIN
        // per phase kind. An ask artifact must be a durably committed answer
        // whose origin_scope_id (stamped at CREATION by the producing
        // request) IS this case. A dataLab artifact must be a real dataset
        // whose immutable origin_case_id (v119, stamped at CREATION by the
        // case-scoped DataLab service) IS this case — a workspace-global
        // dataset or another case's dataset is refused regardless of binding
        // order, even within the same workspace.
        switch phase {
        case .dataLab:
            let rows = try await database.query(
                "SELECT origin_case_id FROM workbench_datasets WHERE id = ? LIMIT 1;", [.uuid(artifactID)])
            guard let row = rows.first else {
                throw CasePhaseArtifactError.artifactMissing(artifactID)
            }
            guard row.uuid(0) == caseID else {
                throw CasePhaseArtifactError.artifactOriginMismatch(artifactID: artifactID)
            }
        case .ask:
            let rows = try await database.query("""
            SELECT a.origin_scope_id FROM answers a
            WHERE a.id = ? AND EXISTS (SELECT 1 FROM answer_revision_events e
                                       WHERE e.answer_id = a.id AND e.state = 'verifiedFinal');
            """, [.uuid(artifactID)])
            guard let row = rows.first else {
                throw CasePhaseArtifactError.artifactMissing(artifactID)
            }
            guard row.uuid(0) == caseID else {
                throw CasePhaseArtifactError.artifactOriginMismatch(artifactID: artifactID)
            }
        default:
            break
        }
        // One artifact → one case (backed by UNIQUE(phase_kind, artifact_id)):
        // re-recording the SAME binding is idempotent; a different case is
        // refused; a same-case re-record at a DIFFERENT state is refused
        // (bindings are immutable — twelfth audit).
        let bound = try await database.query("""
        SELECT id, case_id, case_revision, scope_fingerprint FROM case_phase_artifacts
        WHERE phase_kind = ? AND artifact_id = ? LIMIT 1;
        """, [.text(phase.rawValue), .uuid(artifactID)])
        if let row = bound.first, let existingID = row.uuid(0), let boundCase = row.uuid(1) {
            guard boundCase == caseID else {
                throw CasePhaseArtifactError.artifactAlreadyBound(artifactID: artifactID, boundCaseID: boundCase)
            }
            guard row.int(2).map(Int.init) == caseRevision, row.string(3) == fingerprint.value else {
                throw CasePhaseArtifactError.bindingStateMismatch(artifactID: artifactID)
            }
            return existingID
        }
        // ATOMIC insert (twelfth audit): the revision guard rides INSIDE the
        // INSERT, so a case mutation between the checks above and this write
        // cannot bind evidence to a superseded state. Zero rows inserted
        // means the revision moved — report it as staleness.
        let id = UUID()
        try await database.exec("""
        INSERT INTO case_phase_artifacts
            (id, case_id, case_revision, scope_fingerprint, phase_kind, artifact_id, detail, created_at)
        SELECT ?, ?, ?, ?, ?, ?, ?, ?
        WHERE EXISTS (SELECT 1 FROM investigation_cases WHERE id = ? AND revision = ?);
        """, [.uuid(id), .uuid(caseID), .integer(Int64(caseRevision)), .text(fingerprint.value),
              .text(phase.rawValue), .uuid(artifactID),
              .text(detail), .real(date.timeIntervalSince1970),
              .uuid(caseID), .integer(Int64(caseRevision))])
        let inserted = try await database.query("SELECT changes();", []).first?.int(0) ?? 0
        guard inserted == 1 else {
            let now = try await database.query(
                "SELECT revision FROM investigation_cases WHERE id = ? LIMIT 1;", [.uuid(caseID)])
                .first?.int(0).map(Int.init) ?? -1
            throw CasePhaseArtifactError.caseRevisionStale(supplied: caseRevision, current: now)
        }
        return id
    }

    /// Per-phase artifact counts for a case (the observation input).
    /// TWELFTH/THIRTEENTH AUDIT — only bindings matching the case's CURRENT
    /// revision AND CURRENT authoritative scope fingerprint count: evidence
    /// recorded under a superseded scope is stale and no longer
    /// machine-observed (the INV-01-C4 staleness doctrine applied to
    /// conformance) — including when the underlying source-version set moved
    /// without a case-revision bump. The current state is resolved by this
    /// repository's own authority; there is no caller input to get wrong.
    public func phaseCounts(caseID: UUID) async throws -> [(phase: PersonaJobKind, count: Int)] {
        guard let authority = try await currentAuthoritativeState(caseID: caseID) else { return [] }
        let rows = try await database.query("""
        SELECT phase_kind, COUNT(*)
        FROM case_phase_artifacts
        WHERE case_id = ? AND case_revision = ? AND scope_fingerprint = ?
        GROUP BY phase_kind;
        """, [.uuid(caseID), .integer(Int64(authority.revision)), .text(authority.fingerprint.value)])
        return rows.compactMap { r in
            guard let raw = r.string(0), let phase = PersonaJobKind(rawValue: raw),
                  let count = r.int(1) else { return nil }
            return (phase, Int(count))
        }
    }
}
