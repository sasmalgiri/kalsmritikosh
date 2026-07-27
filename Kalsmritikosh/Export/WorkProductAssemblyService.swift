//
//  WorkProductAssemblyService.swift
//  Kalsmritikosh
//
//  PA-CUT — the single application service that assembles a validated WorkProduct for export.
//  `WorkspacesView` no longer loads claims / events / reviews / evidence itself, and both the
//  report export and the receipt export call the SAME `compose(...)` method (so a report and
//  its receipt are always the identical assembled product).
//
//  Routing: EXPLICIT per-template capability routing, not a runtime flag. ALL four templates are
//  now registry-backed — each goes through the ClaimSelectionService → WorkProductContext →
//  registered composer → WorkProduct pipeline via an explicit `plan(for:)` route table (the
//  composer order IS the report's section order). There is NO legacy production route: the
//  registry branch is the only branch, and it NEVER silently falls back — a missing composer
//  throws.
//
//  A fail-closed evidence-integrity gate runs on the composed product: an unsupported material
//  claim blocks the export (and therefore the receipt) — nothing is written.
//

import Foundation
import OSLog

public struct AssembledWorkProduct: Sendable {
    public let workProduct: WorkProduct
    public let manifest: ExportManifest
    public nonisolated init(workProduct: WorkProduct, manifest: ExportManifest) {
        self.workProduct = workProduct; self.manifest = manifest
    }
}

public enum WorkProductAssemblyError: Error, Equatable {
    /// The fail-closed gate: N material claims cite a source that cannot be reopened.
    case evidenceIntegrity(violationCount: Int)
    /// A registry-backed template has no registered composer for its central section.
    case missingComposer(String)
    /// SensitiveScope enforcement blocked the export (repo error or no scope repo wired).
    case scopedAccessDenied
}

/// An explicit, ordered plan for a registry-backed template: which composers run and in what
/// output order, and whether disclosures must be prepared. The composer order IS the report's
/// section order — never `registry.all` (alphabetical id order is not report-semantic order).
public struct WorkProductTemplatePlan: Sendable {
    public let composerIDs: [WorkProductComposerID]
    public let requiresDisclosures: Bool
}

public actor WorkProductAssemblyService {
    private let workspaces: WorkspaceRepository
    private let knowledgeObjects: KnowledgeObjectRepository
    private let evidence: EvidenceStore
    private let sensitiveScopes: SensitiveScopeRepository?
    private let selection: ClaimSelectionService
    private let disclosures: DisclosureSelectionService
    private let registry: WorkProductComposerRegistry

    public init(database: Database,
                events: EventsRepository,
                contradictions: ContradictionsRepository,
                gaps: GapNodeRepository,
                workspaces: WorkspaceRepository,
                independenceKeyProvider: (any SourceIndependenceKeyProvider)? = nil) throws {
        let claims = ClaimRepository(database: database)
        let resolver = ClaimResolver(claims: claims, reviews: ClaimReviewRepository(database: database))
        // `events` feeds the selector's temporal lineage; `contradictions`/`gaps` feed the
        // scoped disclosure selector. Neither is used for any whole-archive production route.
        let selection = ClaimSelectionService(
            claims: claims, resolver: resolver,
            temporalClaims: TemporalClaimRepository(database: database),
            events: events, independenceKeyProvider: independenceKeyProvider)
        let disclosures = DisclosureSelectionService(
            contradictions: contradictions,
            claimContradictions: ClaimContradictionRepository(database: database), gaps: gaps)
        // Built-in composers are registered via the throwing factory — a duplicate/misconfigured
        // built-in fails construction here rather than being silently dropped.
        self.init(workspaces: workspaces, knowledgeObjects: KnowledgeObjectRepository(database: database),
                  evidence: EvidenceStore(database: database),
                  sensitiveScopes: SensitiveScopeRepository(database: database),
                  selection: selection, disclosures: disclosures,
                  registry: try WorkProductComposerRegistry.makeDefault())
    }

    /// Designated init — also the seam tests use to inject a registry (e.g. empty, to prove
    /// the registry branch throws rather than falling back). `sensitiveScopes` defaults to nil
    /// so existing test callers compile unchanged; scope filtering is skipped when nil.
    init(workspaces: WorkspaceRepository, knowledgeObjects: KnowledgeObjectRepository,
         evidence: EvidenceStore,
         sensitiveScopes: SensitiveScopeRepository? = nil,
         selection: ClaimSelectionService,
         disclosures: DisclosureSelectionService, registry: WorkProductComposerRegistry) {
        self.workspaces = workspaces; self.knowledgeObjects = knowledgeObjects
        self.evidence = evidence
        self.sensitiveScopes = sensitiveScopes
        self.selection = selection
        self.disclosures = disclosures; self.registry = registry
    }

    /// The registry plan for a template. TOTAL — every template is registry-backed (there is no
    /// legacy route). This explicit table (not a hidden flag) is the report's section order.
    public nonisolated static func plan(for template: WorkProductTemplate) -> WorkProductTemplatePlan {
        switch template {
        case .chronology:
            return WorkProductTemplatePlan(composerIDs: [WorkProductComposerID("history.chronology")],
                                           requiresDisclosures: false)
        case .generalSummary:
            return WorkProductTemplatePlan(
                composerIDs: [WorkProductComposerID("claims.sourced-summary"),
                              WorkProductComposerID("history.chronology"),
                              WorkProductComposerID("evidence.gaps-conflicts")],
                requiresDisclosures: true)
        case .investigationFindings:
            return WorkProductTemplatePlan(
                composerIDs: [WorkProductComposerID("investigation.findings"),
                              WorkProductComposerID("evidence.gaps-conflicts"),
                              WorkProductComposerID("investigation.limitations")],
                requiresDisclosures: true)
        case .factMemo:
            return WorkProductTemplatePlan(
                composerIDs: [WorkProductComposerID("fact-memo.core")],
                requiresDisclosures: true)
        }
    }

    // MARK: - Compose

    public func compose(workspace: Workspace, template: WorkProductTemplate,
                        subjectLabel: String, corpusSnapshotID: UUID?,
                        access: SensitiveAccessContext) async throws -> AssembledWorkProduct {
        // OPS-003C.2: three mandatory guards — purpose, workspace identity, repo availability.
        // Any bypass here would allow unscoped reports; all three must hold before composition begins.
        guard access.scope.purpose == .export else {
            KalsmritikoshLog.storage.error(
                "WorkProductAssemblyService: compose called with purpose '\(access.scope.purpose.rawValue, privacy: .public)' — .export required; denying.")
            throw WorkProductAssemblyError.scopedAccessDenied
        }
        guard access.scope.workspaceID == workspace.id else {
            KalsmritikoshLog.storage.error(
                "WorkProductAssemblyService: compose access.workspaceID does not match workspace.id — denying.")
            throw WorkProductAssemblyError.scopedAccessDenied
        }
        guard sensitiveScopes != nil else {
            KalsmritikoshLog.storage.error(
                "WorkProductAssemblyService: SensitiveScopeRepository not wired — denying.")
            throw WorkProductAssemblyError.scopedAccessDenied
        }
        // Registry arm ONLY — every template is registry-backed. A failure here THROWS; there is
        // no legacy fallback.
        let composed = try await composeThroughRegistry(
            plan: Self.plan(for: template), workspace: workspace, template: template,
            subjectLabel: subjectLabel, corpusSnapshotID: corpusSnapshotID, access: access)
        // PA-REC-001 — enrich every citation with its EXACT source-version custody hash ONCE, here,
        // so both the report and its receipt consume the identical hash-pinned product.
        let wp = try await enrichCustodyHashes(composed)
        // Fail-closed gate on both arms (single point → report and receipt share the verdict).
        let integrity = WorkProductValidator().validateProductionExport(wp)
        guard integrity.isValid else {
            throw WorkProductAssemblyError.evidenceIntegrity(violationCount: integrity.violations.count)
        }
        return AssembledWorkProduct(workProduct: wp, manifest: manifest(for: wp, workspace: workspace))
    }

    // MARK: - Registry arm

    private func composeThroughRegistry(plan: WorkProductTemplatePlan, workspace: Workspace,
                                        template: WorkProductTemplate,
                                        subjectLabel: String, corpusSnapshotID: UUID?,
                                        access: SensitiveAccessContext) async throws -> WorkProduct {
        // Workspace membership is resolved here (outside the Claim model). Claim selection runs
        // ONCE; disclosure selection runs ONCE over the same selected claims. No global fallback.
        let members = Set(try await workspaces.entityIDs(in: workspace.id))
        // PA-PROD B4 — the workspace's evidence-SOURCE boundary: its source files' KnowledgeObject
        // ids. A claim is selected only when its subject is a member AND all of its evidence lives
        // inside this set, so a member's claim backed only by an out-of-workspace source can never
        // leak into the export.
        let sourceFileIDs = try await workspaces.sourceIDs(in: workspace.id)
        let allowedObjectIDs = try await knowledgeObjects.objectIDs(inFileIDs: sourceFileIDs)
        var context = try await selection.buildContext(
            scope: .workspace(id: workspace.id, memberSubjectIDs: members, allowedObjectIDs: allowedObjectIDs),
            subjectLabel: subjectLabel, corpusSnapshotID: corpusSnapshotID)
        // OPS-003C.2: sensitivity scope filter always enforced; repo availability was verified
        // at compose() entry so scopeFilter will not throw on nil-repo here.
        context = try await scopeFilter(context, access: access)
        if plan.requiresDisclosures {
            let conflicts = try await disclosures.conflicts(forSelectedClaims: context.selectedClaims)
            let scopedGaps = try await disclosures.gaps(forSelectedClaims: context.selectedClaims)
            context = WorkProductContext(
                selectedClaims: context.selectedClaims, selectedConflicts: conflicts, selectedGaps: scopedGaps,
                subjectLabel: subjectLabel, workspaceID: workspace.id, corpusSnapshotID: corpusSnapshotID)
        }
        // Run composers in PLAN ORDER and flatten — that order is the report's section order.
        var sections: [WorkProductSection] = []
        for composerID in plan.composerIDs {
            guard let composer = registry.composer(for: composerID) else {
                throw WorkProductAssemblyError.missingComposer(composerID.rawValue)
            }
            sections += composer.compose(context)
        }
        return WorkProduct(
            template: template,
            title: "\(workspace.title) — \(template.displayName)",
            subtitle: "Work product for the \"\(workspace.title)\" workspace (\(workspace.template.displayName)).",
            sections: sections,
            disclaimer: PersonaTemplateCatalog.disclaimer(for: workspace.template))
    }

    // MARK: - OPS-003C sensitivity scope filter

    /// Remove claims whose evidence KOs exceed the access scope, before ANY composer renders.
    /// Mirrors the permitted() logic in SensitiveRetrievalPolicy exactly.
    /// Fails CLOSED: if the scope repository errors, throws scopedAccessDenied (nothing exported).
    private func scopeFilter(_ ctx: WorkProductContext,
                             access: SensitiveAccessContext) async throws -> WorkProductContext {
        // Early return for empty selection — nothing to filter. Avoids a repo round-trip for
        // workspaces that have no claims in scope (e.g. new workspaces, failing registry tests).
        let claims = ctx.selectedClaims
        guard !claims.isEmpty else { return ctx }
        guard let repository = sensitiveScopes else {
            KalsmritikoshLog.storage.error(
                "WorkProductAssemblyService: scopeFilter — SensitiveScopeRepository not wired — denying all.")
            throw WorkProductAssemblyError.scopedAccessDenied
        }

        // Collect all evidence KO IDs from all selected claims.
        var koIDs: Set<UUID> = []
        for sc in claims {
            for ref in sc.resolved.claim.evidence { koIDs.insert(ref.objectID) }
        }

        let targets = koIDs.map { SensitiveScopeTarget(kind: .knowledgeObject, id: $0) }
        let resolutions: [SensitiveScopeTarget: ProtectionResolution]
        do {
            resolutions = try await repository.batchResolution(targets)
        } catch {
            KalsmritikoshLog.storage.error(
                "WorkProductAssemblyService: scope batchResolution failed — denying all. \(error, privacy: .public)")
            throw WorkProductAssemblyError.scopedAccessDenied
        }

        func permitted(_ koID: UUID) -> Bool {
            let t = SensitiveScopeTarget(kind: .knowledgeObject, id: koID)
            switch resolutions[t] {
            case .resolved(let label): return access.scope.permits(label)
            case .brokenLineage:       return false
            case nil:
                // OPS-003C.2.1: fail-closed on any resolution gap — a target absent from
                // the batch result is denied, not treated as default internalLevel.
                return false
            }
        }

        // A claim is withheld when ANY of its evidence KOs is blocked.
        let filtered = claims.filter { sc in
            sc.resolved.claim.evidence.allSatisfy { permitted($0.objectID) }
        }
        if filtered.count < claims.count {
            KalsmritikoshLog.storage.notice(
                "WorkProductAssemblyService: scope filter withheld \(claims.count - filtered.count, privacy: .public) claim(s) with blocked evidence KOs.")
        }
        return WorkProductContext(
            selectedClaims:   filtered,
            selectedConflicts: ctx.selectedConflicts,
            selectedGaps:     ctx.selectedGaps,
            subjectLabel:     ctx.subjectLabel,
            workspaceID:      ctx.workspaceID,
            corpusSnapshotID: ctx.corpusSnapshotID)
    }

    // MARK: - PA-REC-001 custody-hash enrichment

    /// Populate each citation's `sourceHash` from its EXACT cited source version's content hash.
    /// Preserves every other field (ids, order, roles, locators, sourceClaimID, occurrence
    /// identity); only fills a nil `sourceHash`. Never substitutes the current file hash, and never
    /// overwrites a hash already present.
    private func enrichCustodyHashes(_ wp: WorkProduct) async throws -> WorkProduct {
        var versionIDs = Set<UUID>()
        for section in wp.sections {
            for claim in section.claims {
                for c in claim.supporting + claim.contradicting {
                    if let v = c.sourceVersionID { versionIDs.insert(v) }
                }
            }
        }
        guard !versionIDs.isEmpty else { return wp }
        let hashes = try await evidence.contentHashes(forSourceVersionIDs: versionIDs)
        guard !hashes.isEmpty else { return wp }
        func enrich(_ c: CitationRecord) -> CitationRecord {
            guard c.sourceHash == nil, let v = c.sourceVersionID, let h = hashes[v] else { return c }
            var copy = c; copy.sourceHash = h; return copy
        }
        var out = wp
        out.sections = wp.sections.map { section in
            var s = section
            s.claims = section.claims.map { claim in
                var k = claim
                k.supporting = claim.supporting.map(enrich)
                k.contradicting = claim.contradicting.map(enrich)
                return k
            }
            return s
        }
        return out
    }

    // MARK: - Manifest (derived from the composed product, not raw ledger loads)

    private func manifest(for wp: WorkProduct, workspace: Workspace) -> ExportManifest {
        let appVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
        // A label is resolved ONLY when EVERY citation grouped under it is resolved — one
        // resolved citation must not mask an unresolved one sharing the same title.
        var resolvedByLabel: [String: Bool] = [:]
        for c in wp.allCitations { resolvedByLabel[c.sourceTitle] = (resolvedByLabel[c.sourceTitle] ?? true) && c.isResolved }
        // A canonical claim rendered in several sections (summary + chronology) counts ONCE by
        // its sourceClaimID; output-only rows (gap/conflict disclosures) count by occurrence.
        var canonicalClaimIDs = Set<UUID>()
        var outputOnlyCount = 0
        for claim in wp.sections.flatMap(\.claims) {
            if let cid = claim.sourceClaimID { canonicalClaimIDs.insert(cid) } else { outputOnlyCount += 1 }
        }
        let findingCount = canonicalClaimIDs.count + outputOnlyCount
        // PA-REC-001 — the cited source VERSIONS and their custody hashes, one hash per version
        // (unique (sourceVersionID, sourceHash)), so a claim rendered in both summary and
        // chronology contributes a single recorded hash — not one per rendered occurrence.
        var hashByVersion: [UUID: String] = [:]
        var versionSet = Set<UUID>()
        for c in wp.allCitations {
            guard let v = c.sourceVersionID else { continue }
            versionSet.insert(v)
            if let h = c.sourceHash, hashByVersion[v] == nil { hashByVersion[v] = h }
        }
        let sourceVersionIDs = versionSet.map(\.uuidString).sorted()
        let sourceHashes = hashByVersion.keys.sorted(by: { $0.uuidString < $1.uuidString }).map { hashByVersion[$0]! }
        return ExportManifest(
            exportedAt: Date(),
            appVersion: appVersion,
            schemaVersion: SchemaMigrations.latestVersion,
            workspaceTitle: workspace.title,
            workspaceTemplate: workspace.template.displayName,
            sourceVersionIDs: sourceVersionIDs,
            sourceHashes: sourceHashes,
            selectedFindingCount: findingCount,
            citationMap: resolvedByLabel.keys.sorted().map { CitationMapEntry(label: $0, resolved: resolvedByLabel[$0] ?? false) },
            reviewStatusSummary: "\(findingCount) claim(s) in scope",
            knownLimitations: [
                "Deterministic composition — no generative model was used.",
                PersonaTemplateCatalog.disclaimer(for: workspace.template)
            ])
    }
}
