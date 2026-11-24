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

    // MARK: - ALC-12 time

    @Test("ALC-12: custody, case actions, AI runs and access events written now carry the recorder's time zone and clock source")
    func rowsCarryZoneAndClock() async throws {
        let f = try await CaseErasureTests.boot()
        defer { try? FileManager.default.removeItem(at: f.temp) }
        let tz = TimeZone.current.identifier
        // The fixture's ingest wrote custody through CustodyRepository.
        #expect(try await CaseErasureTests.count(f.db, "SELECT COUNT(*) FROM custody_events WHERE recorded_tz = ? AND clock_source IS NOT NULL;", [.text(tz)]) > 0)
        try await CaseFileRepository(database: f.db).logAction(caseID: f.caseA, action: "note", detail: nil, actor: "Asha")
        #expect(try await CaseErasureTests.count(f.db, "SELECT COUNT(*) FROM case_actions WHERE case_id = ? AND recorded_tz = ? AND clock_source = 'system';",
                                                 [.uuid(f.caseA), .text(tz)]) >= 1)
        let repo = CaseAIRecordRepository(database: f.db)
        let run = try await repo.openRun(caseID: f.caseA, .init(kind: .question, task: "q", provider: "anthropic", modelRequested: "m", requestedBy: "Asha",
                                                                 documentsFingerprint: nil, inputVersions: [], coverage: [:], promptVersion: CaseAgent.promptVersion))
        #expect(try await f.db.query("SELECT recorded_tz FROM case_ai_runs WHERE id = ?;", [.uuid(run)]).first?.string(0) == tz)
        try await CaseAccessLog.record(f.db, caseID: f.caseA, kind: .caseOpened, actor: "Asha")
        #expect(try await CaseAccessLog.events(f.db, caseID: f.caseA).first?.clockSource == RecorderClock.systemSource)
        await f.state.shutdown()
    }

    final class FakeClock: @unchecked Sendable {
        let lock = NSLock()
        var wall = Date(timeIntervalSince1970: 1_800_000_000)
        var mono: TimeInterval = 1000
        func advance(_ s: TimeInterval, wallExtra: TimeInterval = 0) { lock.lock(); mono += s; wall = wall.addingTimeInterval(s + wallExtra); lock.unlock() }
        func w() -> Date { lock.lock(); defer { lock.unlock() }; return wall }
        func m() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return mono }
    }

    @Test("ALC-12: the wall clock is paired with the monotonic clock; a move over 2 minutes is a sealed clock-jump event, marks later rows and shows in the health line")
    func clockJump() async throws {
        let f = try await CaseErasureTests.boot()
        defer { try? FileManager.default.removeItem(at: f.temp); RecorderClock.resetForTesting() }
        RecorderClock.resetForTesting()
        let chain = try #require(await f.state.auditChain)
        let fake = FakeClock()
        let monitor = ClockMonitor(database: f.db, wall: { fake.w() }, monotonic: { fake.m() })
        await monitor.start()
        #expect(try await CaseErasureTests.count(f.db, "SELECT COUNT(*) FROM clock_sessions WHERE id = ?;", [.uuid(monitor.sessionID)]) == 1)
        fake.advance(60)
        #expect(await monitor.check() == nil, "in step")
        fake.advance(60, wallExtra: 90)
        #expect(await monitor.check() == nil, "90 s is under the threshold")
        #expect(await monitor.healthLine().hasPrefix("Clock: no jump"))
        fake.advance(60, wallExtra: -600)
        let jump = try #require(await monitor.check())
        #expect(abs(jump.delta + 600) < 0.001)
        #expect(RecorderClock.stamp().clockSource == RecorderClock.jumpedSource)
        #expect(await monitor.healthLine().contains("1 jump this session"))
        let events = try await ClockMonitor.auditChainEvents(f.db)
        #expect(events.count == 1 && events[0].source == .clockEvent)
        #expect(try await chain.seal() > 0)
        #expect(try await chain.verify().isIntact)
        await #expect(throws: (any Error).self) { try await f.db.exec("DELETE FROM clock_events;", []) }
        await f.state.shutdown()
    }

    /// A TimeStampResp around an (unsigned) SignedData carrying a TSTInfo — the shape a TSA returns, without a signer.
    static func syntheticResponse(digestHex: String, nonce: [UInt8], status: UInt8 = 0) -> Data {
        let digest = RFC3161.hexBytes(digestHex) ?? []
        let imprint = DER.sequence([DER.sequence([DER.oid(DER.sha256OID), [0x05, 0x00]]), DER.tlv(0x04, digest)])
        let tst = DER.sequence([DER.integer([1]), DER.oid([1, 2, 3, 4]), imprint, DER.integer([0x2A]), DER.tlv(0x18, Array("20261124120000Z".utf8)), DER.integer(nonce)])
        let encap = DER.sequence([DER.oid(DER.tstInfoOID), DER.tlv(0xA0, DER.tlv(0x04, tst))])
        let signed = DER.sequence([DER.integer([3]), DER.tlv(0x31, []), encap, DER.tlv(0x31, [])])
        let token = DER.sequence([DER.oid(DER.signedDataOID), DER.tlv(0xA0, signed)])
        return Data(DER.sequence([DER.sequence([DER.integer([status])]), token]))
    }

    @Test("ALC-12: RFC 3161 — the request carries only the SHA-256 and a nonce; a token is read (imprint, nonce, time) and checked; a refusal or an unsigned token never verifies")
    func rfc3161() throws {
        let digest = CaseFileHash.sha256("audit chain head")
        let nonce: [UInt8] = [0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x08]
        let req = try #require(RFC3161.request(digestHex: digest, nonce: nonce))
        #expect(req.count < NetworkHelperClient.timestampMaxBody, "small enough for the door")
        #expect(Data(req).range(of: Data(RFC3161.hexBytes(digest) ?? [])) != nil, "the imprint is the digest")
        let token = try RFC3161.token(fromResponse: Self.syntheticResponse(digestHex: digest, nonce: nonce))
        let info = try RFC3161.info(token: token)
        #expect(info.digestHex == digest && info.nonce == nonce)
        #expect(info.genTime == RFC3161.generalizedTime("20261124120000Z") && info.genTime != nil)
        let check = RFC3161.check(token: token, digestHex: digest, nonce: nonce)
        #expect(check.imprintMatches && check.nonceMatches && !check.signatureValid && !check.ok, "no signer: never verified")
        #expect(!RFC3161.check(token: token, digestHex: CaseFileHash.sha256("other"), nonce: nonce).imprintMatches)
        #expect(throws: RFC3161.Failure.notGranted(2)) { try RFC3161.token(fromResponse: Self.syntheticResponse(digestHex: digest, nonce: nonce, status: 2)) }
    }

    @Test("ALC-12: timestamps are off by default; when on, only the named authority is reachable through the door, the token is kept append-only and checkable")
    func trustedTimestampsThroughTheDoor() async throws {
        let f = try await CaseErasureTests.boot()
        defer { try? FileManager.default.removeItem(at: f.temp) }
        let defaults = try #require(UserDefaults(suiteName: "alc12-\(UUID().uuidString)"))
        #expect(!TrustedTimestampSettings.isEnabled(defaults), "off by default")
        let chain = try #require(await f.state.auditChain)
        await #expect(throws: (any Error).self) {
            try await TrustedTimestamps.stampChainHead(f.db, chain: chain, defaults: defaults) { _ in OutboundHTTPResponse(status: 200, body: Data(), retryAfter: nil) }
        }
        TrustedTimestampSettings.set(enabled: true, url: "https://tsa.example.org/tsr", defaults)
        #expect(TrustedTimestampSettings.allowedHost(defaults) == "tsa.example.org")
        let sent = SentBox()
        let kept = try await TrustedTimestamps.stampChainHead(f.db, chain: chain, defaults: defaults) { req in
            sent.set(req)
            // The TSA answers for the digest and nonce it was sent.
            let bytes = Array(req.body)
            let top = try #require(DER.read(bytes[...]))
            let parts = DER.children(top.content)
            let digest = DER.children(parts[1].content)[1].content
            let nonce = Array(parts[2].content.drop { $0 == 0 })
            return OutboundHTTPResponse(status: 200, body: Self.syntheticResponse(digestHex: digest.map { String(format: "%02x", $0) }.joined(), nonce: nonce), retryAfter: nil)
        }
        let req = try #require(sent.get())
        #expect(req.purpose == "timestamp" && req.method == nil && req.headers["Content-Type"] == "application/timestamp-query")
        #expect(req.url == "https://tsa.example.org/tsr" && req.body.count <= NetworkHelperClient.timestampMaxBody)
        let head = try await chain.head()
        #expect(kept.digestHex == head.hash && kept.subjectKind == "chainHead")
        let stored = try await TrustedTimestamps.kept(f.db)
        #expect(stored.count == 1 && stored[0].token == kept.token)
        let check = TrustedTimestamps.verify(stored[0])
        #expect(check.imprintMatches && check.nonceMatches && !check.ok, "\(check.line)")
        await #expect(throws: (any Error).self) { try await f.db.exec("UPDATE trusted_timestamps SET tsa_url = 'x';", []) }
        // The helper accepts only the small typed POST (source check: the helper target is not in the test host).
        let helper = try String(contentsOf: Self.repo("KalsmritikoshNetworkHelper/KalsmritikoshNetworkHelper.swift"), encoding: .utf8)
        #expect(helper.contains("req.purpose == \"timestamp\"") && helper.contains("application/timestamp-query") && helper.contains("timestampMaxBody = 256"))
        await f.state.shutdown()
    }

    @Test("ALC-12: the network door lets a timestamp request reach only the authority named while timestamping is on")
    func doorAllowsOnlyTheNamedAuthority() {
        let store = AppDefaults.store
        let before = (TrustedTimestampSettings.isEnabled(store), TrustedTimestampSettings.url(store) ?? "")
        defer { TrustedTimestampSettings.set(enabled: before.0, url: before.1, store) }
        TrustedTimestampSettings.set(enabled: false, url: "https://tsa.example.org/tsr", store)
        #expect(!NetworkHelperClient.allows(host: "tsa.example.org", method: nil, purpose: "timestamp"), "off")
        TrustedTimestampSettings.set(enabled: true, url: "https://tsa.example.org/tsr", store)
        #expect(NetworkHelperClient.allows(host: "tsa.example.org", method: nil, purpose: "timestamp"))
        #expect(!NetworkHelperClient.allows(host: "evil.example.com", method: nil, purpose: "timestamp"), "another host")
        #expect(!NetworkHelperClient.allows(host: "tsa.example.org", method: "GET", purpose: "timestamp"), "POST only")
        #expect(!NetworkHelperClient.allows(host: "tsa.example.org", method: nil, purpose: nil), "not an AI host")
    }

    final class SentBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: OutboundHTTPRequest?
        func set(_ v: OutboundHTTPRequest) { lock.lock(); value = v; lock.unlock() }
        func get() -> OutboundHTTPRequest? { lock.lock(); defer { lock.unlock() }; return value }
    }

    // MARK: - ALC-14 reproducibility

    @Test("ALC-14: every agent run keeps each AI reply body and its tool calls and results, in order, hashed; erased with the case")
    func runExchangesKept() async throws {
        let r = try await AgentSplitX2Tests.rig(AgentSplitX2Tests.docs()) { send in
            send.purpose == "case.picture" ? AgentSplitX2Tests.pictureReply(send) : AgentSplitX2Tests.questionReply(send)
        }
        _ = try await r.service.answer(caseID: r.caseID, question: "Was Kestrel Supplies paid twice for INV-104?", access: .testUnrestricted())
        let runs = try await r.repo.runs(caseID: r.caseID)
        let question = try #require(runs.first { $0.kind == "question" })
        let qx = try await r.repo.exchanges(runID: question.id)
        #expect(qx.map(\.kind).prefix(3) == ["reply", "toolCalls", "toolResults"], "\(qx.map(\.kind))")
        #expect(qx.contains { $0.kind == "toolCalls" && $0.body.contains("sum") })
        #expect(qx.contains { $0.kind == "reply" && $0.body.contains("need_tools") }, "the reply body as it came back")
        #expect(qx.last?.kind == "reply", "the final answer's body")
        #expect(qx.allSatisfy(\.intact) && qx.allSatisfy { $0.bodySHA256.count == 64 })
        let picture = try #require(runs.first { $0.kind == "picture" })
        #expect(!(try await r.repo.exchanges(runID: picture.id)).isEmpty, "the picture pass keeps its steps too")
        await #expect(throws: (any Error).self) { try await r.db.exec("UPDATE case_ai_run_exchanges SET body = 'x';", []) }
        await #expect(throws: (any Error).self) { try await r.db.exec("DELETE FROM case_ai_run_exchanges;", []) }
        // Erased with the case.
        let report = try await CaseEraser(database: r.db).erase(caseID: r.caseID, sourceVersionIDs: [], eraseExclusiveSources: false,
                                                                reason: "test", legalBasis: nil, actor: "Tester")
        #expect(report.refused == nil, "\(report.refused ?? "")")
        #expect(try await r.repo.exchanges().isEmpty)
        #expect(CaseDataInventory.entry("case_ai_run_exchanges")?.lifecycle == .caseID)
    }

    @Test("ALC-14: a person erasure removes kept AI replies that name the person; others stay")
    func runExchangesPersonErasure() async throws {
        let f = try await CaseErasureTests.boot()
        defer { try? FileManager.default.removeItem(at: f.temp) }
        let row = try #require(try await f.db.query("SELECT id, value FROM entities WHERE kind = 'person' AND value LIKE '%Roberts%' LIMIT 1;", []).first)
        let person = try #require(row.string(0).flatMap(UUID.init(uuidString:)))
        let name = try #require(row.string(1))
        let repo = CaseAIRecordRepository(database: f.db)
        let run = UUID()
        try await repo.recordExchanges(runID: run, caseID: f.caseA, [
            .init(step: 1, kind: .reply, body: "{\"answer\": \"\(name) signed the release\"}", modelServed: "m"),
            .init(step: 1, kind: .reply, body: "{\"answer\": \"the invoice was paid once\"}", modelServed: "m"),
        ])
        #expect(try await repo.exchanges(runID: run).count == 2)
        let out = try await f.state.erasePerson(person, reason: "Subject request", legalBasis: nil, actor: "Tester")
        #expect(out.report.refused == nil)
        let left = try await repo.exchanges(runID: run)
        #expect(left.count == 1 && !left[0].body.contains(name), "\(left.map(\.body))")
        #expect(out.report.rowsErased["case_ai_run_exchanges"] == 1)
        await f.state.shutdown()
    }
}
