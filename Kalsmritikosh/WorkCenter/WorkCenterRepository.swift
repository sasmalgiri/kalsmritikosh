//
//  WorkCenterRepository.swift
//  Kalsmritikosh
//
//  WORK-CENTER persistence (migration v105) — the numbered-document ledger
//  behind the Work Center. One actor over the single Database: transactional
//  number ranges (SAP-style TYPE-YEAR-#### from work_center_counters), run
//  documents (WF-…) holding captured fields + confirmed steps, and step
//  documents (IMP/RPT/PRD/…) posted on confirmation. The repository is
//  FAIL-CLOSED: confirming a step re-validates required fields and gates
//  itself — the UI's checks are a convenience, not the enforcement.
//

import Foundation

public enum WorkCenterError: Error, Equatable {
    case runNotFound(UUID)
    case unknownDefinition(String)
    case unknownStep(Int)
    case stepAlreadyConfirmed(Int)
    case missingRequiredFields([String])
    case gatesLocked([String])
    case invalidStatusAdvance(from: String, to: String)
}

public nonisolated enum WCRunStatus: String, Sendable, Equatable, CaseIterable {
    case open, released, confirmed
}

public nonisolated struct WCDocument: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let docNumber: String
    public let docType: String
    public let runID: UUID?
    public let defID: String?
    public let stepSeq: Int?
    public let title: String
    public let status: WCRunStatus
    /// Captured field values. Run docs: seq -> (key -> value). Step docs: flat map under their own seq.
    public let fieldValues: [Int: [String: String]]
    public let confirmedSeqs: Set<Int>
    public let actor: String
    public let createdAt: Date
    public let updatedAt: Date
}

/// One sealed field change to an editable register record (migration v106).
/// Append-only: corrections are further edits, never rewrites of this row.
public nonisolated struct WCRecordEdit: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let docID: UUID
    public let fieldKey: String
    public let oldValue: String
    public let newValue: String
    public let editor: String
    public let note: String
    public let editedAt: Date
}

public actor WorkCenterRepository {
    private let database: Database

    public init(database: Database) { self.database = database }

    // MARK: - Number ranges (transactional)

    /// Issue the next TYPE-YEAR-#### number — SYNCHRONOUS, called only from
    /// inside a `database.withSavepoint` isolated closure. Actors are
    /// re-entrant across `await`, so the async increment-then-read version
    /// could interleave two callers between the two statements and hand out
    /// the SAME number (caught by the concurrent-burst test; the schema's
    /// UNIQUE then rejected the insert). Zero suspension points here means
    /// zero interleaving window.
    private nonisolated static func issueNumber(_ db: isolated Database,
                                                type: String, at date: Date) throws -> String {
        let year = Calendar(identifier: .gregorian).component(.year, from: date)
        try db.exec("""
            INSERT INTO work_center_counters (doc_type, year, next_seq) VALUES (?,?,2)
            ON CONFLICT(doc_type, year) DO UPDATE SET next_seq = next_seq + 1;
            """, [.text(type), .integer(Int64(year))])
        let rows = try db.query(
            "SELECT next_seq FROM work_center_counters WHERE doc_type = ? AND year = ?;",
            [.text(type), .integer(Int64(year))])
        let next = Int(rows.first?.int(0) ?? 2)
        return WCDocumentNumber.format(type: type, year: year, sequence: next - 1)
    }

    // MARK: - Runs

    /// Start a run: posts the WF- run document (status open).
    public func createRun(defID: String, title: String, actor: String, at date: Date) async throws -> WCDocument {
        guard WCCatalog.definition(defID) != nil else { throw WorkCenterError.unknownDefinition(defID) }
        let id = UUID()
        try await database.withSavepoint("wcrun_\(id.uuidString.replacingOccurrences(of: "-", with: ""))") { db in
            let number = try Self.issueNumber(db, type: "WF", at: date)
            try db.exec("""
                INSERT INTO work_center_documents
                    (id, doc_number, doc_type, run_id, def_id, step_seq, title, status,
                     fields_json, confirmed_seqs, actor, created_at, updated_at)
                VALUES (?,?,?,NULL,?,NULL,?,?,?,?,?,?,?);
                """, [.uuid(id), .text(number), .text("WF"), .text(defID),
                      .text(title), .text(WCRunStatus.open.rawValue),
                      .text("{}"), .text(""), .text(actor), .real(date.timeIntervalSince1970),
                      .real(date.timeIntervalSince1970)])
        }
        return try await requireRun(id)
    }

    /// Save (or update) the captured field values for one step of a run.
    /// Read-modify-write of fields_json runs inside ONE isolated closure so
    /// a concurrent save can never clobber another step's just-saved values.
    public func saveFields(runID: UUID, seq: Int, values: [String: String], at date: Date) async throws {
        _ = try await requireRun(runID)   // friendly not-found error first
        try await database.withSavepoint("wcsave_\(runID.uuidString.replacingOccurrences(of: "-", with: ""))_\(seq)") { db in
            let rows = try db.query(
                "SELECT fields_json FROM work_center_documents WHERE id = ? LIMIT 1;", [.uuid(runID)])
            guard let json = rows.first?.string(0) else { throw WorkCenterError.runNotFound(runID) }
            var all = Self.decodeFields(json)
            all[seq] = values
            try db.exec(
                "UPDATE work_center_documents SET fields_json = ?, updated_at = ? WHERE id = ?;",
                [.text(Self.encodeFields(all)), .real(date.timeIntervalSince1970), .uuid(runID)])
        }
    }

    /// Confirm a step: re-validates required fields + gates (fail-closed),
    /// records the confirmation, and — when the step posts — issues the step
    /// its own numbered document. Returns (stepDoc?, updatedRun).
    public func confirmStep(runID: UUID, seq: Int, actor: String, at date: Date) async throws -> (WCDocument?, WCDocument) {
        let run = try await requireRun(runID)
        guard let defID = run.defID, let def = WCCatalog.definition(defID) else {
            throw WorkCenterError.unknownDefinition(run.defID ?? "nil")
        }
        guard let op = def.operations.first(where: { $0.seq == seq }) else {
            throw WorkCenterError.unknownStep(seq)
        }
        guard !run.confirmedSeqs.contains(seq) else { throw WorkCenterError.stepAlreadyConfirmed(seq) }
        let values = run.fieldValues[seq] ?? [:]
        let missing = WCFieldValidation.missingRequired(op.fields, values: values)
        guard missing.isEmpty else { throw WorkCenterError.missingRequiredFields(missing) }
        let locked = WCGatePolicy.lockedReasons(op, state: .init(
            confirmed: run.confirmedSeqs, fieldValues: run.fieldValues))
        guard locked.isEmpty else { throw WorkCenterError.gatesLocked(locked) }

        // The write section runs as ONE isolated closure — no suspension
        // points, so number issue + step-doc insert + run update can never
        // interleave with another confirm/save. Authoritative state (fields,
        // confirmed set) is RE-READ inside the barrier; the friendly checks
        // above are advisory, the closure is the enforcement.
        let opTitle = op.title
        let postsType = op.postsDocType
        let totalOps = def.operations.count
        let stepDocID: UUID? = try await database.withSavepoint(
            "wcstep_\(runID.uuidString.replacingOccurrences(of: "-", with: ""))_\(seq)") { db in
            let rows = try db.query("""
                SELECT fields_json, confirmed_seqs, title FROM work_center_documents
                WHERE id = ? LIMIT 1;
                """, [.uuid(runID)])
            guard let row = rows.first, let json = row.string(0),
                  let confirmedRaw = row.string(1), let runTitle = row.string(2) else {
                throw WorkCenterError.runNotFound(runID)
            }
            var confirmed = Set(confirmedRaw.split(separator: ",").compactMap { Int($0) })
            guard !confirmed.contains(seq) else { throw WorkCenterError.stepAlreadyConfirmed(seq) }

            // Stamp the attestation (who/when) into the step's value map — the
            // reserved keys ride inside fields_json so both the run and the
            // posted document carry the record with no extra table.
            var allFields = Self.decodeFields(json)
            var stamped = allFields[seq] ?? [:]
            stamped[WCReservedKey.confirmedAt] = String(date.timeIntervalSince1970)
            stamped[WCReservedKey.confirmedBy] = actor
            allFields[seq] = stamped

            var stepID: UUID?
            if let type = postsType {
                let id = UUID()
                let number = try Self.issueNumber(db, type: type, at: date)
                try db.exec("""
                    INSERT INTO work_center_documents
                        (id, doc_number, doc_type, run_id, def_id, step_seq, title, status,
                         fields_json, confirmed_seqs, actor, created_at, updated_at)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?);
                    """, [.uuid(id), .text(number), .text(type), .uuid(runID), .text(defID),
                          .integer(Int64(seq)), .text("\(opTitle) — \(runTitle)"),
                          .text(WCRunStatus.confirmed.rawValue),
                          .text(Self.encodeFields([seq: stamped])), .text("\(seq)"),
                          .text(actor), .real(date.timeIntervalSince1970),
                          .real(date.timeIntervalSince1970)])
                stepID = id
            }
            confirmed.insert(seq)
            let joined = confirmed.sorted().map(String.init).joined(separator: ",")
            // The run auto-advances open -> released on first confirmation, and
            // released -> confirmed when every operation is done (the SAP
            // lifecycle; statuses only ever move forward).
            let newStatus: WCRunStatus = confirmed.count == totalOps ? .confirmed : .released
            try db.exec("""
                UPDATE work_center_documents
                SET confirmed_seqs = ?, status = ?, fields_json = ?, updated_at = ? WHERE id = ?;
                """, [.text(joined), .text(newStatus.rawValue), .text(Self.encodeFields(allFields)),
                      .real(date.timeIntervalSince1970), .uuid(runID)])
            return stepID
        }
        var stepDoc: WCDocument?
        if let stepDocID { stepDoc = try await self.run(stepDocID) }
        return (stepDoc, try await requireRun(runID))
    }

    // MARK: - Universal capture (SAP: anything that leaves the app gets a number)

    /// Post a standalone numbered document outside any run — the "universal
    /// capture" of the source system: an export, a produced artifact, any
    /// completed piece of work becomes a quotable TYPE-YEAR-#### record in
    /// the register, with its facts riding in fields_json.
    public func capture(type: String, title: String, values: [String: String],
                        actor: String, at date: Date) async throws -> WCDocument {
        let id = UUID()
        try await database.withSavepoint("wccap_\(id.uuidString.replacingOccurrences(of: "-", with: ""))") { db in
            let number = try Self.issueNumber(db, type: type, at: date)
            try db.exec("""
                INSERT INTO work_center_documents
                    (id, doc_number, doc_type, run_id, def_id, step_seq, title, status,
                     fields_json, confirmed_seqs, actor, created_at, updated_at)
                VALUES (?,?,?,NULL,NULL,NULL,?,?,?,?,?,?,?);
                """, [.uuid(id), .text(number), .text(type), .text(title),
                      .text(WCRunStatus.confirmed.rawValue),
                      .text(Self.encodeFields([1: values])), .text(""),
                      .text(actor), .real(date.timeIntervalSince1970),
                      .real(date.timeIntervalSince1970)])
        }
        return try await requireRun(id)
    }

    // MARK: - Variants & rename

    /// Rename a run (the "Client / matter" name) so it's findable later.
    public func rename(runID: UUID, title: String, at date: Date) async throws {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        _ = try await requireRun(runID)
        try await database.exec(
            "UPDATE work_center_documents SET title = ?, updated_at = ? WHERE id = ?;",
            [.text(clean), .real(date.timeIntervalSince1970), .uuid(runID)])
    }

    /// Save a run's entries as a reusable VARIANT (SAP master data): a
    /// numbered VAR- document holding the field values, minus reserved
    /// system keys — a variant is a template, not a specific run's record.
    public func createVariant(defID: String, name: String, values: [Int: [String: String]],
                              actor: String, at date: Date) async throws -> WCDocument {
        guard WCCatalog.definition(defID) != nil else { throw WorkCenterError.unknownDefinition(defID) }
        let clean = values.mapValues { $0.filter { !WCReservedKey.isReserved($0.key) } }
            .filter { !$0.value.isEmpty }
        let id = UUID()
        try await database.withSavepoint("wcvar_\(id.uuidString.replacingOccurrences(of: "-", with: ""))") { db in
            let number = try Self.issueNumber(db, type: "VAR", at: date)
            try db.exec("""
                INSERT INTO work_center_documents
                    (id, doc_number, doc_type, run_id, def_id, step_seq, title, status,
                     fields_json, confirmed_seqs, actor, created_at, updated_at)
                VALUES (?,?,?,NULL,?,NULL,?,?,?,?,?,?,?);
                """, [.uuid(id), .text(number), .text("VAR"), .text(defID),
                      .text(name), .text(WCRunStatus.confirmed.rawValue),
                      .text(Self.encodeFields(clean)), .text(""), .text(actor),
                      .real(date.timeIntervalSince1970), .real(date.timeIntervalSince1970)])
        }
        return try await requireRun(id)
    }

    /// Saved variants for one workflow definition, newest first.
    public func variants(defID: String) async throws -> [WCDocument] {
        let rows = try await database.query(
            "\(select) WHERE doc_type = 'VAR' AND def_id = ? ORDER BY created_at DESC;",
            [.text(defID)])
        return rows.compactMap(Self.decode)
    }

    // MARK: - Registers (editable records with a change history)

    /// Create a register record — a numbered, editable document of `type`
    /// (INT/REQ/LOG). Reuses the transactional `capture` path; the record's
    /// field values ride under seq 1, exactly like a captured document.
    public func createRecord(type: String, title: String, values: [String: String],
                             actor: String, at date: Date) async throws -> WCDocument {
        try await capture(type: type, title: title, values: values, actor: actor, at: date)
    }

    /// Edit a register record in place, sealing every changed field to the
    /// append-only edit log (v106). Title is re-derived by the caller (which
    /// knows the register schema) and passed in. Read-modify-write + the diff
    /// insert happen in ONE isolated closure so a concurrent edit can't
    /// interleave — the same zero-suspension discipline as issueNumber.
    /// Returns the number of fields actually changed (0 = no-op, nothing logged).
    @discardableResult
    public func updateRecord(docID: UUID, title: String, values: [String: String],
                             editor: String, note: String, at date: Date) async throws -> Int {
        _ = try await requireRun(docID)   // fail-closed: the record must exist
        return try await database.withSavepoint(
            "wcedit_\(docID.uuidString.replacingOccurrences(of: "-", with: ""))") { db in
            let rows = try db.query(
                "SELECT fields_json FROM work_center_documents WHERE id = ? LIMIT 1;", [.uuid(docID)])
            guard let json = rows.first?.string(0) else { throw WorkCenterError.runNotFound(docID) }
            let old = Self.decodeFields(json)[1] ?? [:]

            // The union of keys present before or after — captures adds, edits, clears.
            let keys = Set(old.keys).union(values.keys)
            var changed = 0
            for key in keys.sorted() {
                let before = old[key] ?? ""
                let after = values[key] ?? ""
                guard before != after else { continue }
                try db.exec("""
                    INSERT INTO work_center_record_edits
                        (id, doc_id, field_key, old_value, new_value, editor, note, edited_at)
                    VALUES (?,?,?,?,?,?,?,?);
                    """, [.uuid(UUID()), .uuid(docID), .text(key), .text(before), .text(after),
                          .text(editor), .text(note), .real(date.timeIntervalSince1970)])
                changed += 1
            }
            guard changed > 0 else { return 0 }
            try db.exec("""
                UPDATE work_center_documents
                SET fields_json = ?, title = ?, updated_at = ? WHERE id = ?;
                """, [.text(Self.encodeFields([1: values])), .text(title),
                      .real(date.timeIntervalSince1970), .uuid(docID)])
            return changed
        }
    }

    /// Every record of one register type, newest first.
    public func records(type: String, limit: Int = 500) async throws -> [WCDocument] {
        let rows = try await database.query(
            "\(select) WHERE doc_type = ? ORDER BY created_at DESC LIMIT ?;",
            [.text(type), .integer(Int64(limit))])
        return rows.compactMap(Self.decode)
    }

    /// The change history for a record, newest edit first.
    public func editHistory(docID: UUID) async throws -> [WCRecordEdit] {
        let rows = try await database.query("""
            SELECT id, doc_id, field_key, old_value, new_value, editor, note, edited_at
            FROM work_center_record_edits WHERE doc_id = ? ORDER BY edited_at DESC;
            """, [.uuid(docID)])
        return rows.compactMap { r in
            guard let id = r.uuid(0), let docID = r.uuid(1), let key = r.string(2),
                  let editor = r.string(5), let at = r.double(7) else { return nil }
            return WCRecordEdit(
                id: id, docID: docID, fieldKey: key,
                oldValue: r.string(3) ?? "", newValue: r.string(4) ?? "",
                editor: editor, note: r.string(6) ?? "",
                editedAt: Date(timeIntervalSince1970: at))
        }
    }

    // MARK: - Queries

    public func run(_ id: UUID) async throws -> WCDocument? {
        let rows = try await database.query(
            "\(select) WHERE id = ? LIMIT 1;", [.uuid(id)])
        return rows.first.flatMap(Self.decode)
    }

    /// All WF run documents, newest first (optionally one definition's).
    public func runs(defID: String? = nil) async throws -> [WCDocument] {
        let rows: [SQLRow]
        if let defID {
            rows = try await database.query(
                "\(select) WHERE doc_type = 'WF' AND def_id = ? ORDER BY created_at DESC;", [.text(defID)])
        } else {
            rows = try await database.query(
                "\(select) WHERE doc_type = 'WF' ORDER BY created_at DESC;", [])
        }
        return rows.compactMap(Self.decode)
    }

    /// Step documents posted by a run, in step order.
    public func documents(inRun runID: UUID) async throws -> [WCDocument] {
        let rows = try await database.query(
            "\(select) WHERE run_id = ? ORDER BY step_seq ASC;", [.uuid(runID)])
        return rows.compactMap(Self.decode)
    }

    /// Every document, newest first — the Work Center "Documents" register.
    public func allDocuments(limit: Int = 200) async throws -> [WCDocument] {
        let rows = try await database.query(
            "\(select) ORDER BY created_at DESC LIMIT ?;", [.integer(Int64(limit))])
        return rows.compactMap(Self.decode)
    }

    // MARK: - Internals

    private let select = """
        SELECT id, doc_number, doc_type, run_id, def_id, step_seq, title, status,
               fields_json, confirmed_seqs, actor, created_at, updated_at
        FROM work_center_documents
        """

    private func requireRun(_ id: UUID) async throws -> WCDocument {
        guard let doc = try await run(id) else { throw WorkCenterError.runNotFound(id) }
        return doc
    }

    private static func decode(_ r: SQLRow) -> WCDocument? {
        guard let id = r.uuid(0), let number = r.string(1), let type = r.string(2),
              let title = r.string(6), let statusRaw = r.string(7),
              let status = WCRunStatus(rawValue: statusRaw),
              let fieldsJSON = r.string(8), let confirmedRaw = r.string(9),
              let actor = r.string(10), let created = r.double(11), let updated = r.double(12)
        else { return nil }
        return WCDocument(
            id: id, docNumber: number, docType: type,
            runID: r.uuid(3), defID: r.string(4), stepSeq: r.int(5).map(Int.init),
            title: title, status: status,
            fieldValues: decodeFields(fieldsJSON),
            confirmedSeqs: Set(confirmedRaw.split(separator: ",").compactMap { Int($0) }),
            actor: actor,
            createdAt: Date(timeIntervalSince1970: created),
            updatedAt: Date(timeIntervalSince1970: updated))
    }

    static func encodeFields(_ values: [Int: [String: String]]) -> String {
        let keyed = Dictionary(uniqueKeysWithValues: values.map { (String($0.key), $0.value) })
        guard let data = try? JSONEncoder().encode(keyed),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    static func decodeFields(_ json: String) -> [Int: [String: String]] {
        guard let data = json.data(using: .utf8),
              let keyed = try? JSONDecoder().decode([String: [String: String]].self, from: data)
        else { return [:] }
        return Dictionary(uniqueKeysWithValues: keyed.compactMap { k, v in Int(k).map { ($0, v) } })
    }
}
