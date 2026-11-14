//
//  ContradictionStableIdentityTests.swift
//  KalsmritikoshTests
//
//  UI walk 2026-11-07 — an archive rescan re-inserted every contradiction with a new random id, so the
//  decisions recorded against the old ids were orphaned (items read "Not reviewed yet" after relaunch).
//  The rescan now assigns ids from the finding's identity, so the same finding keeps its id.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Archive-scan contradictions keep their identity across rescans")
struct ContradictionStableIdentityTests {
    let docA = UUID(), docB = UUID()

    func finding(_ description: String, _ a: String, _ b: String, docs: (UUID?, UUID?)? = nil) -> Contradiction {
        let d = docs ?? (docA, docB)
        return Contradiction(kind: .date, description: description, claimA: a, claimB: b, evidenceA: d.0, evidenceB: d.1)
    }

    @Test("The same findings from two scans (fresh random ids, any order) get the same ids")
    func sameFindingSameID() {
        let scan1 = [finding("Conflicting dates for \"Delivery delayed\"", "3 March", "9 March"),
                     finding("Conflicting dates for \"Contract modified\"", "1 May", "4 May")]
        let scan2 = [finding("Conflicting dates for \"Contract modified\"", "1 May", "4 May"),
                     finding("Conflicting dates for \"Delivery delayed\"", "3 March", "9 March")]
        #expect(scan1.map(\.id) != scan2.reversed().map(\.id), "the detector's own ids are random")
        let ids1 = Dictionary(uniqueKeysWithValues: Contradiction.stableIdentities(scan1).map { ($0.description, $0.id) })
        let ids2 = Dictionary(uniqueKeysWithValues: Contradiction.stableIdentities(scan2).map { ($0.description, $0.id) })
        #expect(ids1 == ids2)
    }

    @Test("The side reported first does not matter; other documents or other claim text are another finding")
    func identityIsKindDescriptionDocumentsAndClaims() {
        let before = Contradiction.stableIdentities([finding("Conflicting dates for \"Delivery delayed\"", "3 March", "9 March")])[0]
        let swapped = Contradiction.stableIdentities([finding("Conflicting dates for \"Delivery delayed\"", "9 March", "3 March",
                                                              docs: (docB, docA))])[0]
        let revised = Contradiction.stableIdentities([finding("Conflicting dates for \"Delivery delayed\"", "3 March", "12 March")])[0]
        let otherDocs = Contradiction.stableIdentities([finding("Conflicting dates for \"Delivery delayed\"", "3 March", "9 March",
                                                                docs: (UUID(), docB))])[0]
        #expect(before.id == swapped.id, "the pair of documents and the pair of claims, not their order")
        #expect(before.id != revised.id)
        #expect(before.id != otherDocs.id)
        #expect(swapped.claimA == "9 March", "content is carried unchanged")
    }

    @Test("Two same-description findings between the same documents keep their own ids whatever the order, orientation or company")
    func sameDescriptionFindingsDoNotSwap() {
        let a = finding("Conflicting dates for \"Contract modified\"", "1 May", "4 May")
        let b = finding("Conflicting dates for \"Contract modified\"", "2 June", "9 June")
        let flippedA = finding("Conflicting dates for \"Contract modified\"", "4 May", "1 May", docs: (docB, docA))
        let first = Contradiction.stableIdentities([a, b])
        let later = Contradiction.stableIdentities([b, flippedA])
        let idA = first.first { $0.claimA == "1 May" }?.id, idB = first.first { $0.claimA == "2 June" }?.id
        #expect(idA != nil && idB != nil && idA != idB)
        #expect(later.first { $0.claimA == "4 May" }?.id == idA && later.first { $0.claimA == "2 June" }?.id == idB)
        #expect(Contradiction.stableIdentities([flippedA])[0].id == idA, "a finding's id does not depend on which other findings exist")
        #expect(Contradiction.stableIdentities([a, a]).count == 1, "the very same finding twice is one row")
    }

    @Test("A decision recorded against an item still matches after a rescan replaces the rows")
    func decisionSurvivesRescan() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let repo = ContradictionsRepository(database: db)
        let scan = { [self] in [finding("Conflicting dates for \"Delivery delayed\"", "3 March", "9 March")] }
        await repo.insertMany(Contradiction.stableIdentities(scan()))
        let decidedID = try #require(await repo.all().first?.id)
        // The rescan: clear its rows, insert what it finds again (fresh detector ids).
        await repo.clearKeepingCaseChecks()
        await repo.insertMany(Contradiction.stableIdentities(scan()))
        #expect(await repo.all().map(\.id) == [decidedID])
    }
}
