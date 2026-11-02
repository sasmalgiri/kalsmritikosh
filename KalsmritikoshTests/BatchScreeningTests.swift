//
//  BatchScreeningTests.swift
//  KalsmritikoshTests
//
//  N2 — batch name screening: term classification, conservative phone / email normalisation,
//  screening on a small ledger (entity hit, text-only hit, zero-hit term listed, case scope
//  excluding an out-of-scope document, sensitive documents withheld and counted), the CSV
//  import column / header choice and the CSV export.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite struct ScreeningTermTests {

    @Test func classifiesNamesPhonesAndEmails() {
        #expect(ScreeningTermClassifier.classify("  Jane Doe ")?.kind == .name)
        #expect(ScreeningTermClassifier.classify("Jane Doe")?.normalized == "jane doe")
        let p = ScreeningTermClassifier.classify("+1 (555) 123-4567")
        #expect(p?.kind == .phone)
        #expect(p?.normalized == "+15551234567")
        #expect(ScreeningTermClassifier.classify("555.123.4567")?.normalized == "5551234567")
        let e = ScreeningTermClassifier.classify("Jane.Doe@Example.COM")
        #expect(e?.kind == .email)
        #expect(e?.normalized == "jane.doe@example.com")
        // A date is not a phone number; too few digits is not a phone number.
        #expect(ScreeningTermClassifier.classify("2024-01-02")?.kind == .name)
        #expect(ScreeningTermClassifier.classify("12-34")?.kind == .name)
        #expect(ScreeningTermClassifier.classify(" ") == nil)
        // Duplicates collapse by kind + normalised value.
        #expect(ScreeningTermClassifier.terms(["Jane Doe", "jane  doe", "555 123 4567", "555-123-4567"]).count == 2)
    }

    @Test func phoneNormalisationIsConservative() {
        #expect(ScreeningTermClassifier.normalizePhone("1+555 123 4567") == nil)       // "+" only leading
        #expect(ScreeningTermClassifier.normalizePhone("555 123 4567 ext") == nil)     // letters → not a phone
        #expect(ScreeningTermClassifier.normalizePhone("0044 20 7946 0958") == "00442079460958")   // "00" kept as written
        // Same digits, same form.
        #expect(ScreeningTermClassifier.phonesMatch("5551234567", "5551234567"))
        // One side with the country code, the other the same ≥9-digit national number.
        #expect(ScreeningTermClassifier.phonesMatch("+15551234567", "5551234567"))
        #expect(ScreeningTermClassifier.phonesMatch("5551234567", "+15551234567"))
        // Fewer than 9 trailing digits never match across the "+" form.
        #expect(!ScreeningTermClassifier.phonesMatch("+4912345678", "12345678"))
        // Two different country codes, or a trunk 0, never match.
        #expect(!ScreeningTermClassifier.phonesMatch("+15551234567", "+445551234567"))
        #expect(!ScreeningTermClassifier.phonesMatch("+15551234567", "05551234567"))
        // No country code is added or dropped without the "+": a longer unbroken number is another number.
        #expect(!ScreeningTermClassifier.phonesMatch("15551234567", "5551234567"))
    }

    @Test func phoneAndEmailVerificationInText() throws {
        let phone = try #require(ScreeningTermClassifier.classify("5551234567"))
        let hit = BatchScreening.textHits(phone, in: "Call 555-123-4567 2 times, or (555) 123 4567.")
        #expect(hit?.count == 2)
        #expect(hit?.highlight == "555-123-4567")
        #expect(BatchScreening.textHits(phone, in: "Account 15551234567 closed") == nil)
        #expect(BatchScreening.textHits(phone, in: "Ring +1 555 123 4567 now")?.count == 1)
        let email = try #require(ScreeningTermClassifier.classify("jane@acme.com"))
        #expect(BatchScreening.textHits(email, in: "Write to JANE@ACME.COM today")?.highlight == "JANE@ACME.COM")
        #expect(BatchScreening.textHits(email, in: "Write to jane@acme.com.au or ajane@acme.com") == nil)
    }

    @Test func csvImportChoosesColumnAndHeader() {
        let rows = ScreeningListImport.rows("Name,Phone\r\nJane Doe,555 123 4567\r\n\"Doe, John\",\r\n")
        #expect(ScreeningListImport.columnTitles(rows, hasHeader: true) == ["Name", "Phone"])
        #expect(ScreeningListImport.columnTitles(rows, hasHeader: false) == ["Column 1", "Column 2"])
        #expect(ScreeningListImport.values(rows, column: 0, hasHeader: true) == ["Jane Doe", "Doe, John"])
        #expect(ScreeningListImport.values(rows, column: 0, hasHeader: false) == ["Name", "Jane Doe", "Doe, John"])
        #expect(ScreeningListImport.values(rows, column: 1, hasHeader: true) == ["555 123 4567"])
    }
}

@Suite struct BatchScreeningTests {

    private struct Rig {
        let db: Database
        let screening: BatchScreening
        let vA: UUID, vB: UUID, vC: UUID
        let koA: UUID, koB: UUID, koC: UUID
    }

    @MainActor private func rig() async throws -> Rig {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let chunks = ChunksRepository(database: db)
        func source(_ name: String, _ text: String) async throws -> (version: UUID, ko: UUID) {
            let file = UUID(), ko = UUID(), version = UUID()
            try await db.exec("INSERT INTO files (id, url, source_type, availability) VALUES (?,?,?,?);",
                              [.uuid(file), .text("file:///screening/\(name)"), .text("txt"), .text("available")])
            try await db.exec("""
                INSERT INTO source_versions (id, logical_source_id, content_hash, valid_from, is_current, created_at,
                    filename, detected_type, detection_basis, size_bytes, custody_mode, preservation_status, intake_recorded_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?);
                """, [.uuid(version), .uuid(file), .text(String(repeating: "c", count: 64)), .real(1), .integer(1), .real(1),
                      .text(name), .text("txt"), .text("magicBytes"), .integer(1), .text("referenced"),
                      .text("referenceRecorded"), .real(1)])
            try await db.exec("""
                INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at) VALUES (?,?,?,?,?,?);
                """, [.uuid(ko), .uuid(file), .text("txt"), .text(text), .real(0), .real(0)])
            try await chunks.insertBatch([Chunk(objectID: ko, ordinal: 0, text: text, characterRange: 0..<text.count, sourceVersionID: version)])
            return (version, ko)
        }
        func entity(_ kind: String, _ value: String, mentions: [UUID]) async throws {
            let id = UUID()
            try await db.exec("INSERT INTO entities (id, kind, value, normalized, source_object_id) VALUES (?,?,?,?,?);",
                              [.uuid(id), .text(kind), .text(value), .text(value.lowercased()), .uuid(mentions[0])])
            for ko in mentions {
                try await db.exec("INSERT INTO entity_mentions (id, entity_id, kind, surface, normalized, source_object_id) VALUES (?,?,?,?,?,?);",
                                  [.uuid(UUID()), .uuid(id), .text(kind), .text(value), .text(value.lowercased()), .uuid(ko)])
            }
        }
        let a = try await source("memo-a.txt", "Payment approved by Jane Doe on Friday. Call +1 555 123 4567 for details.")
        let b = try await source("notes-b.txt", "Meeting with Rahul Verma about the contract. Write to rverma@example.com.")
        let c = try await source("outside-c.txt", "The lease was signed by Doe, Jane in March.")
        try await entity("person", "Jane Doe", mentions: [a.ko, c.ko])
        try await entity("phoneNumber", "+1 (555) 123-4567", mentions: [a.ko])
        let screening = BatchScreening(database: db, chunks: chunks, evidence: EvidenceStore(database: db))
        return Rig(db: db, screening: screening, vA: a.version, vB: b.version, vC: c.version, koA: a.ko, koB: b.ko, koC: c.ko)
    }

    private static let terms = ["Jane Doe", "Rahul Verma", "Zygmunt Nobody", "555-123-4567", "RVerma@Example.com"]
    private static let everything: @Sendable ([UUID]) async -> Set<UUID> = { Set($0) }

    @Test func wholeArchiveListsEveryTermWithHowItWasFound() async throws {
        let r = try await rig()
        let report = try await r.screening.run(lines: Self.terms, scope: .unscoped, scopeLabel: "Whole archive", visible: Self.everything)
        #expect(report.documentsSearched == 3)
        #expect(report.results.map(\.term.raw) == Self.terms)

        // Entity hit: both documents, the reordered "Doe, Jane" found through the entity.
        let jane = report.results[0]
        #expect(Set(jane.documents.map(\.objectID)) == [r.koA, r.koC])
        let inA = try #require(jane.documents.first { $0.objectID == r.koA })
        #expect(inA.foundBy == [.namedEntity, .textMatch])
        #expect(inA.howFound.contains("named entity — exact"))
        #expect(inA.highlight == "Jane Doe")
        #expect(inA.passage.contains("Payment approved by Jane Doe"))
        let inC = try #require(jane.documents.first { $0.objectID == r.koC })
        #expect(inC.foundBy == [.namedEntity])
        #expect(inC.name == "outside-c.txt")

        // Text-only hit: never extracted as an entity, still found.
        let rahul = report.results[1]
        #expect(rahul.documents.map(\.objectID) == [r.koB])
        #expect(rahul.documents[0].foundBy == [.textMatch])
        #expect(rahul.documents[0].howFound == "text match — exact words")
        #expect(rahul.mentions == 1)

        // Zero-hit term is listed, with what was searched.
        let nobody = report.results[2]
        #expect(nobody.documents.isEmpty)
        #expect(report.noMatchText(nobody) == "No match in 3 documents searched")

        // Phone: national form against "+1" — the entity and the text.
        let phone = report.results[3]
        #expect(phone.term.kind == .phone)
        #expect(phone.documents.map(\.objectID) == [r.koA])
        #expect(phone.documents[0].foundBy == [.namedEntity, .textMatch])
        #expect(phone.documents[0].howFound.contains("with/without the country code"))

        // Email, case-insensitive.
        let email = report.results[4]
        #expect(email.term.kind == .email)
        #expect(email.documents.map(\.objectID) == [r.koB])
        #expect(email.documents[0].highlight == "rverma@example.com")
    }

    @Test func caseScopeExcludesOutOfScopeDocuments() async throws {
        let r = try await rig()
        let report = try await r.screening.run(lines: Self.terms, scope: .authorizing([r.vA, r.vB]), scopeLabel: "Case “Lease”",
                                               visible: Self.everything)
        #expect(report.documentsSearched == 2)
        #expect(report.results[0].documents.map(\.objectID) == [r.koA])   // the entity's mention in C is out of scope
        // An empty case scope searches nothing, never the archive.
        let empty = try await r.screening.run(lines: Self.terms, scope: .authorizing([]), scopeLabel: "Case", visible: Self.everything)
        #expect(empty.documentsSearched == 0)
        #expect(empty.results.allSatisfy { $0.documents.isEmpty })
    }

    @Test func sensitiveDocumentsAreWithheldAndCounted() async throws {
        let r = try await rig()
        let hidden = r.koB
        let report = try await r.screening.run(lines: ["Rahul Verma"], scope: .unscoped, scopeLabel: "Whole archive",
                                               visible: { ids in Set(ids.filter { $0 != hidden }) })
        let rahul = report.results[0]
        #expect(rahul.documents.isEmpty)
        #expect(rahul.withheldDocuments == 1)
        #expect(report.noMatchText(rahul).hasPrefix("No match you can see in 3 documents searched"))
    }

    @Test func csvCarriesScopeDateAndEveryTerm() async throws {
        let r = try await rig()
        let report = try await r.screening.run(lines: ["Rahul Verma", "Zygmunt Nobody"], scope: .unscoped, scopeLabel: "Whole archive",
                                               visible: Self.everything, at: Date(timeIntervalSince1970: 1_800_000_000))
        let lines = report.csv().components(separatedBy: "\r\n").filter { !$0.isEmpty }
        #expect(lines[0] == "Name screening — scope: Whole archive — run 2027-01-15T08:00:00Z — 3 documents searched")
        #expect(lines[1] == "Term,Kind,Documents,Mentions,Document,How found,Passage")
        #expect(lines[2].hasPrefix("Rahul Verma,Name,1,1,notes-b.txt,text match — exact words,"))
        #expect(lines[2].contains("Meeting with Rahul Verma"))
        #expect(lines[3] == "Zygmunt Nobody,Name,0,0,,,No match in 3 documents searched")
        #expect(lines.count == 4)
    }
}
