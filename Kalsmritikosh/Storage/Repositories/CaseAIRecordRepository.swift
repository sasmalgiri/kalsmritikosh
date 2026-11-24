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
                    .text(r.origin == "picture" ? "picture" : "question"), t(r.documentFingerprint), .text(r.keyDigest), .date(r.createdAt),
                    r.runID.map { .uuid($0) } ?? .null, t(r.modelRequested), t(r.modelServed), t(r.requestSHA256), t(r.promptVersion), t(r.requestedBy)]
        }
        return try await database.withSavepoint("ai_rec_\(UUID().uuidString.prefix(8))") { db in
            guard !(try ErasureGenerations.isErased(db, caseID: caseID)) else { throw Failure.caseErased }
            try CaseAccessPolicy.require(db, caseID: caseID, actor: nil, .work)
            var added = 0
            for var row in rows {
                // ALCOA ALC-01 — a statement re-found after its document changed (its earlier row withdrawn) comes back as a
                // NEW row; the withdrawn row stays as it was (history never rewritten). An active row with the same statement
                // still means "already stored".
                guard case .text(let key) = row[18] else { continue }
                let existing = try db.query("""
                    SELECT key_digest, withdrawn_at IS NULL FROM case_ai_records
                    WHERE upper(case_id) = upper(?) AND (key_digest = ? OR key_digest LIKE ? ESCAPE '\\');
                    """, [.uuid(caseID), .text(key), .text(Self.likeEscaped(key) + ":r%")])
                if existing.contains(where: { ($0.int(1) ?? 0) == 1 }) { continue }
                if !existing.isEmpty { row[18] = .text(key + ":r\(existing.count)") }
                try db.exec("""
                    INSERT OR IGNORE INTO case_ai_records (id, case_id, kind, text, entity_type, role, date_text, from_name, to_name, relation,
                        quote, document_id, quote_b, document_b_id, support_json, checked, origin, document_fingerprint, key_digest, created_at,
                        run_id, model_requested, model_served, request_sha256, prompt_version, requested_by)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                    """, row)
                added += Int(try db.query("SELECT changes();", []).first?.int(0) ?? 0)
            }
            return added
        }
    }

    /// `s` with LIKE's wildcards escaped (escape character `\`).
    nonisolated static func likeEscaped(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
    }

    /// The case's records (withdrawn ones left out unless asked), oldest first.
    public func records(caseID: UUID, includeWithdrawn: Bool = false) async throws -> [CaseAIRecord] {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        let rows = try await database.query("""
            SELECT id, kind, text, entity_type, role, date_text, from_name, to_name, relation, quote, document_id, quote_b, document_b_id,
                   support_json, origin, document_fingerprint, created_at,
                   run_id, model_requested, model_served, request_sha256, prompt_version, requested_by
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
            var rec = CaseAIRecord(id: id, kind: kind, text: r.string(2) ?? "", entityType: r.string(3), role: r.string(4), dateText: r.string(5),
                                   from: r.string(6), to: r.string(7), relation: r.string(8), quote: r.string(9), document: r.uuid(10),
                                   quoteB: r.string(11), documentB: r.uuid(12), supporting: pro, against: con, origin: r.string(14) ?? "question",
                                   documentFingerprint: r.string(15), createdAt: r.date(16) ?? Date(timeIntervalSince1970: 0))
            rec.runID = r.uuid(17); rec.modelRequested = r.string(18); rec.modelServed = r.string(19)
            rec.requestSHA256 = r.string(20); rec.promptVersion = r.string(21); rec.requestedBy = r.string(22)
            return rec
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
                // ALCOA ALC-10 — an upsert (not INSERT OR REPLACE, which deletes silently): the v214 trigger keeps the earlier read.
                try db.exec("""
                    INSERT INTO case_ai_picture_documents (case_id, document_id, fingerprint, records, rejected, read_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT (case_id, document_id) DO UPDATE SET fingerprint = excluded.fingerprint, records = excluded.records,
                        rejected = excluded.rejected, read_at = excluded.read_at;
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

    // MARK: - ALCOA ALC-02 (owner 2026-11-24): the agent's runs

    /// What one agent run is (a question, or one case-picture pass) when it starts.
    public struct RunStart: Sendable, Equatable {
        public enum Kind: String, Sendable { case question, picture }
        public var kind: Kind
        /// The question (clipped), or the picture's documents.
        public var task: String?
        public var provider: String
        public var modelRequested: String
        /// Who asked: the acting person's name ("this Mac's owner" when no one else is named).
        public var requestedBy: String
        public var documentsFingerprint: String?
        /// The exact source versions read (the input versions).
        public var inputVersions: [UUID]
        /// What the run covered: the case's documents, how many were sent, how many parts.
        public var coverage: [String: Int]
        public var promptVersion: String
        public init(kind: Kind, task: String?, provider: String, modelRequested: String, requestedBy: String, documentsFingerprint: String?,
                    inputVersions: [UUID], coverage: [String: Int], promptVersion: String) {
            self.kind = kind; self.task = task; self.provider = provider; self.modelRequested = modelRequested; self.requestedBy = requestedBy
            self.documentsFingerprint = documentsFingerprint; self.inputVersions = inputVersions; self.coverage = coverage; self.promptVersion = promptVersion
        }
    }

    /// The person acting now, by name (the task-local principal; nil = this Mac's owner).
    public nonisolated static func requester() -> String {
        switch CaseAccessContext.principal {
        case .none, .some(.deviceOwner): return "this Mac's owner"
        case .some(.local(let n)): return n
        case .some(.bound(let p, _)): return p
        }
    }

    nonisolated static func json(_ value: Any) -> String {
        do { return String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self) } catch {
            KalsmritikoshLog.storage.error("AI run: value not encoded: \(error.localizedDescription, privacy: .public)")
            return "{}"
        }
    }

    /// Open a running case_ai_runs row (provider, model asked for, person, input versions, coverage, cache key, the case's
    /// access and erasure generations). Returns its id; the records the run stores link to it.
    public func openRun(caseID: UUID, _ start: RunStart, at now: Date = Date()) async throws -> UUID {
        let id = UUID()
        let inputs = Self.json(start.inputVersions.map { $0.uuidString.lowercased() }.sorted())
        let coverage = Self.json(start.coverage)
        let who = start.requestedBy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Self.requester() : start.requestedBy
        let principal = "agent|" + who.lowercased()
        let key = CaseAgent.sha256([caseID.uuidString.lowercased(), start.kind.rawValue, start.task ?? "", start.documentsFingerprint ?? "",
                                    start.provider, start.modelRequested, start.promptVersion, principal, "\(now.timeIntervalSince1970)"].joined(separator: "\u{1F}"))
        try await database.withSavepoint("ai_run_\(UUID().uuidString.prefix(8))") { db in
            guard !(try ErasureGenerations.isErased(db, caseID: caseID)) else { throw Failure.caseErased }
            try CaseAccessPolicy.require(db, caseID: caseID, actor: nil, .work)
            let access = try CaseAccessPolicy.generation(db, caseID: caseID), erasure = try ErasureGenerations.current(db)
            try db.exec("""
                INSERT INTO case_ai_runs (id, case_id, task_kind, task_text, mode, policy_version, provider, model, requested_by, principal_key,
                    documents_fingerprint, input_revisions_json, coverage_json, cache_key, state, access_generation, erasure_generation, started_at,
                    prompt_version)
                VALUES (?, ?, ?, ?, ?, 0, ?, ?, ?, ?, ?, ?, ?, ?, 'running', ?, ?, ?, ?);
                """, [.uuid(id), .uuid(caseID), .text(start.kind.rawValue), start.task.map { .text(String($0.prefix(500))) } ?? .null,
                      .text(start.kind == .picture ? "execute" : "suggest"), .text(start.provider.isEmpty ? "not recorded" : start.provider),
                      .text(start.modelRequested.isEmpty ? "not recorded" : start.modelRequested), .text(who), .text(principal),
                      start.documentsFingerprint.map { .text($0) } ?? .null, .text(inputs), .text(coverage), .text(key),
                      .integer(Int64(access)), .integer(Int64(erasure)), .date(now), .text(start.promptVersion)])
        }
        return id
    }

    /// Finish a run: its state (done / failed / cancelled — a reason unless done), the model the provider says answered
    /// (every distinct one, a fallback included), the calls and tokens, and what it stored. A finished run is never edited.
    public func finishRun(_ id: UUID, caseID: UUID, state: String, reason: String?, usage: [CloudCallUsage], counts: [String: Int],
                          at now: Date = Date()) async throws {
        let served = Array(Set(usage.compactMap(\.model))).sorted()
        let state = ["done", "failed", "cancelled", "refused"].contains(state) ? state : "failed"
        let why = state == "done" ? reason : (reason?.isEmpty == false ? reason : "stopped")
        try await database.withSavepoint("ai_runf_\(UUID().uuidString.prefix(8))") { db in
            try db.exec("""
                UPDATE case_ai_runs SET state = ?, state_reason = ?, answered_by_model = ?, model_calls = ?, input_tokens = ?, output_tokens = ?,
                    cache_read_tokens = ?, cache_write_tokens = ?, counts_json = ?, finished_at = ?
                WHERE id = ? AND upper(case_id) = upper(?) AND state = 'running';
                """, [.text(state), why.map { .text($0) } ?? .null, served.isEmpty ? .null : .text(served.joined(separator: ", ")),
                      .integer(Int64(usage.count)), .integer(Int64(usage.reduce(0) { $0 + $1.inputTokens })),
                      .integer(Int64(usage.reduce(0) { $0 + $1.outputTokens })), .integer(Int64(usage.reduce(0) { $0 + $1.cacheReadTokens })),
                      .integer(Int64(usage.reduce(0) { $0 + $1.cacheWriteTokens })), .text(Self.json(counts)), .date(now), .uuid(id), .uuid(caseID)])
        }
    }

    /// One recorded run, as the review list shows it.
    public struct Run: Sendable, Equatable, Identifiable {
        public let id: UUID
        public let kind: String
        public let provider: String
        public let modelRequested: String
        public let modelServed: String?
        public let requestedBy: String
        public let state: String
        public let startedAt: Date
        /// True when the provider says another model answered than the one asked for (a server-side fallback).
        public var fallback: Bool { modelServed.map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } != [modelRequested] } ?? false }
    }

    public func runs(caseID: UUID) async throws -> [Run] {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        return try await database.query("""
            SELECT id, task_kind, provider, model, answered_by_model, requested_by, state, started_at FROM case_ai_runs
            WHERE upper(case_id) = upper(?) ORDER BY started_at, id;
            """, [.uuid(caseID)]).compactMap { r in
            guard let id = r.uuid(0), let k = r.string(1), let at = r.date(7) else { return nil }
            return Run(id: id, kind: k, provider: r.string(2) ?? "", modelRequested: r.string(3) ?? "", modelServed: r.string(4),
                       requestedBy: r.string(5) ?? "", state: r.string(6) ?? "", startedAt: at)
        }
    }

    // MARK: - ALCOA ALC-02: the person's decision on an AI record (append-only)

    public enum Decision: String, Sendable, CaseIterable { case accept, reject, correct }

    public struct DecisionRecord: Sendable, Equatable, Identifiable {
        public let id: UUID
        public let recordID: UUID
        public let decision: Decision
        public let correctedText: String?
        public let reason: String?
        public let approver: String
        public let decidedAt: Date
    }

    public enum DecisionError: Error, Equatable, LocalizedError {
        case blankApprover, reasonNeeded, correctionNeeded, notInCase
        public var errorDescription: String? {
            switch self {
            case .blankApprover: return "Say who decides."
            case .reasonNeeded: return "Say why: a rejected or corrected AI finding keeps its reason."
            case .correctionNeeded: return "Write the corrected wording."
            case .notInCase: return "That AI finding is not in this case."
            }
        }
    }

    /// Record the person's accept / reject / correct of one AI record, with who approved and why. A new row every time;
    /// the latest decision counts.
    @discardableResult
    public func decide(caseID: UUID, recordID: UUID, _ decision: Decision, correctedText: String? = nil, reason: String?,
                       approver: String, at now: Date = Date()) async throws -> UUID {
        let who = approver.trimmingCharacters(in: .whitespacesAndNewlines)
        let why = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fixed = correctedText?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !who.isEmpty else { throw DecisionError.blankApprover }
        if decision != .accept, (why ?? "").isEmpty { throw DecisionError.reasonNeeded }
        if decision == .correct, (fixed ?? "").isEmpty { throw DecisionError.correctionNeeded }
        let id = UUID()
        try await database.withSavepoint("ai_dec_\(UUID().uuidString.prefix(8))") { db in
            guard !(try ErasureGenerations.isErased(db, caseID: caseID)) else { throw Failure.caseErased }
            try CaseAccessPolicy.require(db, caseID: caseID, actor: who, .work)
            guard try !db.query("SELECT 1 FROM case_ai_records WHERE upper(id) = upper(?) AND upper(case_id) = upper(?);",
                                [.uuid(recordID), .uuid(caseID)]).isEmpty else { throw DecisionError.notInCase }
            try db.exec("""
                INSERT INTO case_ai_record_decisions (id, case_id, record_id, decision, corrected_text, reason, approver, decided_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?);
                """, [.uuid(id), .uuid(caseID), .uuid(recordID), .text(decision.rawValue), decision == .correct ? .text(fixed ?? "") : .null,
                      (why ?? "").isEmpty ? .null : .text(why ?? ""), .text(who), .date(now)])
        }
        return id
    }

    /// Every decision of the case, oldest first.
    public func decisions(caseID: UUID) async throws -> [DecisionRecord] {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        return try await database.query("""
            SELECT id, record_id, decision, corrected_text, reason, approver, decided_at FROM case_ai_record_decisions
            WHERE upper(case_id) = upper(?) ORDER BY decided_at, rowid;
            """, [.uuid(caseID)]).compactMap { r in
            guard let id = r.uuid(0), let rec = r.uuid(1), let d = r.string(2).flatMap(Decision.init(rawValue:)), let at = r.date(6) else { return nil }
            return DecisionRecord(id: id, recordID: rec, decision: d, correctedText: r.string(3), reason: r.string(4), approver: r.string(5) ?? "", decidedAt: at)
        }
    }

    /// The latest decision per record.
    public func latestDecisions(caseID: UUID) async throws -> [UUID: DecisionRecord] {
        var out: [UUID: DecisionRecord] = [:]
        for d in try await decisions(caseID: caseID) { out[d.recordID] = d }
        return out
    }

    /// ALC-02 — the records a report may use: `final` = only those the person accepted or corrected (a correction's wording
    /// replaces the AI's); otherwise every active record (a draft), each still labelled as found by AI.
    public func reportRecords(caseID: UUID, final: Bool) async throws -> [CaseAIRecord] {
        let all = try await records(caseID: caseID)
        guard final else { return all }
        let latest = try await latestDecisions(caseID: caseID)
        return all.compactMap { r in
            guard let d = latest[r.id] else { return nil }
            switch d.decision {
            case .accept: return r
            case .reject: return nil
            case .correct: var c = r; c.text = d.correctedText ?? r.text; return c
            }
        }
    }

    /// ALC-02 — the AI findings as report text: "Final" lists only what the person accepted or corrected; "Draft" lists
    /// every active finding. Each line says it was found by AI (and, for a final, that a person approved it).
    public nonisolated static func reportText(_ records: [CaseAIRecord], final: Bool) -> String {
        let head = final ? "AI findings — final (only findings a person accepted or corrected)"
                         : "AI findings — draft (every finding; not yet approved by a person)"
        guard !records.isEmpty else { return head + "\n\nNone." }
        let label = final ? "found by AI, quote checked, approved" : CaseAIRecord.checkedLabel
        let lines = records.map { r in
            "• [\(r.kind.rawValue)] \(r.text)" + (r.quote.map { " — “\($0)”" } ?? "") + " (\(label))"
        }
        return ([head, ""] + lines).joined(separator: "\n")
    }
}
