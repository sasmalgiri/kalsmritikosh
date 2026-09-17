//
//  GenericFactMergeTests.swift
//  KalsmritikoshTests
//
//  Topic-Ledger Rebuild U1 (owner rule 1) — a fact is one-time-consumable per
//  distinct natural key. Proves: (a) canonicalize() collapses duplicate facts to
//  one row with the distinct-document count; (b) the repository's mergeUpsert
//  writes ONE canonical row when the same fact arrives from 3 documents, instead
//  of the 3 (→ historically 24×) duplicate rows that bloated the live ledger.
//

import Testing
import Foundation
@testable import Kalsmritikosh

@Suite("Topic-Ledger U1 — fact merge / one-per-distinct", .serialized)
struct GenericFactMergeTests {

    private func fact(subject: UUID, value: String, block: UUID, conf: Double = 0.7) -> GenericFact {
        GenericFact(subjectID: subject, subjectLabel: "Subject",
                    field: "role", value: value, unit: nil,
                    assessment: EvidenceAssessment(basis: .sourceAsserted, origin: .sourceExtraction),
                    confidence: conf, sourceBlockIDs: [block])
    }

    @Test func canonicalizeCollapsesDuplicatesAndCountsSources() {
        let subj = UUID()
        let facts = [fact(subject: subj, value: "Director", block: UUID(), conf: 0.6),
                     fact(subject: subj, value: "Director", block: UUID(), conf: 0.9),
                     fact(subject: subj, value: "Director", block: UUID(), conf: 0.7)]
        let canon = GenericFact.canonicalize(facts)
        #expect(canon.count == 1)
        #expect(canon[0].sourceBlockIDs.count == 3)        // union of all three documents
        #expect(canon[0].sourceCount == 3)
        #expect(canon[0].confidence == 0.9)                // highest kept
        #expect(canon[0].id == facts[0].id)                // earliest id is canonical
    }

    @Test func differentValuesStayDistinct() {
        let subj = UUID()
        let canon = GenericFact.canonicalize([
            fact(subject: subj, value: "Director", block: UUID()),
            fact(subject: subj, value: "Applicant", block: UUID()),
        ])
        #expect(canon.count == 2)
    }

    @Test func mergeUpsertWritesOneCanonicalRowForThreeDocuments() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try Database(url: dir.appendingPathComponent("db.sqlite"))
        try await SchemaMigrations.migrate(db)
        let repo = GenericFactRepository(database: db)

        let subj = UUID()
        try await repo.mergeUpsert(fact(subject: subj, value: "Director", block: UUID(), conf: 0.6))
        try await repo.mergeUpsert(fact(subject: subj, value: "Director", block: UUID(), conf: 0.9))
        try await repo.mergeUpsert(fact(subject: subj, value: "Director", block: UUID(), conf: 0.7))

        let rows = try await repo.facts(field: "role", limit: 50)
        #expect(rows.count == 1, "3 documents asserting the same fact must be ONE canonical row")
        #expect(rows[0].sourceBlockIDs.count == 3, "all three source blocks are retained")
        #expect(rows[0].confidence == 0.9)
    }
}
