//
//  LedgerEncryptionCostTests.swift
//  KalsmritikoshTests
//
//  W2-7 — what encryption costs, measured: the same write + full-text workload on a plain
//  and on an encrypted ledger (each run twice, best time kept). The figures are attached as
//  encryption-cost.txt; the test only fails on a gross regression (encrypted > 4× plain).
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("W2-7 encryption cost", .serialized)
struct LedgerEncryptionCostTests {
    private func workload(_ key: LedgerKey?) async throws -> (write: Double, read: Double) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cost-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try Database(url: dir.appendingPathComponent("ledger.sqlite"), key: key)
        try await db.exec("""
            CREATE TABLE chunks(id INTEGER PRIMARY KEY, object_id TEXT, text TEXT);
            CREATE INDEX idx_obj ON chunks(object_id);
            CREATE VIRTUAL TABLE chunks_fts USING fts5(text, content='chunks', content_rowid='id');
            CREATE TRIGGER chunks_ai AFTER INSERT ON chunks BEGIN
              INSERT INTO chunks_fts(rowid, text) VALUES (new.id, new.text);
            END;
            """)
        let words = ["patent", "grant", "examiner", "renewal", "invoice", "meeting", "contract", "deadline", "budget", "review"]
        let t0 = Date()
        for batch in 0..<40 {
            var sql = "BEGIN;"
            for i in 0..<500 {
                let n = batch * 500 + i
                let text = (0..<40).map { words[($0 * 7 + n) % words.count] }.joined(separator: " ") + " item \(n)"
                sql += "INSERT INTO chunks(id, object_id, text) VALUES (\(n), 'o\(n % 997)', '\(text)');"
            }
            sql += "COMMIT;"
            try await db.exec(sql)
        }
        try await db.checkpointWAL()
        let write = Date().timeIntervalSince(t0)
        let t1 = Date()
        for w in words {
            _ = try await db.query("SELECT count(*) FROM chunks_fts WHERE chunks_fts MATCH ?;", [.text(w)])
            _ = try await db.query("SELECT count(*) FROM chunks WHERE object_id = ?;", [.text("o42")])
        }
        _ = try await db.query("SELECT count(*), sum(length(text)) FROM chunks;", [])
        let read = Date().timeIntervalSince(t1)
        await db.close()
        return (write, read)
    }

    @Test(.timeLimit(.minutes(5)))
    func encryptionCostIsMeasured() async throws {
        var plain = (write: Double.infinity, read: Double.infinity)
        var enc = (write: Double.infinity, read: Double.infinity)
        for _ in 0..<2 {
            let p = try await workload(nil)
            plain = (min(plain.write, p.write), min(plain.read, p.read))
            let e = try await workload(LedgerKey.random())
            enc = (min(enc.write, e.write), min(enc.read, e.read))
        }
        let summary = String(format: """
            20,000 chunks (FTS5 + index), best of 2:
            write  plain %.3f s  encrypted %.3f s  ratio %.2f×
            read   plain %.3f s  encrypted %.3f s  ratio %.2f×
            """, plain.write, enc.write, enc.write / plain.write, plain.read, enc.read, enc.read / max(plain.read, 0.0001))
        Attachment.record(summary + "\n", named: "encryption-cost.txt")
        #expect(enc.write / plain.write < 4, "\(summary)")
    }
}
