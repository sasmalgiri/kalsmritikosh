//
//  KnowledgeCParserTests.swift
//  KalsmritikoshTests
//
//  HOST-7 — Apple's CoreDuet activity store. Built against a real SQLite file
//  with a ZOBJECT table, because the whole value of this parser is schema
//  knowledge and a mock would prove nothing.
//
//  The defect it exists to fix is the one pinned hardest here: ZSTARTDATE /
//  ZENDDATE are APPLE EPOCH (seconds since 2001-01-01). Read as Unix time, a
//  2026 event dates to 1994 — a 31-year error that still looks like a plausible
//  date, so nothing downstream would flag it.
//

import Foundation
import SQLite3
import Testing
@testable import Kalsmritikosh

@Suite("Apple activity store — knowledgeC (HOST-7)")
@MainActor
struct KnowledgeCParserTests {

    private let parser = KnowledgeCStructuralParser()

    /// 2026-03-14T09:26:53Z as Apple-epoch seconds.
    private let appleStart: Double = 1_773_480_413 - AppleEpoch.offset
    /// …plus 4m 7s.
    private let appleEnd: Double = 1_773_480_660 - AppleEpoch.offset

    /// A knowledgeC-shaped store: app focus with a span, a lock event, and a row
    /// whose stream we do not map.
    private func makeStore(in dir: URL, includeZObject: Bool = true) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("knowledgeC.db")
        var h: OpaquePointer?
        #expect(sqlite3_open_v2(url.path, &h, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK)
        defer { sqlite3_close(h) }

        if includeZObject {
            #expect(sqlite3_exec(h, """
            CREATE TABLE ZOBJECT(Z_PK INTEGER PRIMARY KEY, ZSTREAMNAME TEXT,
                                 ZVALUESTRING TEXT, ZSTARTDATE REAL, ZENDDATE REAL,
                                 ZSECONDSFROMGMT INTEGER);
            """, nil, nil, nil) == SQLITE_OK)
            let rows = """
            INSERT INTO ZOBJECT(ZSTREAMNAME, ZVALUESTRING, ZSTARTDATE, ZENDDATE, ZSECONDSFROMGMT) VALUES
              ('/app/inFocus','com.apple.Safari',\(appleStart),\(appleEnd),19800),
              ('/device/isLocked','1',\(appleStart + 600),\(appleStart + 600),19800),
              ('/some/unmappedStream','x',\(appleStart + 900),NULL,19800),
              ('/app/inFocus','com.apple.mail',NULL,NULL,19800);
            """
            #expect(sqlite3_exec(h, rows, nil, nil, nil) == SQLITE_OK)
        } else {
            #expect(sqlite3_exec(h, "CREATE TABLE notes(id INTEGER PRIMARY KEY, body TEXT);",
                                 nil, nil, nil) == SQLITE_OK)
            #expect(sqlite3_exec(h, "INSERT INTO notes(body) VALUES('hello');",
                                 nil, nil, nil) == SQLITE_OK)
        }
        return url
    }

    private func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("kc-\(UUID().uuidString)")
    }

    private func parse(_ url: URL) async throws -> ParsedDocument {
        try await parser.parse(data: try Data(contentsOf: url), filename: "knowledgeC.db",
                               type: .knowledgeC, logicalSourceID: UUID(), sourceVersionID: UUID())
    }
    private func records(_ doc: ParsedDocument) -> [String] {
        doc.blocks.filter { $0.kind == .logRecord }.map(\.rawText)
    }
    private func attribute(_ block: EvidenceBlock, _ key: String) -> String? {
        if case .string(let v)? = block.attributes[key]?.value { return v }
        return nil
    }

    // MARK: - The Apple-epoch defect

    @Test("Apple-epoch timestamps become the right year, not 1994")
    func appleEpochConverts() async throws {
        let dir = scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let doc = try await parse(try makeStore(in: dir))
        let focus = try #require(doc.blocks.first { $0.rawText.contains("com.apple.Safari") })
        #expect(attribute(focus, "timestamp") == "2026-03-14T09:26:53Z")
        // The failure this guards: treating the value as Unix seconds gives 1994.
        #expect(!(attribute(focus, "timestamp") ?? "").hasPrefix("1994"))
    }

    @Test("Apple epoch zero is 'never', not 2001-01-01")
    func zeroIsNotADate() {
        #expect(AppleEpoch.date(fromAppleSeconds: 0) == nil)
        #expect(AppleEpoch.date(fromAppleSeconds: nil) == nil)
        // Negative and absurd values are not dates either.
        #expect(AppleEpoch.date(fromAppleSeconds: -5) == nil)
        #expect(AppleEpoch.date(fromAppleSeconds: 9e12) == nil)
    }

    @Test("A seconds-or-nanoseconds column is told apart by magnitude")
    func secondsVersusNanoseconds() {
        // chat.db kept one column and switched its unit, so a message store can
        // hold either. Both must land on the same instant.
        let seconds = 1_773_480_413 - AppleEpoch.offset
        let asSeconds = AppleEpoch.date(fromAppleSecondsOrNanoseconds: seconds)
        let asNanos = AppleEpoch.date(fromAppleSecondsOrNanoseconds: seconds * 1_000_000_000)
        #expect(asSeconds == Date(timeIntervalSince1970: 1_773_480_413))
        #expect(asNanos == asSeconds)
    }

    // MARK: - Events

    @Test("An app-focus span becomes a dated sentence with its duration")
    func focusSpanReadsAsProse() async throws {
        let dir = scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let doc = try await parse(try makeStore(in: dir))
        let line = try #require(records(doc).first { $0.contains("com.apple.Safari") })
        #expect(line.contains("app in focus"))
        #expect(line.contains("2026-03-14T09:26:53Z to 2026-03-14T09:31:00Z"))
        #expect(line.contains("(4m 7s)"))
    }

    @Test("The device's own UTC offset is recorded — the timestamps cannot state it")
    func deviceTimeZoneIsKept() async throws {
        // ZSECONDSFROMGMT tells the examiner which zone the DEVICE was in, which
        // no absolute timestamp can.
        let dir = scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let doc = try await parse(try makeStore(in: dir))
        let line = try #require(records(doc).first { $0.contains("com.apple.Safari") })
        #expect(line.contains("[device UTC+05:30]"))
        let header = try #require(doc.blocks.first { $0.kind == .documentHeader })
        #expect(header.rawText.contains("device time zone +05:30"))
    }

    @Test("An undated activity row says so rather than being dropped or guessed")
    func undatedRowIsExplicit() async throws {
        // An activity row with no time is a DIFFERENT fact from a dated one, and
        // dropping it would hide that the store held it.
        let dir = scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let doc = try await parse(try makeStore(in: dir))
        let line = try #require(records(doc).first { $0.contains("com.apple.mail") })
        #expect(line.contains("no recorded time"))
        #expect(doc.blocks.first { $0.rawText.contains("com.apple.mail") }?
                    .attributes["timestamp"] == nil)
    }

    @Test("Events group by stream, and every event is present")
    func eventsGroupByStream() async throws {
        let dir = scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let doc = try await parse(try makeStore(in: dir))
        let heads = doc.blocks.filter { $0.kind == .sectionHeading }.map(\.rawText)
        #expect(heads.contains { $0.contains("App in focus") && $0.contains("2 event(s)") })
        #expect(heads.contains { $0.contains("Device locked") })
        #expect(records(doc).count == 4)
    }

    @Test("An unmapped stream keeps its raw name instead of getting an invented label")
    func unmappedStreamIsHonest() async throws {
        let dir = scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let doc = try await parse(try makeStore(in: dir))
        #expect(doc.blocks.contains { $0.rawText.contains("/some/unmappedStream") })
        // Readable, but not relabelled as something it is not.
        #expect(KnowledgeCStructuralParser.streamLabel("/some/unmappedStream") == "some unmappedStream")
        #expect(KnowledgeCStructuralParser.streamLabel("/app/inFocus") == "App in focus")
    }

    @Test("Parsing is deterministic — same store, same block order")
    func deterministic() async throws {
        let dir = scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = try makeStore(in: dir)
        let first = try await parse(url).blocks.map(\.rawText)
        let second = try await parse(url).blocks.map(\.rawText)
        #expect(first == second)
    }

    // MARK: - Honesty

    @Test("A SQLite file with no ZOBJECT is reported, not read as activity")
    func notAnActivityStoreIsReported() async throws {
        let dir = scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = try makeStore(in: dir, includeZObject: false)
        let doc = try await parse(url)
        #expect(doc.extractionStatus == .corrupt)
        #expect(records(doc).isEmpty)
        #expect(doc.warnings.contains { $0.code == "knowledgec.no_zobject" })
    }

    @Test("An empty file is empty, not corrupt")
    func emptyIsEmpty() async throws {
        let doc = try await parser.parse(data: Data(), filename: "knowledgeC.db",
                                         type: .knowledgeC, logicalSourceID: UUID(),
                                         sourceVersionID: UUID())
        #expect(doc.extractionStatus == .empty)
        #expect(doc.warnings.contains { $0.code == "knowledgec.empty" })
    }

    @Test("The original store's bytes are never modified")
    func originalUntouched() async throws {
        let dir = scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = try makeStore(in: dir)
        let before = try Data(contentsOf: url)
        _ = try await parse(url)
        #expect(try Data(contentsOf: url) == before)
    }

    // MARK: - Routing and wiring

    @Test("knowledgeC.db is detected by name, ahead of the generic .db mapping")
    func detectedByName() {
        // Without this precedence the store reads as plain `.sqlite` and its
        // Apple-epoch dates stay meaningless numbers.
        #expect(SourceType.detect(from: URL(fileURLWithPath: "/case/knowledgeC.db")) == .knowledgeC)
        #expect(SourceType.detect(from: URL(fileURLWithPath:
            "/case/private/var/db/CoreDuet/Knowledge/knowledgeC.db")) == .knowledgeC)
        // An ordinary database is still a database.
        #expect(SourceType.detect(from: URL(fileURLWithPath: "/case/notes.db")) == .sqlite)
    }

    @Test("It is a host artifact, not a document")
    func categoryIsHostArtifact() {
        #expect(SourceType.knowledgeC.category == .hostArtifact)
    }

    @Test("The registry gives it an immediate plugin with structure AND row records")
    func registryOwnsIt() throws {
        let registry = try UniversalParserRegistryBuilder.standard(ocr: VisionOCR())
        let plugin = try registry.resolve(.knowledgeC)
        #expect(plugin.pluginID == "format.knowledgeC")
        #expect(plugin.executionMode == .immediate)
        #expect(plugin.capabilities.producesStructure)
        // The record lane still reads every row, so nothing is lost to the cap.
        #expect(SQLiteLoader().supportedTypes.contains(.knowledgeC))
    }

    @Test("Every row is still indexed by the record loader, not only the cited events")
    func recordLaneStillCoversEveryRow() async throws {
        let dir = scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = try makeStore(in: dir)
        let objects = try await SQLiteLoader().ingestMany(fileAt: url, type: .knowledgeC)
        let text = objects.map(\.content).joined(separator: "\n")
        #expect(text.contains("ZSTREAMNAME = /app/inFocus"))
        #expect(text.contains("com.apple.mail"))
    }
}
