//
//  AIBatchJobRepository.swift
//  Kalsmritikosh
//
//  Unified path AI-39 (owner 2026-11-22, round 2) — not tested yet. The background case reads sent through the
//  provider's batch service (v202 `ai_batch_jobs`): batch id, purpose, the case's clearance fingerprint and the
//  digest of the exact (masked) request, so a batch survives quitting the app — polling resumes at launch and
//  the result is kept, then used by the next run of the same read (same case, same documents, same request).
//

import Foundation
import os

public actor AIBatchJobRepository {
    private let database: Database
    public init(database: Database) { self.database = database }

    public struct Job: Sendable, Equatable {
        public let id: UUID
        public let batchID: String
        public let kind: String
        public let model: String
        public let caseID: UUID
        public let purpose: String
        public let clearanceFingerprint: String
        public let requestDigest: String
        public let mapping: [String: String]
        public let state: String
        public let resultText: String?
        public let createdAt: Date
    }

    /// The longest a batch is waited for across launches (the provider's own limit is 24 hours).
    public static let maxAge: TimeInterval = 24 * 3_600

    private static let columns = "id, batch_id, provider_kind, model, case_id, purpose, clearance_fingerprint, request_digest, mask_mapping_json, state, result_text, created_at"

    private static func job(_ r: SQLRow) -> Job? {
        guard let id = r.uuid(0), let batch = r.string(1), let caseID = r.uuid(4) else { return nil }
        var mapping: [String: String] = [:]
        if let data = r.string(8)?.data(using: .utf8) {
            do { mapping = try JSONDecoder().decode([String: String].self, from: data) } catch {
                KalsmritikoshLog.storage.error("batch job \(id.uuidString, privacy: .public): mask mapping unreadable: \(String(describing: error), privacy: .public)")
            }
        }
        return Job(id: id, batchID: batch, kind: r.string(2) ?? "", model: r.string(3) ?? "", caseID: caseID, purpose: r.string(5) ?? "",
                   clearanceFingerprint: r.string(6) ?? "", requestDigest: r.string(7) ?? "", mapping: mapping,
                   state: r.string(9) ?? "", resultText: r.string(10), createdAt: Date(timeIntervalSince1970: r.double(11) ?? 0))
    }

    public func insert(batchID: String, kind: String, model: String, caseID: UUID, purpose: String, clearanceFingerprint: String,
                       requestDigest: String, mapping: [String: String], at now: Date = Date()) async throws -> UUID {
        let id = UUID()
        let json = String(decoding: try JSONEncoder().encode(mapping), as: UTF8.self)
        try await database.exec("""
        INSERT INTO ai_batch_jobs (id, batch_id, provider_kind, model, case_id, purpose, clearance_fingerprint, request_digest,
                                   mask_mapping_json, state, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'waiting', ?, ?);
        """, [.uuid(id), .text(batchID), .text(kind), .text(model), .uuid(caseID), .text(purpose), .text(clearanceFingerprint),
              .text(requestDigest), .text(json), .date(now), .date(now)])
        return id
    }

    /// The newest job for exactly this request in `state` (nil: none).
    public func job(caseID: UUID, requestDigest: String, clearanceFingerprint: String, state: String) async throws -> Job? {
        try await database.query("""
        SELECT \(Self.columns) FROM ai_batch_jobs
        WHERE case_id = ? AND request_digest = ? AND clearance_fingerprint = ? AND state = ?
        ORDER BY created_at DESC LIMIT 1;
        """, [.uuid(caseID), .text(requestDigest), .text(clearanceFingerprint), .text(state)]).first.flatMap(Self.job)
    }

    public func waiting() async throws -> [Job] {
        try await database.query("SELECT \(Self.columns) FROM ai_batch_jobs WHERE state = 'waiting' ORDER BY created_at;").compactMap(Self.job)
    }

    /// Record the outcome: 'done' (kept for the next run), 'used' (applied), 'failed' or 'abandoned'.
    public func finish(_ id: UUID, state: String, resultText: String? = nil, usageJSON: String? = nil, detail: String? = nil,
                       at now: Date = Date()) async {
        do {
            try await database.exec("""
            UPDATE ai_batch_jobs SET state = ?, result_text = coalesce(?, result_text), usage_json = coalesce(?, usage_json),
                   detail = ?, updated_at = ? WHERE id = ?;
            """, [.text(state), resultText.map { .text($0) } ?? .null, usageJSON.map { .text($0) } ?? .null,
                  detail.map { .text($0) } ?? .null, .date(now), .uuid(id)])
        } catch {
            KalsmritikoshLog.storage.error("batch job \(id.uuidString, privacy: .public) not updated to \(state, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }
}

/// Unified path AI-39 (owner 2026-11-22, round 2) — not tested yet. Where the online provider keeps its batch
/// jobs (set when the ledger opens; nil = no persistence, the batch is waited for in-task as before).
public nonisolated enum CaseBatchJournal {
    private static let store = OSAllocatedUnfairLock<AIBatchJobRepository?>(initialState: nil)
    public static var current: AIBatchJobRepository? { store.withLock { $0 } }
    public static func set(_ repo: AIBatchJobRepository?) { store.withLock { $0 = repo } }
}
