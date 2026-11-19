//
//  CaseConflictDetailsRepository.swift
//  Kalsmritikosh
//
//  Owner request 2026-11-16 (AI conflict scaffolding) — schema v192 `case_conflict_details`: the record kept beside a case's
//  stored conflict (open kind, who found it, every side, the AI's labelled explanation). A conflict and its detail are
//  written in ONE savepoint, after the write itself checks again that the case exists, was not erased, is not closed and
//  — through the caller's ARCH-09 apply-time check (CaseApplyRecheck) — that every document it rests on is still a current
//  version in the case. A late AI reply refused there leaves nothing behind.
//

import Foundation
import os

public actor CaseConflictDetailsRepository {
    private let database: Database

    public init(database: Database) { self.database = database }

    /// Why a store was refused (the case changed while the AI was working).
    public struct Refused: Error, Equatable, LocalizedError {
        public let reason: String
        public var errorDescription: String? { "Not stored: \(reason) Nothing was written." }
    }

    /// Store conflicts with their details in one write. `recheck` runs inside the same savepoint, before any row.
    /// A detail for a rule finding the AI also found turns an earlier "rule" or "ai" detail into "both".
    public func store(caseID: UUID, conflicts: [Contradiction], details: [CaseConflictDetail], recheck: CaseApplyRecheck.Check?) async throws {
        let rows = details.map(Self.bindings)
        try await database.withSavepoint("conflict_store_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))") { db in
            guard try !db.query("SELECT 1 FROM investigation_cases WHERE id = ? LIMIT 1;", [.uuid(caseID)]).isEmpty else {
                throw Refused(reason: "the case no longer exists (it was erased while the AI was working).")
            }
            if try ErasureGenerations.isErased(db, caseID: caseID) { throw Refused(reason: "the case was erased while the AI was working.") }
            if try !db.query("SELECT 1 FROM case_profiles WHERE case_id = ? AND stage = 'closed' LIMIT 1;", [.uuid(caseID)]).isEmpty {
                throw Refused(reason: "the case was closed while the AI was working.")
            }
            if let recheck {
                do { try recheck(db, caseID) } catch let r as CaseApplyRecheck.Refused { throw Refused(reason: r.reason) }
            }
            for c in conflicts { try ContradictionsRepository.insertRow(db, c) }
            for b in rows {
                try db.exec("""
                    INSERT INTO case_conflict_details (contradiction_id, case_id, kind, found_by, description, sides_json, expected_absent, ai_reasoning,
                        innocent_json, stated_confidence, considered_json, documents_fingerprint, recorded_at)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
                    ON CONFLICT(contradiction_id, case_id) DO UPDATE SET
                        found_by = CASE WHEN case_conflict_details.found_by = excluded.found_by THEN excluded.found_by ELSE 'both' END,
                        kind = excluded.kind, description = excluded.description, sides_json = excluded.sides_json,
                        expected_absent = excluded.expected_absent,
                        ai_reasoning = COALESCE(excluded.ai_reasoning, case_conflict_details.ai_reasoning),
                        innocent_json = CASE WHEN excluded.ai_reasoning IS NULL THEN case_conflict_details.innocent_json ELSE excluded.innocent_json END,
                        stated_confidence = COALESCE(excluded.stated_confidence, case_conflict_details.stated_confidence),
                        considered_json = CASE WHEN excluded.ai_reasoning IS NULL THEN case_conflict_details.considered_json ELSE excluded.considered_json END,
                        documents_fingerprint = COALESCE(excluded.documents_fingerprint, case_conflict_details.documents_fingerprint),
                        recorded_at = excluded.recorded_at;
                    """, b)
            }
        }
    }

    /// The case's conflict details, by the conflict's id.
    // MARK: SEARCH-14 — resumable parts of an AI look

    /// The parts already done for this case and document set.
    public func doneUnits(caseID: UUID, fingerprint: String) async throws -> Set<String> {
        Set(try await database.query("SELECT unit_key FROM case_ai_conflict_units WHERE case_id = ? AND fingerprint = ?;",
                                     [.uuid(caseID), .text(fingerprint)]).compactMap { $0.string(0) })
    }

    /// Record parts as done (their replies were kept).
    public func markUnitsDone(caseID: UUID, fingerprint: String, units: [String], at date: Date = Date()) async throws {
        guard !units.isEmpty else { return }
        try await database.withSavepoint("conflict_units_\(UUID().uuidString.prefix(8))") { db in
            for u in units {
                try db.exec("INSERT OR IGNORE INTO case_ai_conflict_units (case_id, fingerprint, unit_key, done_at) VALUES (?,?,?,?);",
                            [.uuid(caseID), .text(fingerprint), .text(u), .date(date)])
            }
        }
    }

    /// A look that finished every part: the next look reads everything again.
    public func clearUnits(caseID: UUID, fingerprint: String) async throws {
        try await database.withSavepoint("conflict_units_clr_\(UUID().uuidString.prefix(8))") { db in
            try db.exec("DELETE FROM case_ai_conflict_units WHERE case_id = ? AND fingerprint = ?;", [.uuid(caseID), .text(fingerprint)])
        }
    }

    public func details(caseID: UUID) async throws -> [UUID: CaseConflictDetail] {
        let rows = try await database.query("""
            SELECT contradiction_id, case_id, kind, found_by, description, sides_json, expected_absent, ai_reasoning, innocent_json,
                   stated_confidence, considered_json, documents_fingerprint, recorded_at
            FROM case_conflict_details WHERE case_id = ?;
            """, [.uuid(caseID)])
        var out: [UUID: CaseConflictDetail] = [:]
        for r in rows {
            guard let d = Self.decode(r) else {
                KalsmritikoshLog.knowledge.error("case conflict detail: a row could not be read; it is skipped")
                continue
            }
            out[d.contradictionID] = d
        }
        return out
    }

    /// One conflict's detail (nil: none stored, or the row could not be read).
    public func detail(caseID: UUID, contradictionID: UUID) async throws -> CaseConflictDetail? {
        let rows = try await database.query("""
            SELECT contradiction_id, case_id, kind, found_by, description, sides_json, expected_absent, ai_reasoning, innocent_json,
                   stated_confidence, considered_json, documents_fingerprint, recorded_at
            FROM case_conflict_details WHERE case_id = ? AND contradiction_id = ? LIMIT 1;
            """, [.uuid(caseID), .uuid(contradictionID)])
        guard let r = rows.first else { return nil }
        guard let d = Self.decode(r) else {
            KalsmritikoshLog.knowledge.error("case conflict detail: a row could not be read; it is skipped")
            return nil
        }
        return d
    }

    // MARK: - Rows

    static func json<T: Encodable>(_ v: T) -> String {
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        do { return String(decoding: try enc.encode(v), as: UTF8.self) } catch {
            KalsmritikoshLog.knowledge.error("case conflict detail: encode failed: \(String(describing: error), privacy: .public)")
            return "[]"
        }
    }

    static func bindings(_ d: CaseConflictDetail) -> [SQLValue] {
        [.uuid(d.contradictionID), .uuid(d.caseID), .text(d.kind.storageValue), .text(d.foundBy.rawValue), .text(d.description),
         .text(json(d.sides)), d.expectedAbsent.map { .text($0) } ?? .null, d.aiReasoning.map { .text($0) } ?? .null,
         .text(json(d.innocentExplanations)), d.statedConfidence.map { .text($0) } ?? .null,
         .text(json(d.considered.map(\.uuidString))), d.documentsFingerprint.map { .text($0) } ?? .null, .date(d.recordedAt)]
    }

    static func decode(_ r: SQLRow) -> CaseConflictDetail? {
        guard let id = r.uuid(0), let caseID = r.uuid(1), let kind = r.string(2), let foundBy = r.string(3).flatMap(ConflictFoundBy.init(rawValue:)),
              let description = r.string(4), let sidesText = r.string(5), let at = r.date(12) else { return nil }
        let dec = JSONDecoder()
        let sides: [ConflictSide]
        do { sides = try dec.decode([ConflictSide].self, from: Data(sidesText.utf8)) } catch {
            KalsmritikoshLog.knowledge.error("case conflict detail: sides unreadable: \(String(describing: error), privacy: .public)")
            return nil
        }
        func strings(_ i: Int) -> [String] {
            guard let t = r.string(i) else { return [] }
            do { return try dec.decode([String].self, from: Data(t.utf8)) } catch {
                KalsmritikoshLog.knowledge.error("case conflict detail: a list is unreadable: \(String(describing: error), privacy: .public)")
                return []
            }
        }
        return CaseConflictDetail(contradictionID: id, caseID: caseID, kind: ConflictKind(storageValue: kind), foundBy: foundBy, description: description,
                                  sides: sides, expectedAbsent: r.string(6), aiReasoning: r.string(7), innocentExplanations: strings(8),
                                  statedConfidence: r.string(9), considered: strings(10).compactMap(UUID.init(uuidString:)),
                                  documentsFingerprint: r.string(11), recordedAt: at)
    }
}
