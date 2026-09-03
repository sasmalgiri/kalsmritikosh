//
//  V4EventClassGatingTests.swift
//  KalsmritikoshTests
//
//  V4 (D-17 Part A, EV-1) — event markers as a class-gated data table: a patent
//  letter or certificate produces ZERO commercial boilerplate events (the legal
//  extractor is primary there); commercial documents keep their events; email
//  header events stay universal; and across a mixed corpus the event-kind
//  distribution is no longer ≥90% one kind. Plus the v123 document_class column:
//  fresh ingests stamp it, pre-V4 rows stay NULL for the drain.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("V4 — event class gating (EV-1) + document_class")
struct V4EventClassGatingTests {

    private let gen = NoiseFixtureGenerator()

    private func ko(_ content: String, type: SourceType = .txt) -> KnowledgeObject {
        KnowledgeObject(sourceFile: URL(fileURLWithPath: "/tmp/fixture.txt"), sourceType: type, content: content)
    }

    // MARK: - Classification

    @Test("A patent-office letter classifies legalDocument; a certificate classifies certificate (conservative)")
    func classification() {
        let classifier = DocumentClassifier()
        #expect(classifier.classify(ko(gen.noisyGrantLetter)) == .legalDocument,
                "the grant letter must classify as a legal document")
        #expect(classifier.classify(ko("This is to certify that Patent No. 555489 stands granted.")) == .certificate)
        // Commercial documents still classify commercially (gate must not over-reach).
        #expect(classifier.classify(ko("Invoice number INV-42. Amount due: ₹20,000. Bill to: Orchid Ltd.")) == .invoice)
        // An ordinary note stays .other.
        #expect(classifier.classify(ko("Lunch notes and a shopping list.")) == .other)
    }

    // MARK: - EV-1 gating

    @Test("EV-1: ZERO commercial boilerplate events on the patent fixture (legal extractor is primary)")
    func zeroBoilerplateOnPatentFixture() async throws {
        let events = try await RuleEventExtractor().extractEvents(
            from: ko(gen.noisyGrantLetter), chunks: [], entities: [], blocks: [])
        let commercial: Set<Event.Kind> = [.contractSigned, .contractModified, .invoiceIssued, .invoicePaid,
                                           .meetingHeld, .taskAssigned, .deliveryDelayed, .deliveryCompleted]
        let boilerplate = events.filter { commercial.contains($0.kind) }
        #expect(boilerplate.isEmpty,
                "patent letter produced commercial boilerplate: \(boilerplate.map(\.kind.rawValue))")
    }

    @Test("EV-1: a certificate is likewise clean")
    func certificateClean() async throws {
        let cert = "This is to certify that the invoice number arrangements executed on 1 May were noted."
        let events = try await RuleEventExtractor().extractEvents(
            from: ko(cert), chunks: [], entities: [], blocks: [])
        #expect(events.isEmpty, "certificate produced events: \(events.map(\.kind.rawValue))")
    }

    @Test("The gate does not over-suppress: an invoice document still yields its invoice event")
    func invoiceStillFires() async throws {
        let invoice = "Invoice number INV-42, invoice dated 5 May 2024. Amount due ₹20,000. Bill to: Orchid Ltd."
        let events = try await RuleEventExtractor().extractEvents(
            from: ko(invoice), chunks: [], entities: [], blocks: [])
        #expect(events.contains { $0.kind == .invoiceIssued }, "invoice event was wrongly suppressed")
    }

    @Test("Email header events stay universal (not body-marker gated)")
    func emailEventsUniversal() async throws {
        var meta: [String: AnyCodable] = [:]
        meta["subject"] = AnyCodable(.string("Re: patent fees"))
        meta["date"] = AnyCodable(.string("Mon, 15 Jul 2024 10:00:00 +0530"))
        let email = KnowledgeObject(sourceFile: URL(fileURLWithPath: "/tmp/m.eml"), sourceType: .eml,
                                    content: "Body mentioning the patents act and fees.", metadata: meta)
        let events = try await RuleEventExtractor().extractEvents(from: email, chunks: [], entities: [], blocks: [])
        #expect(events.contains { $0.kind == .emailReceived }, "the universal email event must survive gating")
    }

    @Test("Distribution: across a mixed corpus no event kind is ≥90% of the total")
    func distributionNoLongerMonoculture() async throws {
        let docs: [KnowledgeObject] = [
            ko(gen.noisyGrantLetter),                                                         // legal → 0 commercial
            ko("Invoice number INV-1, invoice dated 1 May. Payment received, paid in full."), // invoice events
            ko("The parties signed this agreement, executed on 2 June. Amendment to follow."),// contract events
            ko("Minutes of meeting: we met on 3 July. Action item: owner: Priya."),           // meeting/task
        ]
        var kinds: [Event.Kind: Int] = [:]
        for d in docs {
            for e in try await RuleEventExtractor().extractEvents(from: d, chunks: [], entities: [], blocks: []) {
                kinds[e.kind, default: 0] += 1
            }
        }
        let total = kinds.values.reduce(0, +)
        #expect(total > 0, "corpus produced no events at all")
        for (kind, n) in kinds {
            #expect(Double(n) / Double(total) < 0.9,
                    "\(kind.rawValue) is \(n)/\(total) — distribution is still a monoculture")
        }
    }

    // MARK: - v123 document_class column

    @Test("v123: fresh ingest stamps document_class; a pre-V4 row reads NULL (drain backfills)")
    @MainActor
    func documentClassStamped() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("v4-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try Database(url: dir.appendingPathComponent("db.sqlite"))
        try await SchemaMigrations.migrate(db)
        let objects = KnowledgeObjectRepository(database: db)
        let coordinator = IngestCoordinator(
            universalRegistry: try UniversalParserRegistryBuilder.standard(ocr: VisionOCR()),
            files: FilesRepository(database: db), objects: objects, chunks: ChunksRepository(database: db),
            intakeCoordinator: UniversalSourceIntakeCoordinator(repository: CanonicalSourceIntakeRepository(database: db)))

        let url = dir.appendingPathComponent("grant.md")
        try gen.noisyGrantLetter.write(to: url, atomically: true, encoding: .utf8)
        let result = try await coordinator.ingest(fileAt: url)
        let stamped = try await objects.documentClass(forID: result.object.id)
        #expect(stamped == .legalDocument, "fresh ingest must stamp the class; got \(String(describing: stamped))")

        // A pre-V4 row (inserted directly, as the drain will find them) reads NULL.
        let fileID = UUID(), oldKO = UUID()
        try await db.exec("INSERT INTO files (id, url, source_type) VALUES (?, ?, ?);",
                          [.uuid(fileID), .text("file:///old"), .text("text")])
        try await db.exec("""
        INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at)
        VALUES (?, ?, ?, ?, 0, 0);
        """, [.uuid(oldKO), .uuid(fileID), .text("text"), .text("legacy body")])
        #expect(try await objects.documentClass(forID: oldKO) == nil, "pre-V4 rows await the drain")
    }
}
