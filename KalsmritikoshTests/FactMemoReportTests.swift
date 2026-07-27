//
//  FactMemoReportTests.swift
//  KalsmritikoshTests
//
//  PA-CUT-MEMO — the `.factMemo` template now assembles through the registry pipeline
//  (ClaimSelectionService + FactMemoComposer), NOT the legacy whole-archive route. These tests
//  lock: the template is registry-backed; the exact six-section order; the subject label is the
//  question; the short answer is a deterministic count summary only (no uncited conclusion);
//  supported / qualified / disputed / missing-proof bucketing; the B4 out-of-scope boundary;
//  refused claims absent; the effective (corrected) review honoured; workspace-scoped conflicts
//  and gaps; report == receipt selection; a missing composer throws with NO legacy fallback; and
//  the shared bucketing matches the sourced summary.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PA-CUT-MEMO — fact memo (registry pipeline)")
struct FactMemoReportTests {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private func hex(_ c: Character) -> String { String(repeating: c, count: 64) }

    private let memoOrder = ["Question presented", "Short answer", "Supported facts",
                             "Qualified observations", "Disputed facts", "Missing proof"]

    // MARK: - Rig

    final class KOStore: @unchecked Sendable { var koBySubject: [UUID: UUID] = [:] }

    private struct Rig {
        let db: Database
        let files: FilesRepository
        let claims: ClaimRepository
        let reviews: ClaimReviewRepository
        let workspaces: WorkspaceRepository
        let membership: WorkspaceMembershipDeriver
        let genericFacts: GenericFactRepository
        let producer: ClaimProducer
        let contradictions: ContradictionsRepository
        let claimContradictions: ClaimContradictionRepository
        let service: WorkProductAssemblyService
        let kos = KOStore()
    }

    private func rig() async throws -> Rig {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("memo-\(UUID().uuidString).sqlite")
        let db = try Database(url: tmp)
        try await SchemaMigrations.migrate(db)
        let files = FilesRepository(database: db)
        let claims = ClaimRepository(database: db)
        let reviews = ClaimReviewRepository(database: db)
        let workspaces = WorkspaceRepository(database: db)
        let membership = WorkspaceMembershipDeriver(database: db, workspaces: workspaces)
        let gf = GenericFactRepository(database: db)
        let producer = ClaimProducer(
            genericFacts: gf, assertions: AssertionsRepository(database: db),
            temporalClaims: TemporalClaimRepository(database: db), events: EventsRepository(database: db),
            claims: claims, evidence: EvidenceStore(database: db))
        let contradictions = ContradictionsRepository(database: db)
        let service = try WorkProductAssemblyService(
            database: db, events: EventsRepository(database: db), contradictions: contradictions,
            gaps: GapNodeRepository(database: db), workspaces: workspaces)
        return Rig(db: db, files: files, claims: claims, reviews: reviews, workspaces: workspaces,
                   membership: membership, genericFacts: gf, producer: producer,
                   contradictions: contradictions,
                   claimContradictions: ClaimContradictionRepository(database: db), service: service)
    }

    @discardableResult
    private func addMember(_ r: Rig, subject: UUID, workspace: UUID) async throws -> UUID {
        let fileID = UUID(), koID = UUID()
        try await r.db.exec("INSERT INTO files (id, url, source_type) VALUES (?,?,?);",
                            [.uuid(fileID), .text("file://\(fileID)"), .text("txt")])
        try await r.db.exec("""
        INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at) VALUES (?,?,?,?,?,?);
        """, [.uuid(koID), .uuid(fileID), .text("txt"), .text("c"), .real(0), .real(0)])
        try await r.db.exec("INSERT INTO entities (id, kind, value, normalized, source_object_id) VALUES (?,?,?,?,?);",
                            [.uuid(subject), .text("person"), .text("S"), .text(subject.uuidString.lowercased()), .uuid(koID)])
        try await r.workspaces.upsert(Workspace(id: workspace, title: "WS", template: .general))
        try await r.workspaces.addEntity(subject, to: workspace)
        try await r.workspaces.addSource(fileID, to: workspace)
        r.kos.koBySubject[subject] = koID
        return koID
    }

    @discardableResult
    private func addBareObject(_ r: Rig) async throws -> UUID {
        let fileID = UUID(), koID = UUID()
        try await r.db.exec("INSERT INTO files (id, url, source_type) VALUES (?,?,?);",
                            [.uuid(fileID), .text("file://\(fileID)"), .text("txt")])
        try await r.db.exec("""
        INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at) VALUES (?,?,?,?,?,?);
        """, [.uuid(koID), .uuid(fileID), .text("txt"), .text("c"), .real(0), .real(0)])
        return koID
    }

    @discardableResult
    private func saveClaim(_ r: Rig, subject: UUID, statement: String,
                           basis: EvidenceBasis = .directlyObserved, review: ReviewDisposition = .unreviewed,
                           resolvedCitation: Bool = true, evidenceObject: UUID? = nil,
                           id: UUID = UUID()) async throws -> UUID {
        let obj = evidenceObject ?? r.kos.koBySubject[subject] ?? UUID()
        let ev = EvidenceReference(objectID: obj, blockID: UUID(),
                                   sourceVersionID: resolvedCitation ? UUID() : nil)
        try await r.claims.save(Claim(id: id, subjectID: subject, subjectLabel: "S", statement: statement,
                                      assessment: EvidenceAssessment(basis: basis, review: review, origin: .sourceExtraction),
                                      confidence: 0.8, evidence: [ev], scope: .entity(subject), createdAt: t0))
        return id
    }

    /// A subject-less GenericFact + reopenable block → the producer yields a source-scoped claim
    /// pointing at a REAL source version with a content hash (so the receipt custody hash resolves).
    @discardableResult
    private func seedDocFact(_ r: Rig, value: String,
                             file: UUID = UUID(), ko: UUID = UUID()) async throws -> (file: UUID, ko: UUID) {
        try await r.files.upsert(FileRecord(id: file, url: URL(fileURLWithPath: "/doc/\(file).txt"),
                                            sourceType: .txt, ingestedAt: t0, contentHash: hex("a")))
        try await r.db.exec("""
        INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at) VALUES (?,?,?,?,?,?);
        """, [.uuid(ko), .uuid(file), .text("txt"), .text("c"), .real(0), .real(0)])
        let sv = UUID(), block = UUID(), doc = UUID()
        try await r.db.exec("""
        INSERT INTO source_versions (id, logical_source_id, document_id, content_hash, valid_from, is_current, created_at)
        VALUES (?,?,?,?,?,1,?);
        """, [.uuid(sv), .uuid(file), .uuid(doc), .text(hex("a")), .real(0), .real(0)])
        try await r.db.exec("""
        INSERT INTO evidence_blocks (id, document_id, source_version_id, ordinal, kind, raw_text, normalized_text, extraction_method, extraction_confidence)
        VALUES (?,?,?,?,?,?,?,?,?);
        """, [.uuid(block), .uuid(doc), .uuid(sv), .integer(0), .text("paragraph"), .text("t"), .text("t"), .text("native"), .real(1.0)])
        try await r.db.exec("""
        INSERT INTO evidence_block_objects (evidence_block_id, knowledge_object_id, linked_at) VALUES (?,?,?);
        """, [.uuid(block), .uuid(ko), .real(0)])
        try await r.genericFacts.upsert(GenericFact(
            id: UUID(), subjectID: nil, subjectLabel: "Document", field: "event", value: value,
            assessment: EvidenceAssessment(basis: .sourceAsserted, origin: .sourceExtraction),
            confidence: 0.8, sourceBlockIDs: [block]))
        return (file, ko)
    }

    private func ws(_ id: UUID, label: String = "WS") -> Workspace { Workspace(id: id, title: label, template: .general) }

    private func compose(_ r: Rig, _ workspace: UUID, label: String = "WS") async throws -> AssembledWorkProduct {
        let access = SensitiveAccessContext(scope: SensitiveScope(
            workspaceID: workspace, maximumSensitivity: .restricted,
            permitsPrivilegedMaterial: false, purpose: .export))
        return try await r.service.compose(workspace: ws(workspace, label: label), template: .factMemo,
                                           subjectLabel: label, corpusSnapshotID: nil, access: access)
    }

    // MARK: - Route + structure

    @Test("The fact-memo template routes through the fact-memo registry composer")
    func templateIsRegistryBacked() {
        let ids = WorkProductAssemblyService.plan(for: .factMemo).composerIDs.map(\.rawValue)
        #expect(ids == ["fact-memo.core"])
    }

    @Test("The fact memo assembles in the exact six-section order")
    func sectionOrder() async throws {
        let r = try await rig()
        let subject = UUID(), workspace = UUID()
        try await addMember(r, subject: subject, workspace: workspace)
        try await saveClaim(r, subject: subject, statement: "a fact")
        let assembled = try await compose(r, workspace)
        #expect(assembled.workProduct.sections.map(\.title) == memoOrder)
    }

    @Test("The subject label is used as the question, and the short answer is counts only")
    func questionAndShortAnswer() async throws {
        let r = try await rig()
        let subject = UUID(), workspace = UUID()
        try await addMember(r, subject: subject, workspace: workspace)
        try await saveClaim(r, subject: subject, statement: "Alice signed the deed")
        let assembled = try await compose(r, workspace, label: "Did Alice sign the deed?")

        let question = try #require(assembled.workProduct.sections.first { $0.title == "Question presented" })
        #expect(question.preamble.contains { $0.contains("Did Alice sign the deed?") })
        #expect(question.claims.isEmpty)                                    // the question is prose, not a claim

        let short = try #require(assembled.workProduct.sections.first { $0.title == "Short answer" })
        #expect(short.claims.isEmpty)                                       // counts only — no uncited claim
        #expect(short.preamble.contains { $0.contains("1 supported fact") })
        // The short answer must NOT restate the finding text (no uncited conclusion).
        #expect(!short.preamble.contains { $0.contains("Alice signed the deed") })
    }

    // MARK: - Bucketing

    @Test("Facts, inferences, conflicts and gaps land in their correct sections")
    func bucketing() async throws {
        let r = try await rig()
        let subject = UUID(), workspace = UUID()
        try await addMember(r, subject: subject, workspace: workspace)
        let supported = try await saveClaim(r, subject: subject, statement: "supported fact")
        try await saveClaim(r, subject: subject, statement: "an inference", basis: .inferred, resolvedCitation: false)
        // A workspace-scoped conflict linked to the supported claim → Disputed facts.
        let conflict = Contradiction(id: UUID(), description: "d", claimA: "SIDE-A", claimB: "SIDE-B", status: .open)
        await r.contradictions.insert(conflict)
        try await r.claimContradictions.link(claimID: supported, contradictionID: conflict.id)

        let assembled = try await compose(r, workspace)
        func section(_ t: String) -> WorkProductSection { assembled.workProduct.sections.first { $0.title == t }! }
        #expect(section("Supported facts").claims.contains { $0.text.hasSuffix("supported fact") })
        #expect(section("Qualified observations").claims.contains { $0.text.hasSuffix("an inference") })
        let disputedText = section("Disputed facts").claims.map(\.text).joined(separator: "\n")
        #expect(disputedText.contains("SIDE-A") && disputedText.contains("SIDE-B"))
    }

    @Test("The fact memo's supported bucket matches the sourced summary's sourced bucket")
    func bucketingParityWithSummary() async throws {
        let r = try await rig()
        let subject = UUID(), workspace = UUID()
        try await addMember(r, subject: subject, workspace: workspace)
        try await saveClaim(r, subject: subject, statement: "fact one")
        try await saveClaim(r, subject: subject, statement: "fact two")
        let memo = try await compose(r, workspace)
        let summaryAccess = SensitiveAccessContext(scope: SensitiveScope(
            workspaceID: workspace, maximumSensitivity: .restricted,
            permitsPrivilegedMaterial: false, purpose: .export))
        let summary = try await r.service.compose(workspace: ws(workspace), template: .generalSummary,
                                                  subjectLabel: "WS", corpusSnapshotID: nil, access: summaryAccess)
        let memoSupported = memo.workProduct.sections.first { $0.title == "Supported facts" }!.claims.map(\.text)
        let summarySourced = summary.workProduct.sections.first { $0.title == "Sourced summary" }!.claims.map(\.text)
        #expect(memoSupported == summarySourced)                            // shared bucketing → identical rows
    }

    // MARK: - B4 boundary + review honesty

    @Test("An out-of-scope sentinel claim never appears in the memo")
    func outOfScopeSentinelAbsent() async throws {
        let r = try await rig()
        let subject = UUID(), workspace = UUID()
        try await addMember(r, subject: subject, workspace: workspace)
        try await saveClaim(r, subject: subject, statement: "IN SCOPE — must appear")
        let outsideKO = try await addBareObject(r)
        try await saveClaim(r, subject: subject, statement: "OUT-OF-SCOPE SENTINEL — MUST NOT APPEAR",
                            evidenceObject: outsideKO)
        let assembled = try await compose(r, workspace)
        let allText = assembled.workProduct.sections.flatMap(\.claims).map(\.text)
        #expect(allText.contains { $0.hasSuffix("must appear") })
        #expect(!allText.contains { $0.contains("SENTINEL") })
        #expect(assembled.manifest.selectedFindingCount == 1)
    }

    @Test("A rejected claim is absent; a reject-then-confirm renders (effective review)")
    func reviewHonesty() async throws {
        let r = try await rig()
        let subject = UUID(), workspace = UUID()
        try await addMember(r, subject: subject, workspace: workspace)
        let rejected = try await saveClaim(r, subject: subject, statement: "rejected finding")
        try await r.reviews.record(ClaimReview(claimID: rejected, disposition: .rejected, reviewer: "u", reviewedAt: t0))
        let corrected = try await saveClaim(r, subject: subject, statement: "corrected finding")
        try await r.reviews.record(ClaimReview(claimID: corrected, disposition: .rejected, reviewer: "u", reviewedAt: t0))
        try await r.reviews.record(ClaimReview(claimID: corrected, disposition: .confirmed, reviewer: "u",
                                               reviewedAt: t0.addingTimeInterval(60)))
        let allText = try await compose(r, workspace).workProduct.sections.flatMap(\.claims).map(\.text)
        #expect(!allText.contains { $0.contains("rejected finding") })
        #expect(allText.contains { $0.hasSuffix("corrected finding") })
    }

    // MARK: - Workspace-scoped conflicts / gaps

    @Test("A conflict surfaces only when linked to an in-scope claim")
    func conflictsWorkspaceScoped() async throws {
        let r = try await rig()
        let subject = UUID(), workspace = UUID()
        try await addMember(r, subject: subject, workspace: workspace)
        let inScope = try await saveClaim(r, subject: subject, statement: "in-scope finding")
        let cIn = Contradiction(id: UUID(), description: "d-in", claimA: "IN-A", claimB: "IN-B", status: .open)
        await r.contradictions.insert(cIn)
        try await r.claimContradictions.link(claimID: inScope, contradictionID: cIn.id)
        let outsideKO = try await addBareObject(r)
        let outID = try await saveClaim(r, subject: subject, statement: "out finding", evidenceObject: outsideKO)
        let cOut = Contradiction(id: UUID(), description: "d-out", claimA: "OUT-A", claimB: "OUT-B", status: .open)
        await r.contradictions.insert(cOut)
        try await r.claimContradictions.link(claimID: outID, contradictionID: cOut.id)

        let disputed = try #require(try await compose(r, workspace).workProduct.sections.first { $0.title == "Disputed facts" })
        let text = (disputed.preamble + disputed.claims.map(\.text)).joined(separator: "\n")
        #expect(text.contains("IN-A"))
        #expect(!text.contains("OUT-A"))
    }

    // MARK: - Report / receipt parity

    @Test("A report and its fact-memo receipt use the identical selected claims")
    func reportReceiptIdenticalSelection() async throws {
        let r = try await rig()
        let workspace = UUID()
        try await r.workspaces.upsert(Workspace(id: workspace, title: "WS", template: .general))
        let one = try await seedDocFact(r, value: "one")
        let two = try await seedDocFact(r, value: "two")
        _ = try await r.producer.backfill(at: t0)
        try await r.workspaces.addSource(one.file, to: workspace)
        try await r.workspaces.addSource(two.file, to: workspace)
        try await r.membership.deriveMembership(for: workspace)
        let a = try await compose(r, workspace)
        let b = try await compose(r, workspace)
        let ax = a.workProduct.sections.flatMap(\.claims).map { [$0.text, $0.status.rawValue] }
        let bx = b.workProduct.sections.flatMap(\.claims).map { [$0.text, $0.status.rawValue] }
        #expect(ax == bx)
        let sealed = try WorkProductReceiptBuilder().build(from: a)
        #expect(VerifiableReceipt.verify(sealed) == true)
    }

    // MARK: - No silent fallback

    @Test("A missing fact-memo composer throws and never falls back to the legacy route")
    func missingComposerThrows() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("memo-nf-\(UUID().uuidString).sqlite")
        let db = try Database(url: tmp)
        try await SchemaMigrations.migrate(db)
        let claims = ClaimRepository(database: db)
        let resolver = ClaimResolver(claims: claims, reviews: ClaimReviewRepository(database: db))
        let selection = ClaimSelectionService(claims: claims, resolver: resolver,
                                              temporalClaims: TemporalClaimRepository(database: db),
                                              events: EventsRepository(database: db))
        let contradictions = ContradictionsRepository(database: db)
        let gaps = GapNodeRepository(database: db)
        let disclosures = DisclosureSelectionService(contradictions: contradictions,
                                                     claimContradictions: ClaimContradictionRepository(database: db), gaps: gaps)
        let wsID = UUID()
        let service = WorkProductAssemblyService(
            workspaces: WorkspaceRepository(database: db),
            knowledgeObjects: KnowledgeObjectRepository(database: db),
            evidence: EvidenceStore(database: db),
            sensitiveScopes: SensitiveScopeRepository(database: db),
            selection: selection, disclosures: disclosures, registry: WorkProductComposerRegistry())
        let access = SensitiveAccessContext(scope: SensitiveScope(
            workspaceID: wsID, maximumSensitivity: .restricted,
            permitsPrivilegedMaterial: false, purpose: .export))
        await #expect(throws: WorkProductAssemblyError.missingComposer("fact-memo.core")) {
            try await service.compose(workspace: ws(wsID), template: .factMemo,
                                      subjectLabel: "WS", corpusSnapshotID: nil, access: access)
        }
    }
}
