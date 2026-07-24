//
//  WorkProductAssemblyServiceTests.swift
//  KalsmritikoshTests
//
//  PA-CUT — the explicit per-template cutover. Locks: the route table; chronology assembles
//  through ClaimSelectionService + HistoryChronologyComposer; workspace membership limits the
//  selection; rejected claims are absent; the fail-closed gate blocks (report and receipt
//  share the verdict via the one compose method); the registry arm never falls back to legacy;
//  the other templates still use the legacy composer; and compose is deterministic (a report
//  and its receipt are the identical assembled product).
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PA-CUT — work-product assembly + chronology cutover")
struct WorkProductAssemblyServiceTests {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private struct Rig {
        let db: Database
        let claims: ClaimRepository
        let reviews: ClaimReviewRepository
        let workspaces: WorkspaceRepository
        let service: WorkProductAssemblyService
    }

    private func rig() async throws -> Rig {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("asm-\(UUID().uuidString).sqlite")
        let db = try Database(url: tmp)
        try await SchemaMigrations.migrate(db)
        let claims = ClaimRepository(database: db)
        let reviews = ClaimReviewRepository(database: db)
        let workspaces = WorkspaceRepository(database: db)
        let service = WorkProductAssemblyService(
            database: db, events: EventsRepository(database: db),
            contradictions: ContradictionsRepository(database: db),
            gaps: GapNodeRepository(database: db), workspaces: workspaces)
        return Rig(db: db, claims: claims, reviews: reviews, workspaces: workspaces, service: service)
    }

    /// Satisfy the workspace_entities FK chain (file → knowledge_object → entity) and add the
    /// subject as a workspace member.
    private func addMember(_ r: Rig, subject: UUID, workspace: UUID) async throws {
        let fileID = UUID(), koID = UUID()
        try await r.db.exec("INSERT INTO files (id, url, source_type) VALUES (?,?,?);",
                            [.uuid(fileID), .text("file://x"), .text("txt")])
        try await r.db.exec("""
        INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at)
        VALUES (?,?,?,?,?,?);
        """, [.uuid(koID), .uuid(fileID), .text("txt"), .text("c"), .real(0), .real(0)])
        try await r.db.exec("INSERT INTO entities (id, kind, value, normalized, source_object_id) VALUES (?,?,?,?,?);",
                            [.uuid(subject), .text("person"), .text("S"), .text("s"), .uuid(koID)])
        try await r.workspaces.upsert(Workspace(id: workspace, title: "WS", template: .general))
        try await r.workspaces.addEntity(subject, to: workspace)
    }

    @discardableResult
    private func saveClaim(_ r: Rig, subject: UUID, statement: String,
                           basis: EvidenceBasis = .directlyObserved,
                           resolvedCitation: Bool = true, id: UUID = UUID()) async throws -> UUID {
        let ev = EvidenceReference(objectID: UUID(), blockID: UUID(),
                                   sourceVersionID: resolvedCitation ? UUID() : nil)
        try await r.claims.save(Claim(id: id, subjectID: subject, subjectLabel: "S", statement: statement,
                                      assessment: EvidenceAssessment(basis: basis, origin: .sourceExtraction),
                                      confidence: 0.8, evidence: [ev], createdAt: t0))
        return id
    }

    private func ws(_ id: UUID) -> Workspace { Workspace(id: id, title: "WS", template: .general) }

    // MARK: Route table

    @Test("The route table marks only chronology as registry-backed today")
    func routeTable() {
        #expect(WorkProductAssemblyService.isRegistryBacked(.chronology) == true)
        #expect(WorkProductAssemblyService.isRegistryBacked(.generalSummary) == false)
        #expect(WorkProductAssemblyService.isRegistryBacked(.investigationFindings) == false)
        #expect(WorkProductAssemblyService.isRegistryBacked(.factMemo) == false)
    }

    // MARK: Chronology registry arm

    @Test("Chronology assembles through selection + the chronology composer")
    func chronologyThroughRegistry() async throws {
        let r = try await rig()
        let subject = UUID(), workspace = UUID()
        try await addMember(r, subject: subject, workspace: workspace)
        try await saveClaim(r, subject: subject, statement: "Signed the contract")
        let assembled = try await r.service.compose(workspace: ws(workspace), template: .chronology,
                                                    subjectLabel: "WS", corpusSnapshotID: nil)
        #expect(assembled.workProduct.template == .chronology)
        #expect(assembled.workProduct.sections.first?.title == "Chronology")
        #expect(assembled.workProduct.sections.flatMap(\.claims).contains { $0.text.hasSuffix("Signed the contract") })
    }

    @Test("Workspace membership limits the selection to member subjects")
    func membershipLimitsSelection() async throws {
        let r = try await rig()
        let a = UUID(), b = UUID(), workspace = UUID()
        try await addMember(r, subject: a, workspace: workspace)      // only A is a member
        try await saveClaim(r, subject: a, statement: "A fact")
        try await saveClaim(r, subject: b, statement: "B fact")       // B not in workspace
        let assembled = try await r.service.compose(workspace: ws(workspace), template: .chronology,
                                                    subjectLabel: "WS", corpusSnapshotID: nil)
        let texts = assembled.workProduct.sections.flatMap(\.claims).map(\.text)
        #expect(texts.contains { $0.hasSuffix("A fact") })
        #expect(!texts.contains { $0.hasSuffix("B fact") })
    }

    @Test("A rejected-review claim is absent from the assembled chronology")
    func rejectedAbsent() async throws {
        let r = try await rig()
        let subject = UUID(), workspace = UUID()
        try await addMember(r, subject: subject, workspace: workspace)
        let rid = try await saveClaim(r, subject: subject, statement: "Rejected")
        try await saveClaim(r, subject: subject, statement: "Kept")
        try await r.reviews.record(ClaimReview(claimID: rid, disposition: .rejected, reviewer: "u", reviewedAt: t0))
        let assembled = try await r.service.compose(workspace: ws(workspace), template: .chronology,
                                                    subjectLabel: "WS", corpusSnapshotID: nil)
        let texts = assembled.workProduct.sections.flatMap(\.claims).map(\.text)
        #expect(texts.contains { $0.hasSuffix("Kept") })
        #expect(!texts.contains { $0.hasSuffix("Rejected") })
    }

    @Test("A report and its receipt are the identical assembled product (compose is deterministic)")
    func reportAndReceiptIdentical() async throws {
        let r = try await rig()
        let subject = UUID(), workspace = UUID()
        try await addMember(r, subject: subject, workspace: workspace)
        try await saveClaim(r, subject: subject, statement: "Fact one")
        try await saveClaim(r, subject: subject, statement: "Fact two")
        let report = try await r.service.compose(workspace: ws(workspace), template: .chronology, subjectLabel: "WS", corpusSnapshotID: nil)
        let receipt = try await r.service.compose(workspace: ws(workspace), template: .chronology, subjectLabel: "WS", corpusSnapshotID: nil)
        let a = report.workProduct.sections.flatMap(\.claims).map { [$0.text, $0.status.rawValue] }
        let b = receipt.workProduct.sections.flatMap(\.claims).map { [$0.text, $0.status.rawValue] }
        #expect(a == b)
    }

    // MARK: Fail-closed gate

    @Test("An unsupported material claim blocks the assembly (report and receipt alike)")
    func unsupportedMaterialBlocks() async throws {
        let r = try await rig()
        let subject = UUID(), workspace = UUID()
        try await addMember(r, subject: subject, workspace: workspace)
        // directlyObserved + cited but the citation is unresolvable → fail closed.
        try await saveClaim(r, subject: subject, statement: "Unbacked", resolvedCitation: false)
        await #expect(throws: WorkProductAssemblyError.evidenceIntegrity(violationCount: 1)) {
            try await r.service.compose(workspace: ws(workspace), template: .chronology,
                                        subjectLabel: "WS", corpusSnapshotID: nil)
        }
    }

    // MARK: No silent fallback

    @Test("A registry-arm failure throws and never invokes the legacy composer")
    func registryFailureNeverFallsBack() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("asm-nf-\(UUID().uuidString).sqlite")
        let db = try Database(url: tmp)
        try await SchemaMigrations.migrate(db)
        let claims = ClaimRepository(database: db)
        let resolver = ClaimResolver(claims: claims, reviews: ClaimReviewRepository(database: db))
        let selection = ClaimSelectionService(claims: claims, resolver: resolver,
                                              temporalClaims: TemporalClaimRepository(database: db),
                                              events: EventsRepository(database: db))
        // EMPTY registry → the chronology composer is missing → the arm must throw, not fall back.
        let service = WorkProductAssemblyService(
            events: EventsRepository(database: db), contradictions: ContradictionsRepository(database: db),
            gaps: GapNodeRepository(database: db), workspaces: WorkspaceRepository(database: db),
            selection: selection, registry: WorkProductComposerRegistry())
        await #expect(throws: WorkProductAssemblyError.missingComposer("history.chronology")) {
            try await service.compose(workspace: ws(UUID()), template: .chronology, subjectLabel: "WS", corpusSnapshotID: nil)
        }
    }

    // MARK: Legacy arm intact

    @Test("The non-chronology templates still assemble through the legacy composer")
    func legacyTemplatesUnchanged() async throws {
        let r = try await rig()
        for template in [WorkProductTemplate.generalSummary, .investigationFindings, .factMemo] {
            let assembled = try await r.service.compose(workspace: ws(UUID()), template: template,
                                                        subjectLabel: "WS", corpusSnapshotID: nil)
            #expect(assembled.workProduct.template == template)     // produced via legacy, no throw
        }
    }
}
