//
//  CaseFileRepository.swift
//  Kalsmritikosh
//
//  The durable case file (schema v151). Every write appends a case_actions row inside the SAME
//  savepoint, so the action log can never miss a change (S-4). Nothing is deleted: people, journal
//  entries, exhibits and grid links are retracted with a timestamp and stay in the record.
//

import Foundation
import os

public actor CaseFileRepository {
    private let database: Database

    public init(database: Database) { self.database = database }

    // MARK: - Profile, stage, triage

    /// The case's profile; a case without one yet reads as a fresh intake.
    public func profile(caseID: UUID) async throws -> CaseProfile {
        let rows = try await database.query("\(Self.profileColumns) WHERE case_id = ? LIMIT 1;", [.uuid(caseID)])
        return rows.first.flatMap(Self.decodeProfile) ?? CaseProfile(caseID: caseID, updatedAt: Date())
    }

    public func allProfiles() async throws -> [CaseProfile] {
        (try await database.query("\(Self.profileColumns);")).compactMap(Self.decodeProfile)
    }

    /// Save intake, plan, owner/team, retention and kind. Stage and triage move only through
    /// `moveStage` / `recordTriage`, so their history is in the action log.
    public func saveProfile(_ p: CaseProfile, actor: String, at date: Date = Date()) async throws {
        let actor = try Self.clean(actor, "Actor")
        let current = try await profile(caseID: p.caseID)
        var merged = p
        merged.stage = current.stage
        merged.triage = current.triage
        merged.intake = p.intake.stored
        merged.updatedAt = date
        let row = merged
        try await write("cf_profile", caseID: p.caseID, actor: actor, action: "profileSaved", detail: nil, at: date) { db in
            try Self.upsertProfile(db, row)
        }
    }

    public func moveStage(caseID: UUID, to stage: CaseStage, reason: String?, actor: String, at date: Date = Date()) async throws {
        let actor = try Self.clean(actor, "Actor")
        var p = try await profile(caseID: caseID)
        guard p.stage.next.contains(stage) else { throw CaseFileError.invalidStageMove(from: p.stage, to: stage) }
        let from = p.stage
        p.stage = stage; p.updatedAt = date
        let row = p
        try await write("cf_stage", caseID: caseID, actor: actor, action: "stage",
                        detail: "\(from.label) → \(stage.label)" + (reason.map { ": \($0)" } ?? ""), at: date) { db in
            try Self.upsertProfile(db, row)
        }
    }

    /// Record the triage decision; accept opens the case, decline/refer end it (with the reason).
    public func recordTriage(caseID: UUID, _ triage: CaseTriage, actor: String, at date: Date = Date()) async throws {
        let actor = try Self.clean(actor, "Actor")
        var p = try await profile(caseID: caseID)
        var t = triage
        if let decision = t.decision {
            if decision != .accept { _ = try Self.clean(t.reason ?? "", "The reason for declining or referring") }
            t.decidedBy = actor; t.decidedAt = date
            switch decision {
            case .accept: p.stage = .open
            case .decline: p.stage = .declined
            case .refer: p.stage = .referred
            }
        } else if p.stage == .intake {
            p.stage = .triage
        }
        p.triage = t; p.updatedAt = date
        let row = p
        let detail = [t.severity.map { "severity \($0.label)" }, t.decision.map { "decision \($0.label)" }, t.reason]
            .compactMap { $0 }.joined(separator: "; ")
        try await write("cf_triage", caseID: caseID, actor: actor, action: "triage", detail: detail, at: date) { db in
            try Self.upsertProfile(db, row)
        }
    }

    /// The closure decision (InvestigationClosureRepository) is the authority for closing; the case
    /// file follows it so the caseload shows the right stage.
    public func markClosed(caseID: UUID, reopened: Bool, actor: String, at date: Date = Date()) async throws {
        var p = try await profile(caseID: caseID)
        p.stage = reopened ? .inProgress : .closed; p.updatedAt = date
        let row = p
        try await write("cf_close", caseID: caseID, actor: try Self.clean(actor, "Actor"),
                        action: reopened ? "reopened" : "closed", detail: nil, at: date) { db in
            try Self.upsertProfile(db, row)
        }
    }

    public func archive(caseID: UUID, actor: String, at date: Date = Date()) async throws {
        var p = try await profile(caseID: caseID)
        p.archivedAt = date; p.updatedAt = date
        let row = p
        try await write("cf_archive", caseID: caseID, actor: try Self.clean(actor, "Actor"), action: "archived", detail: nil, at: date) { db in
            try Self.upsertProfile(db, row)
        }
    }

    // MARK: - Allegations + evidence grid

    public func allegations(caseID: UUID) async throws -> [CaseAllegation] {
        (try await database.query("""
            SELECT id, case_id, sequence, text, disposition, rationale, decided_by, decided_at, created_at
            FROM case_allegations WHERE case_id = ? ORDER BY sequence;
            """, [.uuid(caseID)])).compactMap { r in
            guard let id = r.uuid(0), let c = r.uuid(1), let seq = r.int(2), let text = r.string(3),
                  let d = r.string(4).flatMap(AllegationDisposition.init(rawValue:)), let created = r.date(8) else { return nil }
            return CaseAllegation(id: id, caseID: c, sequence: Int(seq), text: text, disposition: d, rationale: r.string(5),
                                  decidedBy: r.string(6), decidedAt: r.date(7), createdAt: created)
        }
    }

    @discardableResult
    public func addAllegation(caseID: UUID, text: String, actor: String, at date: Date = Date()) async throws -> UUID {
        let text = try Self.clean(text, "The allegation")
        let id = UUID()
        try await write("cf_alg", caseID: caseID, actor: try Self.clean(actor, "Actor"), action: "allegationAdded", detail: text, at: date) { db in
            let next = (try db.query("SELECT COALESCE(MAX(sequence), 0) FROM case_allegations WHERE case_id = ?;", [.uuid(caseID)]).first?.int(0) ?? 0) + 1
            try db.exec("INSERT INTO case_allegations (id, case_id, sequence, text, disposition, created_at) VALUES (?,?,?,?, 'pending', ?);",
                        [.uuid(id), .uuid(caseID), .integer(next), .text(text), .date(date)])
        }
        return id
    }

    /// A person records the disposition. Anything but `pending` needs a rationale.
    public func decide(allegationID: UUID, caseID: UUID, disposition: AllegationDisposition, rationale: String?,
                       actor: String, at date: Date = Date()) async throws {
        let actor = try Self.clean(actor, "Actor")
        let why = rationale?.trimmingCharacters(in: .whitespacesAndNewlines)
        if disposition != .pending { _ = try Self.clean(why ?? "", "The rationale") }
        try await write("cf_dec", caseID: caseID, actor: actor, action: "allegationDecided",
                        detail: "\(disposition.label): \(why ?? "")", at: date) { db in
            try db.exec("UPDATE case_allegations SET disposition = ?, rationale = ?, decided_by = ?, decided_at = ? WHERE id = ? AND case_id = ?;",
                        [.text(disposition.rawValue), .optionalText(why), disposition == .pending ? .null : .text(actor),
                         disposition == .pending ? .null : .date(date), .uuid(allegationID), .uuid(caseID)])
        }
    }

    public func allegationEvidence(caseID: UUID) async throws -> [AllegationEvidence] {
        (try await database.query("""
            SELECT e.id, e.allegation_id, e.evidence_ref, e.label, e.stance, e.note, e.added_by, e.created_at
            FROM case_allegation_evidence e JOIN case_allegations a ON a.id = e.allegation_id
            WHERE a.case_id = ? AND e.removed_at IS NULL ORDER BY e.created_at;
            """, [.uuid(caseID)])).compactMap { r in
            guard let id = r.uuid(0), let a = r.uuid(1), let ref = r.string(2),
                  let st = r.string(4).flatMap(GridStance.init(rawValue:)), let by = r.string(6), let at = r.date(7) else { return nil }
            return AllegationEvidence(id: id, allegationID: a, evidenceRef: ref, label: r.string(3), stance: st, note: r.string(5), addedBy: by, createdAt: at)
        }
    }

    public func addAllegationEvidence(caseID: UUID, allegationID: UUID, evidenceRef: String, label: String?, stance: GridStance,
                                      note: String?, actor: String, at date: Date = Date()) async throws {
        let ref = try Self.clean(evidenceRef, "The evidence")
        let actor = try Self.clean(actor, "Actor")
        try await write("cf_grid", caseID: caseID, actor: actor, action: "gridLinked", detail: "\(stance.rawValue) \(label ?? ref)", at: date) { db in
            try db.exec("INSERT INTO case_allegation_evidence (id, allegation_id, evidence_ref, label, stance, note, added_by, created_at) VALUES (?,?,?,?,?,?,?,?);",
                        [.uuid(UUID()), .uuid(allegationID), .text(ref), .optionalText(label), .text(stance.rawValue), .optionalText(note), .text(actor), .date(date)])
        }
    }

    public func retractAllegationEvidence(caseID: UUID, id: UUID, actor: String, at date: Date = Date()) async throws {
        try await write("cf_gridx", caseID: caseID, actor: try Self.clean(actor, "Actor"), action: "gridUnlinked", detail: nil, at: date) { db in
            try db.exec("UPDATE case_allegation_evidence SET removed_at = ? WHERE id = ?;", [.date(date), .uuid(id)])
        }
    }

    // MARK: - Journal + manual chronology

    public func journal(caseID: UUID, kind: CaseJournalKind? = nil) async throws -> [CaseJournalEntry] {
        var sql = "SELECT id, case_id, entry_kind, event_date, text, evidence_ref, author, created_at FROM case_journal WHERE case_id = ? AND removed_at IS NULL"
        var b: [SQLValue] = [.uuid(caseID)]
        if let kind { sql += " AND entry_kind = ?"; b.append(.text(kind.rawValue)) }
        sql += " ORDER BY COALESCE(event_date, created_at), created_at;"
        return (try await database.query(sql, b)).compactMap { r in
            guard let id = r.uuid(0), let c = r.uuid(1), let k = r.string(2).flatMap(CaseJournalKind.init(rawValue:)),
                  let text = r.string(4), let author = r.string(6), let at = r.date(7) else { return nil }
            return CaseJournalEntry(id: id, caseID: c, kind: k, eventDate: r.date(3), text: text, evidenceRef: r.string(5), author: author, createdAt: at)
        }
    }

    @discardableResult
    public func addJournal(caseID: UUID, kind: CaseJournalKind, text: String, eventDate: Date?, evidenceRef: String?,
                           actor: String, at date: Date = Date()) async throws -> UUID {
        let text = try Self.clean(text, kind == .note ? "The note" : "The chronology entry")
        let actor = try Self.clean(actor, "Actor")
        let id = UUID()
        try await write("cf_jr", caseID: caseID, actor: actor, action: kind == .note ? "noteAdded" : "chronologyAdded", detail: text, at: date) { db in
            try db.exec("INSERT INTO case_journal (id, case_id, entry_kind, event_date, text, evidence_ref, author, created_at) VALUES (?,?,?,?,?,?,?,?);",
                        [.uuid(id), .uuid(caseID), .text(kind.rawValue), .optionalDate(eventDate), .text(text), .optionalText(evidenceRef), .text(actor), .date(date)])
        }
        return id
    }

    public func retractJournal(caseID: UUID, id: UUID, actor: String, at date: Date = Date()) async throws {
        try await write("cf_jrx", caseID: caseID, actor: try Self.clean(actor, "Actor"), action: "journalRetracted", detail: nil, at: date) { db in
            try db.exec("UPDATE case_journal SET removed_at = ? WHERE id = ? AND case_id = ?;", [.date(date), .uuid(id), .uuid(caseID)])
        }
    }

    // MARK: - People + contact log

    public func people(caseID: UUID) async throws -> [CasePerson] {
        (try await database.query("""
            SELECT id, case_id, name, role, entity_id, contact, notes, created_at FROM case_people
            WHERE case_id = ? AND removed_at IS NULL ORDER BY role, name;
            """, [.uuid(caseID)])).compactMap { r in
            guard let id = r.uuid(0), let c = r.uuid(1), let name = r.string(2),
                  let role = r.string(3).flatMap(CasePersonRole.init(rawValue:)), let at = r.date(7) else { return nil }
            return CasePerson(id: id, caseID: c, name: name, role: role, entityID: r.uuid(4), contact: r.string(5), notes: r.string(6), createdAt: at)
        }
    }

    @discardableResult
    public func addPerson(caseID: UUID, name: String, role: CasePersonRole, entityID: UUID?, contact: String?, notes: String?,
                          actor: String, at date: Date = Date()) async throws -> UUID {
        let name = try Self.clean(name, "The name")
        let id = UUID()
        try await write("cf_ppl", caseID: caseID, actor: try Self.clean(actor, "Actor"), action: "personAdded", detail: "\(role.label): \(name)", at: date) { db in
            try db.exec("INSERT INTO case_people (id, case_id, name, role, entity_id, contact, notes, created_at) VALUES (?,?,?,?,?,?,?,?);",
                        [.uuid(id), .uuid(caseID), .text(name), .text(role.rawValue), entityID.map { .uuid($0) } ?? .null,
                         .optionalText(contact), .optionalText(notes), .date(date)])
        }
        return id
    }

    public func updatePerson(_ p: CasePerson, actor: String, at date: Date = Date()) async throws {
        let name = try Self.clean(p.name, "The name")
        try await write("cf_pplu", caseID: p.caseID, actor: try Self.clean(actor, "Actor"), action: "personUpdated", detail: name, at: date) { db in
            try db.exec("UPDATE case_people SET name = ?, role = ?, entity_id = ?, contact = ?, notes = ? WHERE id = ?;",
                        [.text(name), .text(p.role.rawValue), p.entityID.map { .uuid($0) } ?? .null, .optionalText(p.contact), .optionalText(p.notes), .uuid(p.id)])
        }
    }

    public func retractPerson(caseID: UUID, id: UUID, actor: String, at date: Date = Date()) async throws {
        try await write("cf_pplx", caseID: caseID, actor: try Self.clean(actor, "Actor"), action: "personRetracted", detail: nil, at: date) { db in
            try db.exec("UPDATE case_people SET removed_at = ? WHERE id = ? AND case_id = ?;", [.date(date), .uuid(id), .uuid(caseID)])
        }
    }

    public func contacts(caseID: UUID) async throws -> [CaseContact] {
        (try await database.query("""
            SELECT c.id, c.person_id, c.at, c.mode, c.note, c.by FROM case_contacts c JOIN case_people p ON p.id = c.person_id
            WHERE p.case_id = ? ORDER BY c.at;
            """, [.uuid(caseID)])).compactMap { r in
            guard let id = r.uuid(0), let p = r.uuid(1), let at = r.date(2), let mode = r.string(3), let by = r.string(5) else { return nil }
            return CaseContact(id: id, personID: p, at: at, mode: mode, note: r.string(4), by: by)
        }
    }

    public func addContact(caseID: UUID, personID: UUID, at when: Date, mode: String, note: String?, actor: String, at date: Date = Date()) async throws {
        let mode = try Self.clean(mode, "How you made contact")
        let actor = try Self.clean(actor, "Actor")
        try await write("cf_ct", caseID: caseID, actor: actor, action: "contactLogged", detail: mode, at: date) { db in
            try db.exec("INSERT INTO case_contacts (id, person_id, at, mode, note, by, created_at) VALUES (?,?,?,?,?,?,?);",
                        [.uuid(UUID()), .uuid(personID), .date(when), .text(mode), .optionalText(note), .text(actor), .date(date)])
        }
    }

    // MARK: - Interviews + credibility

    public func interviews(caseID: UUID) async throws -> [CaseInterview] {
        (try await database.query("\(Self.interviewColumns) WHERE case_id = ? ORDER BY COALESCE(scheduled_at, created_at);", [.uuid(caseID)]))
            .compactMap(Self.decodeInterview)
    }

    public func interview(id: UUID) async throws -> CaseInterview? {
        (try await database.query("\(Self.interviewColumns) WHERE id = ? LIMIT 1;", [.uuid(id)])).first.flatMap(Self.decodeInterview)
    }

    @discardableResult
    public func addInterview(caseID: UUID, personID: UUID?, questions: String?, actor: String, at date: Date = Date()) async throws -> UUID {
        let id = UUID()
        try await write("cf_iv", caseID: caseID, actor: try Self.clean(actor, "Actor"), action: "interviewPlanned", detail: nil, at: date) { db in
            try db.exec("INSERT INTO case_interviews (id, case_id, person_id, status, questions, created_at, updated_at) VALUES (?,?,?, 'planned', ?,?,?);",
                        [.uuid(id), .uuid(caseID), personID.map { .uuid($0) } ?? .null, .optionalText(questions), .date(date), .date(date)])
        }
        return id
    }

    /// Save an interview's working fields. An attested statement can't be changed — the attestation
    /// is the point; a correction is a new interview record.
    public func updateInterview(_ iv: CaseInterview, actor: String, at date: Date = Date()) async throws {
        let actor = try Self.clean(actor, "Actor")
        guard let current = try await interview(id: iv.id) else { throw CaseFileError.notFound("interview", iv.id) }
        if current.status == .attested, current.statementText != iv.statementText { throw CaseFileError.statementAlreadyAttested }
        let status: InterviewStatus = current.status == .attested ? .attested : iv.status
        try await write("cf_ivu", caseID: iv.caseID, actor: actor, action: "interviewUpdated", detail: status.label, at: date) { db in
            try db.exec("""
                UPDATE case_interviews SET person_id = ?, status = ?, scheduled_at = ?, mode = ?, location = ?, questions = ?,
                    recording_ref = ?, transcript_ref = ?, summary = ?, statement_text = ?, updated_at = ? WHERE id = ?;
                """, [iv.personID.map { .uuid($0) } ?? .null, .text(status.rawValue), .optionalDate(iv.scheduledAt), .optionalText(iv.mode),
                      .optionalText(iv.location), .optionalText(iv.questions), .optionalText(iv.recordingRef), .optionalText(iv.transcriptRef),
                      .optionalText(iv.summary), .optionalText(iv.statementText), .date(date), .uuid(iv.id)])
        }
    }

    /// Record that the interviewee read and confirmed the statement. Stores who attested, when, and the
    /// statement's SHA-256 so any later change shows.
    public func attest(interviewID: UUID, caseID: UUID, attestedBy: String, actor: String, at date: Date = Date()) async throws {
        let by = try Self.clean(attestedBy, "Who confirmed the statement")
        guard let iv = try await interview(id: interviewID) else { throw CaseFileError.notFound("interview", interviewID) }
        guard iv.status != .attested else { throw CaseFileError.statementAlreadyAttested }
        guard let text = iv.statementText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { throw CaseFileError.noStatement }
        let hash = CaseFileHash.sha256(iv.statementText ?? "")
        try await write("cf_att", caseID: caseID, actor: try Self.clean(actor, "Actor"), action: "statementAttested", detail: "\(by) · \(hash.prefix(12))", at: date) { db in
            try db.exec("UPDATE case_interviews SET status = 'attested', attested_by = ?, attested_at = ?, statement_sha256 = ?, updated_at = ? WHERE id = ?;",
                        [.text(by), .date(date), .text(hash), .date(date), .uuid(interviewID)])
        }
    }

    public func credibility(caseID: UUID) async throws -> [CredibilityNote] {
        (try await database.query("""
            SELECT c.id, c.interview_id, c.factor, c.assessment, c.note, c.evidence_ref, c.by, c.created_at
            FROM case_credibility c JOIN case_interviews i ON i.id = c.interview_id WHERE i.case_id = ? ORDER BY c.created_at;
            """, [.uuid(caseID)])).compactMap { r in
            guard let id = r.uuid(0), let iv = r.uuid(1), let f = r.string(2).flatMap(CredibilityFactor.init(rawValue:)),
                  let a = r.string(3).flatMap(CredibilityAssessment.init(rawValue:)), let by = r.string(6), let at = r.date(7) else { return nil }
            return CredibilityNote(id: id, interviewID: iv, factor: f, assessment: a, note: r.string(4), evidenceRef: r.string(5), by: by, createdAt: at)
        }
    }

    public func addCredibility(caseID: UUID, interviewID: UUID, factor: CredibilityFactor, assessment: CredibilityAssessment,
                               note: String?, evidenceRef: String?, actor: String, at date: Date = Date()) async throws {
        let actor = try Self.clean(actor, "Actor")
        try await write("cf_cred", caseID: caseID, actor: actor, action: "credibilityNoted", detail: "\(factor.label): \(assessment.label)", at: date) { db in
            try db.exec("INSERT INTO case_credibility (id, interview_id, factor, assessment, note, evidence_ref, by, created_at) VALUES (?,?,?,?,?,?,?,?);",
                        [.uuid(UUID()), .uuid(interviewID), .text(factor.rawValue), .text(assessment.rawValue), .optionalText(note),
                         .optionalText(evidenceRef), .text(actor), .date(date)])
        }
    }

    // MARK: - Exhibits

    public func exhibits(caseID: UUID, includeWithdrawn: Bool = false) async throws -> [CaseExhibit] {
        let rows = try await database.query("""
            SELECT id, case_id, number, description, source_ref, sha256, collected_by, collected_at, collected_where, created_at, withdrawn_at
            FROM case_exhibits WHERE case_id = ? \(includeWithdrawn ? "" : "AND withdrawn_at IS NULL") ORDER BY created_at;
            """, [.uuid(caseID)])
        return rows.compactMap { r in
            guard let id = r.uuid(0), let c = r.uuid(1), let n = r.string(2), let d = r.string(3), let at = r.date(9) else { return nil }
            return CaseExhibit(id: id, caseID: c, number: n, description: d, sourceRef: r.string(4), sha256: r.string(5), collectedBy: r.string(6),
                               collectedAt: r.date(7), collectedWhere: r.string(8), createdAt: at, withdrawnAt: r.date(10))
        }
    }

    /// Register an exhibit. Without a number the next "EX-001"-style number is assigned.
    @discardableResult
    public func addExhibit(caseID: UUID, number: String?, description: String, sourceRef: String?, sha256: String?,
                           collectedBy: String?, collectedAt: Date?, collectedWhere: String?, actor: String, at date: Date = Date()) async throws -> String {
        let description = try Self.clean(description, "The exhibit description")
        let actor = try Self.clean(actor, "Actor")
        let wanted = number?.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = Set(try await exhibits(caseID: caseID, includeWithdrawn: true).map(\.number))
        let assigned: String
        if let wanted, !wanted.isEmpty {
            guard !existing.contains(wanted) else { throw CaseFileError.duplicateExhibitNumber(wanted) }
            assigned = wanted
        } else {
            var n = existing.count + 1
            while existing.contains(String(format: "EX-%03d", n)) { n += 1 }
            assigned = String(format: "EX-%03d", n)
        }
        try await write("cf_ex", caseID: caseID, actor: actor, action: "exhibitRegistered", detail: "\(assigned) \(description)", at: date) { db in
            try db.exec("""
                INSERT INTO case_exhibits (id, case_id, number, description, source_ref, sha256, collected_by, collected_at, collected_where, created_at)
                VALUES (?,?,?,?,?,?,?,?,?,?);
                """, [.uuid(UUID()), .uuid(caseID), .text(assigned), .text(description), .optionalText(sourceRef), .optionalText(sha256),
                      .optionalText(collectedBy ?? actor), .optionalDate(collectedAt), .optionalText(collectedWhere), .date(date)])
        }
        return assigned
    }

    public func withdrawExhibit(caseID: UUID, id: UUID, actor: String, at date: Date = Date()) async throws {
        try await write("cf_exx", caseID: caseID, actor: try Self.clean(actor, "Actor"), action: "exhibitWithdrawn", detail: nil, at: date) { db in
            try db.exec("UPDATE case_exhibits SET withdrawn_at = ? WHERE id = ? AND case_id = ?;", [.date(date), .uuid(id), .uuid(caseID)])
        }
    }

    // MARK: - Legal-hold notices

    public func holdNotices(caseID: UUID) async throws -> [CaseHoldNotice] {
        (try await database.query("""
            SELECT id, case_id, custodian, person_id, notice_text, issued_at, issued_by, acknowledged_at, reminder_due, released_at, release_reason
            FROM case_hold_notices WHERE case_id = ? ORDER BY issued_at;
            """, [.uuid(caseID)])).compactMap { r in
            guard let id = r.uuid(0), let c = r.uuid(1), let cu = r.string(2), let t = r.string(4), let at = r.date(5), let by = r.string(6) else { return nil }
            return CaseHoldNotice(id: id, caseID: c, custodian: cu, personID: r.uuid(3), noticeText: t, issuedAt: at, issuedBy: by,
                                  acknowledgedAt: r.date(7), reminderDue: r.date(8), releasedAt: r.date(9), releaseReason: r.string(10))
        }
    }

    public func issueHold(caseID: UUID, custodian: String, personID: UUID?, noticeText: String, reminderDue: Date?,
                          actor: String, at date: Date = Date()) async throws {
        let cu = try Self.clean(custodian, "The custodian")
        let text = try Self.clean(noticeText, "The notice")
        let actor = try Self.clean(actor, "Actor")
        try await write("cf_hold", caseID: caseID, actor: actor, action: "holdIssued", detail: cu, at: date) { db in
            try db.exec("""
                INSERT INTO case_hold_notices (id, case_id, custodian, person_id, notice_text, issued_at, issued_by, reminder_due) VALUES (?,?,?,?,?,?,?,?);
                """, [.uuid(UUID()), .uuid(caseID), .text(cu), personID.map { .uuid($0) } ?? .null, .text(text), .date(date), .text(actor), .optionalDate(reminderDue)])
        }
    }

    public func acknowledgeHold(caseID: UUID, id: UUID, acknowledgedAt: Date, actor: String) async throws {
        try await write("cf_holda", caseID: caseID, actor: try Self.clean(actor, "Actor"), action: "holdAcknowledged", detail: nil, at: Date()) { db in
            try db.exec("UPDATE case_hold_notices SET acknowledged_at = ? WHERE id = ? AND case_id = ?;", [.date(acknowledgedAt), .uuid(id), .uuid(caseID)])
        }
    }

    public func releaseHold(caseID: UUID, id: UUID, reason: String, actor: String, at date: Date = Date()) async throws {
        let reason = try Self.clean(reason, "The release reason")
        try await write("cf_holdr", caseID: caseID, actor: try Self.clean(actor, "Actor"), action: "holdReleased", detail: reason, at: date) { db in
            try db.exec("UPDATE case_hold_notices SET released_at = ?, release_reason = ? WHERE id = ? AND case_id = ?;",
                        [.date(date), .text(reason), .uuid(id), .uuid(caseID)])
        }
    }

    // MARK: - Redaction log

    public func redactions(caseID: UUID) async throws -> [CaseRedaction] {
        (try await database.query("SELECT id, case_id, source_ref, location, reason, redacted_by, at FROM case_redaction_log WHERE case_id = ? ORDER BY at;",
                                  [.uuid(caseID)])).compactMap { r in
            guard let id = r.uuid(0), let c = r.uuid(1), let s = r.string(2), let l = r.string(3), let why = r.string(4),
                  let by = r.string(5), let at = r.date(6) else { return nil }
            return CaseRedaction(id: id, caseID: c, sourceRef: s, location: l, reason: why, redactedBy: by, at: at)
        }
    }

    public func logRedaction(caseID: UUID, sourceRef: String, location: String, reason: String, actor: String, at date: Date = Date()) async throws {
        let s = try Self.clean(sourceRef, "The document"), l = try Self.clean(location, "Where the redaction is")
        let why = try Self.clean(reason, "The reason"), actor = try Self.clean(actor, "Actor")
        try await write("cf_red", caseID: caseID, actor: actor, action: "redactionLogged", detail: "\(l): \(why)", at: date) { db in
            try db.exec("INSERT INTO case_redaction_log (id, case_id, source_ref, location, reason, redacted_by, at) VALUES (?,?,?,?,?,?,?);",
                        [.uuid(UUID()), .uuid(caseID), .text(s), .text(l), .text(why), .text(actor), .date(date)])
        }
    }

    // MARK: - Review batches + QC

    public func reviewBatches(caseID: UUID) async throws -> [CaseReviewBatch] {
        (try await database.query("""
            SELECT id, case_id, name, reviewer, source_refs_json, status, qc_reviewer, qc_note, created_at, updated_at
            FROM case_review_batches WHERE case_id = ? ORDER BY created_at;
            """, [.uuid(caseID)])).compactMap { r in
            guard let id = r.uuid(0), let c = r.uuid(1), let n = r.string(2), let st = r.string(5).flatMap(ReviewBatchStatus.init(rawValue:)),
                  let cr = r.date(8), let up = r.date(9) else { return nil }
            let refs = (r.string(4)?.data(using: .utf8)).flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
            return CaseReviewBatch(id: id, caseID: c, name: n, reviewer: r.string(3), sourceRefs: refs, status: st,
                                   qcReviewer: r.string(6), qcNote: r.string(7), createdAt: cr, updatedAt: up)
        }
    }

    /// Split a set of documents into batches of `size` for review.
    public func createBatches(caseID: UUID, sourceRefs: [String], size: Int, reviewer: String?, actor: String, at date: Date = Date()) async throws -> Int {
        let refs = Array(NSOrderedSet(array: sourceRefs.filter { !$0.isEmpty })) as? [String] ?? []
        guard !refs.isEmpty else { throw CaseFileError.blank("The documents to review") }
        let size = max(1, size)
        let start = try await reviewBatches(caseID: caseID).count
        let chunks = stride(from: 0, to: refs.count, by: size).map { Array(refs[$0..<min($0 + size, refs.count)]) }
        let actor = try Self.clean(actor, "Actor")
        try await write("cf_rb", caseID: caseID, actor: actor, action: "batchesCreated", detail: "\(chunks.count) × ≤\(size)", at: date) { db in
            for (i, chunk) in chunks.enumerated() {
                let json = String(data: (try? JSONEncoder().encode(chunk)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
                try db.exec("INSERT INTO case_review_batches (id, case_id, name, reviewer, source_refs_json, status, created_at, updated_at) VALUES (?,?,?,?,?, 'open', ?,?);",
                            [.uuid(UUID()), .uuid(caseID), .text("Batch \(start + i + 1)"), .optionalText(reviewer), .text(json), .date(date), .date(date)])
            }
        }
        return chunks.count
    }

    /// First pass done by the reviewer, then QC by a DIFFERENT person.
    public func advanceBatch(caseID: UUID, id: UUID, to status: ReviewBatchStatus, qcNote: String?, actor: String, at date: Date = Date()) async throws {
        let actor = try Self.clean(actor, "Actor")
        guard let b = try await reviewBatches(caseID: caseID).first(where: { $0.id == id }) else { throw CaseFileError.notFound("batch", id) }
        if status == .qcDone, let reviewer = b.reviewer, reviewer.caseInsensitiveCompare(actor) == .orderedSame {
            throw CaseFileError.blank("A second reviewer for QC (the first-pass reviewer can't QC their own batch)")
        }
        try await write("cf_rbs", caseID: caseID, actor: actor, action: "batchAdvanced", detail: "\(b.name): \(status.label)", at: date) { db in
            try db.exec("UPDATE case_review_batches SET status = ?, qc_reviewer = ?, qc_note = ?, updated_at = ? WHERE id = ?;",
                        [.text(status.rawValue), status == .qcDone ? .text(actor) : .optionalText(b.qcReviewer),
                         status == .qcDone ? .optionalText(qcNote) : .optionalText(b.qcNote), .date(date), .uuid(id)])
        }
    }

    // MARK: - Conflict-of-interest check (C-11)

    public func conflictChecks(caseID: UUID) async throws -> [CaseConflictCheck] {
        (try await database.query("""
            SELECT id, case_id, investigator, result, matched, note, checked_by, checked_at FROM case_conflict_checks WHERE case_id = ? ORDER BY checked_at;
            """, [.uuid(caseID)])).compactMap { r in
            guard let id = r.uuid(0), let c = r.uuid(1), let inv = r.string(2), let res = r.string(3).flatMap(ConflictCheckResult.init(rawValue:)),
                  let by = r.string(6), let at = r.date(7) else { return nil }
            return CaseConflictCheck(id: id, caseID: c, investigator: inv, result: res, matched: r.string(4), note: r.string(5), checkedBy: by, checkedAt: at)
        }
    }

    /// Compare an investigator's name and declared relationships with the people in the case. A match
    /// is recorded as a conflict; a person may waive it with a note — the check never decides alone.
    @discardableResult
    public func runConflictCheck(caseID: UUID, investigator: String, declaredRelationships: [String], waiveNote: String?,
                                 actor: String, at date: Date = Date()) async throws -> CaseConflictCheck {
        let inv = try Self.clean(investigator, "The investigator")
        let actor = try Self.clean(actor, "Actor")
        let names = try await people(caseID: caseID).map(\.name)
        let matched = CaseConflictMatcher.matches(investigator: inv, declared: declaredRelationships, people: names)
        let waive = waiveNote?.trimmingCharacters(in: .whitespacesAndNewlines)
        let result: ConflictCheckResult = matched.isEmpty ? .clear : ((waive?.isEmpty == false) ? .waived : .conflict)
        let check = CaseConflictCheck(id: UUID(), caseID: caseID, investigator: inv, result: result,
                                      matched: matched.isEmpty ? nil : matched.joined(separator: ", "), note: waive, checkedBy: actor, checkedAt: date)
        try await write("cf_coi", caseID: caseID, actor: actor, action: "conflictCheck", detail: "\(inv): \(result.rawValue)", at: date) { db in
            try db.exec("INSERT INTO case_conflict_checks (id, case_id, investigator, result, matched, note, checked_by, checked_at) VALUES (?,?,?,?,?,?,?,?);",
                        [.uuid(check.id), .uuid(caseID), .text(inv), .text(result.rawValue), .optionalText(check.matched), .optionalText(waive), .text(actor), .date(date)])
        }
        return check
    }

    // MARK: - Tasks (links into the one task engine)

    public func linkTask(caseID: UUID, taskID: UUID, title: String, actor: String, at date: Date = Date()) async throws {
        try await write("cf_tk", caseID: caseID, actor: try Self.clean(actor, "Actor"), action: "taskAdded", detail: title, at: date) { db in
            try db.exec("INSERT OR IGNORE INTO case_task_links (case_id, task_id, created_at) VALUES (?,?,?);", [.uuid(caseID), .uuid(taskID), .date(date)])
        }
    }

    public func linkedTaskIDs(caseID: UUID) async throws -> [UUID] {
        (try await database.query("SELECT task_id FROM case_task_links WHERE case_id = ? ORDER BY created_at;", [.uuid(caseID)])).compactMap { $0.uuid(0) }
    }

    public func linkedTaskIDsByCase() async throws -> [UUID: [UUID]] {
        var out: [UUID: [UUID]] = [:]
        for r in try await database.query("SELECT case_id, task_id FROM case_task_links;") {
            if let c = r.uuid(0), let t = r.uuid(1) { out[c, default: []].append(t) }
        }
        return out
    }

    // MARK: - Action log

    public func actions(caseID: UUID) async throws -> [CaseAction] {
        (try await database.query("SELECT id, case_id, sequence, actor, action, detail, at FROM case_actions WHERE case_id = ? ORDER BY sequence;",
                                  [.uuid(caseID)])).compactMap { r in
            guard let id = r.uuid(0), let c = r.uuid(1), let s = r.int(2), let a = r.string(3), let act = r.string(4), let at = r.date(6) else { return nil }
            return CaseAction(id: id, caseID: c, sequence: Int(s), actor: a, action: act, detail: r.string(5), at: at)
        }
    }

    /// Record a read or export (viewing the case file, exporting a report) — S-4.
    public func logAction(caseID: UUID, action: String, detail: String?, actor: String, at date: Date = Date()) async throws {
        try await write("cf_act", caseID: caseID, actor: try Self.clean(actor, "Actor"), action: action, detail: detail, at: date) { _ in }
    }

    // MARK: - Internals

    /// One savepoint: the change and its action-log row.
    private func write(_ prefix: String, caseID: UUID, actor: String, action: String, detail: String?, at date: Date,
                       _ body: @escaping @Sendable (isolated Database) throws -> Void) async throws {
        let sp = "\(prefix)_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let clipped = detail.map { String($0.prefix(500)) }
        try await database.withSavepoint(sp) { db in
            guard try !db.query("SELECT 1 FROM investigation_cases WHERE id = ? LIMIT 1;", [.uuid(caseID)]).isEmpty else {
                throw CaseFileError.caseNotFound(caseID)
            }
            try body(db)
            let next = (try db.query("SELECT COALESCE(MAX(sequence), 0) FROM case_actions WHERE case_id = ?;", [.uuid(caseID)]).first?.int(0) ?? 0) + 1
            try db.exec("INSERT INTO case_actions (id, case_id, sequence, actor, action, detail, at) VALUES (?,?,?,?,?,?,?);",
                        [.uuid(UUID()), .uuid(caseID), .integer(next), .text(actor), .text(action), .optionalText(clipped), .date(date)])
        }
    }

    private static func clean(_ s: String, _ field: String) throws -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { throw CaseFileError.blank(field) }
        return t
    }

    private static let profileColumns = """
        SELECT case_id, kind, stage, severity, risk_note, triage_decision, triage_reason, triage_by, triage_at,
               owner, team_json, reviewer, received_at, channel, anonymous, complainant, complainant_contact,
               allegation_summary, incident_date, incident_location, people_named,
               plan_method, plan_evidence, plan_interviews, plan_notes, retention_policy, retain_until, archived_at, updated_at
        FROM case_profiles
        """

    private nonisolated static func decodeProfile(_ r: SQLRow) -> CaseProfile? {
        guard let id = r.uuid(0), let stage = r.string(2).flatMap(CaseStage.init(rawValue:)), let up = r.date(28) else { return nil }
        let team = (r.string(10)?.data(using: .utf8)).flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        return CaseProfile(
            caseID: id, kind: r.string(1), stage: stage,
            triage: CaseTriage(severity: r.string(3).flatMap(CaseSeverity.init(rawValue:)), riskNote: r.string(4),
                               decision: r.string(5).flatMap(CaseTriageDecision.init(rawValue:)), reason: r.string(6),
                               decidedBy: r.string(7), decidedAt: r.date(8)),
            owner: r.string(9), team: team, reviewer: r.string(11),
            intake: CaseIntake(receivedAt: r.date(12), channel: r.string(13).flatMap(CaseIntakeChannel.init(rawValue:)),
                               anonymous: (r.int(14) ?? 0) != 0, complainant: r.string(15), complainantContact: r.string(16),
                               allegationSummary: r.string(17), incidentDate: r.string(18), incidentLocation: r.string(19), peopleNamed: r.string(20)),
            plan: CasePlan(method: r.string(21), evidenceToCollect: r.string(22), interviewsToHold: r.string(23), notes: r.string(24)),
            retentionPolicy: r.string(25), retainUntil: r.date(26), archivedAt: r.date(27), updatedAt: up)
    }

    private static func upsertProfile(_ db: isolated Database, _ p: CaseProfile) throws {
        let team = String(data: (try? JSONEncoder().encode(p.team)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
        let i = p.intake.stored
        try db.exec("""
            INSERT INTO case_profiles (case_id, kind, stage, severity, risk_note, triage_decision, triage_reason, triage_by, triage_at,
                owner, team_json, reviewer, received_at, channel, anonymous, complainant, complainant_contact,
                allegation_summary, incident_date, incident_location, people_named,
                plan_method, plan_evidence, plan_interviews, plan_notes, retention_policy, retain_until, archived_at, updated_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT (case_id) DO UPDATE SET kind = excluded.kind, stage = excluded.stage, severity = excluded.severity,
                risk_note = excluded.risk_note, triage_decision = excluded.triage_decision, triage_reason = excluded.triage_reason,
                triage_by = excluded.triage_by, triage_at = excluded.triage_at, owner = excluded.owner, team_json = excluded.team_json,
                reviewer = excluded.reviewer, received_at = excluded.received_at, channel = excluded.channel, anonymous = excluded.anonymous,
                complainant = excluded.complainant, complainant_contact = excluded.complainant_contact,
                allegation_summary = excluded.allegation_summary, incident_date = excluded.incident_date,
                incident_location = excluded.incident_location, people_named = excluded.people_named,
                plan_method = excluded.plan_method, plan_evidence = excluded.plan_evidence, plan_interviews = excluded.plan_interviews,
                plan_notes = excluded.plan_notes, retention_policy = excluded.retention_policy, retain_until = excluded.retain_until,
                archived_at = excluded.archived_at, updated_at = excluded.updated_at;
            """, [.uuid(p.caseID), .optionalText(p.kind), .text(p.stage.rawValue), .optionalText(p.triage.severity?.rawValue),
                  .optionalText(p.triage.riskNote), .optionalText(p.triage.decision?.rawValue), .optionalText(p.triage.reason),
                  .optionalText(p.triage.decidedBy), .optionalDate(p.triage.decidedAt), .optionalText(p.owner), .text(team),
                  .optionalText(p.reviewer), .optionalDate(i.receivedAt), .optionalText(i.channel?.rawValue), .bool(i.anonymous),
                  .optionalText(i.complainant), .optionalText(i.complainantContact), .optionalText(i.allegationSummary),
                  .optionalText(i.incidentDate), .optionalText(i.incidentLocation), .optionalText(i.peopleNamed),
                  .optionalText(p.plan.method), .optionalText(p.plan.evidenceToCollect), .optionalText(p.plan.interviewsToHold),
                  .optionalText(p.plan.notes), .optionalText(p.retentionPolicy), .optionalDate(p.retainUntil), .optionalDate(p.archivedAt),
                  .date(p.updatedAt)])
    }

    private static let interviewColumns = """
        SELECT id, case_id, person_id, status, scheduled_at, mode, location, questions, recording_ref, transcript_ref,
               summary, statement_text, attested_by, attested_at, statement_sha256, created_at, updated_at
        FROM case_interviews
        """

    private nonisolated static func decodeInterview(_ r: SQLRow) -> CaseInterview? {
        guard let id = r.uuid(0), let c = r.uuid(1), let st = r.string(3).flatMap(InterviewStatus.init(rawValue:)),
              let cr = r.date(15), let up = r.date(16) else { return nil }
        return CaseInterview(id: id, caseID: c, personID: r.uuid(2), status: st, scheduledAt: r.date(4), mode: r.string(5), location: r.string(6),
                             questions: r.string(7), recordingRef: r.string(8), transcriptRef: r.string(9), summary: r.string(10),
                             statementText: r.string(11), attestedBy: r.string(12), attestedAt: r.date(13), statementSHA256: r.string(14),
                             createdAt: cr, updatedAt: up)
    }
}

/// Name matching for the conflict check: the investigator's own name and every declared relationship
/// against each person in the case, by whole-word overlap of surname-or-full-name (case-insensitive).
public nonisolated enum CaseConflictMatcher {
    public static func matches(investigator: String, declared: [String], people: [String]) -> [String] {
        let probes = ([investigator] + declared).map(normalise).filter { !$0.isEmpty }
        return people.filter { person in
            let p = normalise(person)
            guard !p.isEmpty else { return false }
            return probes.contains { probe in
                probe == p || (tokens(probe).count >= 2 && tokens(p).count >= 2 && tokens(probe).last == tokens(p).last && tokens(probe).first == tokens(p).first)
            }
        }
    }
    static func normalise(_ s: String) -> String {
        s.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }
    static func tokens(_ s: String) -> [String] { s.split(separator: " ").map(String.init) }
}
