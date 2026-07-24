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
        let service = try WorkProductAssemblyService(
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
                           basis: EvidenceBasis = .directlyObserved, review: ReviewDisposition = .unreviewed,
                           resolvedCitation: Bool = true, evidenceObject: UUID = UUID(),
                           id: UUID = UUID()) async throws -> UUID {
        let ev = EvidenceReference(objectID: evidenceObject, blockID: UUID(),
                                   sourceVersionID: resolvedCitation ? UUID() : nil)
        try await r.claims.save(Claim(id: id, subjectID: subject, subjectLabel: "S", statement: statement,
                                      assessment: EvidenceAssessment(basis: basis, review: review, origin: .sourceExtraction),
                                      confidence: 0.8, evidence: [ev], createdAt: t0))
        return id
    }

    private func ws(_ id: UUID) -> Workspace { Workspace(id: id, title: "WS", template: .general) }

    // MARK: Route table

    @Test("The route table marks chronology and general summary as registry-backed")
    func routeTable() {
        #expect(WorkProductAssemblyService.isRegistryBacked(.chronology) == true)
        #expect(WorkProductAssemblyService.isRegistryBacked(.generalSummary) == true)
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
        let contradictions = ContradictionsRepository(database: db)
        let gaps = GapNodeRepository(database: db)
        let disclosures = DisclosureSelectionService(contradictions: contradictions,
                                                     claimContradictions: ClaimContradictionRepository(database: db), gaps: gaps)
        let service = WorkProductAssemblyService(
            events: EventsRepository(database: db), contradictions: contradictions,
            gaps: gaps, workspaces: WorkspaceRepository(database: db),
            selection: selection, disclosures: disclosures, registry: WorkProductComposerRegistry())
        await #expect(throws: WorkProductAssemblyError.missingComposer("history.chronology")) {
            try await service.compose(workspace: ws(UUID()), template: .chronology, subjectLabel: "WS", corpusSnapshotID: nil)
        }
    }

    // MARK: Legacy arm intact

    @Test("Investigation and fact memo remain legacy-backed")
    func legacyTemplatesUnchanged() async throws {
        let r = try await rig()
        for template in [WorkProductTemplate.investigationFindings, .factMemo] {
            #expect(WorkProductAssemblyService.isRegistryBacked(template) == false)
            let assembled = try await r.service.compose(workspace: ws(UUID()), template: template,
                                                        subjectLabel: "WS", corpusSnapshotID: nil)
            #expect(assembled.workProduct.template == template)     // produced via legacy, no throw
        }
    }

    // MARK: General-summary migration (registry, multi-composer)

    private let generalSummaryOrder = ["Sourced summary", "Qualified observations", "Claim-level conflicts",
                                       "Chronology", "Conflicts", "Gaps"]

    @Test("General summary assembles in plan section order across all composers")
    func generalSummarySectionOrder() async throws {
        let r = try await rig()
        let subject = UUID(), workspace = UUID()
        try await addMember(r, subject: subject, workspace: workspace)
        try await saveClaim(r, subject: subject, statement: "A fact")
        let assembled = try await r.service.compose(workspace: ws(workspace), template: .generalSummary,
                                                    subjectLabel: "WS", corpusSnapshotID: nil)
        #expect(assembled.workProduct.sections.map(\.title) == generalSummaryOrder)
    }

    @Test("Inference and conflict claims are allowed and land in their disclosure sections")
    func generalSummaryDisclosuresAllowed() async throws {
        let r = try await rig()
        let subject = UUID(), workspace = UUID()
        try await addMember(r, subject: subject, workspace: workspace)
        try await saveClaim(r, subject: subject, statement: "inferred", basis: .inferred, resolvedCitation: false)
        // Does not throw (inference is a disclosure, not a blocked material assertion).
        let assembled = try await r.service.compose(workspace: ws(workspace), template: .generalSummary,
                                                    subjectLabel: "WS", corpusSnapshotID: nil)
        let qualified = assembled.workProduct.sections.first { $0.title == "Qualified observations" }
        #expect(qualified?.claims.contains { $0.text.hasSuffix("inferred") } == true)
    }

    @Test("The same canonical claim keeps its sourceClaimID across summary and chronology, with distinct occurrence ids")
    func sameClaimAcrossSections() async throws {
        let r = try await rig()
        let subject = UUID(), workspace = UUID()
        try await addMember(r, subject: subject, workspace: workspace)
        let claimID = try await saveClaim(r, subject: subject, statement: "shared fact")
        let assembled = try await r.service.compose(workspace: ws(workspace), template: .generalSummary,
                                                    subjectLabel: "WS", corpusSnapshotID: nil)
        let occurrences = assembled.workProduct.sections.flatMap(\.claims).filter { $0.sourceClaimID == claimID }
        #expect(occurrences.count >= 2)                                  // summary + chronology
        #expect(Set(occurrences.map(\.id)).count == occurrences.count)   // distinct occurrence ids
        #expect(occurrences.allSatisfy { $0.sourceClaimID == claimID })  // same canonical id
    }

    @Test("Workspace scope is preserved across every section")
    func workspaceScopePreservedAllSections() async throws {
        let r = try await rig()
        let a = UUID(), b = UUID(), workspace = UUID()
        try await addMember(r, subject: a, workspace: workspace)
        try await saveClaim(r, subject: a, statement: "member")
        try await saveClaim(r, subject: b, statement: "outsider")       // not a member
        let assembled = try await r.service.compose(workspace: ws(workspace), template: .generalSummary,
                                                    subjectLabel: "WS", corpusSnapshotID: nil)
        let texts = assembled.workProduct.sections.flatMap(\.claims).map(\.text)
        #expect(texts.contains { $0.hasSuffix("member") })
        #expect(!texts.contains { $0.hasSuffix("outsider") })
    }

    @Test("A rejected claim neither renders nor lets its linked conflict surface")
    func rejectedNeitherRendersNorScopes() async throws {
        let r = try await rig()
        let subject = UUID(), workspace = UUID()
        try await addMember(r, subject: subject, workspace: workspace)
        let rid = try await saveClaim(r, subject: subject, statement: "rejected")
        try await r.reviews.record(ClaimReview(claimID: rid, disposition: .rejected, reviewer: "u", reviewedAt: t0))
        // Link a contradiction to the rejected claim.
        let cont = Contradiction(id: UUID(), description: "d", claimA: "sideA", claimB: "sideB", status: .open)
        await ContradictionsRepository(database: r.db).insert(cont)
        try await ClaimContradictionRepository(database: r.db).link(claimID: rid, contradictionID: cont.id)
        let assembled = try await r.service.compose(workspace: ws(workspace), template: .generalSummary,
                                                    subjectLabel: "WS", corpusSnapshotID: nil)
        let texts = assembled.workProduct.sections.flatMap(\.claims).map(\.text)
        #expect(!texts.contains { $0.hasSuffix("rejected") })            // claim not rendered
        #expect(!texts.contains { $0.contains("sideA") })                // its conflict did not surface
    }

    @Test("Decision-aware validation blocks an unresolved user-attributed material claim")
    func decisionAwareBlocksUserAttributed() async throws {
        let r = try await rig()
        let subject = UUID(), workspace = UUID()
        try await addMember(r, subject: subject, workspace: workspace)
        // unknownLegacy + confirmed + UNRESOLVED citation → assertWithUserAttribution (assertive,
        // status .humanNote). The legacy gate would miss it; the decision-aware gate blocks it.
        try await saveClaim(r, subject: subject, statement: "u", basis: .unknownLegacy,
                            review: .confirmed, resolvedCitation: false)
        await #expect(throws: WorkProductAssemblyError.self) {
            try await r.service.compose(workspace: ws(workspace), template: .generalSummary,
                                        subjectLabel: "WS", corpusSnapshotID: nil)
        }
    }

    @Test("A report and its general-summary receipt are the identical assembled product")
    func generalSummaryReportReceiptIdentical() async throws {
        let r = try await rig()
        let subject = UUID(), workspace = UUID()
        try await addMember(r, subject: subject, workspace: workspace)
        try await saveClaim(r, subject: subject, statement: "one")
        try await saveClaim(r, subject: subject, statement: "two")
        let a = try await r.service.compose(workspace: ws(workspace), template: .generalSummary, subjectLabel: "WS", corpusSnapshotID: nil)
        let b = try await r.service.compose(workspace: ws(workspace), template: .generalSummary, subjectLabel: "WS", corpusSnapshotID: nil)
        let ax = a.workProduct.sections.flatMap(\.claims).map { [$0.text, $0.status.rawValue] }
        let bx = b.workProduct.sections.flatMap(\.claims).map { [$0.text, $0.status.rawValue] }
        #expect(ax == bx)
    }

    // MARK: Corrections folded into this commit

    @Test("The manifest does not hide an unresolved citation behind a same-title resolved one")
    func manifestSameTitleNotMasked() async throws {
        let r = try await rig()
        let subject = UUID(), workspace = UUID()
        try await addMember(r, subject: subject, workspace: workspace)
        // An INFERENCE claim (not material → won't block) with two evidence refs sharing the
        // subject label as citation title: one resolved, one not.
        let ev1 = EvidenceReference(objectID: UUID(), blockID: UUID(), sourceVersionID: UUID())      // resolved
        let ev2 = EvidenceReference(objectID: UUID(), blockID: UUID(), sourceVersionID: nil)         // unresolved
        try await r.claims.save(Claim(subjectID: subject, subjectLabel: "S", statement: "guess",
                                      assessment: EvidenceAssessment(basis: .inferred, origin: .modelProposed),
                                      confidence: 0.5, evidence: [ev1, ev2], createdAt: t0))
        let assembled = try await r.service.compose(workspace: ws(workspace), template: .chronology,
                                                    subjectLabel: "WS", corpusSnapshotID: nil)
        // The composer titles both citations with the claim's subjectLabel ("S"); the label
        // must be reported UNRESOLVED because one of its citations is unresolved.
        let entry = assembled.manifest.citationMap.first { $0.label == "S" }
        #expect(entry != nil)
        #expect(entry?.resolved == false)
    }

    @Test("Duplicate composer registration cannot be silently ignored")
    func duplicateRegistrationThrows() throws {
        var reg = try WorkProductComposerRegistry.makeDefault()   // built-ins register cleanly
        #expect(throws: WorkProductComposerRegistry.RegistrationError.duplicate(WorkProductComposerID("history.chronology"))) {
            try reg.register(HistoryChronologyComposer())         // a duplicate must throw
        }
    }
}
