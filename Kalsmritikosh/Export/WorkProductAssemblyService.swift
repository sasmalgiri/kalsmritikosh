//
//  WorkProductAssemblyService.swift
//  Kalsmritikosh
//
//  PA-CUT — the single application service that assembles a validated WorkProduct for export.
//  `WorkspacesView` no longer loads claims / events / reviews / evidence itself, and both the
//  report export and the receipt export call the SAME `compose(...)` method (so a report and
//  its receipt are always the identical assembled product).
//
//  Cutover strategy: EXPLICIT per-template capability routing, not a runtime flag.
//   • Templates whose required sections have a genuine registry composer go through the new
//     ClaimSelectionService → WorkProductContext → registered composer → WorkProduct pipeline.
//   • The remaining templates use the legacy WorkProductComposer, unchanged.
//   • The registry branch NEVER silently falls back to legacy on failure — an error propagates.
//   • As each template reaches parity it moves from the legacy arm to the registry arm; when
//     all four are registry-backed the legacy production branch is removed.
//
//  A fail-closed evidence-integrity gate runs on BOTH arms: an unsupported material claim
//  blocks the export (and therefore the receipt) — nothing is written.
//

import Foundation

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
}

/// An explicit, ordered plan for a registry-backed template: which composers run and in what
/// output order, and whether disclosures must be prepared. The composer order IS the report's
/// section order — never `registry.all` (alphabetical id order is not report-semantic order).
public struct WorkProductTemplatePlan: Sendable {
    public let composerIDs: [WorkProductComposerID]
    public let requiresDisclosures: Bool
}

public actor WorkProductAssemblyService {
    private let events: EventsRepository
    private let contradictions: ContradictionsRepository
    private let gaps: GapNodeRepository
    private let workspaces: WorkspaceRepository
    private let knowledgeObjects: KnowledgeObjectRepository
    private let evidence: EvidenceStore
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
        let selection = ClaimSelectionService(
            claims: claims, resolver: resolver,
            temporalClaims: TemporalClaimRepository(database: database),
            events: events, independenceKeyProvider: independenceKeyProvider)
        let disclosures = DisclosureSelectionService(
            contradictions: contradictions,
            claimContradictions: ClaimContradictionRepository(database: database), gaps: gaps)
        // Built-in composers are registered via the throwing factory — a duplicate/misconfigured
        // built-in fails construction here rather than being silently dropped.
        self.init(events: events, contradictions: contradictions, gaps: gaps,
                  workspaces: workspaces, knowledgeObjects: KnowledgeObjectRepository(database: database),
                  evidence: EvidenceStore(database: database),
                  selection: selection, disclosures: disclosures,
                  registry: try WorkProductComposerRegistry.makeDefault())
    }

    /// Designated init — also the seam tests use to inject a registry (e.g. empty, to prove
    /// the registry branch never falls back to the legacy composer).
    init(events: EventsRepository, contradictions: ContradictionsRepository, gaps: GapNodeRepository,
         workspaces: WorkspaceRepository, knowledgeObjects: KnowledgeObjectRepository,
         evidence: EvidenceStore,
         selection: ClaimSelectionService,
         disclosures: DisclosureSelectionService, registry: WorkProductComposerRegistry) {
        self.events = events; self.contradictions = contradictions; self.gaps = gaps
        self.workspaces = workspaces; self.knowledgeObjects = knowledgeObjects
        self.evidence = evidence
        self.selection = selection
        self.disclosures = disclosures; self.registry = registry
    }

    /// The registry plan for a template, or nil when the template is still legacy-backed. This
    /// explicit table (not a hidden flag) is the migration's source of truth AND the report's
    /// section order.
    public nonisolated static func plan(for template: WorkProductTemplate) -> WorkProductTemplatePlan? {
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
        case .investigationFindings, .factMemo:
            return nil
        }
    }

    public nonisolated static func isRegistryBacked(_ template: WorkProductTemplate) -> Bool {
        plan(for: template) != nil
    }

    // MARK: - Compose

    public func compose(workspace: Workspace, template: WorkProductTemplate,
                        subjectLabel: String, corpusSnapshotID: UUID?) async throws -> AssembledWorkProduct {
        let composed: WorkProduct
        if let plan = Self.plan(for: template) {
            // Registry arm. A failure here THROWS — it must never invoke the legacy composer.
            composed = try await composeThroughRegistry(plan: plan, workspace: workspace, template: template,
                                                        subjectLabel: subjectLabel, corpusSnapshotID: corpusSnapshotID)
        } else {
            composed = try await composeThroughLegacy(workspace: workspace, template: template)
        }
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
                                        subjectLabel: String, corpusSnapshotID: UUID?) async throws -> WorkProduct {
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

    // MARK: - Legacy arm (unchanged behaviour; removed per-template as parity is reached)

    private func composeThroughLegacy(workspace: Workspace, template: WorkProductTemplate) async throws -> WorkProduct {
        let eventRows = (try? await events.recent(limit: 500)) ?? []
        let filenames = (try? await events.sourceFilenames(forEventIDs: eventRows.map(\.id))) ?? [:]
        let inputs = eventRows.map { WorkProductComposer.EventInput(event: $0, filename: filenames[$0.id]) }
        let cx = await contradictions.all()
        let gp = await gaps.all(includeDismissed: false)
        return WorkProductComposer.compose(
            template: template,
            title: "\(workspace.title) — \(template.displayName)",
            scopeNote: "Work product for the \"\(workspace.title)\" workspace (\(workspace.template.displayName)).",
            events: inputs, contradictions: cx, gaps: gp,
            disclaimer: PersonaTemplateCatalog.disclaimer(for: workspace.template))
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
