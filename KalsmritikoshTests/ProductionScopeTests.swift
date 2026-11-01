//
//  ProductionScopeTests.swift
//  KalsmritikoshTests
//
//  Practitioner review 2026-11-02, Lawyer blocker: a production is for ONE matter. A document privileged
//  in another matter is never produced, slip-sheeted or logged in this one.
//

import Testing
import Foundation
@testable import Kalsmritikosh

@Suite("Legal production is scoped to one matter", .serialized)
struct ProductionScopeTests {

    @Test("Case B's production holds only case B's documents; case A's privileged document appears only in case A's")
    func scopedToMatter() async throws {
        let f = try await CaseErasureTests.boot()
        defer { try? FileManager.default.removeItem(at: f.temp) }
        let exclusive = try #require(try await f.db.query("SELECT id FROM knowledge_objects WHERE file_id = ? LIMIT 1;", [.uuid(f.exclusiveFile)]).first?.uuid(0))
        let shared = try #require(try await f.db.query("SELECT id FROM knowledge_objects WHERE file_id = ? LIMIT 1;", [.uuid(f.sharedFile)]).first?.uuid(0))
        let codes = ReviewCodesRepository(database: f.db)
        try await codes.setCode(.privileged, for: exclusive)   // privileged — in case A only
        try await codes.setCode(.responsive, for: shared)      // responsive — in both cases

        let b = await f.state.productionDocuments(tag: nil, caseID: f.caseB)
        #expect(b.map(\.id) == [shared], "case B never sees case A's privileged document, not even as a slip sheet")
        #expect(b.allSatisfy { !$0.privileged })

        let a = await f.state.productionDocuments(tag: nil, caseID: f.caseA)
        #expect(Set(a.map(\.id)) == [exclusive, shared])
        #expect(a.first { $0.id == exclusive }?.privileged == true, "withheld with a slip sheet in its own matter")

        // A matter that does not exist produces nothing (no ledger-wide fallback).
        #expect(await f.state.productionDocuments(tag: nil, caseID: UUID()).isEmpty)
    }
}
