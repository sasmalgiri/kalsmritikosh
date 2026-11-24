//
//  ALCOAGroup3Tests.swift
//  KalsmritikoshTests
//
//  ALCOA++ program, group 3 (owner 2026-11-24; docs/ALCOA_PROGRAM_2026-11-24.md): the erasure / audit-chain fix (a
//  recorded erasure leaves seal tombstones, so verify reads "erased (recorded)", not broken), ALC-11 view log, ALC-12 time,
//  ALC-14 reproducibility, ALC-15 secure staging, ALC-16 availability. No model, no network, no API spend.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("ALCOA group 3 — erasure tombstones, ALC-11/12/14/15/16", .serialized)
struct ALCOAGroup3Tests {

    // MARK: - Fix: a recorded erasure is not a broken chain

    /// Case A's sealed work beyond the fixture's case action: an AI record (and its withdrawal), a decision, a run, a revision.
    static func sealedWork(_ f: CaseErasureTests.Fixture) async throws {
        let repo = CaseAIRecordRepository(database: f.db)
        let doc = UUID()
        let rec = CaseAIRecord(kind: .fact, text: "Kestrel was paid", quote: "debit INR 50,000 to Kestrel", document: doc, origin: "picture")
        try await repo.record(caseID: f.caseA, [rec])
        try await repo.decide(caseID: f.caseA, recordID: rec.id, .accept, reason: nil, approver: "Asha")
        let run = try await repo.openRun(caseID: f.caseA, .init(kind: .question, task: "q", provider: "anthropic", modelRequested: "m", requestedBy: "Asha",
                                                                 documentsFingerprint: nil, inputVersions: [], coverage: [:], promptVersion: CaseAgent.promptVersion))
        try await repo.finishRun(run, caseID: f.caseA, state: "done", reason: nil, usage: [], counts: [:])
        try await repo.withdraw(caseID: f.caseA, documents: [doc], reason: "changed")
        try await f.db.exec("""
            INSERT INTO case_record_revisions (id, case_id, action_id, record_kind, record_id, change, before_json, after_json, actor, recorded_at)
            VALUES (?, ?, NULL, 'profile', 'r1', 'profileSaved', '{"a":1}', '{"a":2}', 'Asha', ?);
            """, [.uuid(UUID()), .uuid(f.caseA), .date(Date())])
    }

    @Test("Fix: erasing a case (and its own documents) leaves verify intact with 'N rows erased (recorded)'; the tombstones carry no content")
    func caseErasureKeepsChainVerifiable() async throws {
        let f = try await CaseErasureTests.boot()
        defer { try? FileManager.default.removeItem(at: f.temp) }
        let chain = try #require(await f.state.auditChain)
        try await Self.sealedWork(f)
        #expect(try await chain.seal() > 0)
        #expect(try await chain.verify().isIntact)
        let out = try await f.state.eraseCase(f.caseA, eraseExclusiveSources: true, reason: "Client request", legalBasis: nil, actor: "Tester")
        #expect(out.report.refused == nil, "\(out.report.refused ?? "")")
        let v = try await chain.verify()
        #expect(v.isIntact, "\(v.statusLine)")
        // case action, AI record + withdrawal, decision, run, revision, custody/source versions of the erased document, …
        #expect(v.erasedRecordedCount >= 6, "\(v.erasedRecordedCount)")
        #expect(v.statusLine.contains("\(v.erasedRecordedCount) rows erased (recorded)"), "\(v.statusLine)")
        let tables = Set(try await f.db.query("SELECT DISTINCT tbl FROM audit_chain_tombstones;", []).compactMap { $0.string(0) })
        #expect(tables.isSuperset(of: ["case_actions", "case_ai_records", "case_ai_runs", "case_ai_record_decisions", "case_record_revisions"]), "\(tables)")
        let cols = Set(try await f.db.query("PRAGMA table_info(audit_chain_tombstones);", []).compactMap { $0.string(1) })
        #expect(cols == ["id", "erasure_id", "tbl", "row_key", "source", "event_id", "seq", "seal_digest", "recorded_at"], "content-free: \(cols)")
        let digest = try await f.db.query("SELECT seal_tombstones_sha256 FROM case_erasures WHERE case_id = ?;", [.uuid(f.caseA)]).first?.string(0)
        #expect(digest?.count == 64, "the erasure register binds its tombstones")
        // The erasure itself seals; the chain stays intact; tombstones cannot be edited or removed.
        #expect(try await chain.seal() > 0)
        #expect(try await chain.verify().isIntact)
        await #expect(throws: (any Error).self) { try await f.db.exec("DELETE FROM audit_chain_tombstones;", []) }
        await #expect(throws: (any Error).self) { try await f.db.exec("UPDATE audit_chain_tombstones SET seal_digest = 'x';", []) }
        await f.state.shutdown()
    }

    @Test("Fix: a sealed row deleted behind the app's back still breaks the chain — and a forged tombstone does not excuse it")
    func deletionBehindTheAppsBackStillBreaks() async throws {
        let f = try await CaseErasureTests.boot()
        defer { try? FileManager.default.removeItem(at: f.temp) }
        let chain = try #require(await f.state.auditChain)
        try await Self.sealedWork(f)
        #expect(try await chain.seal() > 0)
        // A recorded erasure of case A first (its rows are excused) …
        let out = try await f.state.eraseCase(f.caseA, eraseExclusiveSources: false, reason: "Client request", legalBasis: nil, actor: "Tester")
        #expect(out.report.refused == nil)
        _ = try await chain.seal()
        #expect(try await chain.verify().isIntact)
        // … then case B's sealed action removed directly (the guard's marker set by hand; no erasure recorded).
        let action = try #require(try await f.db.query("SELECT id FROM case_actions WHERE case_id = ? LIMIT 1;", [.uuid(f.caseB)]).first?.string(0))
        try await f.db.exec("INSERT INTO ledger_case_erase (case_id) VALUES (?);", [.uuid(f.caseB)])
        try await f.db.exec("DELETE FROM case_actions WHERE id = ?;", [.text(action)])
        try await f.db.exec("DELETE FROM ledger_case_erase;", [])
        let v = try await chain.verify()
        #expect(!v.isIntact && v.missingEventSeq != nil, "\(v.statusLine)")
        #expect(v.statusLine.hasPrefix("BROKEN"))
        // A tombstone forged under the recorded erasure's id does not match that erasure's sealed digest: not used.
        let erasure = try #require(out.report.erasureID)
        let seal = try #require(try await f.db.query("SELECT seq, payload_hash FROM audit_chain WHERE source = 'caseAction' AND event_id = ?;",
                                                     [.text(action.uppercased())]).first)
        try await f.db.exec("""
            INSERT INTO audit_chain_tombstones (erasure_id, tbl, row_key, source, event_id, seq, seal_digest, recorded_at)
            VALUES (?, 'case_actions', ?, 'caseAction', ?, ?, ?, 0);
            """, [.uuid(erasure), .text(action), .text(action.uppercased()), .integer(seal.int(0) ?? 0), .text(seal.string(1) ?? "")])
        let forged = try await chain.verify()
        #expect(!forged.isIntact, "\(forged.statusLine)")
        await f.state.shutdown()
    }

    @Test("Fix: a person erasure that removes sealed rows is recorded; a full erase empties the chain and the tombstones together")
    func personAndFullErasure() async throws {
        let f = try await CaseErasureTests.boot()
        defer { try? FileManager.default.removeItem(at: f.temp) }
        let chain = try #require(await f.state.auditChain)
        let row = try #require(try await f.db.query("SELECT id FROM entities WHERE kind = 'person' AND value LIKE '%Roberts%' LIMIT 1;", []).first)
        let person = try #require(row.string(0).flatMap(UUID.init(uuidString:)))
        // A sealed review of the person's fact: a person erasure removes it.
        try await f.db.exec("INSERT INTO fact_reviews (id, subject_kind, subject_id, action, reviewer, reviewed_at) VALUES (?, 'entity', ?, 'accept', 'u', 1);",
                            [.uuid(UUID()), .uuid(person)])
        _ = try await chain.seal()
        #expect(try await chain.verify().isIntact)
        let out = try await f.state.erasePerson(person, reason: "Subject request", legalBasis: nil, actor: "Tester")
        #expect(out.report.refused == nil)
        let v = try await chain.verify()
        #expect(v.isIntact, "\(v.statusLine)")
        _ = try await chain.seal()
        #expect(try await chain.verify().isIntact)
        _ = await f.state.deleteAllData()
        #expect(try await CaseErasureTests.count(f.db, "SELECT COUNT(*) FROM audit_chain_tombstones;", []) == 0)
        #expect(try await chain.verify().isIntact)
        await f.state.shutdown()
    }

    // MARK: - ALC-11 view log

    @Test("ALC-11: access events are content-free, append-only, carry the recorder time zone, are sealed, and go with the case (erased, recorded)")
    func accessLog() async throws {
        let f = try await CaseErasureTests.boot()
        defer { try? FileManager.default.removeItem(at: f.temp) }
        let chain = try #require(await f.state.auditChain)
        let version = UUID(), output = UUID()
        for (kind, subject) in [(CaseAccessKind.caseOpened, nil), (.originalOpened, version), (.exportCreated, output), (.exportViewed, output), (.aiFindingsReviewed, nil)] as [(CaseAccessKind, UUID?)] {
            try await CaseAccessLog.record(f.db, caseID: f.caseA, kind: kind, subject: subject, actor: "Asha")
        }
        try await CaseAccessLog.record(f.db, caseID: f.caseB, kind: .caseOpened, actor: "Ravi")
        let a = try await CaseAccessLog.events(f.db, caseID: f.caseA)
        #expect(a.map(\.kind) == [.caseOpened, .originalOpened, .exportCreated, .exportViewed, .aiFindingsReviewed])
        #expect(a.allSatisfy { $0.recordedTimeZone == TimeZone.current.identifier && $0.actor == "Asha" })
        #expect(a[1].subjectRef?.uppercased() == version.uuidString, "the id only")
        #expect(CaseAccessLog.line(a[1]).contains("opened an original") && CaseAccessLog.line(a[1]).contains(TimeZone.current.identifier))
        // Content-free: no column for a name or text.
        let cols = Set(try await f.db.query("PRAGMA table_info(case_access_events);", []).compactMap { $0.string(1) })
        #expect(cols == ["id", "case_id", "actor", "kind", "subject_ref", "occurred_at", "recorded_tz", "clock_source"])
        await #expect(throws: (any Error).self) { try await f.db.exec("UPDATE case_access_events SET actor = 'x';", []) }
        await #expect(throws: (any Error).self) { try await f.db.exec("DELETE FROM case_access_events;", []) }
        // Sealed.
        let events = try await CaseAccessLog.auditChainEvents(f.db)
        #expect(events.count == 6 && events.allSatisfy { $0.source == .accessEvent })
        #expect(try await chain.seal() > 0)
        #expect(try await chain.verify().isIntact)
        // Erased with the case; the chain reads erased (recorded).
        let out = try await f.state.eraseCase(f.caseA, eraseExclusiveSources: false, reason: "Client request", legalBasis: nil, actor: "Tester")
        #expect(out.report.refused == nil)
        #expect(try await CaseAccessLog.events(f.db, caseID: f.caseA).isEmpty)
        #expect(try await CaseAccessLog.events(f.db, caseID: f.caseB).count == 1)
        let v = try await chain.verify()
        #expect(v.isIntact && v.erasedRecordedCount >= 5, "\(v.statusLine)")
        #expect(CaseDataInventory.entry("case_access_events")?.lifecycle == .caseID)
        await f.state.shutdown()
    }

    @Test("ALC-11: an export made through the output door is an access event; the access log is shown in the case log")
    func exportCreatesAccessEvent() async throws {
        let src = try String(contentsOf: Self.repo("Kalsmritikosh/Investigate/CaseFile/CaseOutputService.swift"), encoding: .utf8)
        #expect(src.contains("kind: .exportCreated"))
        let view = try String(contentsOf: Self.repo("Kalsmritikosh/UI/CaseFileView.swift"), encoding: .utf8)
        #expect(view.contains("CaseAccessLogSection(") && view.contains("kind: .caseOpened"))
        let cite = try String(contentsOf: Self.repo("Kalsmritikosh/UI/Shared/CitedSourceOpening.swift"), encoding: .utf8)
        #expect(cite.contains("kind: .originalOpened"))
        let review = try String(contentsOf: Self.repo("Kalsmritikosh/UI/CaseMapUnifiedTools.swift"), encoding: .utf8)
        #expect(review.contains("kind: .aiFindingsReviewed"))
    }

    static func repo(_ rel: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(rel)
    }
}
