//
//  UtmpParserTests.swift
//  KalsmritikoshTests
//
//  HOST-4 — Linux login accounting.
//
//  The load-bearing test in this file is `btmpIsNeverRenderedAsALogin`. utmp,
//  wtmp and btmp share one record layout and mean three different things, and
//  the difference exists ONLY in the filename. If a btmp record renders like a
//  wtmp record, a rejected break-in attempt becomes evidence that someone was
//  signed in — an inversion that would point an investigation at the wrong
//  conclusion with full confidence. Everything else here is ordinary fidelity.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Linux login accounting (HOST-4)")
struct UtmpParserTests {

    private let parser = UtmpStructuralParser()

    private func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f.date(from: iso)!
    }

    private func parse(_ data: Data, as filename: String) async throws -> ParsedDocument {
        try await parser.parse(data: data, filename: filename, type: .loginRecord,
                               logicalSourceID: UUID(), sourceVersionID: UUID())
    }

    private func text(_ doc: ParsedDocument) -> String {
        doc.blocks.map(\.rawText).joined(separator: "\n")
    }

    /// Attributes hold an `AnyCodable.AnySendable` enum, NOT `Any`, so
    /// `as? Bool` quietly yields nil and an assertion written that way passes
    /// whatever the block contains. These read the case.
    private func isDerived(_ block: EvidenceBlock) -> Bool {
        if case .bool(true) = block.attributes["derived"]?.value { return true }
        return false
    }
    private func intAttribute(_ block: EvidenceBlock, _ key: String) -> Int64? {
        if case .int(let value) = block.attributes[key]?.value { return value }
        return nil
    }

    // MARK: - Fidelity

    @Test("Every field of a record is decoded exactly")
    func fieldsAreExact() throws {
        let when = date("2026-03-12T09:26:53Z")
        let data = UtmpFixtureWriter().build(records: [
            .init(kind: .userProcess, pid: 4242, line: "pts/3", id: "ts/3",
                  user: "riyaz", host: "workstation-7.lan", time: when,
                  ipv4: (10, 0, 4, 91))
        ])
        var reader = try UtmpReader(data: data, filename: "wtmp")
        let record = try #require(reader.records().first)
        #expect(record.kind == .userProcess)
        #expect(record.pid == 4242)
        #expect(record.line == "pts/3")
        #expect(record.id == "ts/3")
        #expect(record.user == "riyaz")
        #expect(record.host == "workstation-7.lan")
        #expect(record.time == when)
        #expect(record.address == "10.0.4.91")
        #expect(record.fileOffset == 0)
        #expect(!reader.isBigEndian)
    }

    @Test("A big-endian file is decoded, not rendered as garbage")
    func bigEndianIsDetected() throws {
        // s390x and older PowerPC/SPARC write host order, and nothing in the file
        // declares it. Assuming little-endian would make every record's type
        // invalid and the whole file unreadable.
        var writer = UtmpFixtureWriter()
        writer.bigEndian = true
        let when = date("2026-03-12T09:26:53Z")
        let data = writer.build(records: [.session("riyaz", on: "pts/0", at: when)])

        var reader = try UtmpReader(data: data, filename: "wtmp")
        #expect(reader.isBigEndian)
        let record = try #require(reader.records().first)
        #expect(record.kind == .userProcess)
        #expect(record.user == "riyaz")
        #expect(record.time == when)
        // And the byte order is reported, because it is a fact about the machine.
        #expect(reader.problems.contains { $0.lowercased().contains("big-endian") })
    }

    @Test("A field filled to capacity is read without running into the next field")
    func fullWidthFieldIsBounded() throws {
        // ut_user is 32 bytes and a full field is NOT NUL-terminated, so the
        // width is the only bound. Reading past it would append ut_host.
        let user = String(repeating: "a", count: 32)
        let data = UtmpFixtureWriter().build(records: [
            .init(kind: .userProcess, line: "tty1", user: user, host: "elsewhere",
                  time: date("2026-03-12T09:00:00Z"))
        ])
        var reader = try UtmpReader(data: data, filename: "wtmp")
        let record = try #require(reader.records().first)
        #expect(record.user == user)
        #expect(record.user.count == 32)
        #expect(record.host == "elsewhere")
    }

    @Test("A zero timestamp is no date, not 1970")
    func zeroTimeIsNotADate() throws {
        let data = UtmpFixtureWriter().build(records: [
            .init(kind: .loginProcess, line: "tty2", time: nil),
            .session("riyaz", on: "pts/0", at: date("2026-03-12T09:00:00Z"))
        ])
        var reader = try UtmpReader(data: data, filename: "wtmp")
        let records = reader.records()
        #expect(records[0].time == nil)
        #expect(records[1].time != nil)
    }

    @Test("A local login has no address rather than 0.0.0.0")
    func localLoginHasNoAddress() throws {
        let data = UtmpFixtureWriter().build(records: [
            .init(kind: .userProcess, line: "tty1", user: "riyaz",
                  time: date("2026-03-12T09:00:00Z"))
        ])
        var reader = try UtmpReader(data: data, filename: "wtmp")
        #expect(try #require(reader.records().first).address == nil)
    }

    // MARK: - THE inversion guard

    @Test("A btmp record is NEVER rendered as a login")
    func btmpIsNeverRenderedAsALogin() async throws {
        let data = UtmpFixtureWriter().build(records: [
            .init(kind: .userProcess, pid: 9, line: "ssh:notty", user: "root",
                  host: "203.0.113.9", time: date("2026-03-12T02:14:07Z"),
                  ipv4: (203, 0, 113, 9))
        ])
        let doc = try await parse(data, as: "btmp")
        let body = text(doc)

        // The record type on disk is USER_PROCESS — identical to a successful
        // login. Only the filename says it failed.
        #expect(body.contains("FAILED"))
        #expect(!body.lowercased().contains("signed in"))
        #expect(!body.contains("Session opened"))
        // The file-level framing must say so too, not just individual records.
        #expect(body.contains("rejected sign-in"))
        // And no session block is emitted: a failed attempt has no duration.
        #expect(!doc.blocks.contains { isDerived($0) })
        // The account someone tried, and where from, are still recorded.
        #expect(body.contains("root"))
        #expect(body.contains("203.0.113.9"))
    }

    @Test("The same bytes under three filenames produce three different meanings")
    func filenameDecidesMeaning() async throws {
        let records: [UtmpFixtureWriter.Record] = [
            .session("riyaz", on: "pts/0", at: date("2026-03-12T09:00:00Z"))
        ]
        let data = UtmpFixtureWriter().build(records: records)

        let utmp = text(try await parse(data, as: "utmp"))
        let wtmp = text(try await parse(data, as: "wtmp"))
        let btmp = text(try await parse(data, as: "btmp"))

        #expect(utmp.contains("open at the moment the machine was imaged"))
        #expect(wtmp.contains("historical logins"))
        #expect(btmp.contains("FAILED"))
        #expect(utmp != wtmp && wtmp != btmp)
    }

    @Test("A file whose name is not utmp/wtmp/btmp says the kind is unknown")
    func unknownFilenameIsDisclosed() async throws {
        // Silently treating it as wtmp would be the inversion again, just quieter.
        let data = UtmpFixtureWriter().build(records: [
            .session("riyaz", on: "pts/0", at: date("2026-03-12T09:00:00Z"))
        ])
        let doc = try await parse(data, as: "login-records.bin")
        #expect(doc.warnings.contains { $0.message.contains("is not utmp/wtmp/btmp") })
        #expect(doc.warnings.contains { $0.message.contains("failed attempts rather than logins") })
    }

    // MARK: - Sessions (derived)

    @Test("A login paired with its logout reports a duration")
    func sessionDuration() async throws {
        let start = date("2026-03-12T09:00:00Z")
        let end = date("2026-03-12T11:30:00Z")
        let data = UtmpFixtureWriter().build(records: [
            .session("riyaz", on: "pts/0", at: start, from: "10.0.4.91"),
            .ended(on: "pts/0", at: end, user: "riyaz")
        ])
        let doc = try await parse(data, as: "wtmp")
        let session = try #require(doc.blocks.first { isDerived($0) })
        #expect(session.rawText.contains("riyaz"))
        #expect(session.rawText.contains("2h 30m"))
        #expect(intAttribute(session, "durationSeconds") == 9000)
    }

    @Test("A login with no logout is reported as still open, not as zero-length")
    func unmatchedLoginIsStillOpen() async throws {
        let data = UtmpFixtureWriter().build(records: [
            .session("riyaz", on: "pts/0", at: date("2026-03-12T09:00:00Z"))
        ])
        let doc = try await parse(data, as: "wtmp")
        let session = try #require(doc.blocks.first { isDerived($0) })
        #expect(session.rawText.contains("no end recorded"))
        #expect(session.attributes["durationSeconds"] == nil)
        #expect(session.attributes["end"] == nil)
    }

    @Test("A recycled terminal does not let one session steal another's logout")
    func recycledTerminalPairsInOrder() throws {
        // pts/0 is reused constantly. Closing the NEWEST open session would
        // attribute the first user's logout to the second user.
        let first = date("2026-03-12T09:00:00Z")
        let firstEnd = date("2026-03-12T10:00:00Z")
        let second = date("2026-03-12T10:05:00Z")
        let secondEnd = date("2026-03-12T12:00:00Z")
        let data = UtmpFixtureWriter().build(records: [
            .session("riyaz", on: "pts/0", at: first),
            .session("anita", on: "pts/0", at: second),
            .ended(on: "pts/0", at: firstEnd),
            .ended(on: "pts/0", at: secondEnd)
        ])
        var reader = try UtmpReader(data: data, filename: "wtmp")
        let sessions = UtmpReader.sessions(from: reader.records())
        #expect(sessions.count == 2)
        let riyaz = try #require(sessions.first { $0.user == "riyaz" })
        let anita = try #require(sessions.first { $0.user == "anita" })
        #expect(riyaz.end == firstEnd)
        #expect(anita.end == secondEnd)
    }

    @Test("A logout stamped before its login is called a clock change, not a negative session")
    func clockChangeIsNotANegativeDuration() async throws {
        let start = date("2026-03-12T09:00:00Z")
        let end = date("2026-03-12T08:00:00Z")   // clock moved back mid-session
        let data = UtmpFixtureWriter().build(records: [
            .session("riyaz", on: "pts/0", at: start),
            .ended(on: "pts/0", at: end)
        ])
        let doc = try await parse(data, as: "wtmp")
        let session = try #require(doc.blocks.first { isDerived($0) })
        #expect(session.rawText.contains("clock was changed"))
        #expect(!session.rawText.contains("-1h"))
    }

    @Test("A boot record dates the machine powering on")
    func bootIsDated() async throws {
        let when = date("2026-03-12T08:41:02Z")
        let data = UtmpFixtureWriter().build(records: [.boot(at: when), .emptySlot])
        let doc = try await parse(data, as: "wtmp")
        let body = text(doc)
        #expect(body.contains("System booted"))
        #expect(body.contains("2026-03-12T08:41:02Z"))
    }

    // MARK: - Honest states

    @Test("Empty slots are counted and not reported as records")
    func emptySlotsAreCounted() async throws {
        let data = UtmpFixtureWriter().build(records: [
            .emptySlot, .emptySlot,
            .session("riyaz", on: "pts/0", at: date("2026-03-12T09:00:00Z"))
        ])
        let doc = try await parse(data, as: "utmp")
        let header = try #require(doc.blocks.first { $0.kind == .documentHeader })
        #expect(header.rawText.contains("3 record(s)"))
        #expect(header.rawText.contains("2 empty slot(s)"))
        // Only the real session is rendered as a record, plus its session block.
        #expect(doc.blocks.filter { $0.kind == .logRecord }.count == 2)
    }

    @Test("A file cut mid-record yields what survived AND says it is short")
    func truncationIsReported() async throws {
        let data = UtmpFixtureWriter().build(
            records: [.session("riyaz", on: "pts/0", at: date("2026-03-12T09:00:00Z"))],
            trailingGarbage: 100)
        let doc = try await parse(data, as: "wtmp")
        #expect(doc.extractionStatus == .partial)
        #expect(text(doc).contains("riyaz"))
        #expect(doc.warnings.contains { $0.message.contains("100 trailing byte(s)") })
    }

    @Test("A complete file is COMPLETE — every field is interpreted")
    func completeFileIsComplete() async throws {
        // Unlike the event log (HOST-3), nothing in this format is left
        // uninterpreted, so claiming complete here is honest.
        let data = UtmpFixtureWriter().build(records: [
            .boot(at: date("2026-03-12T08:41:02Z")),
            .session("riyaz", on: "pts/0", at: date("2026-03-12T09:00:00Z"))
        ])
        let doc = try await parse(data, as: "wtmp")
        #expect(doc.extractionStatus == .complete)
    }

    @Test("Bytes that are not login accounting are reported, never guessed at")
    func junkIsRefused() async throws {
        // 384-byte multiple so the size alone cannot save it — the types and
        // dates have to decode.
        let junk = Data((0..<(384 * 3)).map { UInt8(($0 * 31 + 17) % 251) })
        let doc = try await parse(junk, as: "wtmp")
        #expect(doc.extractionStatus == .corrupt)
        #expect(doc.warnings.contains { $0.code == "utmp.not_utmp" })
    }

    @Test("An empty file is empty, not corrupt")
    func emptyIsEmpty() async throws {
        let doc = try await parse(Data(), as: "wtmp")
        #expect(doc.extractionStatus == .empty)
        #expect(doc.blocks.isEmpty)
    }

    @Test("A cleared log of nothing but empty slots says so")
    func clearedLogIsAFinding() async throws {
        let data = UtmpFixtureWriter().build(records: [.emptySlot, .emptySlot, .emptySlot])
        let doc = try await parse(data, as: "wtmp")
        let header = try #require(doc.blocks.first { $0.kind == .documentHeader })
        #expect(header.rawText.contains("3 empty slot(s)"))
        #expect(doc.blocks.filter { $0.kind == .logRecord }.isEmpty)
    }

    @Test("Parsing is deterministic")
    func deterministic() async throws {
        let data = UtmpFixtureWriter().build(records: [
            .boot(at: date("2026-03-12T08:41:02Z")),
            .session("riyaz", on: "pts/0", at: date("2026-03-12T09:00:00Z")),
            .ended(on: "pts/0", at: date("2026-03-12T10:00:00Z"))
        ])
        let first = text(try await parse(data, as: "wtmp"))
        let second = text(try await parse(data, as: "wtmp"))
        #expect(first == second)
    }

    // MARK: - Routing

    @Test("The accounting files are detected by name, including rotated copies")
    func detectionByName() {
        #expect(SourceType.detect(from: URL(fileURLWithPath: "/var/log/wtmp")) == .loginRecord)
        #expect(SourceType.detect(from: URL(fileURLWithPath: "/var/log/btmp")) == .loginRecord)
        #expect(SourceType.detect(from: URL(fileURLWithPath: "/var/run/utmp")) == .loginRecord)
        #expect(SourceType.detect(from: URL(fileURLWithPath: "/var/log/wtmp.1")) == .loginRecord)
        #expect(SourceType.detect(from: URL(fileURLWithPath: "/case/btmp.2")) == .loginRecord)
        #expect(SourceType.loginRecord.category == .hostArtifact)
    }

    @Test("A TEXT report ABOUT the file is not claimed as the file")
    func reportsAreNotClaimed() {
        // `last > wtmp-report.txt` and `utmpdump wtmp > wtmp.txt` are routine, and
        // both are text documents that must keep parsing as text.
        #expect(SourceType.detect(from: URL(fileURLWithPath: "/case/wtmp.txt")) == .txt)
        #expect(SourceType.detect(from: URL(fileURLWithPath: "/case/utmpdump.txt")) == .txt)
        #expect(SourceType.detect(from: URL(fileURLWithPath: "/case/wtmp-report.txt")) == .txt)
    }

    @Test("A renamed file is recovered by the structural probe")
    func structuralProbeFindsRenamedFiles() {
        // The format has no signature, so this is the only way a file exported
        // under another name is not dropped as unknown bytes.
        let data = UtmpFixtureWriter().build(records: [
            .boot(at: date("2026-03-12T08:41:02Z")),
            .session("riyaz", on: "pts/0", at: date("2026-03-12T09:00:00Z"))
        ])
        #expect(UtmpReader.looksLikeLoginRecords(data))
    }

    @Test("The structural probe refuses things that are not login accounting")
    func structuralProbeIsStrict() {
        // It runs on files that would otherwise be unknown, so a loose probe
        // would reclassify unrelated binaries and make them fail to parse.
        let junk = Data((0..<(384 * 4)).map { UInt8(($0 * 31 + 17) % 251) })
        #expect(!UtmpReader.looksLikeLoginRecords(junk))
        // All zeros: structurally valid empty slots, but no real event — a wiped
        // or sparse file must not be claimed on the strength of its zeros.
        #expect(!UtmpReader.looksLikeLoginRecords(Data(repeating: 0, count: 384 * 4)))
        // Too short to judge.
        #expect(!UtmpReader.looksLikeLoginRecords(Data(repeating: 0, count: 100)))
        // A real one still passes, so the strictness has not closed the door.
        #expect(UtmpReader.looksLikeLoginRecords(UtmpFixtureWriter().build(records: [
            .session("riyaz", on: "pts/0", at: date("2026-03-12T09:00:00Z")),
            .ended(on: "pts/0", at: date("2026-03-12T10:00:00Z"))
        ])))
    }

    @Test("The registry gives .loginRecord a real immediate plugin")
    @MainActor
    func registryOwnsIt() throws {
        let registry = try UniversalParserRegistryBuilder.standard(ocr: VisionOCR())
        let plugin = try registry.resolve(.loginRecord)
        #expect(plugin.pluginID == "format.loginRecord")
        #expect(plugin.executionMode == .immediate)
        #expect(plugin.capabilities.producesStructure)
        #expect(!(plugin is PreservedOnlyPlugin))
    }

    @Test("The published coverage matrix says FULL — nothing here is uninterpreted")
    @MainActor
    func coverageIsFull() throws {
        let entries = ParserCapabilityManifest.generate(
            registry: try UniversalParserRegistryBuilder.standard(ocr: VisionOCR()))
        let entry = try #require(entries.first { $0.sourceType == SourceType.loginRecord.rawValue })
        #expect(entry.coverage == .full)
    }
}
