//
//  ClaimEngineTests.swift
//  KalsmritikoshTests
//
//  PA-009 (persona-v2 Stage 1). The shared Claim engine: migration v63, a canonical
//  persona-neutral Claim that references source truth (never copies it) and binds to the
//  five-dimension EvidenceAssessment + AssertabilityPolicy (never a forked enum), plus the
//  evidence / lineage / contradiction / review / usage links. Locks: round-trip fidelity,
//  idempotent re-save, subject scope isolation (no leakage), persona invariance (no persona
//  field), the evidence reverse index, and the append-only review/usage ledgers.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PA-009 — shared Claim engine")
struct ClaimEngineTests {

    private func freshDB() async throws -> Database {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("claim-\(UUID().uuidString).sqlite")
        let db = try Database(url: tmp)
        try await SchemaMigrations.migrate(db)
        return db
    }

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func sampleClaim(subject: UUID? = nil,
                             assessment: EvidenceAssessment? = nil,
                             evidence: [EvidenceReference]? = nil,
                             derivedFrom: [DerivedReference]? = nil,
                             contradictionGroupID: UUID? = nil) -> Claim {
        Claim(
            subjectID: subject, subjectLabel: "Subject A",
            statement: "Employer is Orchid Labs",
            assessment: assessment ?? EvidenceAssessment(basis: .sourceAsserted, origin: .sourceExtraction),
            confidence: 0.82,
            evidence: evidence ?? [EvidenceReference(objectID: UUID(), blockID: UUID(),
                                                     assertionID: UUID(), role: .supports)],
            derivedFrom: derivedFrom ?? [DerivedReference(kind: .assertion, id: UUID()),
                                         DerivedReference(kind: .historyItem, id: UUID())],
            contradictionGroupID: contradictionGroupID, createdAt: t0)
    }

    @Test("Migration reaches v63 (claims table + links exist)")
    func migration() async throws {
        let db = try await freshDB()
        #expect(try await db.currentUserVersion() == SchemaMigrations.latestVersion)
        #expect(SchemaMigrations.latestVersion == 63)
        #expect(SchemaMigrations.migrationListIsConsistent)
    }

    @Test("A claim round-trips with its assessment, evidence, and lineage intact")
    func roundTrip() async throws {
        let repo = ClaimRepository(database: try await freshDB())
        let original = sampleClaim(
            subject: UUID(),
            assessment: EvidenceAssessment(basis: .directlyObserved, review: .confirmed,
                                           origin: .userCreated, availability: .present,
                                           conflict: .none),
            contradictionGroupID: UUID())
        try await repo.save(original)
        let loaded = try #require(try await repo.claim(id: original.id))

        #expect(loaded.id == original.id)
        #expect(loaded.subjectID == original.subjectID)
        #expect(loaded.subjectLabel == original.subjectLabel)
        #expect(loaded.statement == original.statement)
        #expect(loaded.assessment == original.assessment)          // all five dimensions
        #expect(loaded.confidence == original.confidence)
        #expect(loaded.contradictionGroupID == original.contradictionGroupID)
        #expect(loaded.createdAt == original.createdAt)
        #expect(Set(loaded.evidence) == Set(original.evidence))    // order-independent
        #expect(Set(loaded.derivedFrom) == Set(original.derivedFrom))
    }

    @Test("Re-saving the same claim id is idempotent (no duplicate evidence/lineage rows)")
    func idempotentResave() async throws {
        let repo = ClaimRepository(database: try await freshDB())
        let c = sampleClaim(subject: UUID())
        try await repo.save(c)
        try await repo.save(c)                                     // save twice
        #expect(try await repo.count() == 1)
        let loaded = try #require(try await repo.claim(id: c.id))
        #expect(loaded.evidence.count == c.evidence.count)         // not doubled
        #expect(loaded.derivedFrom.count == c.derivedFrom.count)
    }

    @Test("Claims are subject-scoped: querying one subject never returns another's")
    func subjectScopeNoLeakage() async throws {
        let repo = ClaimRepository(database: try await freshDB())
        let a = UUID(), b = UUID()
        try await repo.save(sampleClaim(subject: a))
        try await repo.save(sampleClaim(subject: a))
        try await repo.save(sampleClaim(subject: b))
        let forA = try await repo.claims(subjectID: a)
        let forB = try await repo.claims(subjectID: b)
        #expect(forA.count == 2)
        #expect(forB.count == 1)
        #expect(forA.allSatisfy { $0.subjectID == a })             // no B claim leaked into A
        #expect(Set(forA.map(\.id)).isDisjoint(with: Set(forB.map(\.id))))
    }

    @Test("A Claim carries no persona (or workspace) field — persona invariance is structural")
    func personaInvariance() throws {
        let enc = JSONEncoder()
        let c = sampleClaim(subject: UUID(), contradictionGroupID: UUID())
        let obj = try JSONSerialization.jsonObject(with: try enc.encode(c)) as! [String: Any]
        for key in obj.keys {
            #expect(!key.lowercased().contains("persona"), "Claim must not carry a persona field")
            #expect(!key.lowercased().contains("workspace"), "Claim must not carry a workspace field")
        }
        // The one canonical claim decodes back identically regardless of any caller context.
        let back = try JSONDecoder().decode(Claim.self, from: try enc.encode(c))
        #expect(back == c)
    }

    @Test("The evidence reverse index finds every claim citing a changed source object")
    func evidenceReverseIndex() async throws {
        let repo = ClaimRepository(database: try await freshDB())
        let sharedObject = UUID()
        let c1 = sampleClaim(subject: UUID(),
                             evidence: [EvidenceReference(objectID: sharedObject, blockID: UUID())])
        let c2 = sampleClaim(subject: UUID(),
                             evidence: [EvidenceReference(objectID: sharedObject, blockID: UUID())])
        let c3 = sampleClaim(subject: UUID(),
                             evidence: [EvidenceReference(objectID: UUID(), blockID: UUID())])
        try await repo.save(c1); try await repo.save(c2); try await repo.save(c3)
        let citing = Set(try await repo.claimIDs(citingObject: sharedObject))
        #expect(citing == [c1.id, c2.id])
    }

    @Test("Claim ↔ Contradiction links are many-to-many and traversable both ways")
    func contradictionLinks() async throws {
        let db = try await freshDB()
        let claims = ClaimRepository(database: db)
        let links = ClaimContradictionRepository(database: db)
        let c = sampleClaim(subject: UUID())
        try await claims.save(c)
        let cont1 = UUID(), cont2 = UUID()
        try await links.link(claimID: c.id, contradictionID: cont1)
        try await links.link(claimID: c.id, contradictionID: cont2)
        try await links.link(claimID: c.id, contradictionID: cont1)   // idempotent
        #expect(Set(try await links.contradictionIDs(claimID: c.id)) == [cont1, cont2])
        #expect(try await links.claimIDs(contradictionID: cont1) == [c.id])
        try await links.unlink(claimID: c.id, contradictionID: cont1)
        #expect(try await links.contradictionIDs(claimID: c.id) == [cont2])
    }

    @Test("Reviews are append-only; the current disposition is the latest recorded one")
    func reviewLedger() async throws {
        let db = try await freshDB()
        let claims = ClaimRepository(database: db)
        let reviews = ClaimReviewRepository(database: db)
        let c = sampleClaim(subject: UUID())
        try await claims.save(c)
        #expect(try await reviews.currentDisposition(claimID: c.id) == .unreviewed)  // none yet
        try await reviews.record(ClaimReview(claimID: c.id, disposition: .disputed,
                                             reviewer: "u", reason: "conflicts", reviewedAt: t0))
        try await reviews.record(ClaimReview(claimID: c.id, disposition: .confirmed,
                                             reviewer: "u", reviewedAt: t0.addingTimeInterval(60)))
        #expect(try await reviews.currentDisposition(claimID: c.id) == .confirmed)   // latest wins
        let history = try await reviews.reviews(claimID: c.id)
        #expect(history.count == 2)                                                  // both preserved
        #expect(history.first?.disposition == .confirmed)                            // newest first
    }

    @Test("Usage is an append-only ledger of where a claim was used")
    func usageLedger() async throws {
        let db = try await freshDB()
        let claims = ClaimRepository(database: db)
        let usage = ClaimUsageRepository(database: db)
        let c = sampleClaim(subject: UUID())
        try await claims.save(c)
        let run = UUID()
        try await usage.record(ClaimUsage(claimID: c.id, context: .workProduct, referenceID: run, usedAt: t0))
        try await usage.record(ClaimUsage(claimID: c.id, context: .export, referenceID: run,
                                          usedAt: t0.addingTimeInterval(30)))
        #expect(try await usage.usageCount(claimID: c.id) == 2)
        let list = try await usage.usage(claimID: c.id)
        #expect(list.first?.context == .export)                    // newest first
        #expect(list.allSatisfy { $0.referenceID == run })
    }

    @Test("A claim's assessment drives AssertabilityPolicy — not a forked status enum")
    func bindsToAssertabilityPolicy() throws {
        // directlyObserved + an exact locator → assertAsFact.
        let observed = sampleClaim(
            assessment: EvidenceAssessment(basis: .directlyObserved, origin: .sourceExtraction))
        let factCtx = AssertabilityContext(assessment: observed.assessment,
                                           exactEvidenceCount: 1, independentEvidenceGroupCount: 1,
                                           hasExactLocator: true, hasReproducibleDerivation: false)
        #expect(AssertabilityPolicy.evaluate(factCtx) == .assertAsFact)

        // inferred → presentAsInference (labelled, never a silent fact).
        let inferred = sampleClaim(
            assessment: EvidenceAssessment(basis: .inferred, origin: .modelProposed))
        let infCtx = AssertabilityContext(assessment: inferred.assessment,
                                          exactEvidenceCount: 1, independentEvidenceGroupCount: 1,
                                          hasExactLocator: true, hasReproducibleDerivation: false)
        let decision = AssertabilityPolicy.evaluate(infCtx)
        #expect(decision == .presentAsInference)
        #expect(decision.isAssertiveDecision == false)
    }
}
