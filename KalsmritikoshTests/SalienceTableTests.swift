//
//  SalienceTableTests.swift
//  KalsmritikoshTests
//
//  S2-U1 (D-17 Part B) — the weight table's laws, pinned: bounded range,
//  neutral prior for the unknown, class overrides only where class changes
//  meaning, and the end-to-end stamp (ingest writes it, the row carries it).
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("S2-U1 — structural salience (table laws + persisted stamp)")
@MainActor
struct SalienceTableTests {

    @Test("Every weight is in [0,1]; unknown and missing kinds read neutral")
    func tableLaws() {
        for (kind, w) in SalienceTable.baseWeights {
            #expect(w >= 0 && w <= 1, "\(kind) weight \(w) out of range")
        }
        for (cls, map) in SalienceTable.classOverrides {
            for (kind, w) in map {
                #expect(w >= 0 && w <= 1, "\(cls)/\(kind) override \(w) out of range")
            }
        }
        #expect(SalienceTable.salience(forBlockKind: nil, documentClass: .email) == SalienceTable.neutral)
        #expect(SalienceTable.salience(forBlockKind: "no-such-kind", documentClass: nil) == SalienceTable.neutral)
        #expect(SalienceTable.salience(forBlockKind: "paragraph", documentClass: nil) == SalienceTable.neutral)
    }

    @Test("The anchor rulings hold: subject over quoted tail; invoice rows privileged; résumé skeleton neutral")
    func anchorRulings() {
        let subject = SalienceTable.salience(forBlockKind: "emailHeader", documentClass: .email)
        let quoted  = SalienceTable.salience(forBlockKind: "quotedEmail", documentClass: .email)
        #expect(subject > quoted, "an email's identity outranks someone else's quoted mail")
        #expect(subject >= 0.9 && quoted <= 0.35)

        let invoiceRow = SalienceTable.salience(forBlockKind: "tableRow", documentClass: .invoice)
        #expect(invoiceRow >= 0.9, "the line-item table IS the invoice")

        let resumeHeading = SalienceTable.salience(forBlockKind: "sectionHeading", documentClass: .resume)
        #expect(resumeHeading == SalienceTable.neutral,
                "résumé structure is navigation, not answers — the owner's live leak shaped this row")

        let grantTitle = SalienceTable.salience(forBlockKind: "documentTitle", documentClass: .legalDocument)
        #expect(grantTitle == 1.0, "LETTER OF GRANT is the document's identity")

        let boiler = SalienceTable.salience(forBlockKind: "emailSignature", documentClass: .email)
        #expect(boiler <= 0.3, "boilerplate stays low — down-ranked, never dropped")
    }

    @Test("A chunk round-trips its salience through the repository")
    func persistedStamp() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("salience-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try Database(url: dir.appendingPathComponent("db.sqlite"))
        try await SchemaMigrations.migrate(db)

        let fileID = UUID(); let koID = UUID()
        try await db.exec("INSERT INTO files (id, url, source_type) VALUES (?, '/tmp/a.eml', 'eml');", [.uuid(fileID)])
        try await db.exec("""
        INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at)
        VALUES (?, ?, 'eml', 'seed', 0, 0);
        """, [.uuid(koID), .uuid(fileID)])

        let repo = ChunksRepository(database: db)
        let stamped = Chunk(
            objectID: koID, ordinal: 0, text: "Subject: grant of patent",
            characterRange: 0..<24, blockKind: "emailHeader",
            salience: SalienceTable.salience(forBlockKind: "emailHeader", documentClass: .email))
        try await repo.insertBatch([stamped])

        let back = try await repo.firstChunk(forObjectID: koID)
        #expect(back?.salience == 0.95, "the class-aware weight must survive the round-trip, got \(back?.salience ?? -1)")

        // Legacy row: the column default is the neutral prior.
        let legacyID = UUID()
        try await db.exec("""
        INSERT INTO chunks (id, object_id, ordinal, text, char_start, char_end, created_at)
        VALUES (?, ?, 1, 'old row', 0, 7, 0);
        """, [.uuid(legacyID), .uuid(koID)])
        let rows = try await db.query("SELECT salience FROM chunks WHERE id = ?;", [.uuid(legacyID)])
        #expect(rows.first?.double(0) == SalienceTable.neutral, "legacy rows read the neutral default")
    }
}

// MARK: - S2-U1 consumer gates (G2/G3 + class-ordered roots)

@Suite("S2-U1 — consumer gates: bounded, tiebreak-only, class-ordered")
@MainActor
struct SalienceConsumerTests {

    @Test("G2 — same rank: the table-row candidate beats the footer candidate; rank still dominates salience")
    func slotTiebreak() {
        func cand(_ conf: Double, salience: Double, value: String = "555489") -> SlotAnswerComposer.Candidate {
            .init(fact: GenericFact(subjectLabel: "s", field: "patentnumber", value: value,
                                    assessment: EvidenceAssessment(basis: .directlyObserved, origin: .sourceExtraction),
                                    confidence: conf, sourceBlockIDs: []),
                  objectID: UUID(), presentation: .fact, isAuthority: false, salience: salience)
        }
        let tableRow = cand(0.8, salience: 0.85)
        let footer   = cand(0.8, salience: 0.3)
        #expect(SlotAnswerComposer.strongerFirst(tableRow, footer), "same rank → higher salience wins")
        #expect(!SlotAnswerComposer.strongerFirst(footer, tableRow))
        // Rank dominates: a stronger-ranked footer still beats a weak table row.
        let strongFooter = cand(0.95, salience: 0.3)
        let weakRow      = cand(0.5,  salience: 0.85)
        #expect(SlotAnswerComposer.strongerFirst(strongFooter, weakRow), "salience is a TIEBREAK, never a driver")
    }

    @Test("G3 — the confidence advisory is bounded at ±0.02 and inert on nil")
    func confidenceAdvisoryBound() {
        let engine = DefaultConfidenceEngine()
        let base = ConfidenceReport(combined: Confidence(0.5), sourceCount: 1,
                                    distinctSourceObjectIDs: 1, agreementScore: 1, contradictions: [])
        #expect(engine.applySalienceAdvisory(base, meanCitedSalience: nil).combined.value == 0.5)
        let up = engine.applySalienceAdvisory(base, meanCitedSalience: 1.0).combined.value
        let down = engine.applySalienceAdvisory(base, meanCitedSalience: 0.0).combined.value
        #expect(abs(up - 0.5) <= 0.02 + 1e-12, "upper bound held, got \(up)")
        #expect(abs(down - 0.5) <= 0.03 + 1e-12, "lower bound held, got \(down)")
        #expect(up > 0.5 && down < 0.5, "direction follows structure")
        let neutral = engine.applySalienceAdvisory(base, meanCitedSalience: SalienceTable.neutral).combined.value
        #expect(neutral == 0.5, "neutral prior moves nothing")
    }

    @Test("Class-ordered roots: the class's own pack is tried first; every pack still runs")
    func classOrderedRoots() {
        let cert = DomainFactExtractor.packOrder(for: .certificate)
        #expect(cert.first == .patent, "a certificate meets the patent root first")
        #expect(Set(cert).count == DomainFactExtractor.PackRoot.allCases.count, "no pack is ever excluded")
        let invoice = DomainFactExtractor.packOrder(for: .invoice)
        #expect(invoice.first == .transaction)
        let unknown = DomainFactExtractor.packOrder(for: .other)
        #expect(unknown.first == .employment, "an other-classed document keeps the historical order")
        #expect(DomainFactExtractor.packOrder(for: nil) == unknown, "nil class = default order (existing callers byte-identical)")
    }
}
