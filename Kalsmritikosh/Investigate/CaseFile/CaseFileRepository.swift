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
                        detail: "\(from.label) → \(stage.label)" + (reason.map { ": \($0)" } ?? ""), at: date,
                        allowedWhenClosed: from == .closed) { db in
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
                        action: reopened ? "reopened" : "closed", detail: nil, at: date, allowedWhenClosed: reopened) { db in
            try Self.upsertProfile(db, row)
        }
    }

    public func archive(caseID: UUID, actor: String, at date: Date = Date()) async throws {
        var p = try await profile(caseID: caseID)
        p.archivedAt = date; p.updatedAt = date
        let row = p
        try await write("cf_archive", caseID: caseID, actor: try Self.clean(actor, "Actor"), action: "archived", detail: nil, at: date,
                        allowedWhenClosed: true) { db in
            try Self.upsertProfile(db, row)
        }
    }

    // MARK: - Allegations + evidence grid

    public func allegations(caseID: UUID) async throws -> [CaseAllegation] {
        (try await database.query("""
            SELECT id, case_id, sequence, text, disposition, rationale, decided_by, decided_at, created_at, response, exception_note
            FROM case_allegations WHERE case_id = ? ORDER BY sequence;
            """, [.uuid(caseID)])).compactMap { r in
            guard let id = r.uuid(0), let c = r.uuid(1), let seq = r.int(2), let text = r.string(3),
                  let d = r.string(4).flatMap(AllegationDisposition.init(rawValue:)), let created = r.date(8) else { return nil }
            return CaseAllegation(id: id, caseID: c, sequence: Int(seq), text: text, disposition: d, rationale: r.string(5),
                                  decidedBy: r.string(6), decidedAt: r.date(7), createdAt: created,
                                  response: r.string(9), exceptionNote: r.string(10))
        }
    }

    /// I4 — record the response put to the respondent (their account or explanation of the allegation),
    /// or that none was obtained and why. Recorded in the case log; an adverse finding needs it.
    public func recordResponse(allegationID: UUID, caseID: UUID, response: String, actor: String, at date: Date = Date()) async throws {
        let text = try Self.clean(response, "The response")
        try await write("cf_resp", caseID: caseID, actor: try Self.clean(actor, "Actor"), action: "responseRecorded", detail: text, at: date) { db in
            try Self.requireInCase(db, "allegation", allegationID, caseID: caseID)
            try db.exec("UPDATE case_allegations SET response = ? WHERE id = ? AND case_id = ?;", [.text(text), .uuid(allegationID), .uuid(caseID)])
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

    /// A person records the disposition. Anything but `pending` needs a rationale. An ADVERSE finding
    /// (substantiated) also needs (I4) at least one documentary link that supports it — a source
    /// passage or an exhibit, not the investigator's own note — and the response put to the
    /// respondent, unless an explicit `exception` says why the finding is recorded without one.
    public func decide(allegationID: UUID, caseID: UUID, disposition: AllegationDisposition, rationale: String?,
                       exception: String? = nil, actor: String, at date: Date = Date()) async throws {
        let actor = try Self.clean(actor, "Actor")
        let why = rationale?.trimmingCharacters(in: .whitespacesAndNewlines)
        let exceptionNote = Self.blankToNil(exception)
        if disposition != .pending { _ = try Self.clean(why ?? "", "The rationale") }
        try await write("cf_dec", caseID: caseID, actor: actor, action: "allegationDecided",
                        detail: "\(disposition.label): \(why ?? "")" + (exceptionNote.map { " (exception: \($0))" } ?? ""), at: date) { db in
            try Self.requireInCase(db, "allegation", allegationID, caseID: caseID)
            if disposition == .substantiated {
                let links = try db.query("SELECT evidence_ref, stance FROM case_allegation_evidence WHERE allegation_id = ? AND removed_at IS NULL;", [.uuid(allegationID)])
                let documentary = links.contains { r in
                    guard r.string(1) == GridStance.supports.rawValue, let ref = r.string(0) else { return false }
                    switch CaseEvidenceReference.parse(ref) { case .sourceVersion, .exhibit: return true; default: return false }
                }
                guard documentary else {
                    throw CaseFileError.adverseFindingUnsupported("link at least one source passage or exhibit that supports it — a typed note is your own entry, not evidence")
                }
                let response = try db.query("SELECT response FROM case_allegations WHERE id = ?;", [.uuid(allegationID)]).first?.string(0)?.trimmingCharacters(in: .whitespacesAndNewlines)
                guard (response?.isEmpty == false) || exceptionNote != nil else {
                    throw CaseFileError.adverseFindingUnsupported("record the response put to the respondent, or state the exception that justifies deciding without one")
                }
            }
            try db.exec("UPDATE case_allegations SET disposition = ?, rationale = ?, decided_by = ?, decided_at = ?, exception_note = ? WHERE id = ? AND case_id = ?;",
                        [.text(disposition.rawValue), .optionalText(why), disposition == .pending ? .null : .text(actor),
                         disposition == .pending ? .null : .date(date), .optionalText(exceptionNote), .uuid(allegationID), .uuid(caseID)])
        }
    }

    public func allegationEvidence(caseID: UUID) async throws -> [AllegationEvidence] {
        (try await database.query("""
            SELECT e.id, e.allegation_id, e.evidence_ref, e.label, e.stance, e.note, e.added_by, e.created_at, e.quote, e.block_id, e.object_id, e.origin
            FROM case_allegation_evidence e JOIN case_allegations a ON a.id = e.allegation_id
            WHERE a.case_id = ? AND e.removed_at IS NULL ORDER BY e.created_at;
            """, [.uuid(caseID)])).compactMap { r in
            guard let id = r.uuid(0), let a = r.uuid(1), let ref = r.string(2),
                  let st = r.string(4).flatMap(GridStance.init(rawValue:)), let by = r.string(6), let at = r.date(7) else { return nil }
            return AllegationEvidence(id: id, allegationID: a, evidenceRef: ref, label: r.string(3), stance: st, note: r.string(5), addedBy: by, createdAt: at,
                                      quote: r.string(8), blockID: r.uuid(9), objectID: r.uuid(10), origin: r.string(11))
        }
    }

    /// Link evidence to an allegation. `passage` (I4) pins the exact quotation and locator inside the
    /// source version; `origin` (I5) names the reviewed result row it was carried from. The reference
    /// itself must resolve in THIS case's scope.
    public func addAllegationEvidence(caseID: UUID, allegationID: UUID, evidenceRef: String, label: String?, stance: GridStance,
                                      note: String?, passage: StudioEvidenceRef? = nil, origin: String? = nil,
                                      actor: String, at date: Date = Date()) async throws {
        let ref = try Self.clean(evidenceRef, "The evidence")
        let actor = try Self.clean(actor, "Actor")
        let quote = Self.blankToNil(passage?.quote)
        try await write("cf_grid", caseID: caseID, actor: actor, action: "gridLinked", detail: "\(stance.rawValue) \(label ?? ref)" + (quote.map { " — “\($0.prefix(80))”" } ?? ""), at: date) { db in
            try Self.requireInCase(db, "allegation", allegationID, caseID: caseID)
            try Self.requireResolvable(db, ref, caseID: caseID)
            try db.exec("""
                INSERT INTO case_allegation_evidence (id, allegation_id, evidence_ref, label, stance, note, added_by, created_at, quote, block_id, object_id, origin)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?);
                """, [.uuid(UUID()), .uuid(allegationID), .text(ref), .optionalText(label), .text(stance.rawValue), .optionalText(note), .text(actor), .date(date),
                      .optionalText(quote), passage?.blockID.map { .uuid($0) } ?? .null, passage?.objectID.map { .uuid($0) } ?? .null, .optionalText(origin)])
        }
    }

    public func retractAllegationEvidence(caseID: UUID, id: UUID, actor: String, at date: Date = Date()) async throws {
        try await write("cf_gridx", caseID: caseID, actor: try Self.clean(actor, "Actor"), action: "gridUnlinked", detail: nil, at: date) { db in
            try Self.requireInCase(db, "evidence link", id, caseID: caseID)
            try db.exec("UPDATE case_allegation_evidence SET removed_at = ? WHERE id = ?;", [.date(date), .uuid(id)])
        }
    }

    // MARK: - Journal + manual chronology

    public func journal(caseID: UUID, kind: CaseJournalKind? = nil) async throws -> [CaseJournalEntry] {
        var sql = "SELECT id, case_id, entry_kind, event_date, text, evidence_ref, author, created_at, quote, origin FROM case_journal WHERE case_id = ? AND removed_at IS NULL"
        var b: [SQLValue] = [.uuid(caseID)]
        if let kind { sql += " AND entry_kind = ?"; b.append(.text(kind.rawValue)) }
        sql += " ORDER BY COALESCE(event_date, created_at), created_at;"
        return (try await database.query(sql, b)).compactMap { r in
            guard let id = r.uuid(0), let c = r.uuid(1), let k = r.string(2).flatMap(CaseJournalKind.init(rawValue:)),
                  let text = r.string(4), let author = r.string(6), let at = r.date(7) else { return nil }
            return CaseJournalEntry(id: id, caseID: c, kind: k, eventDate: r.date(3), text: text, evidenceRef: r.string(5), author: author, createdAt: at,
                                    quote: r.string(8), origin: r.string(9))
        }
    }

    @discardableResult
    public func addJournal(caseID: UUID, kind: CaseJournalKind, text: String, eventDate: Date?, evidenceRef: String?,
                           quote: String? = nil, origin: String? = nil, actor: String, at date: Date = Date()) async throws -> UUID {
        let text = try Self.clean(text, kind == .note ? "The note" : "The chronology entry")
        let actor = try Self.clean(actor, "Actor")
        let id = UUID()
        try await write("cf_jr", caseID: caseID, actor: actor, action: kind == .note ? "noteAdded" : "chronologyAdded", detail: text, at: date) { db in
            if let evidenceRef { try Self.requireResolvable(db, evidenceRef, caseID: caseID) }
            try db.exec("INSERT INTO case_journal (id, case_id, entry_kind, event_date, text, evidence_ref, author, created_at, quote, origin) VALUES (?,?,?,?,?,?,?,?,?,?);",
                        [.uuid(id), .uuid(caseID), .text(kind.rawValue), .optionalDate(eventDate), .text(text), .optionalText(evidenceRef), .text(actor), .date(date),
                         .optionalText(Self.blankToNil(quote)), .optionalText(origin)])
        }
        return id
    }

    // MARK: - I5: the final report's explicit selection

    public func reportItems(caseID: UUID) async throws -> [CaseReportItem] {
        (try await database.query("""
            SELECT id, case_id, allegation_id, text, quote, evidence_ref, origin, included, exclusion_reason, added_by, created_at, decided_by, decided_at
            FROM case_report_items WHERE case_id = ? ORDER BY created_at;
            """, [.uuid(caseID)])).compactMap { r in
            guard let id = r.uuid(0), let c = r.uuid(1), let text = r.string(3), let by = r.string(9), let at = r.date(10) else { return nil }
            return CaseReportItem(id: id, caseID: c, allegationID: r.uuid(2), text: text, quote: r.string(4), evidenceRef: r.string(5), origin: r.string(6),
                                  included: (r.int(7) ?? 1) != 0, exclusionReason: r.string(8), addedBy: by, createdAt: at, decidedBy: r.string(11), decidedAt: r.date(12))
        }
    }

    /// Select a cited item for the final report (included), or record it as excluded with the reason.
    /// The item carries its passage and the reviewed result it came from; nothing is retyped.
    @discardableResult
    public func addReportItem(caseID: UUID, allegationID: UUID?, text: String, quote: String?, evidenceRef: String?, origin: String?,
                              included: Bool = true, exclusionReason: String? = nil, actor: String, at date: Date = Date()) async throws -> UUID {
        let text = try Self.clean(text, "The report item")
        let actor = try Self.clean(actor, "Actor")
        let reason = Self.blankToNil(exclusionReason)
        if !included { _ = try Self.clean(reason ?? "", "The exclusion reason") }
        let id = UUID()
        try await write("cf_rep", caseID: caseID, actor: actor, action: included ? "reportItemIncluded" : "reportItemExcluded",
                        detail: text + (reason.map { " — excluded: \($0)" } ?? ""), at: date) { db in
            if let allegationID { try Self.requireInCase(db, "allegation", allegationID, caseID: caseID) }
            if let evidenceRef { try Self.requireResolvable(db, evidenceRef, caseID: caseID) }
            try db.exec("""
                INSERT INTO case_report_items (id, case_id, allegation_id, text, quote, evidence_ref, origin, included, exclusion_reason, added_by, created_at, decided_by, decided_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?);
                """, [.uuid(id), .uuid(caseID), allegationID.map { .uuid($0) } ?? .null, .text(text), .optionalText(Self.blankToNil(quote)), .optionalText(evidenceRef),
                      .optionalText(origin), .integer(included ? 1 : 0), .optionalText(reason), .text(actor), .date(date), .text(actor), .date(date)])
        }
        return id
    }

    /// Change an item's selection: exclude it with the reason, or include it again. Recorded, never deleted.
    public func setReportItem(caseID: UUID, id: UUID, included: Bool, reason: String?, actor: String, at date: Date = Date()) async throws {
        let actor = try Self.clean(actor, "Actor")
        let why = Self.blankToNil(reason)
        if !included { _ = try Self.clean(why ?? "", "The exclusion reason") }
        try await write("cf_repx", caseID: caseID, actor: actor, action: included ? "reportItemIncluded" : "reportItemExcluded", detail: why, at: date) { db in
            try Self.requireInCase(db, "report item", id, caseID: caseID)
            try db.exec("UPDATE case_report_items SET included = ?, exclusion_reason = ?, decided_by = ?, decided_at = ? WHERE id = ? AND case_id = ?;",
                        [.integer(included ? 1 : 0), .optionalText(included ? nil : why), .text(actor), .date(date), .uuid(id), .uuid(caseID)])
        }
    }

    public func retractJournal(caseID: UUID, id: UUID, actor: String, at date: Date = Date()) async throws {
        try await write("cf_jrx", caseID: caseID, actor: try Self.clean(actor, "Actor"), action: "journalRetracted", detail: nil, at: date) { db in
            try Self.requireInCase(db, "journal entry", id, caseID: caseID)
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
            try Self.requireInCase(db, "person", p.id, caseID: p.caseID)
            try db.exec("UPDATE case_people SET name = ?, role = ?, entity_id = ?, contact = ?, notes = ? WHERE id = ? AND case_id = ?;",
                        [.text(name), .text(p.role.rawValue), p.entityID.map { .uuid($0) } ?? .null, .optionalText(p.contact), .optionalText(p.notes), .uuid(p.id), .uuid(p.caseID)])
        }
    }

    public func retractPerson(caseID: UUID, id: UUID, actor: String, at date: Date = Date()) async throws {
        try await write("cf_pplx", caseID: caseID, actor: try Self.clean(actor, "Actor"), action: "personRetracted", detail: nil, at: date) { db in
            try Self.requireInCase(db, "person", id, caseID: caseID)
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
            try Self.requireInCase(db, "person", personID, caseID: caseID)
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
            if let personID { try Self.requireInCase(db, "person", personID, caseID: caseID) }
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
        // After confirmation the statement's person, recording, transcript and when/how/where are its
        // provenance; changing them silently would change what was confirmed (brief §9).
        if current.status == .attested {
            let locked: [(String, Bool)] = [("interviewee", current.personID != iv.personID), ("recording", current.recordingRef != iv.recordingRef),
                                            ("transcript", current.transcriptRef != iv.transcriptRef), ("date", current.scheduledAt != iv.scheduledAt),
                                            ("mode", current.mode != iv.mode), ("location", current.location != iv.location)]
            if let changed = locked.first(where: { $0.1 }) { throw CaseFileError.attestedFieldLocked(changed.0) }
        }
        let status: InterviewStatus = current.status == .attested ? .attested : iv.status
        guard current.caseID == iv.caseID else { throw CaseFileError.notInCase("interview", iv.id) }
        try await write("cf_ivu", caseID: iv.caseID, actor: actor, action: "interviewUpdated", detail: status.label, at: date) { db in
            try Self.requireInCase(db, "interview", iv.id, caseID: iv.caseID)
            if let personID = iv.personID { try Self.requireInCase(db, "person", personID, caseID: iv.caseID) }
            // A changed recording or transcript must be a source in this case.
            if let r = iv.recordingRef, r != current.recordingRef { try Self.requireResolvable(db, r, caseID: iv.caseID, sourceOnly: true) }
            if let r = iv.transcriptRef, r != current.transcriptRef { try Self.requireResolvable(db, r, caseID: iv.caseID, sourceOnly: true) }
            try db.exec("""
                UPDATE case_interviews SET person_id = ?, status = ?, scheduled_at = ?, mode = ?, location = ?, questions = ?,
                    recording_ref = ?, transcript_ref = ?, summary = ?, statement_text = ?, updated_at = ? WHERE id = ? AND case_id = ? AND status != 'attested' OR (id = ? AND case_id = ? AND status = 'attested' AND COALESCE(statement_text, '') = COALESCE(?, ''));
                """, [iv.personID.map { .uuid($0) } ?? .null, .text(status.rawValue), .optionalDate(iv.scheduledAt), .optionalText(iv.mode),
                      .optionalText(iv.location), .optionalText(iv.questions), .optionalText(iv.recordingRef), .optionalText(iv.transcriptRef),
                      .optionalText(iv.summary), .optionalText(iv.statementText), .date(date), .uuid(iv.id), .uuid(iv.caseID),
                      .uuid(iv.id), .uuid(iv.caseID), .optionalText(iv.statementText)])
        }
    }

    /// Record that the interviewee read and confirmed the statement. Stores who attested, when, and the
    /// statement's SHA-256 so any later change shows.
    public func attest(interviewID: UUID, caseID: UUID, attestedBy: String, actor: String, at date: Date = Date()) async throws {
        let by = try Self.clean(attestedBy, "Who confirmed the statement")
        guard let iv = try await interview(id: interviewID) else { throw CaseFileError.notFound("interview", interviewID) }
        guard iv.caseID == caseID else { throw CaseFileError.notInCase("interview", interviewID) }
        guard iv.status != .attested else { throw CaseFileError.statementAlreadyAttested }
        guard let text = iv.statementText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { throw CaseFileError.noStatement }
        let hash = CaseFileHash.sha256(iv.statementText ?? "")
        try await write("cf_att", caseID: caseID, actor: try Self.clean(actor, "Actor"), action: "statementAttested", detail: "\(by) · \(hash.prefix(12))", at: date) { db in
            try Self.requireInCase(db, "interview", interviewID, caseID: caseID)
            // The statement attested is the one hashed: a change in between refuses the attestation.
            guard try db.query("SELECT 1 FROM case_interviews WHERE id = ? AND case_id = ? AND status != 'attested' AND COALESCE(statement_text, '') = ? LIMIT 1;",
                               [.uuid(interviewID), .uuid(caseID), .text(iv.statementText ?? "")]).isEmpty == false else {
                throw CaseFileError.staleRecord("interview", interviewID)
            }
            try db.exec("UPDATE case_interviews SET status = 'attested', attested_by = ?, attested_at = ?, statement_sha256 = ?, updated_at = ? WHERE id = ? AND case_id = ?;",
                        [.text(by), .date(date), .text(hash), .date(date), .uuid(interviewID), .uuid(caseID)])
        }
    }

    // MARK: - Statement corrections (addenda)

    /// Correct a CONFIRMED statement by an addendum linked to it; the confirmed text stays as it was.
    @discardableResult
    public func addStatementAddendum(caseID: UUID, interviewID: UUID, text: String, reason: String,
                                     actor: String, at date: Date = Date()) async throws -> UUID {
        let actor = try Self.clean(actor, "Actor")
        let body = try Self.clean(text, "Correction")
        let why = try Self.clean(reason, "Reason for the correction")
        let id = UUID(), hash = CaseFileHash.sha256(body)
        try await write("cf_adn", caseID: caseID, actor: actor, action: "statementCorrected", detail: "addendum · \(hash.prefix(12))", at: date) { db in
            try Self.requireInCase(db, "interview", interviewID, caseID: caseID)
            guard try !db.query("SELECT 1 FROM case_interviews WHERE id = ? AND case_id = ? AND status = 'attested' LIMIT 1;",
                                [.uuid(interviewID), .uuid(caseID)]).isEmpty else { throw CaseFileError.notAttested }
            try db.exec("""
                INSERT INTO case_statement_addenda (id, interview_id, case_id, text, reason, sha256, recorded_by, recorded_at)
                VALUES (?,?,?,?,?,?,?,?);
                """, [.uuid(id), .uuid(interviewID), .uuid(caseID), .text(body), .text(why), .text(hash), .text(actor), .date(date)])
        }
        return id
    }

    /// Record that the interviewee confirmed a correction. Once only.
    public func confirmAddendum(caseID: UUID, id: UUID, confirmedBy: String, actor: String, at date: Date = Date()) async throws {
        let by = try Self.clean(confirmedBy, "Who confirmed the correction")
        try await write("cf_adc", caseID: caseID, actor: try Self.clean(actor, "Actor"), action: "correctionConfirmed", detail: by, at: date) { db in
            guard let row = try db.query("SELECT confirmed_by FROM case_statement_addenda WHERE id = ? AND case_id = ? LIMIT 1;",
                                         [.uuid(id), .uuid(caseID)]).first else { throw CaseFileError.notInCase("correction", id) }
            guard row.isNull(0) else { throw CaseFileError.addendumAlreadyConfirmed }
            try db.exec("UPDATE case_statement_addenda SET confirmed_by = ?, confirmed_at = ? WHERE id = ? AND case_id = ? AND confirmed_by IS NULL;",
                        [.text(by), .date(date), .uuid(id), .uuid(caseID)])
        }
    }

    public func addenda(caseID: UUID) async throws -> [StatementAddendum] {
        (try await database.query("""
            SELECT id, interview_id, case_id, text, reason, sha256, recorded_by, recorded_at, confirmed_by, confirmed_at
            FROM case_statement_addenda WHERE case_id = ? ORDER BY recorded_at, id;
            """, [.uuid(caseID)])).compactMap { r in
            guard let id = r.uuid(0), let iv = r.uuid(1), let c = r.uuid(2), let t = r.string(3), let why = r.string(4),
                  let h = r.string(5), let by = r.string(6), let at = r.date(7) else { return nil }
            return StatementAddendum(id: id, interviewID: iv, caseID: c, text: t, reason: why, sha256: h, recordedBy: by, recordedAt: at,
                                     confirmedBy: r.string(8), confirmedAt: r.date(9))
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
            try Self.requireInCase(db, "interview", interviewID, caseID: caseID)
            if let evidenceRef { try Self.requireResolvable(db, evidenceRef, caseID: caseID) }
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
            // An exhibit's source, when it has one, is a document in this case — a physical item has none.
            if let sourceRef { try Self.requireResolvable(db, sourceRef, caseID: caseID, sourceOnly: true) }
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
            try Self.requireInCase(db, "exhibit", id, caseID: caseID)
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
            if let personID { try Self.requireInCase(db, "person", personID, caseID: caseID) }
            try db.exec("""
                INSERT INTO case_hold_notices (id, case_id, custodian, person_id, notice_text, issued_at, issued_by, reminder_due) VALUES (?,?,?,?,?,?,?,?);
                """, [.uuid(UUID()), .uuid(caseID), .text(cu), personID.map { .uuid($0) } ?? .null, .text(text), .date(date), .text(actor), .optionalDate(reminderDue)])
        }
    }

    public func acknowledgeHold(caseID: UUID, id: UUID, acknowledgedAt: Date, actor: String) async throws {
        try await write("cf_holda", caseID: caseID, actor: try Self.clean(actor, "Actor"), action: "holdAcknowledged", detail: nil, at: Date()) { db in
            try Self.requireInCase(db, "hold notice", id, caseID: caseID)
            try db.exec("UPDATE case_hold_notices SET acknowledged_at = ? WHERE id = ? AND case_id = ?;", [.date(acknowledgedAt), .uuid(id), .uuid(caseID)])
        }
    }

    public func releaseHold(caseID: UUID, id: UUID, reason: String, actor: String, at date: Date = Date()) async throws {
        let reason = try Self.clean(reason, "The release reason")
        try await write("cf_holdr", caseID: caseID, actor: try Self.clean(actor, "Actor"), action: "holdReleased", detail: reason, at: date) { db in
            try Self.requireInCase(db, "hold notice", id, caseID: caseID)
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
            for ref in refs { try Self.requireResolvable(db, ref, caseID: caseID, sourceOnly: true) }
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
            try Self.requireInCase(db, "batch", id, caseID: caseID)
            try db.exec("UPDATE case_review_batches SET status = ?, qc_reviewer = ?, qc_note = ?, updated_at = ? WHERE id = ? AND case_id = ?;",
                        [.text(status.rawValue), status == .qcDone ? .text(actor) : .optionalText(b.qcReviewer),
                         status == .qcDone ? .optionalText(qcNote) : .optionalText(b.qcNote), .date(date), .uuid(id), .uuid(caseID)])
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

    /// Every case action written since the seal boundary, as audit-chain events (implementation
    /// brief §5). The free-text detail enters the chain as a digest, not as text.
    public func auditChainEvents() async throws -> [AuditChainEvent] {
        let boundary = try await database.query("SELECT sealed_from_at FROM case_action_seal_boundaries ORDER BY sealed_from_at LIMIT 1;").first?.date(0)
        guard let boundary else { return [] }
        let rows = try await database.query("""
            SELECT id, case_id, sequence, actor, action, detail, at FROM case_actions WHERE at >= ? ORDER BY at ASC, case_id ASC, sequence ASC;
            """, [.date(boundary)])
        return rows.compactMap { r in
            guard let id = r.uuid(0), let c = r.uuid(1), let seq = r.int(2), let actor = r.string(3), let action = r.string(4), let at = r.date(6) else { return nil }
            let payload = "action=\(action);actor=\(actor);at=\(at.timeIntervalSince1970);caseID=\(c.uuidString);"
                + "detailDigest=\(CaseFileHash.sha256(r.string(5) ?? ""));sequence=\(seq)"
            return AuditChainEvent(source: .caseAction, eventID: id, occurredAt: at, canonicalPayload: payload)
        }
    }

    /// Record a read or export (viewing the case file, exporting a report) — S-4.
    public func logAction(caseID: UUID, action: String, detail: String?, actor: String, at date: Date = Date()) async throws {
        try await write("cf_act", caseID: caseID, actor: try Self.clean(actor, "Actor"), action: action, detail: detail, at: date,
                        allowedWhenClosed: true) { _ in }
    }

    /// A readable name for each source version (the file name it was read from).
    public func sourceLabels(_ ids: [UUID]) async throws -> [UUID: String] {
        guard !ids.isEmpty else { return [:] }
        var out: [UUID: String] = [:]
        for chunk in stride(from: 0, to: ids.count, by: 400).map({ Array(ids[$0..<min($0 + 400, ids.count)]) }) {
            let rows = try await database.query(
                "SELECT id, original_url FROM source_versions WHERE id IN (\(chunk.map { _ in "?" }.joined(separator: ",")));",
                chunk.map { .uuid($0) })
            for r in rows {
                guard let id = r.uuid(0) else { continue }
                let url = r.string(1).flatMap { URL(string: $0) ?? URL(fileURLWithPath: $0) }
                let name = url.map { $0.lastPathComponent.removingPercentEncoding ?? $0.lastPathComponent } ?? ""
                out[id] = name.isEmpty ? "Source \(id.uuidString.prefix(8))" : name
            }
        }
        return out
    }

    // MARK: - Internals

    /// One savepoint: the change and its action-log row.
    private func write(_ prefix: String, caseID: UUID, actor: String, action: String, detail: String?, at date: Date,
                       allowedWhenClosed: Bool = false,
                       _ body: @escaping @Sendable (isolated Database) throws -> Void) async throws {
        let sp = "\(prefix)_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let clipped = detail.map { String($0.prefix(500)) }
        try await database.withSavepoint(sp) { db in
            guard try !db.query("SELECT 1 FROM investigation_cases WHERE id = ? LIMIT 1;", [.uuid(caseID)]).isEmpty else {
                throw CaseFileError.caseNotFound(caseID)
            }
            // A closed case takes no new work until it is reopened (reopening, archiving and recording
            // a read or an export are the exceptions) — implementation brief §3.
            if !allowedWhenClosed,
               try !db.query("SELECT 1 FROM case_profiles WHERE case_id = ? AND stage = 'closed' LIMIT 1;", [.uuid(caseID)]).isEmpty {
                throw CaseFileError.caseClosed
            }
            try body(db)
            let next = (try db.query("SELECT COALESCE(MAX(sequence), 0) FROM case_actions WHERE case_id = ?;", [.uuid(caseID)]).first?.int(0) ?? 0) + 1
            try db.exec("INSERT INTO case_actions (id, case_id, sequence, actor, action, detail, at) VALUES (?,?,?,?,?,?,?);",
                        [.uuid(UUID()), .uuid(caseID), .integer(next), .text(actor), .text(action), .optionalText(clipped), .date(date)])
        }
    }

    /// The child record must belong to the case the mutation is guarded by (implementation brief §3:
    /// an operation guarded by case A could link evidence to, or attest, case B's records). Checked
    /// inside the mutation's own savepoint, so nothing changes and nothing is logged when it fails.
    private static func requireInCase(_ db: isolated Database, _ what: String, _ id: UUID, caseID: UUID) throws {
        let sql: String
        switch what {
        case "allegation": sql = "SELECT 1 FROM case_allegations WHERE id = ? AND case_id = ?"
        case "evidence link": sql = "SELECT 1 FROM case_allegation_evidence e JOIN case_allegations a ON a.id = e.allegation_id WHERE e.id = ? AND a.case_id = ? AND e.removed_at IS NULL"
        case "journal entry": sql = "SELECT 1 FROM case_journal WHERE id = ? AND case_id = ? AND removed_at IS NULL"
        case "report item": sql = "SELECT 1 FROM case_report_items WHERE id = ? AND case_id = ?"
        case "person": sql = "SELECT 1 FROM case_people WHERE id = ? AND case_id = ? AND removed_at IS NULL"
        case "interview": sql = "SELECT 1 FROM case_interviews WHERE id = ? AND case_id = ?"
        case "exhibit": sql = "SELECT 1 FROM case_exhibits WHERE id = ? AND case_id = ? AND withdrawn_at IS NULL"
        case "hold notice": sql = "SELECT 1 FROM case_hold_notices WHERE id = ? AND case_id = ?"
        case "batch": sql = "SELECT 1 FROM case_review_batches WHERE id = ? AND case_id = ?"
        default: throw CaseFileError.notFound(what, id)
        }
        guard try !db.query(sql + " LIMIT 1;", [.uuid(id), .uuid(caseID)]).isEmpty else { throw CaseFileError.notInCase(what, id) }
    }

    /// A new reference must resolve in this case (brief §4): an in-scope source version, a live exhibit
    /// of this case, or an explicit investigator note. `sourceOnly` admits only a source version.
    private static func requireResolvable(_ db: isolated Database, _ raw: String, caseID: UUID, sourceOnly: Bool = false) throws {
        if sourceOnly {
            guard case .sourceVersion = CaseEvidenceReference.parse(raw) else {
                throw CaseFileError.unresolvedReference(raw, "only a source in this case can be chosen here")
            }
        }
        if let problem = try CaseEvidenceReference.problem(raw, caseID: caseID, in: db) {
            throw CaseFileError.unresolvedReference(raw, problem)
        }
    }

    /// The repair queue: every stored reference in the case that no longer resolves — legacy free
    /// text, a source taken out of scope, a withdrawn exhibit. Listed as written, never rewritten.
    public func unresolvedReferences(caseID: UUID) async throws -> [UnresolvedCaseReference] {
        try await database.withSavepoint("cf_refq_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))") { db in
            var refs: [(String, UUID, String)] = []
            let sources: [(record: String, sql: String, columns: Int)] = [
                ("Evidence grid", "SELECT e.id, e.evidence_ref FROM case_allegation_evidence e JOIN case_allegations a ON a.id = e.allegation_id WHERE a.case_id = ? AND e.removed_at IS NULL;", 1),
                ("Journal", "SELECT id, evidence_ref FROM case_journal WHERE case_id = ? AND removed_at IS NULL;", 1),
                ("Credibility note", "SELECT c.id, c.evidence_ref FROM case_credibility c JOIN case_interviews i ON i.id = c.interview_id WHERE i.case_id = ?;", 1),
                ("Exhibit", "SELECT id, source_ref FROM case_exhibits WHERE case_id = ? AND withdrawn_at IS NULL;", 1),
                ("Interview", "SELECT id, recording_ref, transcript_ref FROM case_interviews WHERE case_id = ?;", 2),
            ]
            for source in sources {
                for r in try db.query(source.sql, [.uuid(caseID)]) {
                    guard let id = r.uuid(0) else { continue }
                    for i in 1...source.columns { if let ref = r.string(i), !ref.isEmpty { refs.append((source.record, id, ref)) } }
                }
            }
            for r in try db.query("SELECT id, source_refs_json FROM case_review_batches WHERE case_id = ?;", [.uuid(caseID)]) {
                guard let id = r.uuid(0), let data = r.string(1)?.data(using: .utf8),
                      let list = try? JSONDecoder().decode([String].self, from: data) else { continue }
                refs += list.map { ("Review batch", id, $0) }
            }
            return try refs.compactMap { record, id, ref in
                try CaseEvidenceReference.problem(ref, caseID: caseID, in: db).map {
                    UnresolvedCaseReference(record: record, recordID: id, ref: ref, problem: $0)
                }
            }
        }
    }

    /// A trimmed string, or nil when blank.
    private static func blankToNil(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
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
