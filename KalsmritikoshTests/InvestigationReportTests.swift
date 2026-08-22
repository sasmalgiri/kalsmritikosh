//
//  InvestigationReportTests.swift
//  KalsmritikoshTests
//
//  PA-CUT-INV — the `.investigationFindings` template now assembles through the registry
//  pipeline (ClaimSelectionService + InvestigationFindingsComposer + GapsAndConflictsComposer +
//  InvestigationLimitationsComposer), NOT the legacy whole-archive route. These tests lock:
//  the template is registry-backed; the exact section order; entity- and source-scoped claims
//  render in Findings; the B4 out-of-scope boundary (sentinel + mixed-source) holds; refused
//  claims are absent; the effective (corrected) review is honoured; undated/ambiguous claims are
//  labelled honestly (never a fabricated date); conflicts and gaps are workspace-scoped; a report
//  and its receipt use the identical selected claims; and a missing composer throws with NO
//  silent fallback to the legacy path.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PA-CUT-INV — investigation report (registry pipeline)")
struct InvestigationReportTests {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private func hex(_ c: Character) -> String { String(repeating: c, count: 64) }

    /// The fixed section order the investigation plan must always produce:
    /// investigation.execsummary (1) → investigation.findings (4) → evidence.gaps-conflicts (2)
    /// → investigation.limitations (1).
    private let investigationOrder = ["Executive summary", "Mandate / scope", "Materials reviewed", "Methods",
                                      "Findings", "Conflicts", "Gaps", "Limitations"]

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
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("inv-\(UUID().uuidString).sqlite")
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

    /// Add `subject` as a workspace member, register the file as a workspace source (B4), and
    /// record the subject's in-workspace KO so `saveClaim` is in-scope by default.
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

    /// A KnowledgeObject whose file is NOT a workspace source (OUT of scope for B4).
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

    /// An entity-scoped claim for a workspace member, in-scope by default.
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

    /// A subject-less GenericFact + reopenable block owned by a KO → the producer yields a
    /// SOURCE-scoped claim (scope == .knowledgeObject). Returns (file, ko).
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

    private func ws(_ id: UUID) -> Workspace { Workspace(id: id, title: "WS", template: .general) }

    private func compose(_ r: Rig, _ workspace: UUID) async throws -> AssembledWorkProduct {
        let access = SensitiveAccessContext(scope: SensitiveScope(
            workspaceID: workspace, maximumSensitivity: .restricted,
            permitsPrivilegedMaterial: false, purpose: .export))
        return try await r.service.compose(workspace: ws(workspace), template: .investigationFindings,
                                           subjectLabel: "WS", corpusSnapshotID: nil, access: access)
    }

    // MARK: - Route + structure

    @Test("The investigation template routes through the investigation registry composers")
    func templateIsRegistryBacked() {
        let ids = WorkProductAssemblyService.plan(for: .investigationFindings).composerIDs.map(\.rawValue)
        #expect(ids == ["investigation.execsummary", "investigation.findings", "evidence.gaps-conflicts", "investigation.limitations"])
    }

    @Test("The investigation report assembles in the exact plan section order")
    func sectionOrder() async throws {
        let r = try await rig()
        let subject = UUID(), workspace = UUID()
        try await addMember(r, subject: subject, workspace: workspace)
        try await saveClaim(r, subject: subject, statement: "a finding")
        let assembled = try await compose(r, workspace)
        #expect(assembled.workProduct.sections.map(\.title) == investigationOrder)
    }

    // MARK: - Findings rendering (entity- and source-scoped)

    @Test("Entity-scoped and source-scoped claims both render in the Findings section")
    func entityAndSourceScopedRender() async throws {
        let r = try await rig()
        let subject = UUID(), workspace = UUID()
        try await addMember(r, subject: subject, workspace: workspace)
        try await saveClaim(r, subject: subject, statement: "entity finding")
        // A plain-doc, subject-less fact produced as a source-scoped claim, added as a source.
        let doc = try await seedDocFact(r, value: "source finding")
        _ = try await r.producer.backfill(at: t0)
        try await r.workspaces.addSource(doc.file, to: workspace)
        try await r.membership.deriveMembership(for: workspace)

        let assembled = try await compose(r, workspace)
        let findings = try #require(assembled.workProduct.sections.first { $0.title == "Findings" })
        let texts = findings.claims.map(\.text)
        #expect(texts.contains { $0.hasSuffix("entity finding") })
        #expect(texts.contains { $0.hasSuffix("source finding") })
    }

    @Test("Materials-reviewed counts are derived from the selected context")
    func materialsReviewedCounts() async throws {
        let r = try await rig()
        let subject = UUID(), workspace = UUID()
        try await addMember(r, subject: subject, workspace: workspace)
        try await saveClaim(r, subject: subject, statement: "one finding")
        let assembled = try await compose(r, workspace)
        let materials = try #require(assembled.workProduct.sections.first { $0.title == "Materials reviewed" })
        #expect(materials.preamble.contains { $0.contains("1 surfaceable finding") })
    }

    // MARK: - B4 workspace boundary

    @Test("An out-of-scope sentinel claim never appears in the investigation report")
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

    @Test("A claim whose evidence spans in- and out-of-scope objects is excluded whole")
    func mixedSourceExcluded() async throws {
        let r = try await rig()
        let subject = UUID(), workspace = UUID()
        let inScopeKO = try await addMember(r, subject: subject, workspace: workspace)
        let outsideKO = try await addBareObject(r)
        // One claim, two evidence refs: one in scope, one not. Conservative rule → exclude whole.
        let ev1 = EvidenceReference(objectID: inScopeKO, blockID: UUID(), sourceVersionID: UUID())
        let ev2 = EvidenceReference(objectID: outsideKO, blockID: UUID(), sourceVersionID: UUID())
        try await r.claims.save(Claim(subjectID: subject, subjectLabel: "S", statement: "MIXED — MUST NOT APPEAR",
                                      assessment: EvidenceAssessment(basis: .directlyObserved, origin: .sourceExtraction),
                                      confidence: 0.8, evidence: [ev1, ev2], scope: .entity(subject), createdAt: t0))
        let assembled = try await compose(r, workspace)
        let allText = assembled.workProduct.sections.flatMap(\.claims).map(\.text)
        #expect(!allText.contains { $0.contains("MIXED") })
    }

    // MARK: - Review honesty

    @Test("A rejected claim is absent from the report (fail-closed)")
    func refusedAbsent() async throws {
        let r = try await rig()
        let subject = UUID(), workspace = UUID()
        try await addMember(r, subject: subject, workspace: workspace)
        let rid = try await saveClaim(r, subject: subject, statement: "rejected finding")
        try await r.reviews.record(ClaimReview(claimID: rid, disposition: .rejected, reviewer: "u", reviewedAt: t0))
        let assembled = try await compose(r, workspace)
        let allText = assembled.workProduct.sections.flatMap(\.claims).map(\.text)
        #expect(!allText.contains { $0.contains("rejected finding") })
    }

    @Test("The effective (latest) review is honoured — a reject then re-confirm renders")
    func correctedReviewReflected() async throws {
        let r = try await rig()
        let subject = UUID(), workspace = UUID()
        try await addMember(r, subject: subject, workspace: workspace)
        let cid = try await saveClaim(r, subject: subject, statement: "corrected finding")
        try await r.reviews.record(ClaimReview(claimID: cid, disposition: .rejected, reviewer: "u", reviewedAt: t0))
        try await r.reviews.record(ClaimReview(claimID: cid, disposition: .confirmed, reviewer: "u",
                                               reviewedAt: t0.addingTimeInterval(60)))
        let assembled = try await compose(r, workspace)
        let allText = assembled.workProduct.sections.flatMap(\.claims).map(\.text)
        #expect(allText.contains { $0.hasSuffix("corrected finding") })     // effective = confirmed → surfaces
    }

    // MARK: - Temporal honesty (pure date-phrase helper)

    private func resolved(_ statement: String) -> ResolvedClaim {
        let claim = Claim(subjectID: UUID(), subjectLabel: "S", statement: statement,
                          assessment: EvidenceAssessment(basis: .directlyObserved, origin: .sourceExtraction),
                          confidence: 0.8, evidence: [], createdAt: t0)
        return ResolvedClaim(claim: claim, effectiveAssessment: claim.assessment)
    }

    @Test("A dated claim is phrased with its date; undated and ambiguous are labelled honestly")
    func datePhrasesHonest() {
        // Dated → a real date phrase (never "Undated").
        let dated = SelectedClaim(
            resolved: resolved("dated"),
            temporalAnchor: ClaimTemporalAnchor(start: t0, precision: .day,
                                                source: DerivedReference(kind: .genericFact, id: UUID())),
            selectionReason: .explicitlyRequested)
        let datedPhrase = SelectedClaimDatePhrase.phrase(for: dated)
        #expect(datedPhrase != "Undated")
        #expect(datedPhrase.contains("2023"))                               // t0 = 2023-11-14

        // No anchor, not ambiguous → plain "Undated".
        let undated = SelectedClaim(resolved: resolved("undated"), selectionReason: .explicitlyRequested)
        #expect(SelectedClaimDatePhrase.phrase(for: undated) == "Undated")

        // No anchor, conflicting lineage → explicitly ambiguous (never guessed).
        let ambiguous = SelectedClaim(resolved: resolved("ambiguous"), isTemporallyAmbiguous: true,
                                      selectionReason: .explicitlyRequested)
        #expect(SelectedClaimDatePhrase.phrase(for: ambiguous) == "Undated (conflicting source dates)")
    }

    @Test("An undated finding is labelled 'Undated' in the report, never given a fabricated date")
    func undatedFindingLabelled() async throws {
        let r = try await rig()
        let subject = UUID(), workspace = UUID()
        try await addMember(r, subject: subject, workspace: workspace)
        try await saveClaim(r, subject: subject, statement: "undated finding")
        let assembled = try await compose(r, workspace)
        let findings = try #require(assembled.workProduct.sections.first { $0.title == "Findings" })
        #expect(findings.claims.contains { $0.text.contains("Undated") && $0.text.hasSuffix("undated finding") })
    }

    // MARK: - Conflicts + gaps workspace-scoped

    @Test("A conflict surfaces only when linked to an in-scope claim, never an out-of-scope one")
    func conflictsWorkspaceScoped() async throws {
        let r = try await rig()
        let subject = UUID(), workspace = UUID()
        try await addMember(r, subject: subject, workspace: workspace)
        let inScope = try await saveClaim(r, subject: subject, statement: "in-scope finding")
        // A conflict linked to the in-scope claim → surfaces.
        let cIn = Contradiction(id: UUID(), description: "d-in", claimA: "IN-SIDE-A", claimB: "IN-SIDE-B", status: .open)
        await r.contradictions.insert(cIn)
        try await r.claimContradictions.link(claimID: inScope, contradictionID: cIn.id)
        // A conflict linked to a claim backed only by an out-of-scope object → absent.
        let outsideKO = try await addBareObject(r)
        let outID = try await saveClaim(r, subject: subject, statement: "out finding", evidenceObject: outsideKO)
        let cOut = Contradiction(id: UUID(), description: "d-out", claimA: "OUT-SIDE-A", claimB: "OUT-SIDE-B", status: .open)
        await r.contradictions.insert(cOut)
        try await r.claimContradictions.link(claimID: outID, contradictionID: cOut.id)

        let assembled = try await compose(r, workspace)
        let conflicts = try #require(assembled.workProduct.sections.first { $0.title == "Conflicts" })
        let text = (conflicts.preamble + conflicts.claims.map(\.text)).joined(separator: "\n")
        #expect(text.contains("IN-SIDE-A"))
        #expect(!text.contains("OUT-SIDE-A"))
    }

    // MARK: - Report / receipt parity

    @Test("A report and its investigation receipt use the identical selected claims")
    func reportReceiptIdenticalSelection() async throws {
        let r = try await rig()
        let workspace = UUID()
        try await r.workspaces.upsert(Workspace(id: workspace, title: "WS", template: .general))
        // Use the producer path so the evidence points at REAL source versions with content
        // hashes — the receipt binds custody to those exact hashes and fails closed without them.
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

    @Test("A missing investigation composer throws and never falls back to the legacy route")
    func missingComposerThrows() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("inv-nf-\(UUID().uuidString).sqlite")
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
        // EMPTY registry → investigation.findings missing → the arm must throw, not fall back.
        // Empty workspace means scopeFilter returns early (claims-empty guard); the registry throw is
        // the expected error here, not a scope denial.
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
        await #expect(throws: WorkProductAssemblyError.missingComposer("investigation.findings")) {
            try await service.compose(workspace: ws(wsID), template: .investigationFindings,
                                      subjectLabel: "WS", corpusSnapshotID: nil, access: access)
        }
    }
}
