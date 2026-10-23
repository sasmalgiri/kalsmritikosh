//
//  ACHRepository.swift
//  Kalsmritikosh
//
//  A-6 — Competing hypotheses (ACH) in the ledger (schema v152). The matrix used to live in one
//  @AppStorage JSON blob; it now lives in ach_analyses / ach_hypotheses / ach_evidence / ach_cells,
//  scoped by an optional case (investigation_cases.id) or workspace, with who and when on every row.
//
//  The value model is unchanged: the repository reads and writes `ACHAnalysis`, so the inconsistency
//  scoring, ranking and diagnosticity logic in ACHAnalysis.swift runs exactly as before. Nothing is
//  deleted — removing a hypothesis, an evidence row or a whole analysis sets retracted_at/retracted_by
//  and the row stays in the record. A save carries the analysis's own updatedAt; a save older than
//  what the ledger already holds is refused (returns false), so out-of-order writes cannot roll the
//  matrix back.
//

import Foundation
import os

public nonisolated enum ACHRepositoryError: Error, Equatable, LocalizedError {
    case blankActor
    case retracted(UUID)

    public var errorDescription: String? {
        switch self {
        case .blankActor: return "A name is needed to record who made the change."
        case .retracted(let id): return "Analysis \(id.uuidString) was removed; it is kept in the record but can no longer be edited."
        }
    }
}

/// One analysis as the ledger holds it: the value model plus its scope and who made it.
public nonisolated struct ACHStoredAnalysis: Sendable, Identifiable, Hashable {
    public var id: UUID { analysis.id }
    public var analysis: ACHAnalysis
    public var caseID: UUID?
    public var workspaceID: UUID?
    public var createdBy: String
    public var updatedBy: String
    /// True when it came from the old on-device (AppStorage) store.
    public var importedFromDevice: Bool
}

public actor ACHRepository {
    /// The UserDefaults key the old view stored its JSON blob under. Read once for the import;
    /// never written or removed.
    public static let legacyAppStorageKey = "kalsmritikosh.ach.store"

    private let database: Database

    public init(database: Database) { self.database = database }

    // MARK: - Read

    /// Live (not retracted) analyses, newest first. `caseID` / `workspaceID` narrow the scope;
    /// both nil returns every live analysis.
    public func analyses(caseID: UUID? = nil, workspaceID: UUID? = nil) async throws -> [ACHStoredAnalysis] {
        var sql = "\(Self.analysisColumns) WHERE retracted_at IS NULL"
        var params: [SQLValue] = []
        if let caseID { sql += " AND case_id = ?"; params.append(.uuid(caseID)) }
        if let workspaceID { sql += " AND workspace_id = ?"; params.append(.uuid(workspaceID)) }
        sql += " ORDER BY updated_at DESC, id;"
        let heads = try await database.query(sql, params).compactMap(Self.decodeHead)
        return try await assemble(heads)
    }

    /// One analysis by id, including a retracted one (so the record can still be read).
    public func analysis(id: UUID) async throws -> ACHStoredAnalysis? {
        let heads = try await database.query("\(Self.analysisColumns) WHERE id = ? LIMIT 1;", [.uuid(id)]).compactMap(Self.decodeHead)
        return try await assemble(heads).first
    }

    public func isRetracted(id: UUID) async throws -> Bool {
        let rows = try await database.query("SELECT 1 FROM ach_analyses WHERE id = ? AND retracted_at IS NOT NULL LIMIT 1;", [.uuid(id)])
        return !rows.isEmpty
    }

    // MARK: - Write

    /// Save the whole analysis (header, hypotheses, evidence, cells) in ONE savepoint. Hypotheses and
    /// evidence missing from `a` are retracted, never deleted. Returns false (and writes nothing) when
    /// the ledger already holds a newer version of this analysis.
    @discardableResult
    public func save(_ a: ACHAnalysis, caseID: UUID? = nil, workspaceID: UUID? = nil,
                     actor: String, at date: Date = Date()) async throws -> Bool {
        let who = try Self.clean(actor)
        let sp = "ach_save_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let encoded = Self.encodeParts(a)
        return try await database.withSavepoint(sp) { db -> Bool in
            let existing = try db.query("SELECT updated_at, retracted_at FROM ach_analyses WHERE id = ? LIMIT 1;", [.uuid(a.id)]).first
            if let existing {
                if existing.date(1) != nil { throw ACHRepositoryError.retracted(a.id) }
                if let stored = existing.date(0), stored > a.updatedAt { return false }
            }
            try Self.writeAnalysis(db, a, encoded: encoded, caseID: caseID, workspaceID: workspaceID,
                                   origin: "ledger", actor: who, at: date)
            return true
        }
    }

    /// Retract an analysis: it disappears from the list but every row stays in the ledger.
    public func retract(analysisID: UUID, actor: String, at date: Date = Date()) async throws {
        let who = try Self.clean(actor)
        try await database.withSavepoint("ach_retract_\(analysisID.uuidString.replacingOccurrences(of: "-", with: ""))") { db in
            try db.exec("UPDATE ach_analyses SET retracted_at = ?, retracted_by = ? WHERE id = ? AND retracted_at IS NULL;",
                        [.date(date), .text(who), .uuid(analysisID)])
        }
    }

    /// Move an analysis to a case or workspace (or back to unscoped).
    public func assign(analysisID: UUID, caseID: UUID?, workspaceID: UUID?, actor: String, at date: Date = Date()) async throws {
        let who = try Self.clean(actor)
        try await database.withSavepoint("ach_assign_\(analysisID.uuidString.replacingOccurrences(of: "-", with: ""))") { db in
            try db.exec("UPDATE ach_analyses SET case_id = ?, workspace_id = ?, updated_by = ?, updated_at = MAX(updated_at, ?) WHERE id = ?;",
                        [Self.optionalUUID(caseID), Self.optionalUUID(workspaceID),
                         .text(who), .date(date), .uuid(analysisID)])
        }
    }

    // MARK: - One-time import of the old AppStorage store

    public func hasImportedLegacy(sourceKey: String = ACHRepository.legacyAppStorageKey) async throws -> Bool {
        !(try await database.query("SELECT 1 FROM ach_legacy_imports WHERE source_key = ? LIMIT 1;", [.text(sourceKey)])).isEmpty
    }

    /// Import analyses decoded from the old store, once. Analyses already in the ledger (same id) are
    /// left as they are. The marker row is written in the same savepoint, so a failed import leaves
    /// no marker and can be retried. Returns how many analyses were newly imported (0 when the import
    /// had already run).
    @discardableResult
    public func importLegacy(_ analyses: [ACHAnalysis], sourceKey: String = ACHRepository.legacyAppStorageKey,
                             actor: String, at date: Date = Date()) async throws -> Int {
        let who = try Self.clean(actor)
        let parts = analyses.map { ($0, Self.encodeParts($0)) }
        return try await database.withSavepoint("ach_import_legacy") { db -> Int in
            guard try db.query("SELECT 1 FROM ach_legacy_imports WHERE source_key = ? LIMIT 1;", [.text(sourceKey)]).isEmpty else { return 0 }
            var imported = 0
            for (a, encoded) in parts {
                guard try db.query("SELECT 1 FROM ach_analyses WHERE id = ? LIMIT 1;", [.uuid(a.id)]).isEmpty else { continue }
                try Self.writeAnalysis(db, a, encoded: encoded, caseID: nil, workspaceID: nil,
                                       origin: "appStorageImport", actor: who, at: date)
                imported += 1
            }
            try db.exec("INSERT INTO ach_legacy_imports (source_key, analysis_count, imported_by, imported_at) VALUES (?,?,?,?);",
                        [.text(sourceKey), .integer(Int64(imported)), .text(who), .date(date)])
            return imported
        }
    }

    // MARK: - Internals

    private nonisolated struct EncodedParts: Sendable {
        let assumptions: String
        let indicators: String
        let history: String
    }

    private static func encodeParts(_ a: ACHAnalysis) -> EncodedParts {
        EncodedParts(assumptions: json(a.assumptions), indicators: json(a.indicators), history: json(a.history ?? []))
    }

    private static func json<T: Encodable>(_ value: T) -> String {
        do {
            return String(data: try JSONEncoder().encode(value), encoding: .utf8) ?? "[]"
        } catch {
            KalsmritikoshLog.storage.error("ACH encode failed: \(error.localizedDescription, privacy: .public)")
            return "[]"
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ raw: String?) -> T? {
        guard let raw, let data = raw.data(using: .utf8) else { return nil }
        do { return try JSONDecoder().decode(type, from: data) } catch {
            KalsmritikoshLog.storage.error("ACH decode failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// The synchronous body shared by save and import.
    private static func writeAnalysis(_ db: isolated Database, _ a: ACHAnalysis, encoded: EncodedParts,
                                      caseID: UUID?, workspaceID: UUID?, origin: String,
                                      actor: String, at date: Date) throws {
        try db.exec("""
            INSERT INTO ach_analyses (id, case_id, workspace_id, title, question, assumptions_json, indicators_json,
                leading_hypothesis_id, confidence, conclusion_summary, history_json, origin,
                created_by, created_at, updated_by, updated_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET case_id = excluded.case_id, workspace_id = excluded.workspace_id,
                title = excluded.title, question = excluded.question, assumptions_json = excluded.assumptions_json,
                indicators_json = excluded.indicators_json, leading_hypothesis_id = excluded.leading_hypothesis_id,
                confidence = excluded.confidence, conclusion_summary = excluded.conclusion_summary,
                history_json = excluded.history_json, updated_by = excluded.updated_by, updated_at = excluded.updated_at;
            """, headerBindings(a, encoded: encoded, caseID: caseID, workspaceID: workspaceID, origin: origin, actor: actor))

        // Hypotheses (columns) — upsert in order, retract the ones no longer present.
        let liveH = Set(try db.query("SELECT id FROM ach_hypotheses WHERE analysis_id = ? AND retracted_at IS NULL;",
                                     [.uuid(a.id)]).compactMap { $0.uuid(0) })
        for (i, h) in a.hypotheses.enumerated() {
            try db.exec("""
                INSERT INTO ach_hypotheses (id, analysis_id, position, text, created_by, created_at, updated_by, updated_at)
                VALUES (?,?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET position = excluded.position, text = excluded.text,
                    updated_by = excluded.updated_by, updated_at = excluded.updated_at, retracted_at = NULL, retracted_by = NULL
                WHERE ach_hypotheses.analysis_id = excluded.analysis_id
                  AND (ach_hypotheses.position != excluded.position OR ach_hypotheses.text != excluded.text
                       OR ach_hypotheses.retracted_at IS NOT NULL);
                """, [.uuid(h.id), .uuid(a.id), .integer(Int64(i)), .text(h.text), .text(actor), .date(date), .text(actor), .date(date)])
        }
        for gone in liveH.subtracting(a.hypotheses.map(\.id)) {
            try db.exec("UPDATE ach_hypotheses SET retracted_at = ?, retracted_by = ? WHERE id = ? AND retracted_at IS NULL;",
                        [.date(date), .text(actor), .uuid(gone)])
        }

        // Evidence (rows) — same rule.
        let liveE = Set(try db.query("SELECT id FROM ach_evidence WHERE analysis_id = ? AND retracted_at IS NULL;",
                                     [.uuid(a.id)]).compactMap { $0.uuid(0) })
        for (i, e) in a.evidence.enumerated() {
            try db.exec("""
                INSERT INTO ach_evidence (id, analysis_id, position, text, source, created_by, created_at, updated_by, updated_at)
                VALUES (?,?,?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET position = excluded.position, text = excluded.text, source = excluded.source,
                    updated_by = excluded.updated_by, updated_at = excluded.updated_at, retracted_at = NULL, retracted_by = NULL
                WHERE ach_evidence.analysis_id = excluded.analysis_id
                  AND (ach_evidence.position != excluded.position OR ach_evidence.text != excluded.text
                       OR ach_evidence.source != excluded.source OR ach_evidence.retracted_at IS NOT NULL);
                """, [.uuid(e.id), .uuid(a.id), .integer(Int64(i)), .text(e.text), .text(e.source),
                      .text(actor), .date(date), .text(actor), .date(date)])
        }
        for gone in liveE.subtracting(a.evidence.map(\.id)) {
            try db.exec("UPDATE ach_evidence SET retracted_at = ?, retracted_by = ? WHERE id = ? AND retracted_at IS NULL;",
                        [.date(date), .text(actor), .uuid(gone)])
        }

        // Cells — keyed "evidenceID|hypothesisID" exactly as ACHAnalysis.key builds them.
        for (key, rating) in a.ratings {
            let parts = key.split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count == 2, let eid = UUID(uuidString: String(parts[0])), let hid = UUID(uuidString: String(parts[1])) else { continue }
            try db.exec("""
                INSERT INTO ach_cells (analysis_id, evidence_id, hypothesis_id, consistency, updated_by, updated_at)
                VALUES (?,?,?,?,?,?)
                ON CONFLICT(evidence_id, hypothesis_id) DO UPDATE SET consistency = excluded.consistency,
                    updated_by = excluded.updated_by, updated_at = excluded.updated_at
                WHERE ach_cells.analysis_id = excluded.analysis_id AND ach_cells.consistency != excluded.consistency;
                """, [.uuid(a.id), .uuid(eid), .uuid(hid), .text(rating.rawValue), .text(actor), .date(date)])
        }
    }

    private nonisolated struct Head: Sendable {
        var analysis: ACHAnalysis
        var caseID: UUID?
        var workspaceID: UUID?
        var createdBy: String
        var updatedBy: String
        var imported: Bool
    }

    private static let analysisColumns = """
        SELECT id, case_id, workspace_id, title, question, assumptions_json, indicators_json, leading_hypothesis_id,
               confidence, conclusion_summary, history_json, origin, created_by, created_at, updated_by, updated_at
        FROM ach_analyses
        """

    private static func decodeHead(_ r: SQLRow) -> Head? {
        guard let id = r.uuid(0), let title = r.string(3), let created = r.date(13), let updated = r.date(15) else { return nil }
        var a = ACHAnalysis(title: title, now: created)
        a.id = id
        a.question = r.string(4) ?? ""
        a.assumptions = decode([String].self, r.string(5)) ?? []
        a.indicators = decode([String].self, r.string(6)) ?? []
        a.conclusion.leadingHypothesisID = r.uuid(7)
        a.conclusion.confidence = r.string(8).flatMap(ACHConfidence.init(rawValue:)) ?? .moderate
        a.conclusion.summary = r.string(9) ?? ""
        let history = decode([StudioAuditEntry].self, r.string(10)) ?? []
        a.history = history.isEmpty ? nil : history
        a.createdAt = created
        a.updatedAt = updated
        return Head(analysis: a, caseID: r.uuid(1), workspaceID: r.uuid(2), createdBy: r.string(12) ?? "",
                    updatedBy: r.string(14) ?? "", imported: r.string(11) == "appStorageImport")
    }

    private func assemble(_ heads: [Head]) async throws -> [ACHStoredAnalysis] {
        guard !heads.isEmpty else { return [] }
        let ids = Self.json(heads.map { $0.analysis.id.uuidString })
        let hRows = try await database.query("""
            SELECT analysis_id, id, text FROM ach_hypotheses
            WHERE analysis_id IN (SELECT value FROM json_each(?)) AND retracted_at IS NULL ORDER BY analysis_id, position, created_at;
            """, [.text(ids)])
        let eRows = try await database.query("""
            SELECT analysis_id, id, text, source FROM ach_evidence
            WHERE analysis_id IN (SELECT value FROM json_each(?)) AND retracted_at IS NULL ORDER BY analysis_id, position, created_at;
            """, [.text(ids)])
        let cRows = try await database.query("""
            SELECT analysis_id, evidence_id, hypothesis_id, consistency FROM ach_cells
            WHERE analysis_id IN (SELECT value FROM json_each(?));
            """, [.text(ids)])
        var hyps: [UUID: [ACHHypothesis]] = [:]
        for r in hRows {
            guard let aid = r.uuid(0), let id = r.uuid(1), let text = r.string(2) else { continue }
            var h = ACHHypothesis(text: text); h.id = id
            hyps[aid, default: []].append(h)
        }
        var evs: [UUID: [ACHEvidence]] = [:]
        for r in eRows {
            guard let aid = r.uuid(0), let id = r.uuid(1), let text = r.string(2) else { continue }
            var e = ACHEvidence(text: text, source: r.string(3) ?? ""); e.id = id
            evs[aid, default: []].append(e)
        }
        var cells: [UUID: [String: ACHConsistency]] = [:]
        for r in cRows {
            guard let aid = r.uuid(0), let eid = r.uuid(1), let hid = r.uuid(2),
                  let c = r.string(3).flatMap(ACHConsistency.init(rawValue:)) else { continue }
            cells[aid, default: [:]][ACHAnalysis.key(eid, hid)] = c
        }
        return heads.map { head in
            var a = head.analysis
            a.hypotheses = hyps[a.id] ?? []
            a.evidence = evs[a.id] ?? []
            a.ratings = cells[a.id] ?? [:]
            return ACHStoredAnalysis(analysis: a, caseID: head.caseID, workspaceID: head.workspaceID,
                                     createdBy: head.createdBy, updatedBy: head.updatedBy, importedFromDevice: head.imported)
        }
    }

    private static func optionalUUID(_ id: UUID?) -> SQLValue {
        guard let id else { return .null }
        return .uuid(id)
    }

    private static func headerBindings(_ a: ACHAnalysis, encoded: EncodedParts, caseID: UUID?, workspaceID: UUID?,
                                       origin: String, actor: String) -> [SQLValue] {
        var v: [SQLValue] = [.uuid(a.id), optionalUUID(caseID), optionalUUID(workspaceID)]
        v += [.text(a.title), .text(a.question), .text(encoded.assumptions), .text(encoded.indicators)]
        v += [optionalUUID(a.conclusion.leadingHypothesisID), .text(a.conclusion.confidence.rawValue)]
        v += [.text(a.conclusion.summary), .text(encoded.history), .text(origin)]
        v += [.text(actor), .date(a.createdAt), .text(actor), .date(a.updatedAt)]
        return v
    }

    private static func clean(_ actor: String) throws -> String {
        let t = actor.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { throw ACHRepositoryError.blankActor }
        return t
    }
}
