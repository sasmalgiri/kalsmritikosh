//
//  ClaimSelectionServiceTests.swift
//  KalsmritikoshTests
//
//  PA-SEL — the deterministic claim selection/ordering service. Locks: subject and workspace
//  isolation (and NO global fallback); rejected-review claims resolve to a refusal the
//  composer drops; temporal anchors come from lineage (Event/TemporalClaim), never fabricated;
//  deterministic chronology order (dated < undated, start ascending, stable id tie-break);
//  undated placement; conflicting lineage → explicitly ambiguous; explicit-id selection;
//  independence keys resolved during preparation; and selection is persona-invariant.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PA-SEL — claim selection / ordering service")
struct ClaimSelectionServiceTests {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private struct Rig {
        let claims: ClaimRepository
        let reviews: ClaimReviewRepository
        let tclaims: TemporalClaimRepository
        let service: ClaimSelectionService
    }

    private func rig(keyProvider: (any SourceIndependenceKeyProvider)? = nil) async throws -> Rig {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sel-\(UUID().uuidString).sqlite")
        let db = try Database(url: tmp)
        try await SchemaMigrations.migrate(db)
        let claims = ClaimRepository(database: db)
        let reviews = ClaimReviewRepository(database: db)
        let resolver = ClaimResolver(claims: claims, reviews: reviews)
        let tclaims = TemporalClaimRepository(database: db)
        let events = EventsRepository(database: db)
        let service = ClaimSelectionService(claims: claims, resolver: resolver,
                                            temporalClaims: tclaims, events: events,
                                            independenceKeyProvider: keyProvider)
        return Rig(claims: claims, reviews: reviews, tclaims: tclaims, service: service)
    }

    /// Anchor via a TemporalClaim (tier 1 — no FK prerequisites). The Event tier shares the
    /// same finalize/order/ambiguity path, differing only in where start/precision come from.
    private func saveTemporalClaim(_ repo: TemporalClaimRepository, id: UUID, subject: UUID, start: Date) async throws {
        let tc = TemporalClaim(id: id, subjectID: subject, predicate: "p", object: .literal("x"),
                               validFrom: TemporalValue(start: start, precision: .day, confidence: 1.0),
                               status: .sourceAsserted, confidence: 0.8,
                               extractorID: "t", extractorVersion: "1", createdAt: t0)
        try await repo.insert(tc)
    }
    private func tcRef(_ id: UUID) -> DerivedReference { DerivedReference(kind: .temporalClaim, id: id) }

    @discardableResult
    private func saveClaim(_ repo: ClaimRepository, subject: UUID?, statement: String,
                           basis: EvidenceBasis = .sourceAsserted, lineage: [DerivedReference] = [],
                           evidenceObjectID: UUID = UUID(), id: UUID = UUID()) async throws -> UUID {
        let c = Claim(id: id, subjectID: subject, subjectLabel: "S", statement: statement,
                      assessment: EvidenceAssessment(basis: basis, origin: .sourceExtraction),
                      confidence: 0.8,
                      evidence: [EvidenceReference(objectID: evidenceObjectID, blockID: UUID(), sourceVersionID: UUID())],
                      derivedFrom: lineage, createdAt: t0)
        try await repo.save(c)
        return id
    }

    private func date(_ y: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(y) * 31_536_000) }

    // MARK: Scope isolation & no global fallback

    @Test("Subject scope returns only that subject's claims")
    func subjectIsolation() async throws {
        let r = try await rig()
        let a = UUID(), b = UUID()
        try await saveClaim(r.claims, subject: a, statement: "A1")
        try await saveClaim(r.claims, subject: a, statement: "A2")
        try await saveClaim(r.claims, subject: b, statement: "B1")
        let ctx = try await r.service.buildContext(scope: .subject(a), subjectLabel: "A")
        #expect(Set(ctx.selectedClaims.map { $0.resolved.claim.statement }) == ["A1", "A2"])
    }

    @Test("Workspace scope returns only member subjects' claims; a non-member is excluded")
    func workspaceIsolation() async throws {
        let r = try await rig()
        let a = UUID(), b = UUID(), ws = UUID()
        let objA = UUID()
        try await saveClaim(r.claims, subject: a, statement: "A1", evidenceObjectID: objA)
        try await saveClaim(r.claims, subject: b, statement: "B1")
        let ctx = try await r.service.buildContext(
            scope: .workspace(id: ws, memberSubjectIDs: [a], allowedObjectIDs: [objA]), subjectLabel: "WS")
        #expect(ctx.selectedClaims.map { $0.resolved.claim.statement } == ["A1"])
        #expect(ctx.workspaceID == ws)
    }

    @Test("No global fallback: unknown subject and empty workspace both select nothing")
    func noGlobalFallback() async throws {
        let r = try await rig()
        try await saveClaim(r.claims, subject: UUID(), statement: "X")
        try await saveClaim(r.claims, subject: UUID(), statement: "Y")
        let emptySubject = try await r.service.buildContext(scope: .subject(UUID()), subjectLabel: "?")
        #expect(emptySubject.selectedClaims.isEmpty)
        let emptyWorkspace = try await r.service.buildContext(
            scope: .workspace(id: UUID(), memberSubjectIDs: [], allowedObjectIDs: []), subjectLabel: "?")
        #expect(emptyWorkspace.selectedClaims.isEmpty)          // NOT all claims
    }

    // MARK: B4 — workspace evidence-source boundary

    @Test("Workspace scope: same subject, only the claim backed by an in-scope source renders")
    func sourceBoundaryExcludesOutsideEvidence() async throws {
        let r = try await rig()
        let s = UUID(), ws = UUID()
        let inside = UUID(), outside = UUID()
        try await saveClaim(r.claims, subject: s, statement: "inside", evidenceObjectID: inside)
        try await saveClaim(r.claims, subject: s, statement: "outside", evidenceObjectID: outside)
        let ctx = try await r.service.buildContext(
            scope: .workspace(id: ws, memberSubjectIDs: [s], allowedObjectIDs: [inside]), subjectLabel: "WS")
        #expect(ctx.selectedClaims.map { $0.resolved.claim.statement } == ["inside"])
    }

    @Test("Workspace scope: a claim citing a mix of in- and out-of-scope sources is excluded whole")
    func sourceBoundaryExcludesMixedEvidence() async throws {
        let r = try await rig()
        let s = UUID(), ws = UUID()
        let inside = UUID(), outside = UUID()
        // Two evidence refs — one inside, one outside → conservative all-in-scope excludes it whole
        // (canonical evidence is NOT trimmed; the whole claim is dropped rather than partly rendered).
        let mixed = Claim(subjectID: s, subjectLabel: "S", statement: "mixed",
                          assessment: EvidenceAssessment(basis: .sourceAsserted, origin: .sourceExtraction),
                          confidence: 0.8,
                          evidence: [EvidenceReference(objectID: inside, blockID: UUID(), sourceVersionID: UUID()),
                                     EvidenceReference(objectID: outside, blockID: UUID(), sourceVersionID: UUID())],
                          createdAt: t0)
        try await r.claims.save(mixed)
        let ctx = try await r.service.buildContext(
            scope: .workspace(id: ws, memberSubjectIDs: [s], allowedObjectIDs: [inside]), subjectLabel: "WS")
        #expect(ctx.selectedClaims.isEmpty)
    }

    @Test("Workspace scope: a member whose only claim is out-of-scope yields no material rows")
    func memberWithoutWorkspaceBackedClaim() async throws {
        let r = try await rig()
        let s = UUID(), ws = UUID()
        try await saveClaim(r.claims, subject: s, statement: "only-outside", evidenceObjectID: UUID())
        let ctx = try await r.service.buildContext(
            scope: .workspace(id: ws, memberSubjectIDs: [s], allowedObjectIDs: [UUID()]), subjectLabel: "WS")
        #expect(ctx.selectedClaims.isEmpty)
    }

    @Test("Explicit-id scope selects exactly the requested claims")
    func explicitIDSelection() async throws {
        let r = try await rig()
        let s = UUID()
        let id1 = try await saveClaim(r.claims, subject: s, statement: "one")
        _        = try await saveClaim(r.claims, subject: s, statement: "two")
        let id3 = try await saveClaim(r.claims, subject: s, statement: "three")
        let ctx = try await r.service.buildContext(scope: .explicitClaimIDs([id1, id3]), subjectLabel: "S")
        #expect(Set(ctx.selectedClaims.map { $0.resolved.claim.statement }) == ["one", "three"])
    }

    // MARK: Review

    @Test("A rejected-review claim resolves to a refusal the composer drops")
    func rejectedReviewRefused() async throws {
        let r = try await rig()
        let s = UUID()
        let rid = try await saveClaim(r.claims, subject: s, statement: "Rejected", basis: .directlyObserved)
        try await saveClaim(r.claims, subject: s, statement: "Kept", basis: .directlyObserved)
        try await r.reviews.record(ClaimReview(claimID: rid, disposition: .rejected, reviewer: "u",
                                               reason: "not this subject", reviewedAt: t0))
        let ctx = try await r.service.buildContext(scope: .subject(s), subjectLabel: "S")
        // The selector applied the resolver — the rejected claim carries an effective rejection.
        let rejected = try #require(ctx.selectedClaims.first { $0.resolved.claim.id == rid })
        #expect(rejected.resolved.effectiveAssessment.review == .rejected)
        // …and the composer drops it (fail-closed), keeping the other.
        let section = HistoryChronologyComposer().compose(ctx)[0]
        #expect(section.claims.contains { $0.text.hasSuffix("Kept") })
        #expect(!section.claims.contains { $0.text.hasSuffix("Rejected") })
    }

    // MARK: Temporal anchoring & ordering

    @Test("Dated claims are ordered by lineage date ascending, regardless of save order")
    func temporalOrdering() async throws {
        let r = try await rig()
        let s = UUID()
        let e1 = UUID(), e2 = UUID(), e3 = UUID()
        try await saveTemporalClaim(r.tclaims, id: e1, subject: s, start: date(2001))
        try await saveTemporalClaim(r.tclaims, id: e2, subject: s, start: date(2002))
        try await saveTemporalClaim(r.tclaims, id: e3, subject: s, start: date(2003))
        // Saved out of order; each anchored to a different lineage date.
        try await saveClaim(r.claims, subject: s, statement: "mid",  lineage: [tcRef(e2)])
        try await saveClaim(r.claims, subject: s, statement: "first", lineage: [tcRef(e1)])
        try await saveClaim(r.claims, subject: s, statement: "last", lineage: [tcRef(e3)])
        let ctx = try await r.service.buildContext(scope: .subject(s), subjectLabel: "S")
        #expect(ctx.selectedClaims.map { $0.resolved.claim.statement } == ["first", "mid", "last"])
        #expect(ctx.selectedClaims.first?.temporalAnchor?.start == date(2001))
    }

    @Test("Undated claims are placed after dated claims")
    func undatedPlacement() async throws {
        let r = try await rig()
        let s = UUID()
        let e1 = UUID()
        try await saveTemporalClaim(r.tclaims, id: e1, subject: s, start: date(2001))
        try await saveClaim(r.claims, subject: s, statement: "undated", lineage: [])
        try await saveClaim(r.claims, subject: s, statement: "dated", lineage: [tcRef(e1)])
        let ctx = try await r.service.buildContext(scope: .subject(s), subjectLabel: "S")
        #expect(ctx.selectedClaims.map { $0.resolved.claim.statement } == ["dated", "undated"])
        #expect(ctx.selectedClaims.last?.temporalAnchor == nil)
    }

    @Test("Conflicting lineage dates leave the claim explicitly ambiguous (undated, flagged)")
    func ambiguousDates() async throws {
        let r = try await rig()
        let s = UUID()
        let eX = UUID(), eY = UUID()
        try await saveTemporalClaim(r.tclaims, id: eX, subject: s, start: date(2001))
        try await saveTemporalClaim(r.tclaims, id: eY, subject: s, start: date(2005))
        try await saveClaim(r.claims, subject: s, statement: "conflicted", lineage: [tcRef(eX), tcRef(eY)])
        let ctx = try await r.service.buildContext(scope: .subject(s), subjectLabel: "S")
        let sel = try #require(ctx.selectedClaims.first)
        #expect(sel.temporalAnchor == nil)              // never guessed
        #expect(sel.isTemporallyAmbiguous == true)      // flagged, not silently undated
    }

    @Test("Same-date claims order by stable Claim id")
    func stableTieOrdering() async throws {
        let r = try await rig()
        let s = UUID()
        let eP = UUID(), eQ = UUID()
        try await saveTemporalClaim(r.tclaims, id: eP, subject: s, start: date(2001))
        try await saveTemporalClaim(r.tclaims, id: eQ, subject: s, start: date(2001))     // same date
        let id1 = UUID(), id2 = UUID()
        try await saveClaim(r.claims, subject: s, statement: "c1", lineage: [tcRef(eP)], id: id1)
        try await saveClaim(r.claims, subject: s, statement: "c2", lineage: [tcRef(eQ)], id: id2)
        let ctx = try await r.service.buildContext(scope: .subject(s), subjectLabel: "S")
        let expected = [id1, id2].sorted { $0.uuidString < $1.uuidString }
        #expect(ctx.selectedClaims.map { $0.resolved.claim.id } == expected)
    }

    // MARK: Independence keys & determinism

    private struct StubKeyProvider: SourceIndependenceKeyProvider {
        let map: [KnowledgeObject.ID: String]
        func keys(for objectIDs: Set<KnowledgeObject.ID>) async throws -> [KnowledgeObject.ID: String] {
            map.filter { objectIDs.contains($0.key) }
        }
    }

    @Test("Independence keys are resolved during preparation and carried on the selected claim")
    func independenceKeysResolved() async throws {
        let obj = UUID()
        let r = try await rig(keyProvider: StubKeyProvider(map: [obj: "hash-1"]))
        let s = UUID()
        try await saveClaim(r.claims, subject: s, statement: "c", evidenceObjectID: obj)
        let ctx = try await r.service.buildContext(scope: .subject(s), subjectLabel: "S")
        #expect(ctx.selectedClaims.first?.independenceKeys[obj] == "hash-1")
    }

    @Test("Selection is deterministic and persona-invariant (no persona input; identical results)")
    func personaInvariantDeterministic() async throws {
        let r = try await rig()
        let s = UUID()
        let e1 = UUID()
        try await saveTemporalClaim(r.tclaims, id: e1, subject: s, start: date(2001))
        try await saveClaim(r.claims, subject: s, statement: "a", lineage: [tcRef(e1)])
        try await saveClaim(r.claims, subject: s, statement: "b")
        // Two identical scoped calls (no persona parameter exists) produce equal selections.
        let ctx1 = try await r.service.buildContext(scope: .subject(s), subjectLabel: "S")
        let ctx2 = try await r.service.buildContext(scope: .subject(s), subjectLabel: "S")
        #expect(ctx1.selectedClaims == ctx2.selectedClaims)
    }
}
