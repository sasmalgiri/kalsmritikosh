//
//  CaseAIRecordRepository.swift
//  Kalsmritikosh
//
//  AI split AI-44 / AI-45 (owner 2026-11-23). The AI's own case records (v209 `case_ai_records`), stored only after the
//  agent's mechanical verifier passed them ("found by AI, quote checked"), and which documents the AI has read for the
//  case picture at which fingerprint (`case_ai_picture_documents`, so the picture re-reads only new or changed documents).
//
//  Every write runs inside a savepoint behind the case access policy (`CaseAccessPolicy.require(.work)`) and is refused for
//  an erased case; every read checks `requireRead`. A record of a changed document is withdrawn (kept, never deleted) with
//  its reason. Case erasure deletes the rows (case_id); a person erasure deletes the records naming the person
//  (CaseErasure.scrubAICaches); a full erase empties both tables.
//

import Foundation
import os

public actor CaseAIRecordRepository {
    private let database: Database
    public init(database: Database) { self.database = database }

    public enum Failure: Error, Equatable { case caseErased }

    /// Store verified records (one row per statement; a repeat is skipped). Returns how many rows were new.
    @discardableResult
    public func record(caseID: UUID, _ records: [CaseAIRecord]) async throws -> Int {
        guard !records.isEmpty else { return 0 }
        let rows: [[SQLValue]] = records.map { r in
            let support: String
            do {
                support = String(decoding: try JSONSerialization.data(withJSONObject: ["for": r.supporting, "against": r.against], options: [.sortedKeys]), as: UTF8.self)
            } catch {
                KalsmritikoshLog.storage.error("AI record: support list not encoded: \(error.localizedDescription, privacy: .public)")
                support = "{}"
            }
            func t(_ s: String?) -> SQLValue { s.map { .text($0) } ?? .null }
            return [.uuid(r.id), .uuid(caseID), .text(r.kind.rawValue), .text(r.text), t(r.entityType), t(r.role), t(r.dateText),
                    t(r.from), t(r.to), t(r.relation), t(r.quote), r.document.map { .uuid($0) } ?? .null, t(r.quoteB),
                    r.documentB.map { .uuid($0) } ?? .null, .text(support), .text(CaseAIRecord.checkedLabel),
                    .text(r.origin == "picture" ? "picture" : "question"), t(r.documentFingerprint), .text(r.keyDigest), .date(r.createdAt)]
        }
        return try await database.withSavepoint("ai_rec_\(UUID().uuidString.prefix(8))") { db in
            guard !(try ErasureGenerations.isErased(db, caseID: caseID)) else { throw Failure.caseErased }
            try CaseAccessPolicy.require(db, caseID: caseID, actor: nil, .work)
            var added = 0
            for row in rows {
                try db.exec("""
                    INSERT OR IGNORE INTO case_ai_records (id, case_id, kind, text, entity_type, role, date_text, from_name, to_name, relation,
                        quote, document_id, quote_b, document_b_id, support_json, checked, origin, document_fingerprint, key_digest, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                    """, row)
                added += Int(try db.query("SELECT changes();", []).first?.int(0) ?? 0)
            }
            return added
        }
    }

    /// The case's records (withdrawn ones left out unless asked), oldest first.
    public func records(caseID: UUID, includeWithdrawn: Bool = false) async throws -> [CaseAIRecord] {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        let rows = try await database.query("""
            SELECT id, kind, text, entity_type, role, date_text, from_name, to_name, relation, quote, document_id, quote_b, document_b_id,
                   support_json, origin, document_fingerprint, created_at
            FROM case_ai_records WHERE upper(case_id) = upper(?) \(includeWithdrawn ? "" : "AND withdrawn_at IS NULL")
            ORDER BY created_at, id;
            """, [.uuid(caseID)])
        return rows.compactMap { r in
            guard let id = r.uuid(0), let kind = r.string(1).flatMap(CaseAIRecord.Kind.init(rawValue:)) else { return nil }
            var pro: [String] = [], con: [String] = []
            if let data = r.string(13)?.data(using: .utf8) {
                do {
                    let o = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                    pro = o?["for"] as? [String] ?? []; con = o?["against"] as? [String] ?? []
                } catch {
                    KalsmritikoshLog.storage.error("AI record: support list unreadable: \(error.localizedDescription, privacy: .public)")
                }
            }
            return CaseAIRecord(id: id, kind: kind, text: r.string(2) ?? "", entityType: r.string(3), role: r.string(4), dateText: r.string(5),
                                from: r.string(6), to: r.string(7), relation: r.string(8), quote: r.string(9), document: r.uuid(10),
                                quoteB: r.string(11), documentB: r.uuid(12), supporting: pro, against: con, origin: r.string(14) ?? "question",
                                documentFingerprint: r.string(15), createdAt: r.date(16) ?? Date(timeIntervalSince1970: 0))
        }
    }

    /// AI split AI-48 — the cases holding records (the archive-level view reads each through `records`, which checks access).
    public func caseIDs() async throws -> [UUID] {
        try await database.query("SELECT DISTINCT case_id FROM case_ai_records WHERE withdrawn_at IS NULL ORDER BY case_id;", []).compactMap { $0.uuid(0) }
    }

    /// Document → the fingerprint it was read at for the case picture.
    public func pictureState(caseID: UUID) async throws -> [UUID: String] {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        var out: [UUID: String] = [:]
        for r in try await database.query("SELECT document_id, fingerprint FROM case_ai_picture_documents WHERE upper(case_id) = upper(?);", [.uuid(caseID)]) {
            if let d = r.uuid(0), let f = r.string(1) { out[d] = f }
        }
        return out
    }

    /// The picture read these documents at these fingerprints (with how many records it kept and how many writes were rejected).
    public func markRead(caseID: UUID, documents: [(id: UUID, fingerprint: String)], records: Int, rejected: Int, at now: Date = Date()) async throws {
        guard !documents.isEmpty else { return }
        try await database.withSavepoint("ai_pic_\(UUID().uuidString.prefix(8))") { db in
            guard !(try ErasureGenerations.isErased(db, caseID: caseID)) else { throw Failure.caseErased }
            try CaseAccessPolicy.require(db, caseID: caseID, actor: nil, .work)
            for d in documents {
                try db.exec("""
                    INSERT OR REPLACE INTO case_ai_picture_documents (case_id, document_id, fingerprint, records, rejected, read_at)
                    VALUES (?, ?, ?, ?, ?, ?);
                    """, [.uuid(caseID), .uuid(d.id), .text(d.fingerprint), .integer(Int64(records)), .integer(Int64(rejected)), .date(now)])
            }
        }
    }

    /// Withdraw (never delete) the records citing a document whose text changed or that left the case.
    @discardableResult
    public func withdraw(caseID: UUID, documents: [UUID], reason: String, at now: Date = Date()) async throws -> Int {
        guard !documents.isEmpty else { return 0 }
        return try await database.withSavepoint("ai_wd_\(UUID().uuidString.prefix(8))") { db in
            try CaseAccessPolicy.require(db, caseID: caseID, actor: nil, .work)
            var n = 0
            for d in documents {
                try db.exec("""
                    UPDATE case_ai_records SET withdrawn_at = ?, withdrawn_reason = ?
                    WHERE upper(case_id) = upper(?) AND withdrawn_at IS NULL AND (upper(document_id) = upper(?) OR upper(document_b_id) = upper(?));
                    """, [.date(now), .text(reason), .uuid(caseID), .uuid(d), .uuid(d)])
                n += Int(try db.query("SELECT changes();", []).first?.int(0) ?? 0)
                try db.exec("DELETE FROM case_ai_picture_documents WHERE upper(case_id) = upper(?) AND upper(document_id) = upper(?);", [.uuid(caseID), .uuid(d)])
            }
            return n
        }
    }
}
