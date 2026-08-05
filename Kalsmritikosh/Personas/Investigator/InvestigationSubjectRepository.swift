//
//  InvestigationSubjectRepository.swift
//  Kalsmritikosh
//
//  INV-02 — the durable authority for investigation subjects (schema v98 `investigation_subjects`). A
//  subject anchors a case to one canonical entity id and carries its identity disposition: PROPOSED when
//  nominated, CONFIRMED only by an explicit human decision (which records the confirmer + timestamp), or
//  REJECTED. Every mutation is one SAVEPOINT with optimistic revision CAS, so a subject survives relaunch
//  and its confirmation is provable. This actor REFERENCES a canonical entity by id — it never copies or
//  mutates the canonical row.
//

import Foundation

public actor InvestigationSubjectRepository {
    private let database: Database

    public init(database: Database) { self.database = database }

    // MARK: - Nominate (proposed)

    /// Nominate a canonical entity as a subject of a case. The subject starts PROPOSED (revision 1); a
    /// human must later confirm the identity. Fails if the case is missing/closed, the label/actor is
    /// blank, or the entity is already a subject of this case.
    public func createSubject(caseID: UUID, canonicalEntityID: UUID, label: String,
                              actor: String, at date: Date) async throws -> InvestigationSubject {
        let cleanLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanLabel.isEmpty else { throw InvestigationSubjectError.blankLabel }
        let cleanActor = try validatedActor(actor)
        try await requireOpenCase(caseID)
        let exists = try await database.query(
            "SELECT 1 FROM investigation_subjects WHERE case_id = ? AND canonical_entity_id = ? LIMIT 1;",
            [.uuid(caseID), .uuid(canonicalEntityID)]).first != nil
        if exists { throw InvestigationSubjectError.subjectAlreadyExists(caseID: caseID, entityID: canonicalEntityID) }

        let id = UUID()
        let sp = savepoint("invsubj", id)
        do {
            try await database.exec("SAVEPOINT \(sp);")
            try await database.exec("""
                INSERT INTO investigation_subjects (id, case_id, canonical_entity_id, label, identity_status,
                    confirmed_by, confirmed_at, revision, actor, created_at, updated_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?);
                """, [.uuid(id), .uuid(caseID), .uuid(canonicalEntityID), .text(cleanLabel),
                      .text(SubjectIdentityStatus.proposed.rawValue), .null, .null, .integer(1),
                      .text(cleanActor), .date(date), .date(date)])
            try await database.exec("RELEASE SAVEPOINT \(sp);")
        } catch {
            try? await database.exec("ROLLBACK TO SAVEPOINT \(sp);")
            try? await database.exec("RELEASE SAVEPOINT \(sp);")
            throw error
        }
        return try await requireSubject(id)
    }

    // MARK: - Human identity decision (proposed → confirmed / rejected)

    /// Confirm a subject's identity — the human decision INV-02 records. Only a PROPOSED subject can be
    /// confirmed; the confirmer + timestamp are stamped. Optimistic CAS on `expectedRevision`.
    public func confirmIdentity(subjectID: UUID, expectedRevision: Int, actor: String, at date: Date) async throws -> InvestigationSubject {
        try await transition(subjectID: subjectID, expectedRevision: expectedRevision, to: .confirmed,
                             confirmer: actor, actor: actor, at: date)
    }

    /// Reject a subject's proposed identity (recorded, not deleted). Only a PROPOSED subject can be rejected.
    public func rejectIdentity(subjectID: UUID, expectedRevision: Int, actor: String, at date: Date) async throws -> InvestigationSubject {
        try await transition(subjectID: subjectID, expectedRevision: expectedRevision, to: .rejected,
                             confirmer: nil, actor: actor, at: date)
    }

    private func transition(subjectID: UUID, expectedRevision: Int, to status: SubjectIdentityStatus,
                            confirmer: String?, actor: String, at date: Date) async throws -> InvestigationSubject {
        let cleanActor = try validatedActor(actor)
        let sp = savepoint("invsubjt", subjectID)
        do {
            try await database.exec("SAVEPOINT \(sp);")
            let current = try await requireSubject(subjectID)
            guard current.revision == expectedRevision else {
                throw InvestigationSubjectError.revisionConflict(expected: expectedRevision, actual: current.revision)
            }
            guard current.identityStatus == .proposed else { throw InvestigationSubjectError.notProposed(subjectID) }
            let newRevision = current.revision + 1
            let confirmedBy: SQLValue = confirmer.map { .text($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? .null
            let confirmedAt: SQLValue = confirmer != nil ? .date(date) : .null
            try await database.exec("""
                UPDATE investigation_subjects SET identity_status = ?, confirmed_by = ?, confirmed_at = ?,
                    revision = ?, actor = ?, updated_at = ? WHERE id = ? AND revision = ?;
                """, [.text(status.rawValue), confirmedBy, confirmedAt, .integer(Int64(newRevision)),
                      .text(cleanActor), .date(date), .uuid(subjectID), .integer(Int64(current.revision))])
            try await database.exec("RELEASE SAVEPOINT \(sp);")
        } catch {
            try? await database.exec("ROLLBACK TO SAVEPOINT \(sp);")
            try? await database.exec("RELEASE SAVEPOINT \(sp);")
            throw error
        }
        return try await requireSubject(subjectID)
    }

    // MARK: - Read / resume

    public func fetch(subjectID: UUID) async throws -> InvestigationSubject? {
        let rows = try await database.query("\(subjectSelect) WHERE id = ? LIMIT 1;", [.uuid(subjectID)])
        return rows.first.flatMap(decode)
    }

    public func subject(caseID: UUID, canonicalEntityID: UUID) async throws -> InvestigationSubject? {
        let rows = try await database.query(
            "\(subjectSelect) WHERE case_id = ? AND canonical_entity_id = ? LIMIT 1;",
            [.uuid(caseID), .uuid(canonicalEntityID)])
        return rows.first.flatMap(decode)
    }

    /// All subjects of a case, oldest first.
    public func subjects(caseID: UUID) async throws -> [InvestigationSubject] {
        let rows = try await database.query(
            "\(subjectSelect) WHERE case_id = ? ORDER BY created_at ASC, id ASC;", [.uuid(caseID)])
        return rows.compactMap(decode)
    }

    // MARK: - Internals

    private let subjectSelect = """
        SELECT id, case_id, canonical_entity_id, label, identity_status, confirmed_by, confirmed_at,
               revision, actor, created_at, updated_at
        FROM investigation_subjects
        """

    private func requireSubject(_ subjectID: UUID) async throws -> InvestigationSubject {
        guard let s = try await fetch(subjectID: subjectID) else { throw InvestigationSubjectError.subjectNotFound(subjectID) }
        return s
    }

    private func requireOpenCase(_ caseID: UUID) async throws {
        let rows = try await database.query("SELECT status FROM investigation_cases WHERE id = ? LIMIT 1;", [.uuid(caseID)])
        guard let status = rows.first?.string(0) else { throw InvestigationSubjectError.caseNotFound(caseID) }
        if status == InvestigationCaseStatus.closed.rawValue { throw InvestigationSubjectError.caseClosed(caseID) }
    }

    private nonisolated func decode(_ r: SQLRow) -> InvestigationSubject? {
        guard let id = r.uuid(0), let caseID = r.uuid(1), let entityID = r.uuid(2), let label = r.string(3),
              let status = r.string(4).flatMap(SubjectIdentityStatus.init(rawValue:)),
              let revision = r.int(7), let actor = r.string(8),
              let createdAt = r.date(9), let updatedAt = r.date(10) else { return nil }
        return InvestigationSubject(id: id, caseID: caseID, canonicalEntityID: entityID, label: label,
                                    identityStatus: status, confirmedBy: r.string(5), confirmedAt: r.date(6),
                                    revision: Int(revision), actor: actor, createdAt: createdAt, updatedAt: updatedAt)
    }

    private nonisolated func validatedActor(_ actor: String) throws -> String {
        let clean = actor.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw InvestigationSubjectError.blankActor }
        return clean
    }

    private nonisolated func savepoint(_ prefix: String, _ id: UUID) -> String {
        "\(prefix)_\(id.uuidString.replacingOccurrences(of: "-", with: ""))"
    }
}
