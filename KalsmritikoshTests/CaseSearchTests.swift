//
//  CaseSearchTests.swift
//  KalsmritikoshTests
//
//  Living case map M5 — "Search case evidence": the versioned query tree (strict parsing, repair only
//  offered, explanation ⇔ compiled meaning), the documented matching semantics, case scope, counts, paging,
//  caps and time limits, witnesses, the coverage receipt and saved searches. Every expected match set below
//  is written out by hand from the fixture texts, independently of the matcher. Throwaway ledgers; no network.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@MainActor
@Suite("Case evidence search (M5)")
struct CaseSearchTests {

    // MARK: Fixture

    struct Fixture {
        let base: CaseFileTests.Fixture
        let service: CaseSearchService
        var db: Database { base.db }
        var caseID: UUID { base.caseID }
        /// Document name → knowledge object id.
        let doc: [String: UUID]
        let version: [String: UUID]
    }

    static let texts: [(String, String)] = [
        ("invoice-17.txt", "Invoice No. A-17/B was paid on 3 March 2024. Net-30 terms apply to the supplier."),
        ("approval-email.eml", "The payment was approved by José Álvarez. This is a draft."),
        ("statement.txt", "Witness statement: I never approved the second payment to O'Brien."),
        ("ledger.txt", "The supplier was paid twice in error, according to the ledger."),
        ("notes.txt", "Ｆｉｎａｌ review: the ﬁnancial INVOICE is a DRAFT; jose alvarez agreed."),
        ("aside.txt", "Public part. Secret kickback words here."),
        ("scan.pdf", ""),
    ]

    static func utf16Range(_ text: String, _ piece: String) -> Range<Int> {
        let r = (text as NSString).range(of: piece)
        return r.location..<(r.location + r.length)
    }

    static func chunk(_ db: Database, object: UUID, ordinal: Int, _ r: Range<Int>, text: String, rejected: Bool = false) async throws {
        try await db.exec("INSERT INTO chunks (id, object_id, ordinal, text, char_start, char_end, created_at) VALUES (?,?,?,?,?,?,?);",
                          [.uuid(UUID()), .uuid(object), .integer(Int64(ordinal)), .text(text), .integer(Int64(r.lowerBound)), .integer(Int64(r.upperBound)), .real(1)])
        if rejected { try await db.exec("UPDATE chunks SET review_status = 'rejected' WHERE object_id = ? AND ordinal = ?;", [.uuid(object), .integer(Int64(ordinal))]) }
    }

    static func make() async throws -> Fixture {
        let base = try await CaseFileTests.fixture(title: "Supplier paid twice?")
        var doc: [String: UUID] = [:], version: [String: UUID] = [:]
        for (name, text) in texts {
            let s = try await CaseFileTestSources.seedPassage(base.db, cases: base.cases, caseID: base.caseID, name: name, text: text)
            doc[name] = s.object; version[name] = s.version
        }
        let db = base.db
        func fileOf(_ name: String) -> SQLValue { .uuid(doc[name] ?? UUID()) }
        // Fields: type, stated date, modified dates, an event, a mention, a tag.
        try await db.exec("UPDATE knowledge_objects SET source_type = 'email', metadata_json = ? WHERE id = ?;",
                          [.text(#"{"date":"Mon, 4 Mar 2024 10:00:00 +0000","subject":"Approval"}"#), fileOf("approval-email.eml")])
        try await db.exec("UPDATE files SET modified_at = ? WHERE id = (SELECT file_id FROM knowledge_objects WHERE id = ?);",
                          [.real(Self.utc(2024, 2, 10)), fileOf("invoice-17.txt")])
        try await db.exec("UPDATE files SET modified_at = ? WHERE id = (SELECT file_id FROM knowledge_objects WHERE id = ?);",
                          [.real(Self.utc(2024, 5, 1)), fileOf("approval-email.eml")])
        try await db.exec("INSERT INTO events (id, kind, date, title, source_object_id) VALUES (?,?,?,?,?);",
                          [.uuid(UUID()), .text("statement"), .real(Self.utc(2024, 3, 4) + 3600), .text("Statement given"), fileOf("statement.txt")])
        let entity = UUID()
        try await db.exec("INSERT INTO entities (id, kind, value, normalized, source_object_id) VALUES (?,?,?,?,?);",
                          [.uuid(entity), .text("person"), .text("José Álvarez"), .text("josé álvarez"), fileOf("approval-email.eml")])
        try await db.exec("INSERT INTO entity_mentions (id, entity_id, kind, surface, normalized, source_object_id, confidence) VALUES (?,?,?,?,?,?,?);",
                          [.uuid(UUID()), .uuid(entity), .text("person"), .text("José Álvarez"), .text("josé álvarez"), fileOf("approval-email.eml"), .real(0.9)])
        let tag = UUID()
        try await db.exec("INSERT INTO user_tags (id, name, created_at) VALUES (?,?,?);", [.uuid(tag), .text("contract"), .real(1)])
        try await db.exec("INSERT INTO user_tag_links (tag_id, subject_kind, subject_id, created_at) VALUES (?,?,?,?);",
                          [.uuid(tag), .text("object"), fileOf("ledger.txt"), .real(1)])
        // Passages: the ledger's phrase "paid twice" is split across two passages; aside.txt's second passage is set aside.
        let ledger = texts[3].1
        let cut = (ledger as NSString).range(of: "twice").location
        try await chunk(db, object: doc["ledger.txt"] ?? UUID(), ordinal: 0, 0..<cut, text: (ledger as NSString).substring(to: cut))
        try await chunk(db, object: doc["ledger.txt"] ?? UUID(), ordinal: 1, cut..<ledger.utf16.count, text: (ledger as NSString).substring(from: cut))
        let aside = texts[5].1
        try await chunk(db, object: doc["aside.txt"] ?? UUID(), ordinal: 0, utf16Range(aside, "Public part."), text: "Public part.")
        try await chunk(db, object: doc["aside.txt"] ?? UUID(), ordinal: 1, utf16Range(aside, "Secret kickback words here."), text: "Secret kickback words here.", rejected: true)
        let inv = texts[0].1
        try await chunk(db, object: doc["invoice-17.txt"] ?? UUID(), ordinal: 0, 0..<inv.utf16.count, text: inv)
        let service = CaseSearchService(sources: CaseSearchSources.live(database: db))
        return Fixture(base: base, service: service, doc: doc, version: version)
    }

    static func utc(_ y: Int, _ m: Int, _ d: Int) -> Double {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC") ?? .current
        return c.date(from: DateComponents(year: y, month: m, day: d))?.timeIntervalSince1970 ?? 0
    }

    nonisolated static let utcOptions = CaseSearchOptions(timeZoneID: "UTC")

    func names(_ f: Fixture, _ text: String, _ options: CaseSearchOptions = CaseSearchTests.utcOptions, caseID: UUID? = nil) async throws -> [String] {
        let outcome = await f.service.run(caseID: caseID ?? f.caseID, text: text, options: options)
        let run = try #require(outcome.run, "\(text): \(outcome)")
        return run.hits.map(\.name)
    }

    // MARK: Matching semantics

    @Test("Words, prefixes, phrases and exact characters: punctuation, case, Unicode and accents as documented")
    func textSemantics() async throws {
        let f = try await Self.make()
        #expect(try await names(f, "invoice") == ["invoice-17.txt", "notes.txt"])           // "Invoice" and "INVOICE"; not "invoice-17" the file name
        #expect(try await names(f, "invoic*") == ["invoice-17.txt", "notes.txt"])
        #expect(try await names(f, "invoices") == [])                                       // no stemming
        #expect(try await names(f, "\"net 30\"") == ["invoice-17.txt"])                     // "Net-30": punctuation between words ignored
        #expect(try await names(f, "exact:\"A-17/B\"") == ["invoice-17.txt"])
        #expect(try await names(f, "exact:\"a-17/b\"") == ["invoice-17.txt"])               // case off
        #expect(try await names(f, "exact:\"A-17 B\"") == [])                               // exact characters: "/" is not a space
        #expect(try await names(f, "O'Brien") == ["statement.txt"])
        #expect(try await names(f, "\"to O Brien\"") == ["statement.txt"])
        #expect(try await names(f, "jose") == ["approval-email.eml", "notes.txt"])          // accents ignored by default
        var accents = Self.utcOptions; accents.matchAccents = true
        #expect(try await names(f, "josé", accents) == ["approval-email.eml"])
        #expect(try await names(f, "jose", accents) == ["notes.txt"])
        var cased = Self.utcOptions; cased.matchCase = true
        #expect(try await names(f, "INVOICE", cased) == ["notes.txt"])
        #expect(try await names(f, "financial") == ["notes.txt"])                           // the "ﬁ" ligature (NFKC)
        #expect(try await names(f, "final") == ["notes.txt"])                               // full-width letters (NFKC)
        #expect(try await names(f, "approved NEAR/3 payment") == ["approval-email.eml", "statement.txt"])
        #expect(try await names(f, "approved NEAR/1 payment") == ["approval-email.eml"])
    }

    @Test("A phrase across a passage boundary is found, and the witness says it crosses the boundary")
    func crossChunkPhrase() async throws {
        let f = try await Self.make()
        let run = try #require(await f.service.run(caseID: f.caseID, text: "\"paid twice\"", options: Self.utcOptions).run)
        #expect(run.hits.map(\.name) == ["ledger.txt"])
        let hit = try #require(run.hits.first)
        #expect(hit.occurrences == 1 && hit.passages == 2 && hit.crossBoundaryOccurrences == 1)
        #expect(hit.witnesses.first?.crossesPassageBoundary == true && hit.witnesses.first?.matchedText == "paid twice")
        // Document-level AND across the two passages too.
        #expect(try await names(f, "paid AND error") == ["ledger.txt"])
    }

    @Test("Negation and document-level NOT: never matches a document that was not searched")
    func negation() async throws {
        let f = try await Self.make()
        #expect(try await names(f, "payment AND NOT draft") == ["statement.txt"])
        #expect(try await names(f, "payment -draft") == ["statement.txt"])
        // Every searched document without "draft": scan.pdf has no text and is never listed as lacking it.
        #expect(try await names(f, "NOT draft") == ["aside.txt", "invoice-17.txt", "ledger.txt", "statement.txt"])
        // A set-aside passage is blanked out: its words are not found.
        let run = try #require(await f.service.run(caseID: f.caseID, text: "kickback", options: Self.utcOptions).run)
        #expect(run.hits.isEmpty && run.receipt.setAsidePassages == 1)
    }

    @Test("Field OR, nested field logic and person/tag/type/file fields")
    func fields() async throws {
        let f = try await Self.make()
        #expect(try await names(f, "type:email OR file:ledger") == ["approval-email.eml", "ledger.txt"])
        #expect(try await names(f, "(type:email OR file:statement) AND (approved NOT draft)") == ["statement.txt"])
        #expect(try await names(f, "supplier AND (file:invoice OR NOT paid)") == ["invoice-17.txt"])
        #expect(try await names(f, "person:\"jose alvarez\"") == ["approval-email.eml"])   // a recorded mention, not the words in notes.txt
        #expect(try await names(f, "tag:contract") == ["ledger.txt"])
        #expect(try await names(f, "tag:contract OR (type:email AND NOT person:\"jose alvarez\")") == ["ledger.txt"])
        let run = try #require(await f.service.run(caseID: f.caseID, text: "type:email OR file:ledger", options: Self.utcOptions).run)
        let email = try #require(run.hits.first { $0.name == "approval-email.eml" })
        #expect(email.satisfied == ["are of document type “email”"])
        let ledger = try #require(run.hits.first { $0.name == "ledger.txt" })
        #expect(ledger.satisfied == ["have a file name containing “ledger” — file name: ledger.txt"])
    }

    @Test("Date kinds: file modified, the date the document states and an extracted event are different dates")
    func dateKinds() async throws {
        let f = try await Self.make()
        #expect(try await names(f, "modified-before:2024-03") == ["invoice-17.txt"])
        #expect(try await names(f, "modified-on:2024-03-04") == [])
        #expect(try await names(f, "stated-on:2024-03-04") == ["approval-email.eml"])
        #expect(try await names(f, "stated-after:2024-03-03") == ["approval-email.eml"])
        #expect(try await names(f, "stated-after:2024-03-04") == [])                      // after excludes the named day
        #expect(try await names(f, "event-on:2024-03") == ["statement.txt"])
        #expect(try await names(f, "event-on:2024-03 OR stated-on:2024-03") == ["approval-email.eml", "statement.txt"])
        // The archive's ambiguous before:/after: is refused in a case search, with a repair that names the date.
        let p = CaseSearchParser.parse("before:2024-03")
        #expect(!p.isValid && p.repair?.text == "modified-before:2024-03")
        let run = try #require(await f.service.run(caseID: f.caseID, text: "stated-on:2024", options: Self.utcOptions).run)
        #expect(run.receipt.notes.contains { $0.contains("state no date of their own") })
    }

    // MARK: Scope, counts, paging, caps

    @Test("Excluded and unreadable files are in the receipt and are not counted as searched; zero matches says so")
    func receipt() async throws {
        let f = try await Self.make()
        // An authorised version with no text in the ledger, and a document excluded from the case.
        _ = try await CaseFileTestSources.inScope(f.db, cases: f.base.cases, caseID: f.caseID)
        let excluded = try await CaseFileTestSources.seedPassage(f.db, cases: f.base.cases, caseID: f.caseID, name: "withdrawn.txt",
                                                                text: "Another invoice that was withdrawn from the case.")
        let header = try #require(try await f.base.cases.fetch(caseID: f.caseID)?.caseHeader)
        _ = try await f.base.cases.excludeSource(caseID: f.caseID, expectedRevision: header.revision, sourceRef: excluded.version.uuidString,
                                                 sourceKind: .sourceVersion, actor: "Ada", at: Date())
        let run = try #require(await f.service.run(caseID: f.caseID, text: "invoice", options: Self.utcOptions).run)
        #expect(run.hits.map(\.name) == ["invoice-17.txt", "notes.txt"])                    // not withdrawn.txt
        let r = run.receipt
        #expect(r.items(.excluded).map(\.name) == ["withdrawn.txt"])
        #expect(r.items(.noText).map(\.name) == ["scan.pdf"])
        #expect(r.items(.unavailable).count + r.items(.failed).count == 1)
        #expect(r.searched == 6)                                                          // the six documents with text; not scan.pdf, the unreadable one or withdrawn.txt
        #expect(!r.complete && !run.isComplete && run.countsLine.contains("incomplete"))
        #expect(r.coverageLine != nil)
        let none = try #require(await f.service.run(caseID: f.caseID, text: "refund", options: Self.utcOptions).run)
        let statement = try #require(none.zeroMatchStatement)
        #expect(statement.hasPrefix("No match among the 6 documents searched.") && statement.contains("says nothing about what was not searched"))
    }

    @Test("Counts: documents, occurrences and passages are kept apart")
    func counts() async throws {
        let f = try await Self.make()
        let run = try #require(await f.service.run(caseID: f.caseID, text: "supplier OR paid", options: Self.utcOptions).run)
        #expect(run.hits.map(\.name) == ["invoice-17.txt", "ledger.txt"])
        let inv = try #require(run.hits.first { $0.name == "invoice-17.txt" })
        #expect(inv.occurrences == 2 && inv.passages == 1)                                 // "paid", "supplier"; one passage
        let led = try #require(run.hits.first { $0.name == "ledger.txt" })
        #expect(led.occurrences == 2 && led.passages == 1)                                 // both in the first passage
        #expect(run.documentCount == 2 && run.occurrenceCount == 4 && run.passageCount == 2)
    }

    @Test("All pages concatenated equal the expected set, in a stable order")
    func paging() async throws {
        let f = try await Self.make()
        var o = Self.utcOptions; o.pageSize = 3
        let run = try #require(await f.service.run(caseID: f.caseID, text: "NOT draft", options: o).run)
        let pages = (0..<run.pageCount).map { run.page($0) }
        #expect(pages.count == 2 && pages.map(\.hits.count) == [3, 1])
        #expect(pages.flatMap(\.hits).map(\.name) == ["aside.txt", "invoice-17.txt", "ledger.txt", "statement.txt"])
        #expect(pages[1].rangeLine == "Matches 4–4 of 4 · page 2 of 2")
        let again = try #require(await f.service.run(caseID: f.caseID, text: "NOT draft", options: o).run)
        #expect(again.hits.map(\.objectID) == run.hits.map(\.objectID))
    }

    @Test("A document cap and the time limit are disclosed; what was not reached is listed")
    func capsAndTimeouts() async throws {
        let f = try await Self.make()
        var capped = Self.utcOptions; capped.maxDocuments = 2
        let run = try #require(await f.service.run(caseID: f.caseID, text: "invoice", options: capped).run)
        #expect(run.stoppedEarly?.contains("at most 2 documents") == true)
        #expect(run.receipt.items(.notReached).count == 5 && !run.isComplete)
        var timed = Self.utcOptions; timed.timeLimitSeconds = 0.000_001
        let slow = try #require(await f.service.run(caseID: f.caseID, text: "invoice", options: timed).run)
        #expect(slow.stoppedEarly?.contains("time limit") == true && slow.hits.isEmpty)
        #expect(slow.receipt.items(.notReached).count == 7 && slow.receipt.searched == 0)
        #expect(slow.zeroMatchStatement?.contains("7 not searched") == true)
        var stem = Self.utcOptions; stem.stemming = true
        if case .rejected(let why, _) = await f.service.run(caseID: f.caseID, text: "invoice", options: stem) {
            #expect(why.first?.contains("stemming") == true)
        } else { Issue.record("stemming must be refused, not ignored") }
    }

    @Test("Two cases sharing a source never see each other's documents")
    func twoCaseIsolation() async throws {
        let f = try await Self.make()
        let other = try await f.base.cases.createCase(workspaceID: f.base.workspaceID, title: "Other", actor: "Ada", at: Date())
        _ = try await CaseFileTestSources.seedPassage(f.db, cases: f.base.cases, caseID: other.id, name: "other-invoice.txt", text: "An invoice of the other case.")
        let h = try #require(try await f.base.cases.fetch(caseID: other.id)?.caseHeader)
        _ = try await f.base.cases.includeSource(caseID: other.id, expectedRevision: h.revision, sourceRef: (f.version["invoice-17.txt"] ?? UUID()).uuidString,
                                                 sourceKind: .sourceVersion, actor: "Ada", at: Date())
        #expect(try await names(f, "invoice") == ["invoice-17.txt", "notes.txt"])
        #expect(try await names(f, "invoice", caseID: other.id) == ["invoice-17.txt", "other-invoice.txt"])
        let otherRun = try #require(await f.service.run(caseID: other.id, text: "NOT zzz", options: Self.utcOptions).run)
        #expect(Set(otherRun.hits.map(\.name)) == ["invoice-17.txt", "other-invoice.txt"])
        if case .failed = await f.service.run(caseID: UUID(), text: "invoice", options: Self.utcOptions) {} else { Issue.record("an unknown case must fail") }
    }

    // MARK: The tree

    @Test("Explanation ⇔ compiled meaning on a table of queries; the canonical text parses back to the same tree")
    func explanationEquivalence() async throws {
        let f = try await Self.make()
        let table: [(String, [String], [String])] = [
            ("\"net 30\"", ["Documents in this case that contain the words “net 30” in this order"], ["invoice-17.txt"]),
            ("payment AND NOT draft", ["Documents in this case that match ALL of these:", "• contain the word “payment”", "• do not contain the word “draft”"], ["statement.txt"]),
            ("type:email OR file:ledger", ["Documents in this case that match AT LEAST ONE of these:", "• are of document type “email”", "• have a file name containing “ledger”"],
             ["approval-email.eml", "ledger.txt"]),
            ("(type:email OR file:statement) AND (approved NOT draft)",
             ["Documents in this case that match ALL of these:", "• AT LEAST ONE of these:", "    • are of document type “email”",
              "    • have a file name containing “statement”", "• contain the word “approved”", "• do not contain the word “draft”"], ["statement.txt"]),
            ("NOT (draft OR kickback)", ["Documents in this case that match NONE of these:", "• contain the word “draft”", "• contain the word “kickback”"],
             ["aside.txt", "invoice-17.txt", "ledger.txt", "statement.txt"]),
            ("approved NEAR/1 payment", ["Documents in this case that contain “approved” and “payment” with at most 1 other word between them"], ["approval-email.eml"]),
            ("a b OR c", ["Documents in this case that match AT LEAST ONE of these:", "• ALL of these:", "    • contain the word “a”", "    • contain the word “b”",
                          "• contain the word “c”"], ["invoice-17.txt"]),   // "A-17/B" holds the words a and b
            ("stated-before:2024-03-05", ["Documents in this case that state a date of their own before 5 March 2024"], ["approval-email.eml"]),
        ]
        for (text, explanation, expected) in table {
            let p = CaseSearchParser.parse(text)
            let q = try #require(p.query, "\(text): \(p.errors)")
            #expect(q.explanation == explanation, "\(text)")
            #expect(CaseSearchParser.parse(q.text).query == q, "\(text) → \(q.text)")
            let plan = CaseSearchPlan(query: q, options: Self.utcOptions)
            #expect(plan.clauseText == q.root.leaves.map { CaseSearchRenderer.leaf($0, negated: false) })
            #expect(try await names(f, text) == expected, "\(text)")
        }
        // Stored as JSON with its version, read back identically.
        let q = try #require(CaseSearchParser.parse("(type:email OR file:statement) AND (approved NOT draft)").query)
        #expect(CaseSearchQuery.decode(q.encoded()) == q && q.version == CaseSearchQuery.currentVersion)
    }

    @Test("An invalid query never runs and never broadens; a repair is only offered")
    func invalidNeverBroadens() async throws {
        let f = try await Self.make()
        for bad in ["invoice AND (draft", "invoice AND", "OR invoice", "invoice group:Payments", "foo:bar", "invoice ) draft", "type:", "NEAR/5 x",
                    "stated-on:March", "invoice NEAR/500 paid", "inv*ice", "\"unclosed", "()", "(type:email) NEAR/3 paid", "before:2024"] {
            let p = CaseSearchParser.parse(bad)
            #expect(!p.isValid && p.query == nil && !p.errors.isEmpty, "\(bad) must be rejected")
            guard case .rejected = await f.service.run(caseID: f.caseID, text: bad, options: Self.utcOptions) else {
                Issue.record("\(bad) ran"); continue
            }
            if let repair = p.repair {
                #expect(CaseSearchParser.parse(repair.text).isValid, "\(bad) → \(repair.text)")
                #expect(!repair.changes.isEmpty)
            }
        }
        #expect(CaseSearchParser.parse("invoice group:Payments").repair?.broadens == true)
        #expect(CaseSearchParser.parse("invoice AND (draft").repair?.text == "invoice AND draft")
        #expect(CaseSearchParser.parse("foo:bar").repair?.text == "\"foo bar\"")
        #expect(CaseSearchParser.parse("(type:email) NEAR/3 paid").repair?.broadens == true)
        // Lowercase and/or/not are words, not operators.
        #expect(CaseSearchParser.parse("paid and approved").query?.explanation.count == 4)
    }

    // MARK: Saved searches

    @Test("Saved searches persist query version, options, scope, index revision and time; a receipt is frozen")
    func savedSearchPersistence() async throws {
        let f = try await Self.make()
        var o = Self.utcOptions; o.matchAccents = true; o.pageSize = 7
        let run = try #require(await f.service.run(caseID: f.caseID, text: "josé OR invoice", options: o, now: Date(timeIntervalSince1970: 1_800_000_000)).run)
        let live = try await f.service.save(run, name: "Payments", kind: .live, actor: "Ada")
        let receipt = try await f.service.save(run, name: "As at today", kind: .receipt, actor: "Ada")
        let saved = try await f.service.repository.savedSearches(caseID: f.caseID)
        #expect(saved.map(\.id) == [live, receipt] && saved.map(\.kind) == [.live, .receipt])
        let s = try #require(saved.first)
        #expect(s.query == run.query && s.queryVersion == CaseSearchQuery.currentVersion && s.options == o && s.queryText == run.query.text)
        #expect(s.scopeFingerprint == run.scopeFingerprint && s.scopeVersionIDs == run.scopeVersionIDs && s.indexRevision == run.indexRevision)
        #expect(s.executedAt == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(s.result.matchedObjectIDs == run.hits.map(\.objectID) && s.result.documents == 3 && !s.result.receiptLines.isEmpty)
        await #expect(throws: CaseSearchRepositoryError.frozen) {
            try await f.service.acknowledge(saved[1], run: run)
        }
        await #expect(throws: (any Error).self) {
            try await f.db.exec("UPDATE case_saved_searches SET result_json = '{}' WHERE id = ?;", [.uuid(receipt)])
        }
        await #expect(throws: (any Error).self) {
            try await f.db.exec("UPDATE case_saved_searches SET query_text = 'other' WHERE id = ?;", [.uuid(live)])
        }
        // Nothing of the search is kept in preferences.
        let prefs = UserDefaults.standard.dictionaryRepresentation().values.compactMap { $0 as? String }
        #expect(!prefs.contains(run.query.text))
    }

    @Test("A live search detects new matches when case material changes, and never admits a document that is not in the case")
    func newMatchDetection() async throws {
        let f = try await Self.make()
        let run = try #require(await f.service.run(caseID: f.caseID, text: "refund", options: Self.utcOptions).run)
        #expect(run.hits.isEmpty)
        let id = try await f.service.save(run, name: "Refunds", kind: .live, actor: "Ada")
        // An archive document outside the case mentions a refund: never searched, never added.
        let archive = try await CaseFileTestSources.seed(f.db)
        let fileRow = try #require(try await f.db.query("SELECT logical_source_id FROM source_versions WHERE id = ?;", [.uuid(archive)]).first?.uuid(0))
        try await f.db.exec("INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at) VALUES (?,?,?,?,?,?);",
                            [.uuid(UUID()), .uuid(fileRow), .text("txt"), .text("A refund was requested."), .real(0), .real(0)])
        let sourcesBefore = try #require(try await f.base.cases.fetch(caseID: f.caseID)).sources.count
        var saved = try #require(try await f.service.repository.savedSearch(id: id))
        guard case .success(let none) = await f.service.changes(for: saved) else { Issue.record("no changes report"); return }
        #expect(none.newMatches.isEmpty && !none.scopeChanged)
        // The case's material changes: a new document is added to the case, an existing one is read again.
        _ = try await CaseFileTestSources.seedPassage(f.db, cases: f.base.cases, caseID: f.caseID, name: "refund-letter.txt", text: "We ask for a refund.")
        try await f.db.exec("UPDATE knowledge_objects SET content = content || ' A refund followed.', updated_at = 5 WHERE id = ?;", [.uuid(f.doc["statement.txt"] ?? UUID())])
        guard case .success(let changed) = await f.service.changes(for: saved) else { Issue.record("no changes report"); return }
        #expect(changed.newMatches.map(\.name) == ["refund-letter.txt", "statement.txt"])
        #expect(changed.scopeChanged && changed.indexChanged)
        #expect(try #require(try await f.base.cases.fetch(caseID: f.caseID)).sources.count == sourcesBefore + 1)   // only the document the person added
        try await f.service.acknowledge(saved, run: changed.current)
        saved = try #require(try await f.service.repository.savedSearch(id: id))
        guard case .success(let after) = await f.service.changes(for: saved) else { Issue.record("no changes report"); return }
        #expect(after.newMatches.isEmpty && after.noLongerMatching.isEmpty && !after.scopeChanged && !after.indexChanged)
    }

    @Test("A hit's passage goes to the report through the case file, verified; the same passage twice is refused")
    func reportHandoff() async throws {
        let f = try await Self.make()
        let run = try #require(await f.service.run(caseID: f.caseID, text: "\"second payment\"", options: Self.utcOptions).run)
        let hit = try #require(run.hits.first)
        let w = try #require(hit.witnesses.first)
        let added = try await PassageReportSelection.add(caseID: f.caseID, objectID: hit.objectID, sourceVersionID: hit.versionIDs.first, quote: w.matchedText,
                                                         text: "The witness denies the second payment", caseFiles: f.base.svc, actor: "Ada")
        #expect(added.support.isDocumentary)
        await #expect(throws: PassageReportSelectionError.alreadySelected) {
            try await PassageReportSelection.add(caseID: f.caseID, objectID: hit.objectID, sourceVersionID: hit.versionIDs.first, quote: w.matchedText,
                                                 text: "again", caseFiles: f.base.svc, actor: "Ada")
        }
    }
}
