//
//  ExactSourceExtractionTests.swift
//  KalsmritikoshTests
//
//  Smart-map S2 (docs/IME_Full_Smart_Map_Implementation_TODO_2026-11-08.md §05: SRC-02, SRC-03, SRC-04, SRC-07, SRC-10;
//  schema v178 S2-B). Deterministic throwaway ledgers, AI off — nothing here calls a model or the network:
//  • SRC-02: a persisted passage names its reader run (reader, version, extraction time, coverage) and the OCR engine
//    with its version; original text, recognised text and an investigator's statement are told apart;
//  • SRC-03: quoted words cut from a longer sentence keep its negation and attribution as qualifiers (with the full
//    sentence), so a truncated quote is never shown as a plain verified passage; assertions store typed qualifiers;
//  • SRC-04: rewording a point, a chronology entry or a report item leaves its quotation, locator and verification as
//    they were, and the ledger refuses to change a recorded quotation in place;
//  • SRC-07: field-kind checks (quote, name, date, amount, summary); a genuine quotation attached to a statement it does
//    not support is unverified after re-verification — citation existence alone validates nothing;
//  • SRC-10: three copies of one report are one evidential origin on the map, with every repeated reference listed.
//

import Foundation
import Testing
@testable import Kalsmritikosh

/// A readable source with a chosen content hash (copies share one), included in the case by exact version.
enum ExactSourceSeeds {
    static func hex64() -> String {
        let h = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return h + h
    }

    static func seed(_ f: CaseFileTests.Fixture, name: String, text: String, hash: String) async throws -> (version: UUID, object: UUID, logical: UUID, blocks: [UUID]) {
        let db = f.db
        let fileID = UUID(), koID = UUID(), version = UUID(), docID = UUID()
        try await db.exec("INSERT INTO files (id, url, source_type, availability, content_hash) VALUES (?,?,?,?,?);",
                          [.uuid(fileID), .text("file:///exact-source/\(fileID.uuidString)/\(name)"), .text("txt"), .text("available"), .text(hash)])
        try await db.exec("INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at) VALUES (?,?,?,?,?,?);",
                          [.uuid(koID), .uuid(fileID), .text("txt"), .text(text), .real(0), .real(0)])
        try await db.exec("""
            INSERT INTO source_versions (id, logical_source_id, document_id, content_hash, valid_from, is_current, created_at,
                filename, detected_type, detection_basis, size_bytes, custody_mode, preservation_status, intake_recorded_at, original_url)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(version), .uuid(fileID), .uuid(docID), .text(hash), .real(100), .integer(1), .real(100),
                  .text(name), .text("txt"), .text("magicBytes"), .integer(Int64(text.utf8.count)), .text("referenced"), .text("referenceRecorded"), .real(100),
                  .text("file:///exact-source/\(fileID.uuidString)/\(name)")])
        var blocks: [UUID] = []
        let sentences = text.components(separatedBy: ". ").map { $0.hasSuffix(".") ? $0 : $0 + "." }.filter { $0.count > 2 }
        for (i, sentence) in sentences.enumerated() {
            let blockID = UUID()
            try await db.exec("""
                INSERT INTO evidence_blocks (id, document_id, source_version_id, ordinal, kind, raw_text, normalized_text, extraction_method, extraction_confidence)
                VALUES (?,?,?,?,?,?,?,?,?);
                """, [.uuid(blockID), .uuid(docID), .uuid(version), .integer(Int64(i)), .text("paragraph"), .text(sentence), .text(sentence.lowercased()), .text("native"), .real(1.0)])
            try await db.exec("INSERT INTO evidence_block_objects (evidence_block_id, knowledge_object_id, linked_at) VALUES (?,?,?);", [.uuid(blockID), .uuid(koID), .real(0)])
            blocks.append(blockID)
        }
        let header = try await f.cases.fetch(caseID: f.caseID)?.caseHeader
        _ = try await f.cases.includeSource(caseID: f.caseID, expectedRevision: header?.revision ?? 1, sourceRef: version.uuidString,
                                            sourceKind: .sourceVersion, actor: "Ada", at: Date())
        return (version, koID, fileID, blocks)
    }

    /// A bare source version (no structure attached yet), for EvidenceStore.persist to attach to.
    static func bareVersion(_ db: Database, hash: String) async throws -> (version: UUID, logical: UUID) {
        let version = UUID(), logical = UUID()
        try await db.exec("INSERT INTO files (id, url, source_type, availability, content_hash) VALUES (?,?,?,?,?);",
                          [.uuid(logical), .text("file:///exact-source/\(logical.uuidString).pdf"), .text("pdf"), .text("available"), .text(hash)])
        try await db.exec("""
            INSERT INTO source_versions (id, logical_source_id, content_hash, valid_from, is_current, created_at,
                filename, detected_type, detection_basis, size_bytes, custody_mode, preservation_status, intake_recorded_at, original_url)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(version), .uuid(logical), .text(hash), .real(100), .integer(1), .real(100),
                  .text("scan.pdf"), .text("pdf"), .text("magicBytes"), .integer(10), .text("referenced"), .text("referenceRecorded"), .real(100),
                  .text("file:///exact-source/\(logical.uuidString).pdf")])
        return (version, logical)
    }
}

@Suite("Smart map S2 — exact sources, extraction and representation (SRC-02/03/04/07/10)", .serialized)
struct ExactSourceExtractionTests {

    // MARK: - SRC-02 extraction provenance

    @Test("SRC-02: a persisted passage names its reader, reader version, extraction time and coverage; OCR names its engine and version; original, recognised and investigator text are told apart")
    func extractionProvenance() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let hash = ExactSourceSeeds.hex64()
        let v = try await ExactSourceSeeds.bareVersion(db, hash: hash)
        let docID = UUID()
        let native = EvidenceBlock(documentID: docID, sourceVersionID: v.version, ordinal: 0, kind: .paragraph,
                                   rawText: "Invoice INV-104 was approved by the finance manager.", locator: SourceLocator(page: 1, paragraphIndex: 0),
                                   extractionMethod: .native, language: "en")
        let scanned = EvidenceBlock(documentID: docID, sourceVersionID: v.version, ordinal: 1, kind: .paragraph,
                                    rawText: "Received 50,000 by cheque", locator: SourceLocator(page: 2, paragraphIndex: 0),
                                    extractionMethod: .ocr, extractionConfidence: 0.6, language: "en")
        let doc = ParsedDocument(id: docID, logicalSourceID: v.logical, sourceVersionID: v.version, filename: "scan.pdf", detectedType: .pdf,
                                 contentHash: hash, blocks: [native, scanned], extractionStatus: .partial)
        let started = Date(timeIntervalSince1970: 1_780_000_000), ended = Date(timeIntervalSince1970: 1_780_000_042)
        let receipt = try await EvidenceStore(database: db).persist(doc, parser: "pdf-structural", parserVersion: "4.2", startedAt: started, endedAt: ended)

        // Each passage names the run that wrote it; the run names the OCR engine it used.
        let stamped = try await db.query("SELECT parser_run_id FROM evidence_blocks WHERE source_version_id = ? ORDER BY ordinal;", [.uuid(v.version)])
        #expect(stamped.count == 2 && stamped.allSatisfy { $0.uuid(0) == receipt.parserRunID })
        let runRow = try await db.query("SELECT engines FROM parser_runs WHERE id = ?;", [.uuid(receipt.parserRunID)]).first
        let engines = ExtractionEngineIdentity.decodeEngines(runRow?.string(0))
        #expect(engines.keys.sorted() == ["ocr"], "only the methods the run used are recorded — the native text layer has no engine")

        let repo = ExtractionProvenanceRepository(database: db)
        let o = try #require(try await repo.provenance(blockID: native.id))
        #expect(o.kind == .original && o.isOriginalWording && o.method == .native)
        #expect(o.reader == "pdf-structural" && o.readerVersion == "4.2" && o.engine == nil && o.runRecordedForPassage)
        #expect(o.extractedAt == ended && o.sourceVersionID == v.version && o.language == "en")
        #expect(o.coverage?.contains("partial") == true, "the run's coverage says it was partial: \(o.coverage ?? "-")")

        let r = try #require(try await repo.provenance(blockID: scanned.id))
        #expect(r.kind == .recognized && !r.isOriginalWording && r.method == .ocr)
        #expect(r.engine?.hasPrefix("Apple Vision text recognition, revision") == true, "\(r.engine ?? "-")")
        #expect(r.confidence == 0.6 && r.lines.contains { $0.contains("Recognition confidence: 60") })
        #expect(r.kind.badge != o.kind.badge, "the badge text differs for original and recognised words")

        // A citation that names only the version and the words resolves to the passage holding them.
        let byQuote = try #require(try await repo.provenance(objectID: nil, sourceVersionID: v.version, blockID: nil, quote: "50,000 by cheque"))
        #expect(byQuote.kind == .recognized && byQuote.blockID == scanned.id)
        // The version as a whole says how its passages divide.
        let whole = try #require(try await repo.provenance(objectID: nil, sourceVersionID: v.version, blockID: nil, quote: nil))
        #expect(whole.mixture?.contains("1 of 2 passages are not the file's own text") == true, "\(whole.mixture ?? "-")")

        // A passage written before per-passage run records says so instead of borrowing the run silently.
        let legacy = UUID()
        try await db.exec("""
            INSERT INTO evidence_blocks (id, document_id, source_version_id, ordinal, kind, raw_text, normalized_text, extraction_method, extraction_confidence)
            VALUES (?,?,?,?,?,?,?,?,?);
            """, [.uuid(legacy), .uuid(docID), .uuid(v.version), .integer(2), .text("paragraph"), .text("Old passage"), .text("Old passage"), .text("native"), .real(1)])
        let l = try #require(try await repo.provenance(blockID: legacy))
        #expect(!l.runRecordedForPassage && l.lines.contains { $0.contains("predates per-passage records") })

        // The investigator's statement and generated text are never original wording.
        #expect(!ExtractionProvenance.statement().isOriginalWording && ExtractionProvenance.statement().kind == .interpretation)
        #expect(!ExtractionProvenance.statement(.generated).isOriginalWording)
        #expect(TextProvenanceKind(method: .asr) == .transcribed && TextProvenanceKind(method: .manual) == .entered)
    }

    // MARK: - SRC-03 qualifications and attribution

    @Test("SRC-03: cutting a quote out of its sentence keeps the sentence's negation and attribution as dropped qualifiers")
    func truncationDetector() {
        let sentence = "The courier said that the seal was not intact on arrival."
        let cut = AssertionQualifierDetector.check(quote: "intact on arrival", in: sentence)
        #expect(cut.dropped == [.negation, .attribution] && cut.changesMeaning && cut.isTruncated)
        #expect(cut.sentence == sentence && cut.qualifiers.speaker == "The courier")
        #expect(cut.lines.contains { $0.contains("negated") } && cut.lines.contains { $0.contains("Full sentence") })

        let keepsNot = AssertionQualifierDetector.check(quote: "the seal was not intact on arrival", in: sentence)
        #expect(keepsNot.dropped == [.attribution], "the negation is inside the words; only the attribution is cut")

        let whole = AssertionQualifierDetector.check(quote: sentence, in: "Intro. " + sentence + " Outro.")
        #expect(whole.dropped.isEmpty && whole.sentence == nil && !whole.changesMeaning)

        let plan = AssertionQualifierDetector.check(quote: "pay the supplier on 5 March 2026", in: "The company will pay the supplier on 5 March 2026 if the goods arrive.")
        #expect(plan.dropped.contains(.proposed) && plan.dropped.contains(.condition) && !plan.dropped.contains(.date))

        let q = AssertionQualifierDetector.detect("According to the auditor, the payment may not have been made.")
        #expect(q.reportedSpeech && q.speaker == "the auditor" && q.negations == ["not"] && q.uncertainty.contains("may"))
    }

    @Test("SRC-03: a point whose quote drops a preceding \"not\" and \"he said that\" carries them and is not shown as a plain verified passage")
    func truncatedPointIsFlagged() async throws {
        let f = try await CaseFileTests.fixture(title: "Seal dispute")
        let text = "The courier said that the seal was not intact on arrival. The sample weighed 12 grams."
        let src = try await ExactSourceSeeds.seed(f, name: "courier-statement.txt", text: text, hash: ExactSourceSeeds.hex64())
        let report = try await f.file.addReport(caseID: f.caseID, CaseReportDetails(title: "Courier statement", sourceVersionID: src.version), actor: "Ada")
        let point = try await f.svc.addPoint(caseID: f.caseID, reportID: report, kind: .finding, statement: "The seal was intact on arrival",
                                             quote: "intact on arrival", actor: "Ada")
        let full = try await f.svc.addPoint(caseID: f.caseID, reportID: report, kind: .finding, statement: "The sample weighed 12 grams",
                                            quote: "The sample weighed 12 grams.", actor: "Ada")
        let ledger = try await f.file.reportLedger(caseID: f.caseID)
        let pt = try #require(ledger.point(point))
        #expect(pt.isVerified && pt.blockID == src.blocks[0], "the words are genuinely in the source")
        let check = try #require(pt.sourceCheck)
        #expect(check.context.dropped.contains(.negation) && check.context.dropped.contains(.attribution) && check.flagsMeaning)
        #expect(pt.quoteContext == "The courier said that the seal was not intact on arrival.")
        #expect(ledger.point(full)?.sourceCheck?.flagsMeaning == false && ledger.point(full)?.quoteContext == nil)

        let p = try #require(await caseMapLoad(f).projection)
        let node = try #require(p.node(CaseMapNodeID(caseID: f.caseID, kind: .reportPoint, id: point)))
        #expect(node.status.kind == .unsupported && node.status.text.contains("negation") && !node.isDocumentary)
        #expect(node.qualifications.contains { $0.contains("Source sentence is negated") } && node.title.hasSuffix("(qualified)"))
        #expect(node.qualifications.contains { $0.contains("reported speech by The courier") })
        #expect(p.node(CaseMapNodeID(caseID: f.caseID, kind: .reportPoint, id: full))?.status.kind == .recorded)

        // The stored qualification is part of the record: it is never changed afterwards.
        await #expect(throws: (any Error).self) {
            try await f.db.exec("UPDATE case_report_points SET qualifiers_json = NULL WHERE id = ?;", [.uuid(point)])
        }
    }

    @Test("SRC-03: an extracted assertion stores the typed qualifiers of its quote")
    func assertionQualifiersStored() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let repo = AssertionsRepository(database: db)
        let a = Assertion(subjectKind: .claim, subjectID: UUID(), predicate: "delivered", object: .literal("goods"),
                          directQuote: "According to the auditor, the supplier did not deliver the goods.")
        try await repo.insert(a)
        let q = try #require(try await repo.qualifiers(assertionID: a.id))
        #expect(q.negations == ["not"] && q.reportedSpeech && q.speaker == "the auditor")
        let plain = Assertion(subjectKind: .claim, subjectID: UUID(), predicate: "delivered", object: .literal("goods"))
        try await repo.insert(plain)
        #expect(try await repo.qualifiers(assertionID: plain.id) == nil, "no quote, nothing invented")
    }

    // MARK: - SRC-04 source and interpretation kept apart

    @Test("SRC-04: rewording a point, a chronology entry or a report item leaves the quotation, its locator and its verification unchanged")
    func rewordingKeepsQuotation() async throws {
        let f = try await CaseFileTests.fixture(title: "Weight dispute")
        let quote = "The sample weighed 12 grams."
        let src = try await ExactSourceSeeds.seed(f, name: "lab.txt", text: "The bag arrived sealed. " + quote, hash: ExactSourceSeeds.hex64())
        let report = try await f.file.addReport(caseID: f.caseID, CaseReportDetails(title: "Lab report", sourceVersionID: src.version), actor: "Ada")
        let point = try await f.svc.addPoint(caseID: f.caseID, reportID: report, kind: .finding, statement: "Weight 12 g", quote: quote, actor: "Ada")
        let before = try #require(try await f.file.reportLedger(caseID: f.caseID).point(point))
        try await f.file.restatePoint(caseID: f.caseID, pointID: point, statement: "The sample weighed twelve grams", actor: "Ada")
        let after = try #require(try await f.file.reportLedger(caseID: f.caseID).point(point))
        #expect(after.statement == "The sample weighed twelve grams" && before.statement == "Weight 12 g")
        #expect(after.quote == quote && after.quote == before.quote && after.blockID == before.blockID && after.blockID == src.blocks[1])
        #expect(after.charStart == before.charStart && after.charEnd == before.charEnd && after.sourceVersionID == before.sourceVersionID)
        #expect(after.supportState == before.supportState && after.isVerified && after.sourceCheck == before.sourceCheck)
        let node = try #require(await caseMapLoad(f).projection?.node(CaseMapNodeID(caseID: f.caseID, kind: .reportPoint, id: point)))
        #expect(node.sources.first?.quote == quote && node.wording?.hasPrefix("The sample weighed twelve grams") == true)
        // The quotation of an unreviewed point is not rewritable either: a different quotation is a new point.
        await #expect(throws: (any Error).self) {
            try await f.db.exec("UPDATE case_report_points SET quote = 'The sample weighed 13 grams.' WHERE id = ?;", [.uuid(point)])
        }
        await #expect(throws: (any Error).self) {
            try await f.db.exec("UPDATE case_report_points SET char_start = 0, char_end = 3 WHERE id = ?;", [.uuid(point)])
        }

        // A chronology entry: its text (the summary) can be reworded; its quotation and citations cannot.
        let r = try await PassageChronology.add(caseID: f.caseID, objectID: src.object, quote: quote, text: "Weight recorded",
                                                eventDate: nil, caseFiles: f.svc, actor: "Ada")
        #expect(r.support.isDocumentary)
        let e0 = try #require(try await f.file.journal(caseID: f.caseID).first { $0.id == r.entryID })
        try await f.db.exec("UPDATE case_journal SET text = 'The lab recorded the weight' WHERE id = ?;", [.uuid(r.entryID)])
        let e1 = try #require(try await f.file.journal(caseID: f.caseID).first { $0.id == r.entryID })
        #expect(e1.text == "The lab recorded the weight" && e1.quote == e0.quote && e1.citations == e0.citations && e1.support == e0.support)
        await #expect(throws: (any Error).self) {
            try await f.db.exec("UPDATE case_journal SET quote = 'The sample weighed 13 grams.' WHERE id = ?;", [.uuid(r.entryID)])
        }
        await #expect(throws: (any Error).self) {
            try await f.db.exec("UPDATE case_journal SET citations_json = '[]' WHERE id = ?;", [.uuid(r.entryID)])
        }

        // A report item likewise.
        let item = try await f.file.addReportItem(caseID: f.caseID, allegationID: nil, text: "Finding: 12 grams", quote: quote,
                                                  evidenceRef: src.version.uuidString, origin: nil,
                                                  citations: [StudioEvidenceRef(sourceVersionID: src.version, objectID: src.object, blockID: src.blocks[1], quote: quote)],
                                                  support: .documentary(version: src.version, object: src.object, block: src.blocks[1]), actor: "Ada")
        try await f.db.exec("UPDATE case_report_items SET text = 'Finding: twelve grams' WHERE id = ?;", [.uuid(item)])
        let i1 = try #require(try await f.file.reportItems(caseID: f.caseID).first { $0.id == item })
        #expect(i1.text == "Finding: twelve grams" && i1.quote == quote && i1.support.isDocumentary)
        await #expect(throws: (any Error).self) {
            try await f.db.exec("UPDATE case_report_items SET quote = 'other words' WHERE id = ?;", [.uuid(item)])
        }
    }

    // MARK: - SRC-07 field-specific checks

    @Test("SRC-07: quotes, names, dates, amounts and summaries are each checked by kind")
    func fieldKindChecks() {
        let passage = "This agreement is signed on 12 January 2024 by John Carter and Maria Lopez. Total contract value: USD 1,800,000."
        #expect(CaseStatementSupport.check("signed on 12 January 2024", as: .quote, against: passage) == nil)
        #expect(CaseStatementSupport.check("signed on 13 January 2024", as: .quote, against: passage) != nil)
        // Names: initials, titles and order are allowed; a different given name is not the same person.
        #expect(CaseStatementSupport.check("John Carter", as: .name, against: passage) == nil)
        #expect(CaseStatementSupport.check("J. Carter", as: .name, against: passage) == nil)
        #expect(CaseStatementSupport.check("Mr Carter", as: .name, against: passage) == nil)
        #expect(CaseStatementSupport.check("Carter, John", as: .name, against: passage) == nil)
        #expect(CaseStatementSupport.check("Jane Carter", as: .name, against: passage) != nil)
        #expect(CaseStatementSupport.check("Peter Lopez", as: .name, against: passage) != nil)
        // Dates and amounts.
        #expect(CaseStatementSupport.check("12 January 2024", as: .date, against: passage) == nil)
        #expect(CaseStatementSupport.check("2024-01-13", as: .date, against: passage) != nil)
        #expect(CaseStatementSupport.check("USD 1,800,000", as: .amount, against: passage) == nil)
        #expect(CaseStatementSupport.check("USD 2,800,000", as: .amount, against: passage) != nil)
        #expect(CaseStatementSupport.check("EUR 1,800,000", as: .amount, against: passage) != nil)
        // Summaries: a paraphrase is fine; what it states must be in the passage.
        #expect(CaseStatementSupport.check(statement: "John Carter signed the agreement on 12 January 2024", against: passage).isSupported)
        let wrong = CaseStatementSupport.check(statement: "Payment of USD 50,000 was made to Acme Ltd on 5 March 2026", against: passage)
        #expect(!wrong.isSupported)
        #expect(wrong.failures.contains { $0.contains("amount") } && wrong.failures.contains { $0.contains("date") } && wrong.failures.contains { $0.contains("Acme") })
        let opposite = CaseStatementSupport.check(statement: "The seal was not intact", against: "The seal was intact on arrival.")
        #expect(opposite.failures.contains { $0.contains("negated") })
        let unrelated = CaseStatementSupport.check(statement: "Warehouse inventory reconciliation showed missing pallets", against: passage)
        #expect(unrelated.failures.contains { $0.contains("does not mention") })
    }

    @Test("SRC-07: a genuine quotation attached to a chronology entry it does not support is unverified after re-verification; a supported entry stays verified")
    func citationExistenceAloneDoesNotValidate() async throws {
        let f = try await CaseFileTests.fixture(title: "Meeting minutes")
        let text = "The meeting was postponed because the chair was ill. The board approved the payment of USD 50,000 to Acme Ltd on 5 March 2026."
        let src = try await ExactSourceSeeds.seed(f, name: "minutes.txt", text: text, hash: ExactSourceSeeds.hex64())
        let unrelated = try await PassageChronology.add(caseID: f.caseID, objectID: src.object, quote: "The meeting was postponed because the chair was ill.",
                                                        text: "Payment of USD 50,000 was made to Acme Ltd on 5 March 2026",
                                                        eventDate: nil, caseFiles: f.svc, actor: "Ada")
        let supported = try await PassageChronology.add(caseID: f.caseID, objectID: src.object,
                                                        quote: "The board approved the payment of USD 50,000 to Acme Ltd on 5 March 2026.",
                                                        text: "Board approved USD 50,000 to Acme Ltd on 5 March 2026",
                                                        eventDate: nil, caseFiles: f.svc, actor: "Ada")
        #expect(unrelated.support.isDocumentary, "the quote itself is genuine")
        try await f.svc.reverifyCarriedItems(caseID: f.caseID)
        let entries = try await f.file.journal(caseID: f.caseID)
        let u = try #require(entries.first { $0.id == unrelated.entryID })
        let s = try #require(entries.first { $0.id == supported.entryID })
        #expect(!u.support.isDocumentary && u.support.label.contains("do not support this statement"), "\(u.support.label)")
        #expect(u.support.label.contains("amount") && u.support.label.contains("Acme"))
        #expect(s.support.isDocumentary, "\(s.support.label)")
        // The same rule is available to any caller, by field kind.
        let name = await f.svc.verifyStatement("Maria Lopez", field: .name, reference: src.version.uuidString,
                                               passage: StudioEvidenceRef(sourceVersionID: src.version, quote: "The meeting was postponed because the chair was ill."),
                                               caseID: f.caseID)
        #expect(!name.support.isDocumentary && name.support.label.contains("does not name Maria Lopez"))
    }

    // MARK: - SRC-10 occurrences and dependence

    @Test("SRC-10: three copies of one report are one evidential origin on the map; every repeated reference is listed, none counted as corroboration")
    func copiesAreOneOrigin() async throws {
        let f = try await CaseFileTests.fixture(title: "Supplier report copies")
        let text = "The supplier delivered 40 cartons on 2 May 2026. Two cartons were damaged."
        let shared = ExactSourceSeeds.hex64()
        var copies: [(version: UUID, object: UUID, logical: UUID, blocks: [UUID])] = []
        for name in ["report.txt", "report (copy).txt", "Fwd report.txt"] {
            copies.append(try await ExactSourceSeeds.seed(f, name: name, text: text, hash: shared))
        }
        let independent = try await ExactSourceSeeds.seed(f, name: "warehouse-log.txt", text: "Warehouse log: 40 cartons received on 2 May 2026.",
                                                           hash: ExactSourceSeeds.hex64())
        var reports: [UUID] = [], points: [UUID] = []
        for (i, c) in copies.enumerated() {
            let r = try await f.file.addReport(caseID: f.caseID, CaseReportDetails(title: "Delivery report \(i + 1)", sourceVersionID: c.version), actor: "Ada")
            reports.append(r)
            points.append(try await f.svc.addPoint(caseID: f.caseID, reportID: r, kind: .claim, statement: "40 cartons delivered",
                                                   quote: "The supplier delivered 40 cartons on 2 May 2026.", actor: "Ada"))
        }
        let log = try await f.file.addReport(caseID: f.caseID, CaseReportDetails(title: "Warehouse log", sourceVersionID: independent.version), actor: "Ada")

        let p = try #require(await caseMapLoad(f).projection)
        func rn(_ id: UUID) -> CaseMapNodeID { CaseMapNodeID(caseID: f.caseID, kind: .report, id: id) }
        func pn(_ id: UUID) -> CaseMapNodeID { CaseMapNodeID(caseID: f.caseID, kind: .reportPoint, id: id) }
        // Each report rests on one origin and lists the other two copies.
        for r in reports {
            let dep = try #require(p.node(rn(r))?.dependence)
            #expect(dep.independentOrigins == 1 && dep.copies.count == 2 && dep.basis == "identical content")
            #expect(dep.lines.contains { $0.contains("not independent corroboration") })
        }
        // Three copies (and their three points) are ONE origin; the independent log makes two.
        #expect(p.independentOrigins(of: reports.map(rn)) == 1)
        #expect(p.independentOrigins(of: points.map(pn)) == 1)
        #expect(p.independentOrigins(of: reports.map(rn) + [rn(log)]) == 2)
        // Every repeated reference is listed: the other points (same words, via a copy) and the reports citing the origin.
        let dep = try #require(p.node(pn(points[0]))?.dependence)
        #expect(dep.occurrenceTotal == 5, "three reports and the two other points cite the same origin")
        let others = dep.occurrences.filter { $0.node.kind == .reportPoint }
        #expect(Set(others.map(\.node)) == Set(points.dropFirst().map(pn)) && others.allSatisfy { $0.sameWords && $0.viaCopy })
        #expect(dep.occurrences.contains { $0.node == rn(reports[0]) && !$0.viaCopy })
        // The independent document is its own origin with no copies.
        let logDep = try #require(p.node(rn(log))?.dependence)
        #expect(logDep.copies.isEmpty && logDep.independentOrigins == 1 && logDep.occurrenceTotal == 0)
    }
}
