//
//  LedgerQueryTests.swift
//  KalsmritikoshTests
//
//  Proves the query compiler is safe (SELECT-only, parameterized, whitelisted)
//  and that the read-only repository returns correct rows against a real ledger.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("LedgerQuery — compiler safety")
struct LedgerQueryCompilerTests {

    @Test("Unknown subject compiles to nil")
    func unknownSubject() {
        #expect(LedgerQueryCompiler.compile(LedgerQuery(subjectID: "not-a-subject")) == nil)
    }

    @Test("A text 'contains' filter is parameterized — value is never in the SQL")
    func containsIsParameterized() throws {
        let q = LedgerQuery(subjectID: "people",
                            filters: [QueryFilter(fieldKey: "name", op: .contains, value: "Alice")],
                            limit: 100)
        let c = try #require(LedgerQueryCompiler.compile(q))
        #expect(c.sql.hasPrefix("SELECT "))
        #expect(c.sql.contains("FROM entities"))
        #expect(c.sql.contains("value LIKE ? ESCAPE"))
        #expect(!c.sql.localizedCaseInsensitiveContains("Alice"), "user value must not be interpolated into SQL")
        // Bound value carries the LIKE wildcards; display shows it inlined.
        #expect(c.bindings.contains(.text("%Alice%")))
        #expect(c.displaySQL.contains("'%Alice%'"))
        // Last binding is always the bounded LIMIT.
        #expect(c.bindings.last == .integer(100))
    }

    @Test("Only SELECT is ever produced; no write/DDL keywords")
    func selectOnly() throws {
        for subject in LedgerQueryCatalog.subjects {
            let c = try #require(LedgerQueryCompiler.compile(LedgerQuery(subjectID: subject.id)))
            let upper = c.sql.uppercased()
            #expect(upper.hasPrefix("SELECT "))
            // Spaced keywords so column names like CREATED_AT don't false-match.
            for bad in ["INSERT ", "UPDATE ", "DELETE ", "DROP ", "ALTER ", "CREATE ", "PRAGMA ", "ATTACH "] {
                #expect(!upper.contains(bad), "\(subject.id) SQL contained \(bad)")
            }
            // A single statement — the only semicolon is the terminator.
            #expect(c.sql.filter { $0 == ";" }.count == 1)
            #expect(c.sql.hasSuffix("LIMIT ?;"))
        }
    }

    @Test("Number and choice filters bind the right value types")
    func typedBindings() throws {
        let q = LedgerQuery(subjectID: "people", filters: [
            QueryFilter(fieldKey: "confidence", op: .greaterThan, value: "0.5"),
            QueryFilter(fieldKey: "kind", op: .isEqual, value: "organization")
        ])
        let c = try #require(LedgerQueryCompiler.compile(q))
        #expect(c.sql.contains("confidence > ?"))
        #expect(c.sql.contains("kind = ?"))
        #expect(c.bindings.contains(.real(0.5)))
        #expect(c.bindings.contains(.text("organization")))
    }

    @Test("Limit is clamped to 1...1000")
    func limitClamp() throws {
        let hi = try #require(LedgerQueryCompiler.compile(LedgerQuery(subjectID: "events", limit: 99999)))
        #expect(hi.bindings.last == .integer(1000))
        let lo = try #require(LedgerQueryCompiler.compile(LedgerQuery(subjectID: "events", limit: 0)))
        #expect(lo.bindings.last == .integer(1))
    }

    @Test("A malformed number filter is dropped, not injected")
    func badNumberDropped() throws {
        let q = LedgerQuery(subjectID: "people",
                            filters: [QueryFilter(fieldKey: "confidence", op: .greaterThan, value: "0.5); DROP TABLE entities;--")])
        let c = try #require(LedgerQueryCompiler.compile(q))
        #expect(!c.sql.uppercased().contains("DROP"))
        // The filter didn't parse as a number, so it's simply absent.
        #expect(!c.sql.contains("confidence >"))
    }
}

@Suite("LedgerQuery — run over a real ledger")
struct LedgerQueryRepositoryTests {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func db() async throws -> Database {
        let d = try await MigrationFixtureBuilder.database(atVersion: 0)
        try await SchemaMigrations.migrate(d)
        return d
    }

    @Test("People query returns matching entities with labelled columns")
    func peopleQuery() async throws {
        let db = try await db()
        let fileID = UUID(), koID = UUID()
        try await db.exec("INSERT INTO files (id, url, source_type) VALUES (?,?,?);",
                          [.uuid(fileID), .text("file://\(fileID)"), .text("pdf")])
        try await db.exec("""
        INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at)
        VALUES (?,?,?,?,?,?);
        """, [.uuid(koID), .uuid(fileID), .text("pdf"), .text("x"), .date(t0), .date(t0)])
        for (kind, value) in [("person", "Alice Martin"), ("organization", "Acme Corp"), ("person", "Bob Chen")] {
            try await db.exec("""
            INSERT INTO entities (id, kind, value, normalized, source_object_id, confidence, attributes_json)
            VALUES (?,?,?,?,?,?, '{}');
            """, [.uuid(UUID()), .text(kind), .text(value), .text(value.lowercased()), .uuid(koID), .real(0.8)])
        }

        let repo = LedgerQueryRepository(database: db)
        let q = LedgerQuery(subjectID: "people",
                            filters: [QueryFilter(fieldKey: "name", op: .contains, value: "li")]) // Alice
        let result = try await repo.run(q)

        #expect(result.columns.map(\.label) == ["Name", "Kind", "Confidence"])
        #expect(result.rows.contains { $0.first == "Alice Martin" })
        #expect(!result.rows.contains { $0.first == "Bob Chen" })
        #expect(result.sql.contains("LIKE '%li%'"))
    }

    @Test("Documents query excludes privileged files")
    func documentsExcludePrivileged() async throws {
        let db = try await db()
        func addDoc(_ name: String, privileged: Int?) async throws {
            let f = UUID(), k = UUID()
            try await db.exec("INSERT INTO files (id, url, source_type) VALUES (?,?,?);",
                              [.uuid(f), .text("file:///\(name)"), .text("pdf")])
            if let p = privileged {
                try await db.exec("""
                INSERT INTO knowledge_objects (id, file_id, source_type, content, privileged, created_at, updated_at)
                VALUES (?,?,?,?,?,?,?);
                """, [.uuid(k), .uuid(f), .text("pdf"), .text("x"), .integer(Int64(p)), .date(t0), .date(t0)])
            } else {
                // Omit privileged → column default (the common ingest path).
                try await db.exec("""
                INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at)
                VALUES (?,?,?,?,?,?);
                """, [.uuid(k), .uuid(f), .text("pdf"), .text("x"), .date(t0), .date(t0)])
            }
        }
        try await addDoc("public.pdf", privileged: 0)
        try await addDoc("open.pdf", privileged: nil)
        try await addDoc("secret.pdf", privileged: 1)

        let result = try await LedgerQueryRepository(database: db).run(LedgerQuery(subjectID: "documents"))
        let files = Set(result.rows.compactMap { $0.first })
        #expect(files.contains("public.pdf"))
        #expect(files.contains("open.pdf"))
        #expect(!files.contains("secret.pdf"), "privileged documents must never appear")
    }
}
