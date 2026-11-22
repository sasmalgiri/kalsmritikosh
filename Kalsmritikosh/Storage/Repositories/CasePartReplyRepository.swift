//
//  CasePartReplyRepository.swift
//  Kalsmritikosh
//
//  Speed PERF-22 (owner 2026-11-23) — not tested yet. The reply of each finished part of a whole-case AI read (v204
//  `case_ai_part_replies`), keyed by (case, the part's prefix fingerprint, the task's digest, part index): a retry of
//  the same read — same case, same part text, same task — takes the finished parts from here and asks the AI only for
//  the missing ones. A changed document, briefing or question changes the key, so nothing stale is reused. A reply is
//  used for `maxAge` at most. Case erasure deletes the rows (case_id); a person erasure deletes replies naming them.
//

import Foundation
import CryptoKit
import os

public actor CasePartReplyRepository {
    private let database: Database
    public init(database: Database) { self.database = database }

    /// The longest a kept part reply is reused.
    public static let maxAge: TimeInterval = 7 * 86_400

    public static func digest(_ parts: [String]) -> String {
        var h = SHA256()
        for p in parts { h.update(data: Data(p.utf8)); h.update(data: Data([0x1E])) }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public func reply(caseID: UUID, prefixFingerprint: String, suffixDigest: String, part: Int, now: Date = Date()) async -> String? {
        do {
            return try await database.query("""
            SELECT reply_text FROM case_ai_part_replies
            WHERE case_id = ? AND prefix_fingerprint = ? AND suffix_digest = ? AND part_index = ? AND created_at >= ?;
            """, [.uuid(caseID), .text(prefixFingerprint), .text(suffixDigest), .integer(Int64(part)),
                  .date(now.addingTimeInterval(-Self.maxAge))]).first?.string(0)
        } catch {
            KalsmritikoshLog.storage.error("case part reply not read (the part is read again): \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    public func keep(caseID: UUID, prefixFingerprint: String, suffixDigest: String, part: Int, reply: String, at now: Date = Date()) async {
        do {
            try await database.exec("""
            INSERT OR REPLACE INTO case_ai_part_replies (case_id, prefix_fingerprint, suffix_digest, part_index, reply_text, created_at)
            VALUES (?, ?, ?, ?, ?, ?);
            """, [.uuid(caseID), .text(prefixFingerprint), .text(suffixDigest), .integer(Int64(part)), .text(reply), .date(now)])
        } catch {
            KalsmritikoshLog.storage.error("case part reply not kept (a retry reads this part again): \(String(describing: error), privacy: .public)")
        }
    }
}

/// Speed PERF-22 (owner 2026-11-23) — not tested yet. Where the case reader keeps finished parts (set when the ledger
/// opens; nil = nothing kept, every part is read).
public nonisolated enum CasePartReplies {
    private static let store = OSAllocatedUnfairLock<CasePartReplyRepository?>(initialState: nil)
    public static var current: CasePartReplyRepository? { store.withLock { $0 } }
    public static func set(_ repo: CasePartReplyRepository?) { store.withLock { $0 = repo } }
}
