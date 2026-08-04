//
//  InvestigationScopeLedger.swift
//  Kalsmritikosh
//
//  INV-01-C4 — the durable record of which case-scope fingerprint each case-produced artifact was made
//  under (schema v97). It lets a later scope change mark CURRENT surfaces stale WITHOUT rewriting the
//  historical artifact: a recorded row is immutable (UNIQUE(case, kind, artifact); re-recording the same
//  artifact is refused), and staleness is simply "recorded fingerprint ≠ the case's current fingerprint".
//  This ledger references artifacts by soft id and never touches canonical evidence.
//

import Foundation

public nonisolated enum InvestigationScopeArtifactKind: String, Sendable, Codable, Equatable, CaseIterable {
    case ask
    case methodRun
    case workbenchDataset
    case workProduct
}

public nonisolated struct InvestigationScopeArtifact: Sendable, Equatable {
    public let id: UUID
    public let caseID: UUID
    public let kind: InvestigationScopeArtifactKind
    public let artifactID: String
    public let fingerprint: CaseScopeFingerprint
    public let caseRevision: Int
    public let createdAt: Date

    public nonisolated init(id: UUID, caseID: UUID, kind: InvestigationScopeArtifactKind, artifactID: String,
                            fingerprint: CaseScopeFingerprint, caseRevision: Int, createdAt: Date) {
        self.id = id; self.caseID = caseID; self.kind = kind; self.artifactID = artifactID
        self.fingerprint = fingerprint; self.caseRevision = caseRevision; self.createdAt = createdAt
    }
}

public nonisolated enum InvestigationScopeLedgerError: Error, Sendable, Equatable {
    case alreadyRecorded(kind: String, artifactID: String)
    case artifactNotFound(kind: String, artifactID: String)
}

public actor InvestigationScopeLedger {
    private let database: Database

    public init(database: Database) { self.database = database }

    /// Record the scope fingerprint an artifact was produced under. Immutable: re-recording the same
    /// (case, kind, artifact) is refused so a historical artifact keeps its original fingerprint.
    @discardableResult
    public func record(caseID: UUID, kind: InvestigationScopeArtifactKind, artifactID: String,
                       fingerprint: CaseScopeFingerprint, caseRevision: Int, at date: Date) async throws -> InvestigationScopeArtifact {
        let clean = artifactID.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = UUID()
        let sp = savepoint("invscope", id)
        do {
            try await database.exec("SAVEPOINT \(sp);")
            let exists = try await database.query(
                "SELECT 1 FROM investigation_scope_artifacts WHERE case_id = ? AND artifact_kind = ? AND artifact_id = ? LIMIT 1;",
                [.uuid(caseID), .text(kind.rawValue), .text(clean)]).first != nil
            if exists { throw InvestigationScopeLedgerError.alreadyRecorded(kind: kind.rawValue, artifactID: clean) }
            try await database.exec("""
                INSERT INTO investigation_scope_artifacts (id, case_id, artifact_kind, artifact_id, scope_fingerprint, case_revision, created_at)
                VALUES (?,?,?,?,?,?,?);
                """, [.uuid(id), .uuid(caseID), .text(kind.rawValue), .text(clean),
                      .text(fingerprint.value), .integer(Int64(caseRevision)), .date(date)])
            try await database.exec("RELEASE SAVEPOINT \(sp);")
        } catch {
            try? await database.exec("ROLLBACK TO SAVEPOINT \(sp);")
            try? await database.exec("RELEASE SAVEPOINT \(sp);")
            throw error
        }
        return InvestigationScopeArtifact(id: id, caseID: caseID, kind: kind, artifactID: clean,
                                          fingerprint: fingerprint, caseRevision: caseRevision, createdAt: date)
    }

    public func artifact(caseID: UUID, kind: InvestigationScopeArtifactKind, artifactID: String) async throws -> InvestigationScopeArtifact? {
        let rows = try await database.query("""
            SELECT id, case_id, artifact_kind, artifact_id, scope_fingerprint, case_revision, created_at
            FROM investigation_scope_artifacts WHERE case_id = ? AND artifact_kind = ? AND artifact_id = ? LIMIT 1;
            """, [.uuid(caseID), .text(kind.rawValue), .text(artifactID.trimmingCharacters(in: .whitespacesAndNewlines))])
        return rows.first.flatMap(decode)
    }

    public func artifacts(caseID: UUID) async throws -> [InvestigationScopeArtifact] {
        let rows = try await database.query("""
            SELECT id, case_id, artifact_kind, artifact_id, scope_fingerprint, case_revision, created_at
            FROM investigation_scope_artifacts WHERE case_id = ? ORDER BY created_at ASC, artifact_id ASC;
            """, [.uuid(caseID)])
        return rows.compactMap(decode)
    }

    /// An artifact is STALE iff the fingerprint it was recorded under differs from the case's current
    /// fingerprint. A never-recorded artifact throws — staleness is only meaningful for a recorded one.
    public func isStale(caseID: UUID, kind: InvestigationScopeArtifactKind, artifactID: String,
                        currentFingerprint: CaseScopeFingerprint) async throws -> Bool {
        guard let recorded = try await artifact(caseID: caseID, kind: kind, artifactID: artifactID) else {
            throw InvestigationScopeLedgerError.artifactNotFound(kind: kind.rawValue, artifactID: artifactID)
        }
        return recorded.fingerprint != currentFingerprint
    }

    private nonisolated func decode(_ r: SQLRow) -> InvestigationScopeArtifact? {
        guard let id = r.uuid(0), let caseID = r.uuid(1),
              let kind = r.string(2).flatMap(InvestigationScopeArtifactKind.init(rawValue:)),
              let artifactID = r.string(3), let fp = r.string(4),
              let rev = r.int(5), let createdAt = r.date(6) else { return nil }
        return InvestigationScopeArtifact(id: id, caseID: caseID, kind: kind, artifactID: artifactID,
                                          fingerprint: CaseScopeFingerprint(value: fp), caseRevision: Int(rev), createdAt: createdAt)
    }

    private nonisolated func savepoint(_ prefix: String, _ id: UUID) -> String {
        "\(prefix)_\(id.uuidString.replacingOccurrences(of: "-", with: ""))"
    }
}
