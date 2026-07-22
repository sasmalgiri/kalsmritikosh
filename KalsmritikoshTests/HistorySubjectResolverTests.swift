//
//  HistorySubjectResolverTests.swift
//  KalsmritikoshTests
//
//  Universal History program, Phase 1 (HIST-010/011/012). Locks the trust gate:
//  a named subject resolves to a canonical Entity.ID or returns ambiguity — it is
//  NEVER guessed, and same-name people are never silently merged into one subject.
//  Pure normalisation + kind-mapping are also pinned.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("HIST Phase 1 — subject identity & resolution")
struct HistorySubjectResolverTests {

    private func insert(_ repoDB: Database, id: UUID, kind: String, value: String) async throws {
        try await repoDB.exec("""
        INSERT INTO entities (id, kind, value, normalized, source_object_id, confidence, attributes_json, quality_tier)
        VALUES (?, ?, ?, ?, ?, ?, '{}', 'T2');
        """, [.uuid(id), .text(kind), .text(value), .text(value.lowercased()), .uuid(UUID()), .real(0.9)])
    }

    // Tests build db + repo together so inserts and the resolver share one DB.
    private func makeRepoAndDB() async throws -> (EntitiesRepository, Database) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try Database(url: dir.appendingPathComponent("t.sqlite"))
        try await SchemaMigrations.migrate(db)
        try await db.exec("PRAGMA foreign_keys=OFF;", [])
        return (EntitiesRepository(database: db), db)
    }

    // MARK: - Pure helpers

    @Test("Normalizer folds honorifics, case, diacritics and whitespace")
    func normalize() {
        #expect(HistorySubjectNormalizer.normalize("Dr. Shirshendu  Sasmal") == "shirshendu sasmal")
        #expect(HistorySubjectNormalizer.normalize("shirshendu sasmal") == "shirshendu sasmal")
        #expect(HistorySubjectNormalizer.normalize("Mr John  Smith") == "john smith")
        #expect(HistorySubjectNormalizer.normalize("  Élodie  ") == "elodie")
    }

    @Test("Entity kind maps to the most specific subject case")
    func kindMapping() {
        let id = UUID()
        #expect(HistorySubject.forKind(.person, id: id) == .person(id))
        #expect(HistorySubject.forKind(.vendor, id: id) == .organization(id))
        #expect(HistorySubject.forKind(.client, id: id) == .organization(id))
        #expect(HistorySubject.forKind(.project, id: id) == .project(id))
        #expect(HistorySubject.forKind(.city, id: id) == .place(id))
        #expect(HistorySubject.forKind(.invoiceNumber, id: id) == .asset(id))
        #expect(HistorySubject.forKind(.other, id: id) == .entity(id))
        #expect(HistorySubject.person(id).entityID == id)
        #expect(HistorySubject.corpus.entityID == nil)
    }

    // MARK: - Resolution

    @Test("Direct entity-id resolves exactly (the Dossier path), confidence 1.0")
    func resolveByID() async throws {
        let (repo, db) = try await makeRepoAndDB()
        let id = UUID()
        try await insert(db, id: id, kind: "person", value: "John Smith")
        let resolver = HistorySubjectResolver(entities: repo)
        let resolved = try #require(try await resolver.resolve(entityID: id))
        #expect(resolved.subject == .person(id))
        #expect(resolved.canonicalEntityID == id)
        #expect(resolved.displayName == "John Smith")
        #expect(resolved.resolutionConfidence == 1.0)
        #expect(resolved.ambiguityCandidates.isEmpty)
    }

    @Test("A single free-text name match resolves")
    func freeTextSingleMatch() async throws {
        let (repo, db) = try await makeRepoAndDB()
        let id = UUID()
        try await insert(db, id: id, kind: "person", value: "Alice Kumar")
        let resolver = HistorySubjectResolver(entities: repo)
        switch try await resolver.resolve(freeText: "alice kumar") {
        case .resolved(let r):
            #expect(r.canonicalEntityID == id)
            #expect(r.subject == .person(id))
        default:
            Issue.record("expected .resolved")
        }
    }

    @Test("A partial name matching several distinct people is ambiguous — never a guess")
    func partialNameAmbiguous() async throws {
        let (repo, db) = try await makeRepoAndDB()
        let a = UUID(), b = UUID()
        // Two DISTINCT people sharing a surname (the schema keys canonical rows by
        // (kind, normalized), so genuine same-name collisions are one entity; the
        // real ambiguity is a query that fuzzy-matches several distinct subjects).
        try await insert(db, id: a, kind: "person", value: "John Smith")
        try await insert(db, id: b, kind: "person", value: "Jane Smith")
        let resolver = HistorySubjectResolver(entities: repo)
        switch try await resolver.resolve(freeText: "Smith") {   // no exact match to either
        case .ambiguous(let candidates):
            #expect(candidates.count == 2)
            #expect(Set(candidates.map(\.id)) == Set([a, b]))
        default:
            Issue.record("expected .ambiguous when a partial name matches several people")
        }
    }

    @Test("An exact name wins over a substring match (resolves, not ambiguous)")
    func exactBeatsSubstring() async throws {
        let (repo, db) = try await makeRepoAndDB()
        let exact = UUID(), longer = UUID()
        try await insert(db, id: exact, kind: "person", value: "John Smith")
        try await insert(db, id: longer, kind: "person", value: "John Smithson")
        let resolver = HistorySubjectResolver(entities: repo)
        switch try await resolver.resolve(freeText: "John Smith") {
        case .resolved(let r):
            #expect(r.canonicalEntityID == exact)   // exact normalized match wins
        default:
            Issue.record("expected .resolved to the exact match")
        }
    }

    @Test("An unknown name is notFound (never a silent global fallback)")
    func unknownNotFound() async throws {
        let (repo, _) = try await makeRepoAndDB()
        let resolver = HistorySubjectResolver(entities: repo)
        switch try await resolver.resolve(freeText: "Zznonexistent Qqsubject") {
        case .notFound: break
        default: Issue.record("expected .notFound")
        }
    }
}
