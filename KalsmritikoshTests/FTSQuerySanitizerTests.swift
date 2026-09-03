//
//  FTSQuerySanitizerTests.swift
//  KalsmritikoshTests
//
//  V1.1 U2.5 + F4.1 — the sanitizer turns a raw punctuated question into a SAFE
//  FTS5 MATCH expression of INFORMATIVE terms: quoted, deduped, OR-joined; no
//  operator ever leaks; stopwords never flood the join (live Q6 lesson: "there"/
//  "from"/"and" displaced Khurana-specific content with résumé junk — a stopword
//  contributes zero recall and only noise). Identifier-shaped tokens are always
//  kept — they are the atoms this product is named for.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("V1.1 U2.5 — FTSQuerySanitizer")
struct FTSQuerySanitizerTests {

    @Test("A punctuated identifier question sanitizes to informative quoted terms carrying the number")
    func punctuatedIdentifierQuestion() {
        let out = FTSQuerySanitizer.sanitize("What is Patent No. 555489?")
        #expect(out == "\"patent\" OR \"555489\"", "stopwords out, meaning kept: \(out)")
        // No raw FTS5 syntax leaks.
        #expect(!out.contains("?"))
        #expect(!out.contains("."))
    }

    @Test("F4.1 flood fixture (sanitizer): the Q6 query keeps ONLY the informative terms")
    func floodQuerySanitizesToInformativeTerms() {
        // Live Q6: "is there any invoice from Khurana and Khurana" — pre-F4.1 the
        // OR-join carried is/there/any/from/and, which match everything and
        // discriminate nothing. Post-F4.1: informative terms only, deduped.
        let out = FTSQuerySanitizer.sanitize("is there any invoice from Khurana and Khurana")
        #expect(out == "\"invoice\" OR \"khurana\"", "flood terms must be excluded, khurana deduped: \(out)")
    }

    @Test("FTS5 operator / punctuation input can never produce a syntax error — every token is quoted")
    func operatorsCannotLeak() {
        let nasty = "\"NEAR\" (foo* -bar) : baz^2 AND 555-489"
        let out = FTSQuerySanitizer.sanitize(nasty)
        let terms = out.components(separatedBy: " OR ")
        for term in terms {
            #expect(term.hasPrefix("\"") && term.hasSuffix("\""), "unquoted term leaked: \(term)")
        }
        #expect(out.contains("\"555\"") && out.contains("\"489\""), "digits survive as separate tokens")
    }

    @Test("Identifier-shaped tokens are ALWAYS kept, regardless of length")
    func identifiersAlwaysKept() {
        #expect(FTSQuerySanitizer.sanitize("2024") == "\"2024\"")
        #expect(FTSQuerySanitizer.sanitize("5") == "\"5\"", "a single digit is identifier-shaped, kept")
        #expect(FTSQuerySanitizer.sanitize("a1") == "\"a1\"", "mixed alnum is identifier-shaped, kept")
    }

    @Test("Empty / noise / all-stopword input → \"\" (the counted FTS abstention, no match-everything)")
    func degenerateInputs() {
        #expect(FTSQuerySanitizer.sanitize("") == "")
        #expect(FTSQuerySanitizer.sanitize("   ...?!  ") == "")
        #expect(FTSQuerySanitizer.sanitize("a b c") == "", "single-char alpha noise dropped")
        #expect(FTSQuerySanitizer.sanitize("is there any of the and") == "",
                "all-stopword query → keyword layer abstains gracefully")
    }

    @Test("Deterministic — same input yields the same expression")
    func deterministic() {
        let q = "Timeline of the patent 555489 filed in 2023"
        #expect(FTSQuerySanitizer.sanitize(q) == FTSQuerySanitizer.sanitize(q))
    }

    // MARK: - F4.1 DB-level flood fixture (red pre-F4.1, green post)

    @Test("DB flood fixture: a common-word chunk cannot swamp the Khurana chunk — it no longer matches at all")
    func dbFloodFixture() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("fts-flood-\(UUID().uuidString).sqlite")
        let db = try Database(url: tmp)
        try await SchemaMigrations.migrate(db)
        // FK scaffolding: one file, one KO (chunks_fts is trigger-synced on chunk insert).
        let fileID = UUID(), ko = UUID()
        try await db.exec("INSERT INTO files (id, url, source_type) VALUES (?, ?, ?);",
                          [.uuid(fileID), .text("file:///flood"), .text("text")])
        try await db.exec("""
        INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at)
        VALUES (?, ?, ?, ?, 0, 0);
        """, [.uuid(ko), .uuid(fileID), .text("text"), .text("flood corpus")])
        let repo = ChunksRepository(database: db)
        let floodID = UUID(), targetID = UUID()
        // The flood chunk is MADE of stopwords — pre-F4.1 it matched the Q6 query
        // on is/there/any/from/and (5 of 8 terms) and could outrank the target.
        try await db.exec("""
        INSERT INTO chunks (id, object_id, ordinal, text, char_start, char_end, created_at)
        VALUES (?, ?, 0, ?, 0, 100, 0);
        """, [.uuid(floodID), .uuid(ko),
              .text("is there any from and the to of on in at is there any from and the to of on in at")])
        try await db.exec("""
        INSERT INTO chunks (id, object_id, ordinal, text, char_start, char_end, created_at)
        VALUES (?, ?, 1, ?, 0, 100, 0);
        """, [.uuid(targetID), .uuid(ko),
              .text("Invoice from Khurana & Khurana, amount ₹20,000, dated 14/08/2024.")])

        let hits = try await repo.searchFTS("is there any invoice from Khurana and Khurana")
        let ids = hits.map(\.id)
        #expect(ids.contains(targetID), "the Khurana invoice chunk must surface")
        #expect(!ids.contains(floodID), "the stopword chunk must not match AT ALL post-F4.1")
    }
}
