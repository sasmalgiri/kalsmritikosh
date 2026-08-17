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

public actor WorkCenterRepository {
    private let database: Database

    public init(database: Database) { self.database = database }

    // MARK: - Number ranges (transactional)

    /// Issue the next TYPE-YEAR-#### number. Runs inside the caller's
    /// savepoint when composed; standalone it is a single UPDATE-or-INSERT
    /// plus read on the serialized database actor.
    private func issueNumber(type: String, at date: Date) async throws -> String {
        let year = Calendar(identifier: .gregorian).component(.year, from: date)
        try await database.exec("""
            INSERT INTO work_center_counters (doc_type, year, next_seq) VALUES (?,?,2)
            ON CONFLICT(doc_type, year) DO UPDATE SET next_seq = next_seq + 1;
            """, [.text(type), .integer(Int64(year))])
        let rows = try await database.query(
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
        let sp = "wcrun_\(id.uuidString.replacingOccurrences(of: "-", with: ""))"
        do {
            try await database.exec("SAVEPOINT \(sp);")
            let number = try await issueNumber(type: "WF", at: date)
            try await database.exec("""
                INSERT INTO work_center_documents
                    (id, doc_number, doc_type, run_id, def_id, step_seq, title, status,
                     fields_json, confirmed_seqs, actor, created_at, updated_at)
                VALUES (?,?,?,NULL,?,NULL,?,?,?,?,?,?,?);
                """, [.uuid(id), .text(number), .text("WF"), .text(defID),
                      .text(title), .text(WCRunStatus.open.rawValue),
                      .text("{}"), .text(""), .text(actor), .real(date.timeIntervalSince1970),
                      .real(date.timeIntervalSince1970)])
            try await database.exec("RELEASE SAVEPOINT \(sp);")
        } catch {
            try? await database.exec("ROLLBACK TO SAVEPOINT \(sp);")
            try? await database.exec("RELEASE SAVEPOINT \(sp);")
            throw error
        }
        return try await requireRun(id)
    }

    /// Save (or update) the captured field values for one step of a run.
    public func saveFields(runID: UUID, seq: Int, values: [String: String], at date: Date) async throws {
        let run = try await requireRun(runID)
        var all = run.fieldValues
        all[seq] = values
        try await database.exec(
            "UPDATE work_center_documents SET fields_json = ?, updated_at = ? WHERE id = ?;",
            [.text(Self.encodeFields(all)), .real(date.timeIntervalSince1970), .uuid(runID)])
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

        var stepDoc: WCDocument?
        let sp = "wcstep_\(runID.uuidString.replacingOccurrences(of: "-", with: ""))_\(seq)"
        do {
            try await database.exec("SAVEPOINT \(sp);")
            if let type = op.postsDocType {
                let id = UUID()
                let number = try await issueNumber(type: type, at: date)
                try await database.exec("""
                    INSERT INTO work_center_documents
                        (id, doc_number, doc_type, run_id, def_id, step_seq, title, status,
                         fields_json, confirmed_seqs, actor, created_at, updated_at)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?);
                    """, [.uuid(id), .text(number), .text(type), .uuid(runID), .text(defID),
                          .integer(Int64(seq)), .text("\(op.title) — \(run.title)"),
                          .text(WCRunStatus.confirmed.rawValue),
                          .text(Self.encodeFields([seq: values])), .text("\(seq)"),
                          .text(actor), .real(date.timeIntervalSince1970),
                          .real(date.timeIntervalSince1970)])
                stepDoc = try await requireRun(id)
            }
            var confirmed = run.confirmedSeqs
            confirmed.insert(seq)
            let joined = confirmed.sorted().map(String.init).joined(separator: ",")
            // The run auto-advances open -> released on first confirmation, and
            // released -> confirmed when every operation is done (the SAP
            // lifecycle; statuses only ever move forward).
            let allDone = confirmed.count == def.operations.count
            let newStatus: WCRunStatus = allDone ? .confirmed : .released
            try await database.exec("""
                UPDATE work_center_documents
                SET confirmed_seqs = ?, status = ?, updated_at = ? WHERE id = ?;
                """, [.text(joined), .text(newStatus.rawValue),
                      .real(date.timeIntervalSince1970), .uuid(runID)])
            try await database.exec("RELEASE SAVEPOINT \(sp);")
        } catch {
            try? await database.exec("ROLLBACK TO SAVEPOINT \(sp);")
            try? await database.exec("RELEASE SAVEPOINT \(sp);")
            throw error
        }
        return (stepDoc, try await requireRun(runID))
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
