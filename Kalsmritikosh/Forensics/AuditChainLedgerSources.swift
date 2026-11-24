//
//  AuditChainLedgerSources.swift
//  Kalsmritikosh
//
//  ALCOA ALC-07 (owner 2026-11-24) — traceable. More of the ledger enters the audit chain (schema v212 admits the sources):
//  the AI's records (and, as its own event, a record's withdrawal), finished AI runs, the person's decisions on AI records,
//  the outbound record, source versions, the erasure registers (case/person erasures and studio erasures) and case record
//  revisions. Only fields that never change after a row is written enter a payload; free text enters as a SHA-256 digest
//  (so an erasure that replaces the text sent — outbound_log.payload_text — changes no sealed payload, and no content is
//  copied into the chain). A field added later (a served model, a revision's reason) enters only when present, so older
//  sealed payloads are unchanged.
//
//  Tamper-evident, not tamper-proof (CaseAuditSources.trustStatement). Rows a recorded erasure removes leave content-free
//  seal tombstones (AuditChainTombstones, v215) that verify counts as "erased (recorded)"; the erasure itself is a sealed event.
//

import Foundation
import CryptoKit

public nonisolated enum AuditChainLedgerSources {

    /// A stable event id derived from a row id and a suffix (a record's withdrawal is its own event).
    static func derivedID(_ id: UUID, _ suffix: String) -> UUID {
        let d = Array(SHA256.hash(data: Data((id.uuidString.lowercased() + ":" + suffix).utf8)))
        return UUID(uuid: (d[0], d[1], d[2], d[3], d[4], d[5], (d[6] & 0x0F) | 0x50, d[7], (d[8] & 0x3F) | 0x80, d[9], d[10], d[11], d[12], d[13], d[14], d[15]))
    }

    static func digest(_ s: String?) -> String { CaseFileHash.sha256(s ?? "") }
    static func t(_ d: Date?) -> String { d.map { "\($0.timeIntervalSince1970)" } ?? "" }
    static func extra(_ key: String, _ value: String?) -> String { value.map { ";\(key)=\($0)" } ?? "" }

    /// Every event of the new sources, in no particular order (the chain orders them).
    public static func events(_ database: Database) async throws -> [AuditChainEvent] {
        var out: [AuditChainEvent] = []
        out += try await aiRecords(database)
        out += try await aiRuns(database)
        out += try await aiDecisions(database)
        out += try await outbound(database)
        out += try await sourceVersions(database)
        out += try await erasures(database)
        out += try await revisions(database)
        return out
    }

    static func aiRecords(_ db: Database) async throws -> [AuditChainEvent] {
        var out: [AuditChainEvent] = []
        for r in try await db.query("""
            SELECT id, case_id, kind, text, quote, document_id, quote_b, document_b_id, origin, document_fingerprint, key_digest, created_at,
                   withdrawn_at, withdrawn_reason, run_id, model_requested, model_served, request_sha256, prompt_version, requested_by, support_json
            FROM case_ai_records;
            """, []) {
            guard let id = r.uuid(0), let c = r.string(1), let at = r.date(11) else { continue }
            let payload = "caseID=\(c.lowercased());createdAt=\(t(at));document=\(r.string(5) ?? "");documentB=\(r.string(7) ?? "");"
                + "fingerprint=\(r.string(9) ?? "");key=\(r.string(10) ?? "");kind=\(r.string(2) ?? "");origin=\(r.string(8) ?? "");"
                + "quoteBDigest=\(digest(r.string(6)));quoteDigest=\(digest(r.string(4)));supportDigest=\(digest(r.string(20)));textDigest=\(digest(r.string(3)))"
                + extra("run", r.string(14)) + extra("modelRequested", r.string(15)) + extra("modelServed", r.string(16))
                + extra("request", r.string(17)) + extra("prompt", r.string(18)) + extra("requestedBy", r.string(19))
            out.append(AuditChainEvent(source: .aiRecord, eventID: id, occurredAt: at, canonicalPayload: payload))
            if let gone = r.date(12) {
                out.append(AuditChainEvent(source: .aiRecord, eventID: derivedID(id, "withdrawn"), occurredAt: gone,
                                           canonicalPayload: "record=\(id.uuidString.lowercased());withdrawnAt=\(t(gone));reasonDigest=\(digest(r.string(13)))"))
            }
        }
        return out
    }

    static func aiRuns(_ db: Database) async throws -> [AuditChainEvent] {
        var out: [AuditChainEvent] = []
        // Only finished runs: a running row still changes (its finish), a finished one never does (case_ai_runs_fixed).
        for r in try await db.query("""
            SELECT id, case_id, task_kind, task_text, mode, policy_version, provider, model, answered_by_model, requested_by, principal_key,
                   documents_fingerprint, input_revisions_json, coverage_json, cache_key, cached_from, state, state_reason, failure_class,
                   model_calls, input_tokens, cache_write_tokens, cache_read_tokens, output_tokens, tools_json, counts_json, started_at, finished_at
            FROM case_ai_runs WHERE state <> 'running';
            """, []) {
            guard let id = r.uuid(0), let c = r.string(1), let at = r.date(26) else { continue }
            let usage = (19...23).map { "\(r.int($0) ?? 0)" }.joined(separator: ",")
            let payload = "answeredBy=\(r.string(8) ?? "");cacheKey=\(r.string(14) ?? "");cachedFrom=\(r.string(15) ?? "");caseID=\(c.lowercased());"
                + "countsDigest=\(digest(r.string(25)));coverageDigest=\(digest(r.string(13)));documents=\(r.string(11) ?? "");failure=\(r.string(18) ?? "");"
                + "finishedAt=\(t(r.date(27)));inputsDigest=\(digest(r.string(12)));kind=\(r.string(2) ?? "");mode=\(r.string(4) ?? "");model=\(r.string(7) ?? "");"
                + "policy=\(r.int(5) ?? 0);principal=\(r.string(10) ?? "");provider=\(r.string(6) ?? "");reasonDigest=\(digest(r.string(17)));"
                + "requestedBy=\(r.string(9) ?? "");startedAt=\(t(at));state=\(r.string(16) ?? "");taskDigest=\(digest(r.string(3)));"
                + "toolsDigest=\(digest(r.string(24)));usage=\(usage)"
            out.append(AuditChainEvent(source: .aiRun, eventID: id, occurredAt: at, canonicalPayload: payload))
        }
        return out
    }

    static func aiDecisions(_ db: Database) async throws -> [AuditChainEvent] {
        try await db.query("SELECT id, case_id, record_id, decision, corrected_text, reason, approver, decided_at FROM case_ai_record_decisions;", [])
            .compactMap { r in
                guard let id = r.uuid(0), let c = r.string(1), let at = r.date(7) else { return nil }
                let payload = "approver=\(r.string(6) ?? "");caseID=\(c.lowercased());correctionDigest=\(digest(r.string(4)));decidedAt=\(t(at));"
                    + "decision=\(r.string(3) ?? "");reasonDigest=\(digest(r.string(5)));record=\((r.string(2) ?? "").lowercased())"
                return AuditChainEvent(source: .aiDecision, eventID: id, occurredAt: at, canonicalPayload: payload)
            }
    }

    static func outbound(_ db: Database) async throws -> [AuditChainEvent] {
        // The text sent is NOT sealed (a case erasure replaces it); its SHA-256, kept, is.
        let served = try await db.query("SELECT 1 FROM pragma_table_info('outbound_log') WHERE name = 'model_served';", []).isEmpty == false
        return try await db.query("""
            SELECT id, sent_at, provider, model, host, bytes_sent, masked_count, payload_sha256, response_bytes, outcome, detail\(served ? ", model_served" : "")
            FROM outbound_log;
            """, []).compactMap { r in
            guard let id = r.uuid(0), let at = r.date(1) else { return nil }
            let payload = "bytes=\(r.int(5) ?? 0);detailDigest=\(digest(r.string(10)));host=\(r.string(4) ?? "");masked=\(r.int(6) ?? 0);"
                + "model=\(r.string(3) ?? "");outcome=\(r.string(9) ?? "");payloadSHA256=\(r.string(7) ?? "");provider=\(r.string(2) ?? "");"
                + "response=\(r.int(8).map { "\($0)" } ?? "");sentAt=\(t(at))" + (served ? extra("served", r.string(11)) : "")
            return AuditChainEvent(source: .outbound, eventID: id, occurredAt: at, canonicalPayload: payload)
        }
    }

    static func sourceVersions(_ db: Database) async throws -> [AuditChainEvent] {
        // What a version is (never changes, source_versions_fixed); its retirement and document attachment are not sealed here.
        try await db.query("""
            SELECT id, logical_source_id, content_hash, supersedes, valid_from, created_at, filename, size_bytes, custody_mode, vault_address
            FROM source_versions;
            """, []).compactMap { r in
            guard let id = r.uuid(0), let at = r.date(5) else { return nil }
            let payload = "contentHash=\((r.string(2) ?? "").lowercased());createdAt=\(t(at));custody=\(r.string(8) ?? "");filenameDigest=\(digest(r.string(6)));"
                + "logical=\((r.string(1) ?? "").lowercased());size=\(r.int(7).map { "\($0)" } ?? "");supersedes=\((r.string(3) ?? "").lowercased());"
                + "validFrom=\(t(r.date(4)));vault=\(r.string(9) ?? "")"
            return AuditChainEvent(source: .sourceVersion, eventID: id, occurredAt: at, canonicalPayload: payload)
        }
    }

    static func erasures(_ db: Database) async throws -> [AuditChainEvent] {
        var out: [AuditChainEvent] = []
        // ALCOA fix (v215) — the digest of the erasure's seal tombstones is sealed with it (only when it removed sealed rows,
        // so an older erasure's payload is unchanged).
        let tomb = try await db.query("SELECT 1 FROM pragma_table_info('case_erasures') WHERE name = 'seal_tombstones_sha256';", []).isEmpty == false
        for r in try await db.query("""
            SELECT id, scope, case_id, subject_sha256, reason, legal_basis, rows_json, sources_erased, sources_kept, erased_by, erased_at\(tomb ? ", seal_tombstones_sha256" : "")
            FROM case_erasures;
            """, []) {
            guard let id = r.uuid(0), let at = r.date(10) else { continue }
            let payload = "register=case_erasures;basisDigest=\(digest(r.string(5)));by=\(r.string(9) ?? "");caseID=\((r.string(2) ?? "").lowercased());"
                + "erasedAt=\(t(at));kept=\(r.int(8) ?? 0);reasonDigest=\(digest(r.string(4)));rowsDigest=\(digest(r.string(6)));"
                + "scope=\(r.string(1) ?? "");sources=\(r.int(7) ?? 0);subject=\(r.string(3) ?? "")" + (tomb ? extra("sealTombstones", r.string(11)) : "")
            out.append(AuditChainEvent(source: .erasure, eventID: id, occurredAt: at, canonicalPayload: payload))
        }
        for r in try await db.query("""
            SELECT id, record_id, case_id, reason, legal_basis, payload_sha256, revisions_cleared, exports_cleared, quarantine_cleared, legacy_originals,
                   erased_by, erased_at FROM studio_erasures;
            """, []) {
            guard let id = r.uuid(0), let at = r.date(11) else { continue }
            let counts = (6...9).map { "\(r.int($0) ?? 0)" }.joined(separator: ",")
            let payload = "register=studio_erasures;basisDigest=\(digest(r.string(4)));by=\(r.string(10) ?? "");caseID=\((r.string(2) ?? "").lowercased());"
                + "cleared=\(counts);erasedAt=\(t(at));payloadSHA256=\(r.string(5) ?? "");reasonDigest=\(digest(r.string(3)));record=\((r.string(1) ?? "").lowercased())"
            out.append(AuditChainEvent(source: .erasure, eventID: id, occurredAt: at, canonicalPayload: payload))
        }
        return out
    }

    static func revisions(_ db: Database) async throws -> [AuditChainEvent] {
        let reason = try await db.query("SELECT 1 FROM pragma_table_info('case_record_revisions') WHERE name = 'reason';", []).isEmpty == false
        return try await db.query("""
            SELECT id, case_id, action_id, record_kind, record_id, change, before_json, after_json, actor, recorded_at\(reason ? ", reason" : "")
            FROM case_record_revisions;
            """, []).compactMap { r in
            guard let id = r.uuid(0), let c = r.string(1), let at = r.date(9) else { return nil }
            let payload = "action=\((r.string(2) ?? "").lowercased());actor=\(r.string(8) ?? "");afterDigest=\(digest(r.string(7)));"
                + "beforeDigest=\(digest(r.string(6)));caseID=\(c.lowercased());change=\(r.string(5) ?? "");kind=\(r.string(3) ?? "");"
                + "record=\(r.string(4) ?? "");recordedAt=\(t(at))" + (reason ? extra("reasonDigest", r.string(10).map(digest)) : "")
            return AuditChainEvent(source: .recordRevision, eventID: id, occurredAt: at, canonicalPayload: payload)
        }
    }
}
