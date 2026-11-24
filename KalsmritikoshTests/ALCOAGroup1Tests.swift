//
//  ALCOAGroup1Tests.swift
//  KalsmritikoshTests
//
//  ALCOA++ program, group 1 (owner 2026-11-24; docs/ALCOA_PROGRAM_2026-11-24.md): ALC-01 re-found AI records come back,
//  ALC-03 locale-aware amounts and unclear currencies, ALC-04 custody events, ALC-05 vault re-hash on open, ALC-06 the
//  audit-chain key survives a restore, ALC-09 "Stopped early", ALC-22 the FAIR2 checker fixes.
//

import Foundation
import CryptoKit
import Testing
@testable import Kalsmritikosh

@Suite("ALCOA group 1 — ALC-01/03/04/05/06/09/22", .serialized)
struct ALCOAGroup1Tests {

    // MARK: - ALC-01

    @Test("ALC-01: a record re-found after its document changed comes back as a new row; the withdrawn row stays, history kept")
    func refoundRecordComesBack() async throws {
        let f = try await CaseErasureTests.boot()
        defer { try? FileManager.default.removeItem(at: f.temp) }
        let repo = CaseAIRecordRepository(database: f.db)
        let doc = UUID()
        func fact() -> CaseAIRecord {
            CaseAIRecord(kind: .fact, text: "Kestrel was paid INR 50,000", quote: "debit INR 50,000 to Kestrel", document: doc,
                         origin: "picture", documentFingerprint: "fp1")
        }
        #expect(try await repo.record(caseID: f.caseA, [fact()]) == 1)
        #expect(try await repo.record(caseID: f.caseA, [fact()]) == 0, "an active repeat is skipped")
        #expect(try await repo.withdraw(caseID: f.caseA, documents: [doc], reason: "changed") == 1)
        #expect(try await repo.records(caseID: f.caseA).isEmpty)
        // Re-found after the change: it is back.
        #expect(try await repo.record(caseID: f.caseA, [fact()]) == 1)
        #expect(try await repo.records(caseID: f.caseA).count == 1)
        let all = try await repo.records(caseID: f.caseA, includeWithdrawn: true)
        #expect(all.count == 2, "the withdrawn version is kept")
        #expect(try await CaseErasureTests.count(f.db, "SELECT COUNT(*) FROM case_ai_records WHERE withdrawn_at IS NOT NULL AND withdrawn_reason = 'changed';", []) == 1)
        // A second change and re-find: a third row, every earlier one kept.
        try await repo.withdraw(caseID: f.caseA, documents: [doc], reason: "changed again")
        #expect(try await repo.record(caseID: f.caseA, [fact(), fact()]) == 1, "one row per statement within a batch")
        #expect(try await repo.records(caseID: f.caseA, includeWithdrawn: true).count == 3)
        #expect(try await repo.records(caseID: f.caseA).count == 1)
        await f.state.shutdown()
    }
}
