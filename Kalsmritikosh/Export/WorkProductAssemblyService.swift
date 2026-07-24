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

public actor WorkProductAssemblyService {
    private let events: EventsRepository
    private let contradictions: ContradictionsRepository
    private let gaps: GapNodeRepository
    private let workspaces: WorkspaceRepository
    private let selection: ClaimSelectionService
    private let registry: WorkProductComposerRegistry

    public init(database: Database,
                events: EventsRepository,
                contradictions: ContradictionsRepository,
                gaps: GapNodeRepository,
                workspaces: WorkspaceRepository,
                independenceKeyProvider: (any SourceIndependenceKeyProvider)? = nil) {
        let claims = ClaimRepository(database: database)
        let resolver = ClaimResolver(claims: claims, reviews: ClaimReviewRepository(database: database))
        let selection = ClaimSelectionService(
            claims: claims, resolver: resolver,
            temporalClaims: TemporalClaimRepository(database: database),
            events: events, independenceKeyProvider: independenceKeyProvider)
        var registry = WorkProductComposerRegistry()
        try? registry.register(HistoryChronologyComposer())
        try? registry.register(ClaimMatrixComposer())
        self.init(events: events, contradictions: contradictions, gaps: gaps,
                  workspaces: workspaces, selection: selection, registry: registry)
    }

    /// Designated init — also the seam tests use to inject a registry (e.g. empty, to prove
    /// the registry branch never falls back to the legacy composer).
    init(events: EventsRepository, contradictions: ContradictionsRepository, gaps: GapNodeRepository,
         workspaces: WorkspaceRepository, selection: ClaimSelectionService, registry: WorkProductComposerRegistry) {
        self.events = events; self.contradictions = contradictions; self.gaps = gaps
        self.workspaces = workspaces; self.selection = selection; self.registry = registry
    }

    /// The route table: which templates the registry pipeline fully supports today. Explicit
    /// and testable — this is the migration's source of truth, not a hidden flag.
    public nonisolated static func isRegistryBacked(_ template: WorkProductTemplate) -> Bool {
        switch template {
        case .chronology:                                       return true
        case .generalSummary, .investigationFindings, .factMemo: return false
        }
    }

    // MARK: - Compose

    public func compose(workspace: Workspace, template: WorkProductTemplate,
                        subjectLabel: String, corpusSnapshotID: UUID?) async throws -> AssembledWorkProduct {
        let wp: WorkProduct
        switch template {
        case .chronology:
            // Registry arm. A failure here THROWS — it must never invoke the legacy composer.
            wp = try await composeThroughRegistry(workspace: workspace, template: template,
                                                  subjectLabel: subjectLabel, corpusSnapshotID: corpusSnapshotID)
        case .generalSummary, .investigationFindings, .factMemo:
            wp = try await composeThroughLegacy(workspace: workspace, template: template)
        }
        // Fail-closed gate on both arms (single point → report and receipt share the verdict).
        let integrity = WorkProductValidator().validateProductionExport(wp)
        guard integrity.isValid else {
            throw WorkProductAssemblyError.evidenceIntegrity(violationCount: integrity.violations.count)
        }
        return AssembledWorkProduct(workProduct: wp, manifest: manifest(for: wp, workspace: workspace))
    }

    // MARK: - Registry arm

    private func composeThroughRegistry(workspace: Workspace, template: WorkProductTemplate,
                                        subjectLabel: String, corpusSnapshotID: UUID?) async throws -> WorkProduct {
        // Workspace membership is resolved here (outside the Claim model) and handed to the
        // selector as the scope; there is no corpus-global fallback.
        let members = Set(try await workspaces.entityIDs(in: workspace.id))
        let context = try await selection.buildContext(
            scope: .workspace(id: workspace.id, memberSubjectIDs: members),
            subjectLabel: subjectLabel, corpusSnapshotID: corpusSnapshotID)
        guard let composer = registry.composer(for: WorkProductComposerID("history.chronology")) else {
            throw WorkProductAssemblyError.missingComposer("history.chronology")
        }
        return WorkProduct(
            template: template,
            title: "\(workspace.title) — \(template.displayName)",
            subtitle: "Work product for the \"\(workspace.title)\" workspace (\(workspace.template.displayName)).",
            sections: composer.compose(context),
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

    // MARK: - Manifest (derived from the composed product, not raw ledger loads)

    private func manifest(for wp: WorkProduct, workspace: Workspace) -> ExportManifest {
        let appVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
        var resolvedByLabel: [String: Bool] = [:]
        for c in wp.allCitations { resolvedByLabel[c.sourceTitle] = (resolvedByLabel[c.sourceTitle] ?? false) || c.isResolved }
        let findingCount = wp.sections.reduce(0) { $0 + $1.claims.count }
        return ExportManifest(
            exportedAt: Date(),
            appVersion: appVersion,
            schemaVersion: SchemaMigrations.latestVersion,
            workspaceTitle: workspace.title,
            workspaceTemplate: workspace.template.displayName,
            selectedFindingCount: findingCount,
            citationMap: resolvedByLabel.keys.sorted().map { CitationMapEntry(label: $0, resolved: resolvedByLabel[$0] ?? false) },
            reviewStatusSummary: "\(findingCount) claim(s) in scope",
            knownLimitations: [
                "Deterministic composition — no generative model was used.",
                PersonaTemplateCatalog.disclaimer(for: workspace.template)
            ])
    }
}
