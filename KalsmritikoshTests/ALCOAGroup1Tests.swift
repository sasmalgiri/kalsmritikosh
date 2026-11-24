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

    // MARK: - ALC-03

    @Test("ALC-03: comma-decimal, space, Swiss and Indian grouping, scale words, ISO codes; $ / Rs never assumed")
    func amountsAllStyles() {
        func v(_ s: String) -> Decimal? { CaseAgent.amount(s)?.value }
        #expect(v("€1.234,56") == Decimal(string: "1234.56") && CaseAgent.amount("€1.234,56")?.currency == "EUR")
        #expect(v("EUR 1 234,56") == Decimal(string: "1234.56"))
        #expect(v("CHF 1'234.50") == Decimal(string: "1234.5") && CaseAgent.amount("CHF 1'234.50")?.currency == "CHF")
        #expect(v("₹1,23,456.78") == Decimal(string: "123456.78") && CaseAgent.amount("₹1,23,456.78")?.currency == "INR")
        #expect(v("SEK 1.234.567") == 1_234_567)
        #expect(v("12,50 EUR") == Decimal(string: "12.5"))
        #expect(v("INR 50,000") == 50_000)
        #expect(v("JPY 2.5 billion") == 2_500_000_000 && CaseAgent.amount("JPY 2.5 billion")?.currency == "JPY")
        #expect(v("AUD 3 mio") == 3_000_000)
        #expect(CaseAgent.amounts(in: "all 500 items were counted").isEmpty, "'all' is not Albanian lek")
        #expect(CaseAgent.amounts(in: "INV 500 was raised").isEmpty, "a 3-letter word that is no ISO code names no currency")
        let dollar = CaseAgent.amount("$1,200")
        #expect(dollar?.currency == nil && dollar?.isCurrencyUnclear == true && dollar?.candidates.contains("USD") == true && dollar?.candidates.contains("AUD") == true)
        #expect(CaseAgent.amount("¥5,000")?.candidates == ["JPY", "CNY"])
        #expect(CaseAgent.amount("A$5,000")?.currency == "AUD" && CaseAgent.amount("US$5")?.currency == "USD")
    }

    @Test("ALC-03 sum: an unclear $ is reported, never guessed; the AI's code, the document's code or the other terms' code resolves it; currencies never mix")
    func sumUnclearCurrency() {
        let unclear = CaseAgent.sum(plus: ["$100", "$50"], minus: [])
        #expect(unclear?.text.contains("currency unclear") == true && unclear?.totals["?$"] == 150, "\(unclear?.text ?? "")")
        #expect(unclear?.text.contains("USD") == true, "the candidates are named")
        let byAI = CaseAgent.sum(plus: ["$100", "$50"], minus: [], currency: "AUD")
        #expect(byAI?.totals == ["AUD": 150], "\(byAI?.text ?? "")")
        let byDoc = CaseAgent.sum(plus: ["$100"], minus: [], context: { _ in ["All amounts in this statement are in CAD."] })
        #expect(byDoc?.totals == ["CAD": 100] && byDoc?.text.contains("read as CAD") == true)
        let twoCodes = CaseAgent.sum(plus: ["$100"], minus: [], context: { _ in ["USD and AUD accounts"] })
        #expect(twoCodes?.totals["?$"] == 100, "two possible codes: still unclear")
        let others = CaseAgent.sum(plus: ["USD 100", "$50"], minus: [])
        #expect(others?.totals == ["USD": 150] && others?.text.contains("the currency the other terms name") == true)
        let never = CaseAgent.sum(plus: ["INR 100", "$50"], minus: [])
        #expect(never?.totals.count == 2 && never?.totals["INR"] == 100 && never?.totals["?$"] == 50)
        #expect(never?.text.contains("never added together") == true)
        let eu = CaseAgent.sum(plus: ["€1.234,56", "EUR 765,44"], minus: [])
        #expect(eu?.totals == ["EUR": 2000], "\(eu?.text ?? "")")
    }

    // MARK: - ALC-05 vault re-hash

    static func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("alc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func overwrite(_ url: URL, _ data: Data) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try data.write(to: url)
    }

    @Test("ALC-05: a plain copy is re-hashed on every open; an altered one is refused (url and data)")
    func plainCopyRehashed() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let vault = EvidenceVault(root: dir.appendingPathComponent("EvidenceVault"))
        let bytes = Data("The fee is 10,000.".utf8)
        let h = try await vault.store(bytes)
        #expect(await vault.checkedURL(for: h).check == .verified)
        #expect(await vault.checkedData(for: h).check == .verified)
        let plain = dir.appendingPathComponent("EvidenceVault/\(h.prefix(2))/\(h)")
        try Self.overwrite(plain, Data("The fee is 90,000.".utf8))
        let opened = await vault.checkedURL(for: h, filename: "contract.txt")
        #expect(opened.url == nil && opened.check == .mismatch)
        #expect(await vault.data(for: h) == nil)
        #expect(await vault.checkedData(for: h).check == .mismatch)
        #expect(await vault.checkedURL(for: String(repeating: "0", count: 64)).check == .notVaulted)
    }

    @Test("ALC-05: an already-opened sealed copy is re-hashed; altered → refused and removed; the next open is from the verified original, read-only 0400")
    func openedCopyRehashed() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let vault = EvidenceVault(root: dir.appendingPathComponent("EvidenceVault"), sealKey: SymmetricKey(size: .bits256))
        let bytes = Data("Sealed original: the fee is 10,000.".utf8)
        let h = try await vault.store(bytes)
        let first = await vault.checkedURL(for: h, filename: "contract.txt")
        let url = try #require(first.url)
        #expect(first.check == .verified)
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(perms?.intValue == 0o400, "opened copies are read-only")
        try Self.overwrite(url, Data("Altered copy".utf8))
        let again = await vault.checkedURL(for: h, filename: "contract.txt")
        #expect(again.url == nil && again.check == .mismatch)
        #expect(!FileManager.default.fileExists(atPath: url.path), "the altered opened copy is removed")
        let third = await vault.checkedURL(for: h, filename: "contract.txt")
        #expect(third.check == .verified)
        let reopened = try Data(contentsOf: try #require(third.url))
        #expect(reopened == bytes)
    }

    // MARK: - ALC-04 custody

    @Test("ALC-04/05: opening a cited version writes hash_verified; an altered kept copy writes hash_mismatch and shows a warning")
    func custodyOnOpen() async throws {
        let f = try await CitedSourceResolverTests.fixture()
        defer { try? FileManager.default.removeItem(at: f.dir) }
        let logical = UUID()
        let old = Data("Version 1: the fee is 10,000.".utf8)
        let v = try await CitedSourceResolverTests.version(f, logical: logical, bytes: old, current: false, url: nil)
        let h = CitedSourceResolverTests.hash(old)
        let shard = f.dir.appendingPathComponent("EvidenceVault/\(h.prefix(2))", isDirectory: true)
        try FileManager.default.createDirectory(at: shard, withIntermediateDirectories: true)
        try old.write(to: shard.appendingPathComponent(h))
        guard case .open = try await CitedSourceResolver.resolve(sourceVersionID: v, objectID: nil, database: f.db, ledgerURL: f.ledger, actor: "Asha Rao") else {
            Issue.record("the kept copy did not open"); return
        }
        func events(_ kind: String) async throws -> [SQLRow] {
            try await f.db.query("SELECT actor, hash, detail FROM custody_events WHERE file_id = ? AND kind = ?;", [.uuid(logical), .text(kind)])
        }
        let verified = try await events("hash_verified")
        #expect(verified.count == 1 && verified.first?.string(0) == "Asha Rao" && verified.first?.string(1) == h)
        // The kept copy is altered (the hard-linked opened name too): refused, recorded, warned.
        let opened = f.dir.appendingPathComponent("EvidenceVault-open/\(h)/contract.txt")
        try? FileManager.default.removeItem(at: opened)
        try Self.overwrite(shard.appendingPathComponent(h), Data("tampered".utf8))
        #expect(try await CitedSourceResolver.resolve(sourceVersionID: v, objectID: nil, database: f.db, ledgerURL: f.ledger) == .unavailable(.keptCopyAltered))
        let mismatch = try await events("hash_mismatch")
        #expect(mismatch.count == 1 && mismatch.first?.string(0) == "system", "no person known: the actor is system")
        #expect(CitedSourceResolver.Unavailable.keptCopyAltered.label.hasPrefix("Warning:"))
        #expect(CaseTypedReference.Availability(.keptCopyAltered) == .changedOnDisk)
    }

    @Test("ALC-04: the reprocessing re-read writes hash_verified, and hash_mismatch for a changed original; exports and disclosures write their events")
    func custodyOnReprocessAndExport() async throws {
        let f = try await CitedSourceResolverTests.fixture()
        defer { try? FileManager.default.removeItem(at: f.dir) }
        let logical = UUID()
        let file = f.dir.appendingPathComponent("contract.txt")
        let bytes = Data("The fee is 10,000.".utf8)
        try bytes.write(to: file)
        let v = try await CitedSourceResolverTests.version(f, logical: logical, bytes: bytes, current: true, url: file)
        let resolver = SourceVersionByteResolver(database: f.db, vault: nil)
        let r = try await resolver.resolve(sourceVersionID: v, at: Date())
        try? FileManager.default.removeItem(at: r.cleanupDirectory)
        func count(_ kind: String) async throws -> Int64 {
            try await f.db.query("SELECT COUNT(*) FROM custody_events WHERE file_id = ? AND kind = ?;", [.uuid(logical), .text(kind)]).first?.int(0) ?? -1
        }
        #expect(try await count("hash_verified") == 1)
        try Data("The fee is 90,000.".utf8).write(to: file)
        await #expect(throws: (any Error).self) { _ = try await resolver.resolve(sourceVersionID: v, at: Date()) }
        #expect(try await count("hash_mismatch") == 1)
        // Export of a derived copy and a disclosure, by version and by content hash.
        #expect(await CustodyRepository.recordForVersions(f.db, versions: [v], kind: .exported, actor: "Asha Rao", detail: "case output") == 1)
        #expect(await CustodyRepository.recordForVersions(f.db, hash: CitedSourceResolverTests.hash(bytes), kind: .disclosed, actor: " ", detail: "legal production") == 1)
        #expect(try await count("exported") == 1)
        #expect(try await count("disclosed") == 1)
        #expect(try await f.db.query("SELECT actor FROM custody_events WHERE kind = 'disclosed';", []).first?.string(0) == "system")
        #expect(await CustodyRepository.recordForVersions(f.db, versions: [UUID()], kind: .exported, actor: nil, detail: "x") == 0)
    }

    // MARK: - ALC-06 audit chain key

    static func events(_ n: Int, from start: Int = 0) -> [AuditChainEvent] {
        (start..<(start + n)).map { i in
            AuditChainEvent(source: .custody, eventID: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", i))!,
                            occurredAt: Date(timeIntervalSince1970: 1_000 + Double(i)), canonicalPayload: "k=\(i);")
        }
    }

    @Test("ALC-06: seals carry their key id; a restore / new Mac with only the ledger key verifies the ledger-key seals and checks the older ones' order")
    func chainSurvivesRestore() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion, at: dir.appendingPathComponent("k.sqlite"))
        let device = Data(repeating: 7, count: 32)
        let ledger = AuditChainSecret.ledgerKey(from: try #require(LedgerKey(raw: Data(repeating: 9, count: 32))))
        #expect(ledger.id.hasPrefix("ledger:") && ledger.secret.count == 32)
        final class Box: @unchecked Sendable { let lock = NSLock(); var events: [AuditChainEvent] = [] }
        let box = Box()
        box.events = Self.events(3)
        let provider: @Sendable () async throws -> [AuditChainEvent] = { box.lock.withLock { box.events } }
        // Before: device-only secret.
        let before = AuditChainService(database: db, secret: device, eventProvider: provider)
        #expect(try await before.seal() == 3)
        // After the upgrade: new seals with the ledger key; the device secret kept to verify the older seals.
        box.lock.withLock { box.events += Self.events(2, from: 3) }
        let after = AuditChainService(database: db, keys: [AuditChainSecret.deviceKeyID: device, ledger.id: ledger.secret], sealingKeyID: ledger.id, eventProvider: provider)
        #expect(try await after.seal() == 2)
        let ids = try await db.query("SELECT key_id FROM audit_chain ORDER BY seq;", []).map { $0.string(0) ?? "NULL" }
        #expect(ids == [AuditChainSecret.deviceKeyID, AuditChainSecret.deviceKeyID, AuditChainSecret.deviceKeyID, ledger.id, ledger.id])
        let here = try await after.verify()
        #expect(here.isIntact && here.keyUnavailableCount == 0)
        // A new Mac / restore: only the ledger key.
        let newMac = AuditChainService(database: db, keys: [ledger.id: ledger.secret], sealingKeyID: ledger.id, eventProvider: provider)
        let there = try await newMac.verify()
        #expect(there.isIntact && there.keyUnavailableCount == 3, "\(there.statusLine)")
        #expect(there.statusLine.contains("3 older seals were made with a key kept only on the Mac"))
        // A ledger-key seal altered after sealing still breaks there.
        box.lock.withLock {
            box.events[4] = AuditChainEvent(source: .custody, eventID: box.events[4].eventID, occurredAt: box.events[4].occurredAt, canonicalPayload: "k=altered;")
        }
        #expect(try await newMac.verify().firstBrokenSeq == 5)
    }

    @Test("ALC-06: the device secret is never overwritten — two loads give the same secret")
    func secretNotOverwritten() {
        let a = AuditChainSecret.loadOrGenerate()
        let b = AuditChainSecret.loadOrGenerate()
        if let a { #expect(a == b && AuditChainSecret.loadExisting() == a) }
    }

    // MARK: - ALC-09 stopped early

    @MainActor
    @Test("ALC-09: the step limit and the cost ceiling are said in the answer ('Stopped early: …') and on the Quality strip; a failed picture part is remembered")
    func stoppedEarly() async throws {
        let agent = CaseAgentTools(documents: [CaseReader.Document(objectID: UUID(), fileName: "a.txt", text: "Some text here.")], writesAllowed: false)
        let ask = #"{"status": "need_tools", "requests": [{"tool": "count", "items": ["a", "b"]}]}"#
        _ = try await CaseReader.agentLoop(["prefix"], rounds: 2, ceiling: nil, agent: agent,
                                           task: { allow, _ in allow ? "task with tools" : "task" }) { _, _ in CaseReader.Reply(text: ask) }
        #expect(agent.stoppedEarly == [CaseAgent.stepLimitNote(2)])
        let capped = CaseAgentTools(documents: [], writesAllowed: false)
        _ = try await CaseReader.agentLoop([String(repeating: "word ", count: 4_000)], rounds: 8, ceiling: 100, agent: capped,
                                           task: { _, _ in "task" }) { _, _ in CaseReader.Reply(text: ask) }
        #expect(capped.stoppedEarly.first?.hasPrefix("the cost ceiling") == true)
        // A loop the AI finished itself is not stopped early.
        let done = CaseAgentTools(documents: [], writesAllowed: false)
        _ = try await CaseReader.agentLoop(["p"], rounds: 2, ceiling: nil, agent: done, task: { _, _ in "t" }) { _, _ in CaseReader.Reply(text: #"{"status": "answered"}"#) }
        #expect(done.stoppedEarly.isEmpty)
        let answer = VerifiedAnswer(body: "The fee is 10,000.", citations: [], confidence: Confidence(0.9))
        let shown = CaseReader.stoppedEarly(answer, agent.stoppedEarly + [CaseAgent.pictureFailedNote(3)])
        #expect(shown.body.hasPrefix("(Stopped early: the AI used all 2 tool steps"))
        #expect(shown.body.contains("3 documents were not read for the case picture"))
        #expect(shown.confidence.value <= 0.6)
        #expect(QualityStrip.formatLine(shown).contains("Stopped early: the AI used all 2 tool steps"))
        #expect(!QualityStrip.formatLine(answer).contains("Stopped early"))
        #expect(CaseReader.stoppedEarly(answer, []).body == answer.body)
        // The failed picture parts registry.
        let reg = CasePictureFailures(), c = UUID(), d1 = UUID(), d2 = UUID()
        reg.record(caseID: c, documents: [d1, d2])
        reg.clear(caseID: c, documents: [d1])
        #expect(reg.documents(caseID: c) == [d2])
        reg.forget(caseID: c)
        #expect(reg.documents(caseID: c).isEmpty)
    }

    // MARK: - ALC-22 FAIR2 checker fixes

    @Test("ALC-22: '03 Aug 26', '3 Aug 2026', '2026-08-03' and 03/08/2026 (either order) read as one date")
    func datesOneReading() {
        typealias C = VerifiedAnswerComposer
        let d = C.values(in: "refunded by Kiln (03 Aug 26)", role: .claim)
        #expect(d.dates.count == 1 && d.dates.first?.year == 2026 && d.dates.first?.month == 8 && d.dates.first?.day == 3)
        #expect(d.numbers.isEmpty, "no bare 3 left over")
        #expect(C.valueMissing(claim: "refunded by Kiln (03 Aug 26)", quote: "Refund 03/08/2026 from Kiln", passage: "") == nil)
        #expect(C.valueMissing(claim: "paid on 3 Aug 2026", quote: "posted 2026-08-03", passage: "") == nil)
        #expect(C.valueMissing(claim: "paid on 8 March 2026", quote: "posted 03/08/2026", passage: "") == nil, "mm/dd reading")
        #expect(C.valueMissing(claim: "paid on 3 Aug 2026", quote: "posted 2026-08-04", passage: "") == "the date")
        #expect(C.values(in: "on 25/12/2026").dates.first?.month == 12, "a first part over 12 is the day")
        #expect(C.values(in: "born 3 Aug 98, recorded in 1998").dates.first?.year == 1998, "the context names 19yy")
    }

    @Test("ALC-22: 'one hundred percent' = 100 on both sides; 'two INR 50,000 debits' — the two is a count word")
    func numberWords() {
        typealias C = VerifiedAnswerComposer
        #expect(C.values(in: "one hundred percent", role: .claim).numbers == [100])
        #expect(C.values(in: "one hundred percent").numbers == [100])
        #expect(C.valueMissing(claim: "The match is one hundred percent.", quote: "a one hundred percent match", passage: "") == nil)
        #expect(C.valueMissing(claim: "The match is 100 per cent.", quote: "a one hundred percent match", passage: "") == nil)
        #expect(!C.values(in: "(two INR 50,000 debits)", role: .claim).numbers.contains(2))
        #expect(C.valueMissing(claim: "Kestrel received two INR 50,000 debits", quote: "debit INR 50,000 to Kestrel", passage: "") == nil)
        #expect(C.values(in: "five dollars", role: .claim).numbers == [5], "a currency unit with no amount after it still counts")
    }

    @Test("ALC-22: an exact quote under 12 characters is allowed when it carries the value the claim needs ('No. 8649.')")
    func shortExactQuote() {
        typealias C = VerifiedAnswerComposer
        let p = C.Passage(objectID: UUID(), text: "SUPREME COURT OF THE STATE\nNo. 8649.\nDecided March 3, 1951.")
        #expect(C.whyNot(.init(text: "The docket number is No. 8649", quote: "No. 8649.", passage: 1, about: nil), passages: [p]) == nil)
        #expect(C.whyNot(.init(text: "The court decided it", quote: "No. 8649.", passage: 1, about: nil), passages: [p]) == "quote too short")
        #expect(C.whyNot(.init(text: "The docket number is 8650", quote: "No. 8649.", passage: 1, about: nil), passages: [p]) != nil)
        #expect(C.whyNot(.init(text: "The docket number is No. 8649", quote: "No. 8648.", passage: 1, about: nil), passages: [p]) != nil)
    }
}
