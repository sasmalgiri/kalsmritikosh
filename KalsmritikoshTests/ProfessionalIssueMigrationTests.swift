//
//  ProfessionalIssueMigrationTests.swift
//  KalsmritikoshTests
//
//  OPS-001 — schema v68 (professional Issue Engine). Locks: a fresh database reaches v68 with the
//  three issue tables; a GENUINE v67→v68 migration preserves every existing row (era-seeded via
//  the fixture builder) and adds ONLY the new tables; integrity + foreign-key checks pass; and no
//  canonical table (claims / contradictions / gap_nodes / events) gained an Issue column.
//  (Milestone coverage 1..68 lives in MigrationMatrixTests, which now targets v68.)
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("OPS-001 — professional issue schema (v68)")
struct ProfessionalIssueMigrationTests {

    private let issueTables = ["professional_issues", "professional_issue_links", "professional_issue_reviews"]

    @Test("A fresh database reaches v68 with the three issue tables and clean integrity")
    func freshV68() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 0)
        try await SchemaMigrations.migrate(db)
        #expect(try await db.currentUserVersion() == 68)
        for t in issueTables {
            #expect(try await MigrationFixtureBuilder.tableExists(db, t), "\(t) missing")
        }
        #expect(try await MigrationFaultHarness.integrityOK(db))
        #expect(try await MigrationFaultHarness.foreignKeyViolationCount(db) == 0)
    }

    @Test("A genuine v67→v68 migration preserves all existing rows and adds only the new tables")
    func v67ToV68Preserves() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 67)
        #expect(try await db.currentUserVersion() == 67)
        let snap = try await MigrationFixtureBuilder.seedPreservationRows(into: db, forVersion: 67)
        for t in issueTables {
            #expect(try await MigrationFixtureBuilder.tableExists(db, t) == false, "\(t) already present at v67")
        }

        try await SchemaMigrations.migrate(db)      // 67 → 68

        #expect(try await db.currentUserVersion() == 68)
        for t in issueTables {
            #expect(try await MigrationFixtureBuilder.tableExists(db, t), "\(t) missing after v68")
        }
        let failures = try await snap.failures(in: db)
        #expect(failures.isEmpty, "v67→v68 lost rows: \(failures)")
        #expect(try await MigrationFaultHarness.integrityOK(db))
        #expect(try await MigrationFaultHarness.foreignKeyViolationCount(db) == 0)

        // v68 must not have touched canonical tables — no Issue columns anywhere canonical.
        for (table, forbidden) in [("claims", "issue"), ("contradictions", "issue"),
                                   ("gap_nodes", "issue"), ("events", "issue")] {
            let cols = try await MigrationFixtureBuilder.columns(db, table)
            #expect(!cols.contains { $0.lowercased().contains(forbidden) },
                    "\(table) gained an issue column")
        }
    }
}
