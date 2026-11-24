//
//  SpeedProgramTests.swift
//  KalsmritikoshTests
//
//  Speed program test phase (owner 2026-11-23): one focused test per core claim of PERF-21 … PERF-32
//  (docs/SPEED_PROGRAM_2026-11-23.md). Scripted providers and helpers only (nothing leaves the Mac),
//  throwaway ledgers only (never the owner's). No timing assertions except generous upper bounds.
//

import Foundation
import CryptoKit
import os
import Testing
@testable import Kalsmritikosh

// MARK: - PERF-22 · AdaptiveConcurrency (AIMD)

private struct ScriptedOverload: AIOverloadSignalling {
    let overloadRetryAfter: Double?
    var isOverload: Bool { true }
}

private nonisolated final class InFlightCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var now = 0, peak = 0, total = 0
    func enter() { lock.withLock { now += 1; total += 1; peak = max(peak, now) } }
    func leave() { lock.withLock { now -= 1 } }
    var snapshot: (peak: Int, total: Int) { lock.withLock { (peak, total) } }
}

@Suite("Speed PERF-22 — AdaptiveConcurrency (AIMD)", .serialized)
struct SpeedAdaptiveConcurrencyTests {

    @Test("+1 per window while throughput rises; no growth when it falls; ×0.5 on an overload down to the floor; growth resumes after")
    func aimd() async throws {
        let l = AdaptiveConcurrency(start: 2, cap: 8)
        #expect(await l.limit == 2)
        // Window 1 (2 successes, slow): the first window always grows.
        await l.release(.success)
        try await Task.sleep(for: .milliseconds(250))
        await l.release(.success)
        #expect(await l.limit == 3)
        // Window 2 (3 successes at once): throughput far above window 1 → +1.
        for _ in 0..<3 { await l.release(.success) }
        #expect(await l.limit == 4)
        // Window 3 (4 successes over ~1.5 s): throughput fell → no growth.
        try await Task.sleep(for: .milliseconds(1_500))
        for _ in 0..<4 { await l.release(.success) }
        #expect(await l.limit == 4)
        // An overload halves; a second halves again; the floor holds.
        await l.release(.overloaded(retryAfter: nil))
        #expect(await l.limit == 2)
        await l.release(.overloaded(retryAfter: nil))
        #expect(await l.limit == 1)
        await l.release(.overloaded(retryAfter: nil))
        #expect(await l.limit == 1)
        // A plain failure changes nothing.
        await l.release(.failure)
        #expect(await l.limit == 1)
        // After a back-off the next window grows again.
        await l.release(.success)
        #expect(await l.limit == 2)
    }

    @Test("The limit never passes the WorkerBudget cap; aiCap is at most 8 and what WorkerBudget allows")
    func capHolds() async throws {
        let l = AdaptiveConcurrency(start: 2, cap: 3)
        for _ in 0..<40 { await l.release(.success) }
        #expect(await l.limit == 3)
        #expect(await AdaptiveConcurrency(start: 10, cap: 4).cap == 4)
        #expect(await AdaptiveConcurrency(start: 10, cap: 4).limit == 4)
        let expected = min(8, WorkerBudget.current(pressure: .normal).workers(perWorkerBytes: 64 * 1_048_576))
        #expect(AdaptiveConcurrency.aiCap(pressure: .normal) == expected)
        #expect(AdaptiveConcurrency.aiCap(pressure: .normal) <= 8)
        // A real loop: never more than the cap in flight; every item done once, results in order.
        let counter = InFlightCounter()
        let out = await AdaptiveConcurrency.mapResults(Array(0..<30), cap: 3) { i -> Int in
            counter.enter(); defer { counter.leave() }
            try await Task.sleep(for: .milliseconds(15))
            return i * 2
        }
        #expect(counter.snapshot.peak <= 3 && counter.snapshot.peak >= 2)
        #expect(counter.snapshot.total == 30)
        #expect(out.compactMap { try? $0.get() } == (0..<30).map { $0 * 2 })
    }

    @Test("Retry-After is honoured: after a 429 asking 0.6 s the next request waits for it")
    func retryAfterHonoured() async throws {
        let l = AdaptiveConcurrency(start: 2, cap: 4)
        await l.acquire()
        await l.release(.overloaded(retryAfter: 0.6))
        let t = ContinuousClock.now
        await l.acquire()
        let waited = ContinuousClock.now - t
        await l.release(.success)
        #expect(waited >= .milliseconds(550), "waited \(waited)")
    }

    @Test("Errors are classified: an overload signal (with its wait) and a timeout back off; other errors and cancellation do not")
    func classification() {
        if case .overloaded(let wait) = AdaptiveConcurrency.classify(ScriptedOverload(overloadRetryAfter: 3)) { #expect(wait == 3) } else {
            Issue.record("an overload signal must classify as overloaded")
        }
        if case .overloaded(let wait) = AdaptiveConcurrency.classify(NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)) { #expect(wait == nil) } else {
            Issue.record("a timeout must classify as overloaded")
        }
        if case .failure = AdaptiveConcurrency.classify(NSError(domain: "x", code: 1)) {} else { Issue.record("a plain error is a failure") }
        if case .failure = AdaptiveConcurrency.classify(CancellationError()) {} else { Issue.record("cancellation is a failure") }
    }

    @Test("An overload noted anywhere (AIOverload) halves a live limiter at its next acquire")
    func globalOverload() async {
        let l = AdaptiveConcurrency(start: 4, cap: 8)
        #expect(await l.limit == 4)
        AIOverload.note(retryAfter: nil)
        await l.acquire()
        await l.release(.failure)
        #expect(await l.limit == 2)
    }
}

// MARK: - PERF-25/26 · WorkStealingQueue

@Suite("Speed PERF-25/26 — WorkStealingQueue")
struct SpeedWorkStealingTests {

    @Test("An idle worker steals the back half of the LARGEST remaining segment; the victim keeps the front half")
    func stealsLargestHalf() throws {
        let q = WorkStealingQueue(0..<100, workers: 4)   // 0..<25, 25..<50, 50..<75, 75..<100
        let own = try #require(q.claim(worker: 0, batch: 25))
        #expect(own == 0..<25)
        // Make segment 2 the largest by draining part of 1 and 3.
        _ = q.claim(worker: 1, batch: 10)   // 25..<35 → 35..<50 left (15)
        _ = q.claim(worker: 3, batch: 20)   // 75..<95 → 95..<100 left (5)
        let stolen = try #require(q.claim(worker: 0, batch: 100))
        #expect(stolen == 62..<75, "half of 50..<75 (the largest) taken from the back")
        #expect(q.claim(worker: 2, batch: 100) == 50..<62, "the victim keeps the front half")
        #expect(q.remaining == 15 + 5)
    }

    @Test("Every index is claimed exactly once under contention (uneven batches, many threads)")
    func exactlyOnce() {
        let n = 10_007
        let q = WorkStealingQueue(0..<n, workers: 6)
        let seen = OSAllocatedUnfairLock(initialState: [Int](repeating: 0, count: n))
        DispatchQueue.concurrentPerform(iterations: 6) { w in
            while let r = q.claim(worker: w, batch: 1 + (w * 7) % 13) {
                if w == 0 { usleep(5) }   // a slow worker: the others steal its share
                seen.withLock { s in for i in r { s[i] += 1 } }
            }
        }
        let counts = seen.withLock { $0 }
        #expect(counts.allSatisfy { $0 == 1 })
        #expect(q.remaining == 0)
    }

    @Test("perform / map / mapSync run every index once and keep index order")
    func runners() async throws {
        let hits = OSAllocatedUnfairLock(initialState: [Int](repeating: 0, count: 500))
        try WorkStealingQueue.perform(count: 500, workers: 5) { i in
            if i % 50 == 0 { usleep(200) }
            hits.withLock { $0[i] += 1 }
        }
        #expect(hits.withLock { $0 }.allSatisfy { $0 == 1 })
        let mapped = await WorkStealingQueue.map(count: 300, workers: 4, batch: 3) { i in i * i }
        let squares: [Int?] = (0..<300).map { (i: Int) -> Int? in i * i }  // CI fix: typed (type-check time)
        #expect(mapped == squares)
        let sync = WorkStealingQueue.mapSync(count: 777, workers: 6) { "#\($0)" }
        #expect(sync == (0..<777).map { "#\($0)" })
        // The first error stops the others from claiming and is rethrown.
        struct Stop: Error {}
        #expect(throws: Stop.self) { try WorkStealingQueue.perform(count: 100, workers: 4) { i in if i == 42 { throw Stop() } } }
    }
}

// MARK: - PERF-25 · StreamingFileCopy + CopyResumeLog

@Suite("Speed PERF-25 — StreamingFileCopy and the copy resume log", .serialized)
struct SpeedStreamingCopyTests {

    static func scratch() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("spc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func randomFile(_ url: URL, bytes: Int) throws -> String {
        var g = SystemRandomNumberGenerator()
        var data = Data(count: bytes)
        data.withUnsafeMutableBytes { raw in
            let words = raw.bindMemory(to: UInt64.self)
            for i in words.indices { words[i] = g.next() }
        }
        try data.write(to: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @Test("One pass: the digest returned by the copy equals the file's own digest; the copy is byte-identical; progress reaches the size")
    func onePassDigest() throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("src.bin"), dst = dir.appendingPathComponent("dst.bin")
        let size = 9 * 1_048_576 + 12_345   // more than one 8 MB buffer
        let digest = try Self.randomFile(src, bytes: size)
        var last: Int64 = 0
        let m = try StreamingFileCopy.copyAndHash(from: src, to: dst) { last = $0 }
        #expect(m.sha256 == digest && m.byteSize == Int64(size))
        #expect(last == Int64(size))
        #expect(try StreamingFileCopy.hash(dst) == m)
        #expect(try Data(contentsOf: dst) == Data(contentsOf: src))
        // Small buffers (many reads) give the same digest.
        #expect(try StreamingFileCopy.hash(src, bufferBytes: 70_000).sha256 == digest)
    }

    @Test("The resume log: a finished file is reused while source and copy are unchanged, re-copied when the source changes, and survives a restart; a damaged line is ignored")
    func resumeLog() throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stage = dir.appendingPathComponent("stage", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        let a = dir.appendingPathComponent("a.bin"), b = dir.appendingPathComponent("b.bin")
        let da = try Self.randomFile(a, bytes: 300_000)
        _ = try Self.randomFile(b, bytes: 200_000)
        let log = CopyResumeLog(folder: stage)
        let first = try log.copy(a, to: stage, relativePath: "x/a.bin")
        #expect(first.sha256 == da)
        #expect(log.reusable(relativePath: "x/a.bin", source: a, copy: stage.appendingPathComponent("x/a.bin")) == first)
        // A restart (a new log over the same folder) still knows the finished file; one damaged line is skipped.
        let h = try FileHandle(forWritingTo: stage.appendingPathComponent(CopyResumeLog.fileName))
        try h.seekToEnd(); try h.write(contentsOf: Data("{not json\n".utf8)); try h.close()
        let reopened = CopyResumeLog(folder: stage)
        #expect(reopened.reusable(relativePath: "x/a.bin", source: a, copy: stage.appendingPathComponent("x/a.bin")) == first)
        #expect(reopened.reusable(relativePath: "b.bin", source: b, copy: stage.appendingPathComponent("b.bin")) == nil)
        // The source changes → not reusable → copied again with the new digest.
        Thread.sleep(forTimeInterval: 0.01)
        let changed = try Self.randomFile(a, bytes: 300_001)
        #expect(reopened.reusable(relativePath: "x/a.bin", source: a, copy: stage.appendingPathComponent("x/a.bin")) == nil)
        #expect(try reopened.copy(a, to: stage, relativePath: "x/a.bin").sha256 == changed)
        reopened.remove()
        #expect(!FileManager.default.fileExists(atPath: stage.appendingPathComponent(CopyResumeLog.fileName).path))
    }
}

// MARK: - PERF-23 · keyset pagers

@Suite("Speed PERF-23 — keyset pagers give the OFFSET order", .serialized)
struct SpeedKeysetPagerTests {

    @Test("Events by (date, id): every row once, in ORDER BY date, id — with many equal dates and lower-case stored ids")
    func eventsKeyset() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        try await db.exec("PRAGMA foreign_keys = OFF;")
        let repo = EventsRepository(database: db)
        let person = UUID()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var events: [Event] = []
        for i in 0..<230 {
            // Five dates only: long runs of ties, so the id tiebreak decides most page edges.
            events.append(Event(kind: .meetingHeld, date: base.addingTimeInterval(Double(i % 5) * 86_400), title: "Meeting \(i)",
                                entityIDs: [person], sourceObjectID: UUID()))
        }
        try await repo.insertBatch(events)
        // A third of the rows store their id in lower case (written by another path).
        let lower = events.enumerated().filter { $0.offset % 3 == 0 }.map(\.element.id)
        for id in lower {
            try await db.exec("UPDATE events SET id = lower(id) WHERE id = ?;", [.uuid(id)])
            try await db.exec("UPDATE event_entities SET event_id = lower(event_id) WHERE event_id = ?;", [.uuid(id)])
        }
        let reference = try await db.query("SELECT id FROM events ORDER BY date ASC, id ASC;", []).compactMap { $0.uuid(0) }
        // The OFFSET pager the code had before, with the same total order.
        var offsetWalk: [UUID] = []
        for page in 0..<40 {
            let rows = try await db.query("SELECT id FROM events ORDER BY date ASC, id ASC LIMIT 7 OFFSET ?;", [.integer(Int64(page * 7))])
            offsetWalk += rows.compactMap { $0.uuid(0) }
        }
        #expect(offsetWalk == reference)

        var walked: [UUID] = []
        var cursor: KeysetCursor?
        var pages = 0
        repeat {
            let page = try await repo.allWithParticipants(after: cursor, pageSize: 7)
            walked += page.rows.map(\.0.id)
            pages += 1
            guard page.isFull(7) else { break }
            cursor = page.next
        } while pages < 200
        #expect(pages < 200, "the walk must end")
        #expect(walked == reference)
        #expect(Set(walked).count == events.count)

        var byEntity: [UUID] = []
        var c2: KeysetCursor?
        var pages2 = 0
        repeat {
            let page = try await repo.allForEntity(person, after: c2, pageSize: 9)
            byEntity += page.rows.map(\.id)
            pages2 += 1
            guard page.isFull(9) else { break }
            c2 = page.next
        } while pages2 < 200
        #expect(byEntity == reference)
    }

    @Test("Knowledge-object ids by (created_at, id): every id once in the stored order")
    func objectIDsKeyset() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        try await db.exec("PRAGMA foreign_keys = OFF;")
        let t = Date(timeIntervalSince1970: 1_700_000_000).timeIntervalSince1970
        for i in 0..<120 {
            try await db.exec("""
                INSERT INTO knowledge_objects (id, file_id, source_type, content, metadata_json, confidence, created_at, updated_at)
                VALUES (?, ?, 'text', ?, '{}', 0.5, ?, ?);
                """, [.uuid(UUID()), .uuid(UUID()), .text("doc \(i)"), .real(t + Double(i % 4)), .real(t)])
        }
        let reference = try await db.query("SELECT id FROM knowledge_objects ORDER BY created_at ASC, id ASC;", []).compactMap { $0.uuid(0) }
        let repo = KnowledgeObjectRepository(database: db)
        var walked: [UUID] = []
        var cursor: KeysetCursor?
        var pages = 0
        repeat {
            let page = try await repo.allIDsPage(after: cursor, pageSize: 11)
            walked += page.rows
            pages += 1
            guard page.isFull(11) else { break }
            cursor = page.next
        } while pages < 100
        #expect(walked == reference)
    }
}

// MARK: - PERF-32 · prepared-statement cache

@Suite("Speed PERF-32 — prepared-statement cache", .serialized)
struct SpeedStatementCacheTests {

    @Test("A statement is prepared once per SQL and reused (reset + unbound between uses); long SQL is not kept; close finalizes all")
    func reuseAndFinalize() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("psc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try Database(url: dir.appendingPathComponent("db.sqlite"))
        try await db.exec("CREATE TABLE t (k INTEGER PRIMARY KEY, v TEXT);", [])
        let before = await db.cachedStatementCount
        for i in 0..<200 { try await db.exec("INSERT INTO t (k, v) VALUES (?, ?);", [.integer(Int64(i)), .text("v\(i)")]) }
        let afterInserts = await db.cachedStatementCount
        #expect(afterInserts == before + 1, "200 inserts share one cached statement")
        // Reuse gives correct, unbound results each time.
        for i in [3, 150, 7] {
            let v = try await db.query("SELECT v FROM t WHERE k = ?;", [.integer(Int64(i))]).first?.string(0)
            #expect(v == "v\(i)")
        }
        let missing = try await db.query("SELECT v FROM t WHERE k = ?;", [.integer(9_999)])
        #expect(missing.isEmpty)
        #expect(await db.cachedStatementCount == afterInserts + 1)
        // A long generated statement (an IN list over 4 KB) is not kept.
        let marks = Array(repeating: "?", count: 2_500).joined(separator: ",")
        let n = try await db.query("SELECT COUNT(*) FROM t WHERE k IN (\(marks));", (0..<2_500).map { .integer(Int64($0)) }).first?.int(0)
        #expect(n == 200)
        #expect(await db.cachedStatementCount == afterInserts + 1)
        // A failing statement leaves the cache usable.
        await #expect(throws: (any Error).self) { try await db.exec("INSERT INTO t (k, v) VALUES (?, ?);", [.integer(3), .text("dup")]) }
        #expect(try await db.query("SELECT COUNT(*) FROM t;", []).first?.int(0) == 200)
        // A cached read whose table is dropped fails as it did before the cache (at prepare: it throws), never as an
        // empty result — a hold check over a vanished table must not read as "no hold" (the defect this phase found).
        try await db.exec("CREATE TABLE holds (id TEXT);", [])
        try await db.exec("INSERT INTO holds (id) VALUES ('h');", [])
        #expect(try await db.query("SELECT id FROM holds;", []).count == 1)
        try await db.exec("DROP TABLE holds;", [])
        await #expect(throws: (any Error).self) { _ = try await db.query("SELECT id FROM holds;", []) }
        await #expect(throws: (any Error).self) { try await db.exec("INSERT INTO holds (id) VALUES ('x');", []) }
        // A cached statement re-prepares itself after an unrelated schema change and still answers.
        try await db.exec("CREATE TABLE other (x INTEGER);", [])
        #expect(try await db.query("SELECT v FROM t WHERE k = ?;", [.integer(5)]).first?.string(0) == "v5")
        await db.close()
        #expect(await db.cachedStatementCount == 0, "close finalizes every cached statement")
    }
}

// MARK: - PERF-22 · case part replies + PERF-21 · one helper link

private nonisolated final class SendLog: @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [Int] = []
    private var failOnce: Set<Int>
    init(failOnce: Set<Int>) { self.failOnce = failOnce }
    func record(_ part: Int) throws {
        try lock.withLock {
            sent.append(part)
            if failOnce.remove(part) != nil { throw URLError(.networkConnectionLost) }
        }
    }
    func take() -> [Int] { lock.withLock { defer { sent.removeAll() }; return sent.sorted() } }
}

@Suite("Speed PERF-21/22 — case part replies kept, one helper link", .serialized)
struct SpeedCasePartTests {

    static func partReply(_ i: Int) -> String {
        #"{"status": "answered", "answer": "Part \#(i) answer.", "claims": [{"text": "Claim \#(i)", "quote": "quote \#(i)", "passage": 1}]}"#
    }

    @Test("A retry of the same read sends only the parts that failed; a third run sends nothing; another question sends all again")
    func partsReusedOnRetry() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let store = CasePartReplyRepository(database: db)
        let caseID = UUID()
        let parts: [[String]] = (0..<6).map { ["Document \($0 + 1): the text of part \($0)."] }
        let log = SendLog(failOnce: [2])
        let reader = CaseReader { _ in CaseReader.Reply(text: "") }
        let send: @Sendable ([String], String) async throws -> CaseReader.Reply = { prefix, _ in
            let i = parts.firstIndex(of: prefix) ?? -1
            try log.record(i)
            return CaseReader.Reply(text: Self.partReply(i))
        }
        let ctx = CaseReader.PathContext(concurrency: 3, toolRounds: 0, secondLook: false, caseID: caseID)
        try await CasePartReplies.TestOverride.$store.withValue(store) {
            await #expect(throws: (any Error).self) {
                _ = try await reader.readCase(parts: parts, question: "Was the supplier paid twice?", related: [], context: ctx, send: send)
            }
            let firstRun = log.take()
            #expect(firstRun.contains(2))
            // Retry: kept parts are not sent again (the parts that never finished, or never started, are).
            let out = try await reader.readCase(parts: parts, question: "Was the supplier paid twice?", related: [], context: ctx, send: send)
            let retry = log.take()
            let keptAfterFirst = Set(firstRun).subtracting([2])
            #expect(Set(retry).isDisjoint(with: keptAfterFirst), "a finished part was sent again: \(retry) after \(firstRun)")
            #expect(Set(retry).union(keptAfterFirst) == Set(0..<6))
            #expect((0..<6).allSatisfy { out.merged.contains("Claim \($0)") })
            // Third run: everything kept.
            _ = try await reader.readCase(parts: parts, question: "Was the supplier paid twice?", related: [], context: ctx, send: send)
            #expect(log.take().isEmpty)
            // Another question is another task digest: every part is read.
            _ = try await reader.readCase(parts: parts, question: "Who approved the payment?", related: [], context: ctx, send: send)
            #expect(log.take() == Array(0..<6))
        }
        // Without a case id nothing is kept or reused.
        let noCase = CaseReader.PathContext(concurrency: 3, toolRounds: 0, secondLook: false)
        try await CasePartReplies.TestOverride.$store.withValue(store) {
            _ = try await reader.readCase(parts: parts, question: "Was the supplier paid twice?", related: [], context: noCase, send: send)
        }
        #expect(log.take() == Array(0..<6))
        #expect(try await db.query("SELECT COUNT(*) FROM case_ai_part_replies WHERE case_id = ?;", [.uuid(caseID)]).first?.int(0) == 12)
    }

    @Test("A case erase deletes its kept part replies (any letter case of a dataset's origin id too); another case's stay; a person erase deletes the replies naming them")
    func erasureClearsParts() async throws {
        let f = try await CaseErasureTests.boot()
        defer { try? FileManager.default.removeItem(at: f.temp) }
        let store = CasePartReplyRepository(database: f.db)
        for (c, n) in [(f.caseA, 3), (f.caseB, 2)] {
            for p in 0..<n { await store.keep(caseID: c, prefixFingerprint: "fp\(p)", suffixDigest: "task", part: p, reply: Self.partReply(p)) }
        }
        // A Data Lab dataset made from case A, its origin id stored in lower case (PERF-29 index path: upper/lower forms).
        let ws = UUID(), now = Date()
        try await f.db.exec("INSERT INTO workspaces (id, title, created_at, updated_at) VALUES (?,?,?,?);",
                            [.uuid(ws), .text("Lab"), .date(now), .date(now)])
        for (id, origin) in [(UUID(), f.caseA.uuidString.lowercased()), (UUID(), f.caseA.uuidString), (UUID(), f.caseB.uuidString)] {
            try await f.db.exec("""
                INSERT INTO workbench_datasets (id, workspace_id, title, mode, revision, created_at, updated_at, origin_case_id)
                VALUES (?, ?, 'From the case', 'advanced', 1, ?, ?, ?);
                """, [.uuid(id), .uuid(ws), .date(now), .date(now), .text(origin)])
        }
        let out = try await f.state.eraseCase(f.caseA, eraseExclusiveSources: false, reason: "Client request", legalBasis: nil, actor: "Tester")
        #expect(out.report.refused == nil, "\(out.report.refused ?? "")")
        #expect(try await CaseErasureTests.count(f.db, "SELECT COUNT(*) FROM case_ai_part_replies WHERE upper(case_id) = upper(?);", [.uuid(f.caseA)]) == 0)
        #expect(try await CaseErasureTests.count(f.db, "SELECT COUNT(*) FROM case_ai_part_replies WHERE case_id = ?;", [.uuid(f.caseB)]) == 2)
        #expect(try await CaseErasureTests.count(f.db, "SELECT COUNT(*) FROM workbench_datasets WHERE upper(origin_case_id) = upper(?);", [.uuid(f.caseA)]) == 0)
        #expect(try await CaseErasureTests.count(f.db, "SELECT COUNT(*) FROM workbench_datasets WHERE origin_case_id = ?;", [.text(f.caseB.uuidString)]) == 1)
        // Every case-scoped table holds nothing for case A in ANY letter case.
        let tables = try await f.db.query("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE '%_fts%';", [])
            .compactMap { $0.string(0) }
        for t in tables where !CaseEraser.keptTables.contains(t) {
            let cols = try await f.db.query("PRAGMA table_info(\"\(t)\");", []).compactMap { $0.string(1) }
            guard cols.contains("case_id") else { continue }
            #expect(try await CaseErasureTests.count(f.db, "SELECT COUNT(*) FROM \"\(t)\" WHERE upper(case_id) = upper(?);", [.uuid(f.caseA)]) == 0, "\(t) kept case A rows")
        }

        // Person erase: the kept reply naming the person goes; the other stays.
        let row = try #require(try await f.db.query("SELECT id, value FROM entities WHERE kind = 'person' AND value LIKE '%Roberts%' LIMIT 1;", []).first)
        let personID = try #require(row.string(0).flatMap(UUID.init(uuidString:)))
        let name = try #require(row.string(1))
        await store.keep(caseID: f.caseB, prefixFingerprint: "named", suffixDigest: "task", part: 9,
                         reply: #"{"status": "answered", "answer": "\#(name) approved it.", "claims": []}"#)
        let person = try await f.state.erasePerson(personID, reason: "Subject request", legalBasis: nil, actor: "Tester")
        #expect(person.report.refused == nil)
        #expect(try await CaseErasureTests.count(f.db, "SELECT COUNT(*) FROM case_ai_part_replies WHERE prefix_fingerprint = 'named';", []) == 0)
        #expect(try await CaseErasureTests.count(f.db, "SELECT COUNT(*) FROM case_ai_part_replies WHERE case_id = ?;", [.uuid(f.caseB)]) == 2)
    }

    @Test("A 6-part case read through the helper door makes ONE helper launch and ONE connection (scripted helper, nothing sent)")
    @MainActor func oneHelperLink() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let phase = try await SpeedBenchmarkTests.aiCaseReadPhase(db: db)
        #expect(phase.metrics["parts"] == 6)
        #expect(phase.metrics["helper process launches"] == 1)
        #expect(phase.metrics["XPC connections"] == 1)
        #expect((phase.metrics["requests at the helper door"] ?? 0) >= 6)
        #expect(phase.metrics["requests at the helper door"] == phase.metrics["requests the scripted helper answered"])
        #expect((phase.metrics["max requests in flight"] ?? 0) >= 2, "the parts run concurrently")
    }
}

// MARK: - PERF-26 · mbox single pass + parallel build

@Suite("Speed PERF-26 — mbox scanned once, built in parallel windows")
struct SpeedMboxTests {

    @Test("700 messages (three 256-message windows, blank pieces, uneven sizes): the stream gives the same records in the same order as the serial reference path")
    func parallelWindowsMatchSerial() async throws {
        var text = "\n\n"
        for i in 0..<700 {
            text += "From sender\(i)@example.com Mon Jan  1 00:00:00 2024\n"
            text += "From: Sender \(i) <sender\(i)@example.com>\nTo: Desk <desk@example.com>\nSubject: Message \(i)\n"
            text += "Date: Mon, 1 Jan 2024 10:\(String(format: "%02d", i % 60)):00 +0000\n\n"
            text += "Body of message number \(i). " + String(repeating: "Payment detail \(i). ", count: (i * 37) % 90) + "\n\n"
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("spm-\(UUID().uuidString).mbox")
        try Data(text.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let loader = EmailLoader()
        let reference = try loader.ingestMBOXAsMessages(at: url, coalesce: false)
        var streamed: [KnowledgeObject] = []
        try await loader.streamMbox(at: url, budget: StreamBatchBudget(maxObjects: 50, maxContentBytes: .max), coalesce: false) { streamed += $0 }
        func fingerprint(_ ko: KnowledgeObject) -> String {
            ko.content + "\u{1}" + ko.metadata.filter { $0.key != EmailLoader.structuredEntitiesMetaKey }
                .map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ";")
        }
        #expect(reference.count == 700)
        #expect(streamed.count == reference.count)
        #expect(streamed.map(fingerprint) == reference.map(fingerprint))
        #expect(streamed.enumerated().allSatisfy { $0.element.content.contains("message number \($0.offset).") })
    }
}

// MARK: - PERF-24/30 · ZIP

@Suite("Speed PERF-24/30 — ZIP members and the streamed ZIP writer", .serialized)
@MainActor
struct SpeedZIPTests {

    @Test("Same-named members stay distinct: each is hashed while extracted and the hash is its own bytes' SHA-256")
    func sameNamedMembersDistinct() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("spz-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try Database(url: dir.appendingPathComponent("db.sqlite"))
        try await SchemaMigrations.migrate(db)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let vault = EvidenceVault(root: dir.appendingPathComponent("vault", isDirectory: true))
        let intake = UniversalSourceIntakeCoordinator(repository: CanonicalSourceIntakeRepository(database: db, vault: vault))
        let repo = ContainerInspectionRepository(database: db)
        let objects = KnowledgeObjectRepository(database: db)
        let c = IngestCoordinator(
            universalRegistry: try UniversalParserRegistryBuilder.standard(ocr: VisionOCR()),
            entityExtractor: NLEntityExtractor(), entityLinker: EntityLinker(), eventExtractor: RuleEventExtractor(),
            files: FilesRepository(database: db), objects: objects,
            chunks: ChunksRepository(database: db), evidenceStore: EvidenceStore(database: db),
            ingestAttempts: IngestAttemptsRepository(database: db),
            sourceRelations: SourceRelationsRepository(database: db),
            readiness: SourceReadinessRepository(database: db),
            containerInspection: repo, intakeCoordinator: intake)
        let bodies = ["first distinct body about the Bluefin invoice", "second distinct body about the Harbor transfer",
                      "third body, a different length again, about the audit fee"]
        let zip = try ZIPTestFixture.writeZIP(bodies.map { ZIPTestFixture.stored("same.txt", $0) }, named: "same.zip")
        let parent = try #require(try await c.ingest(fileAt: zip).sourceVersionID)
        let admitted = try await repo.members(parentSourceVersionID: parent).filter { $0.disposition == .admitted }
        #expect(admitted.count == 3)
        let expected = Set(bodies.map { SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined() })
        #expect(Set(admitted.compactMap { $0.contentHash?.lowercased() }) == expected)
        #expect(Set(admitted.compactMap(\.childSourceVersionID)).count == 3)
        let texts = try await db.query("SELECT content FROM knowledge_objects;", []).compactMap { $0.string(0) }.joined(separator: "\n")
        #expect(bodies.allSatisfy { texts.contains($0) }, "every same-named member was read, none overwritten")
    }

    @Test("The streamed ZIP writer writes the same archive as the in-memory one; zlib crc32 matches the reference value")
    func streamedWriterMatches() throws {
        #expect(ZIPArchiveWriter.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
        #expect(ZIPArchiveWriter.crc32(Data()) == 0)
        let entries: [(String, Data)] = [("a/one.eml", Data("Subject: one\n\nbody one".utf8)),
                                         ("a/one.eml", Data("Subject: one again\n\nanother body".utf8)),
                                         ("b/big.bin", Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31) }))]
        var w = ZIPArchiveWriter()
        for (p, d) in entries { w.addFile(path: p, data: d) }
        let inMemory = w.build()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("spzw-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: url) }
        let s = try ZIPFileStreamer(writingTo: url)
        for (p, d) in entries { try s.add(path: p, data: d) }
        try s.finish()
        let streamed = try Data(contentsOf: url)
        #expect(streamed == inMemory)
        // Each member's stored CRC (local header offset 14) is the crc of its bytes.
        #expect(streamed.count > 30)
        let crc = streamed.subdata(in: 14..<18).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        #expect(UInt32(littleEndian: crc) == ZIPArchiveWriter.crc32(entries[0].1))
    }
}

// MARK: - PERF-28 · vectors

@Suite("Speed PERF-28 — HNSW resume and parallel k-means", .serialized)
struct SpeedVectorTests {

    static func store(_ count: Int) async throws -> (Database, SQLiteVectorStore, [UUID: [Float]]) {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        try await db.exec("PRAGMA foreign_keys = OFF;")
        let store = SQLiteVectorStore(database: db, modelID: "apple.nl.v1")
        var r = SystemRandomNumberGenerator()
        var all: [UUID: [Float]] = [:]
        var batch: [(chunkID: Chunk.ID, embedding: [Float])] = []
        for _ in 0..<count {
            let v = (0..<16).map { _ in Float(Int(r.next() % 2001) - 1000) / 1000 }
            let id = UUID()
            all[id] = v
            batch.append((id, v))
            if batch.count == 500 { _ = try await store.upsertBatch(batch); batch.removeAll() }
        }
        if !batch.isEmpty { _ = try await store.upsertBatch(batch) }
        return (db, store, all)
    }

    /// The checkpoint is written with NSFileProtectionComplete (like the HNSW cache): while the Mac is locked the write is
    /// refused (Cocoa 513), so the resume test can only run on an unlocked Mac (CI, or a local run with the screen on).
    static func completeProtectionWritable() -> Bool {
        let probe = FileManager.default.temporaryDirectory.appendingPathComponent("sph-probe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: probe) }
        do { try Data([1]).write(to: probe, options: [.atomic, .completeFileProtection]); return true } catch { return false }
    }

    @Test("An interrupted HNSW build resumes from its sealed checkpoint and ends with every vector; a changed ledger starts over (needs an unlocked Mac)",
          .enabled(if: SpeedVectorTests.completeProtectionWritable()))
    func hnswResume() async throws {
        let (db, store, all) = try await Self.store(3_200)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sph-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cp = HNSWVectorIndex.Checkpoint(url: dir.appendingPathComponent("hnsw.partial"), key: SymmetricKey(size: .bits256), everyVectors: 1_000)
        // The first build stops right after its first checkpoint (as a quit would).
        let first = HNSWVectorIndex()
        await first.debugStopBuild(afterCheckpoints: 1)
        let partial = await first.build(from: store, pageSize: 500, checkpoint: cp)
        #expect(partial.vectorsLoaded >= 1_000 && partial.vectorsLoaded < 3_200)
        #expect(FileManager.default.fileExists(atPath: cp.url.path), "the partial build is kept")
        let sealed = try Data(contentsOf: cp.url)
        #expect(sealed.prefix(4) != Data([0x57, 0x53, 0x4E, 0x48]), "the checkpoint is sealed, not in the clear")
        // A fresh index resumes from it and finishes.
        let second = HNSWVectorIndex()
        let done = await second.build(from: store, pageSize: 500, checkpoint: cp)
        #expect(await second.lastResumedVectors == partial.vectorsLoaded)
        #expect(done.vectorsLoaded == 3_200)
        #expect(await second.size() == 3_200)
        #expect(!FileManager.default.fileExists(atPath: cp.url.path), "removed when the build completes")
        // The resumed graph finds stored vectors (their own nearest neighbour).
        var found = 0
        for (id, v) in all.prefix(40) where await second.nearest(to: v, limit: 3).contains(where: { $0.chunkID == id }) { found += 1 }
        #expect(found >= 38)
        // A checkpoint whose ledger changed (a vector removed before its key) is not used.
        let third = HNSWVectorIndex()
        await third.debugStopBuild(afterCheckpoints: 1)
        _ = await third.build(from: store, pageSize: 500, checkpoint: cp)
        let firstID = try #require(try await db.query("SELECT chunk_id FROM chunk_embeddings ORDER BY chunk_id LIMIT 1;", []).first?.string(0))
        try await db.exec("DELETE FROM chunk_embeddings WHERE chunk_id = ?;", [.text(firstID)])
        let fourth = HNSWVectorIndex()
        let rebuilt = await fourth.build(from: store, pageSize: 500, checkpoint: cp)
        #expect(await fourth.lastResumedVectors == 0)
        #expect(rebuilt.vectorsLoaded == 3_199)
    }

    @Test("IVF rebuild over 1,300 stored 384-d vectors indexes every one (k-means on all cores, staged then promoted)")
    func ivfRebuildIndexesEverything() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        try await db.exec("PRAGMA foreign_keys = OFF;")
        let store = SQLiteVectorStore(database: db, modelID: "bge-small.v1")
        var rng = XorShift64Star(state: 0x1F)
        var batch: [(chunkID: Chunk.ID, embedding: [Float])] = []
        for _ in 0..<1_300 { batch.append((UUID(), (0..<384).map { _ in Float(Int(rng.next() % 2001) - 1000) / 1000 })) }
        _ = try await store.upsertBatch(batch)
        let lengths = try await db.query("SELECT length(q), COUNT(*) FROM chunk_embeddings GROUP BY 1;", []).map { "\($0.int(0) ?? -1)×\($0.int(1) ?? -1)" }
        let repo = ANNIndexRepository(database: db)
        try await repo.ensureMeta(modelID: "bge-small.v1", dimension: 384, at: Date())
        let ivf = IVFDiskVectorIndex(repository: repo, modelID: "bge-small.v1", dimension: 384)
        try await ivf.rebuild(seed: 0x516B_5F9E_A3C1_D7B2)
        #expect(await ivf.size() == 1_300, "stored q lengths: \(lengths)")
        #expect(await ivf.isReady())
    }

    @Test("Parallel nearest-centroid assignment equals the serial loop exactly")
    func kmeansParallelEqualsSerial() {
        var rng = XorShift64Star(state: 0x5EED)
        let vectors: [[Float]] = (0..<6_000).map { _ in (0..<24).map { _ in Float(Int(rng.next() % 2001) - 1000) / 1000 } }
        let result = KMeansClusterer(seed: 42).cluster(vectors: vectors, k: 32)
        #expect(result.centroids.count == 32 && result.assignments.count == 6_000)
        let serial = vectors.map { KMeansClusterer.nearestCentroid(of: $0, among: result.centroids) }
        #expect(KMeansClusterer.nearestCentroids(ofEach: vectors, among: result.centroids) == serial)
        #expect(result.assignments == serial)
        // Same seed → same clustering.
        #expect(KMeansClusterer(seed: 42).cluster(vectors: vectors, k: 32).assignments == result.assignments)
    }
}

// MARK: - PERF-31 · Data Lab memo

@Suite("Speed PERF-31 — Data Lab projection once per change")
@MainActor
struct SpeedDataLabTests {

    static func record(rows: Int, revision: Int = 1, id: UUID = UUID()) -> (WorkbenchDatasetRecord, [WorkbenchField], [WorkbenchRow]) {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let dataset = WorkbenchDataset(id: id, workspaceID: UUID(), title: "Ledger", mode: .advanced, revision: revision, createdAt: t0, updatedAt: t0)
        let fields = ["date", "payer", "payee", "amount", "invoice"].enumerated().map {
            WorkbenchField(id: UUID(), datasetID: id, name: $1, valueShape: .text, ordinal: $0, createdAt: t0)
        }
        var rs: [WorkbenchRow] = [], cells: [WorkbenchCell] = []
        for i in 0..<rows {
            let row = WorkbenchRow(id: UUID(), datasetID: id, ordinal: i, createdAt: t0)
            rs.append(row)
            for f in fields {
                cells.append(WorkbenchCell(id: UUID(), datasetID: id, rowID: row.id, fieldID: f.id, kind: .sourceValue,
                                           value: "\(f.name)-\(i)", status: .directlyObserved, createdAt: t0))
            }
        }
        return (WorkbenchDatasetRecord(dataset: dataset, fields: fields, rows: rs, cells: cells, bindings: [], savedViews: [], events: []), fields, rs)
    }

    static func override(_ row: WorkbenchRow, _ field: WorkbenchField, _ seq: Int) -> WorkbenchScenarioOperation {
        WorkbenchScenarioOperation(id: UUID(), scenarioID: UUID(), sequence: seq, kind: .valueOverride, targetKind: .cell,
                                   rowID: row.id, fieldID: field.id, beforeValue: nil, afterValue: "$1.00", reason: "test",
                                   status: .live, actor: "test", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test("The projection and cell map are built once per change, not per cell; values equal the scan they replace; a full 20,000-row grid reads fast")
    func memoOncePerChange() {
        let (rec, fields, rows) = Self.record(rows: 20_000)
        let memo = DataLabMemo()
        let scenario = UUID()
        var ops = (0..<50).map { Self.override(rows[$0 * 97], fields[3], $0 + 1) }
        let started = Date()
        var shown = 0
        // A whole redraw: every visible cell asks for the projection and its value.
        for row in rows {
            for field in fields {
                let proj = memo.projection(record: rec, scenarioID: scenario, ops: ops)
                if proj.projectedValue(rowID: row.id, fieldID: field.id) != nil { shown += 1 }
                _ = memo.cellMap(rec)
            }
        }
        let seconds = Date().timeIntervalSince(started)
        #expect(shown == 100_000)
        #expect(memo.projectionBuilds == 1 && memo.cellMapBuilds == 1)
        #expect(seconds < 60, "a 100,000-cell redraw took \(seconds) s (the baseline extrapolated ~11 minutes)")
        // Values: overrides where set, else exactly the first base cell (what the linear scan returned).
        let proj = memo.projection(record: rec, scenarioID: scenario, ops: ops)
        for (k, row) in rows.prefix(300).enumerated() {
            for field in fields {
                let scan = rec.cells.first { $0.rowID == row.id && $0.fieldID == field.id }?.value
                let expected = (field.id == fields[3].id && k % 97 == 0 && k / 97 < 50) ? "$1.00" : scan
                #expect(proj.projectedValue(rowID: row.id, fieldID: field.id) == expected)
                #expect(proj.baseValue(rowID: row.id, fieldID: field.id) == scan)
            }
        }
        #expect(proj.baseValue(rowID: UUID(), fieldID: fields[0].id) == nil)
        // A change of the operations rebuilds the projection only; a dataset change rebuilds both.
        ops.append(Self.override(rows[1], fields[1], 51))
        _ = memo.projection(record: rec, scenarioID: scenario, ops: ops)
        _ = memo.cellMap(rec)
        #expect(memo.projectionBuilds == 2 && memo.cellMapBuilds == 1)
        let (next, _, _) = Self.record(rows: 10, revision: 2, id: rec.dataset.id)
        _ = memo.projection(record: next, scenarioID: scenario, ops: ops)
        _ = memo.cellMap(next)
        #expect(memo.projectionBuilds == 3 && memo.cellMapBuilds == 2)
    }
}

// MARK: - PERF-29 · contradiction finder parallel == serial

@Suite("Speed PERF-29 — case contradiction finder: parallel equals serial")
struct SpeedContradictionTests {

    @Test("Sixty documents (the Logan releases among filler): the findings with eight workers equal the findings with one")
    func parallelEqualsSerial() async {
        typealias F = CaseContradictionFinder
        var docs: [F.Document] = []
        let releases = [CaseContradictionFinderTests.release1, CaseContradictionFinderTests.release4, CaseContradictionFinderTests.release5]
        for i in 0..<60 {
            let text: String
            if i % 20 < 3 { text = releases[i % 20] } else {
                text = "Memo \(i). Ann Lee approved the invoice from Bluefin Logistics for $\(1_000 + (i % 7) * 250) on 3 March 2024. "
                    + "Rahul Mehta, \(30 + i % 4), reviewed the audit fee. " + String(repeating: "The ledger was reconciled. ", count: i % 9)
            }
            docs.append(F.Document(objectID: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", i)) ?? UUID(),
                                   sourceVersionID: nil, text: text, fileName: "doc-\(i).txt"))
        }
        let serial = WorkStealingQueue.TestOverride.$cpuWidth.withValue(1) { F.ruleFindings(docs, limit: 500) }
        let parallel = WorkStealingQueue.TestOverride.$cpuWidth.withValue(8) { F.ruleFindings(docs, limit: 500) }
        #expect(!serial.isEmpty)
        #expect(parallel == serial)
        #expect(serial.contains { $0.kind == .amount && $0.subject == "William Jamey Thompson" })
    }
}

// MARK: - PERF-29 · HybridRetriever

@Suite("Speed PERF-29 — HybridRetriever layers started together, merged in the fixed order", .serialized)
@MainActor
struct SpeedRetrieverTests {

    @Test("Layers are used in the fixed priority order and the merged result is identical on every run")
    func priorityOrderAndDeterminism() async throws {
        let doc = """
        Ann Lee approved the payment of $48,000 to Bluefin Logistics on 3 March 2024 for the warehouse lease.
        Rahul Mehta said the audit fee was too high in a meeting with Priya Nair in Singapore on 9 April 2024.
        Harbor Bank transferred $1,250,000 to Apex Holdings on 12 May 2024. Wei Chen approved the transfer.
        """
        let rig = try await FixtureRig.make(document: doc, name: "speed-retrieval.txt")
        defer { try? FileManager.default.removeItem(at: rig.dir) }
        for q in ["When did Ann Lee approve the payment?", "How much did Harbor Bank transfer to Apex Holdings?", "Who met Priya Nair?"] {
            let intent = (try? await RuleIntentDetector().detect(question: q)) ?? UserIntent(kind: .factualLookup, scope: .global, rawQuestion: q)
            let first = try await rig.retriever.retrieve(for: intent, layers: [])
            #expect(first.layersUsed == RetrievalLayer.priorityOrder)
            func shape(_ r: RetrievalResult) -> [String] {
                r.chunks.map { "\($0.chunk.id)|\($0.viaLayer)|\(String(format: "%.6f", $0.score))" }
                    + r.events.map { "e\($0.id)" } + r.entities.map { "n\($0.id)" } + r.genericFacts.map { "f\($0.id)" }
            }
            for _ in 0..<3 {
                let again = try await rig.retriever.retrieve(for: intent, layers: RetrievalLayer.priorityOrder)
                #expect(again.layersUsed == RetrievalLayer.priorityOrder)
                #expect(shape(again) == shape(first), "the merge order must not depend on which layer finished first")
            }
            // A caller's own ordering is kept as given.
            let custom = try await rig.retriever.retrieve(for: intent, layers: [.metadata, .timeline])
            #expect(custom.layersUsed == [.metadata, .timeline])
        }
    }
}
