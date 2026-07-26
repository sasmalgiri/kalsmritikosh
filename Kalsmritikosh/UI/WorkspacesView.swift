//
//  WorkspacesView.swift
//  Kalsmritikosh
//
//  Persona features Epic 1 (F1 + F2). Organize a bounded matter, case,
//  investigation, research question, or personal issue as a FILTERED VIEW
//  over the one ledger — no evidence is duplicated. This first surface lets
//  the user create/archive workspaces, see membership counts, and manage the
//  shared review model (tags + saved views). Sources are added from Library /
//  Sources (an "Add to workspace" action lands in a later slice); citations,
//  contradictions, and the report composer arrive with F3–F5.
//

import SwiftUI
import os
import UniformTypeIdentifiers
#if canImport(AppKit)
import AppKit
#endif

public struct WorkspacesView: View {
    @Environment(AppState.self) private var appState

    @State private var workspaces: [Workspace] = []
    @State private var selectedID: Workspace.ID?

    // New-workspace form.
    @State private var showingNew = false
    @State private var newTitle = ""
    @State private var newTemplate: WorkspaceTemplate = .general
    @State private var newDescription = ""

    // Selected-workspace detail state.
    @State private var sourceCount = 0
    @State private var entityCount = 0
    @State private var tags: [ReviewTag] = []
    @State private var savedViews: [SavedView] = []
    @State private var newTagName = ""
    @State private var newViewTitle = ""

    // PA-UI-001 — source management.
    @State private var sources: [WorkspaceSourceCandidate] = []
    @State private var showingAddSources = false
    @State private var candidates: [WorkspaceSourceCandidate] = []
    @State private var candidateSelection: Set<UUID> = []
    @State private var candidateSearch = ""
    @State private var loadingCandidates = false
    @State private var applyingSources = false
    @State private var sourceError: String?
    @State private var confirmRemoveLast: WorkspaceSourceCandidate?

    // Report composer (F4).
    @State private var reportTemplate: WorkProductTemplate = .generalSummary
    @State private var reportFormat: ExportFormat = .markdown
    @State private var composing = false
    @State private var reportStatus: String?

    // Research screening (F9) — sheet for researchReview workspaces.
    @State private var showingScreening = false

    public init() {}

    public var body: some View {
        HStack(spacing: 0) {
            listColumn
                .frame(width: 300)
            Divider()
            detailColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(AuroraBackdrop(intensity: 0.5))
        .task { await reloadWorkspaces() }
        .sheet(isPresented: $showingNew) { newWorkspaceSheet }
        .sheet(isPresented: $showingScreening) {
            if let ws = workspaces.first(where: { $0.id == selectedID }) {
                ScreeningView(workspace: ws) { showingScreening = false }
                    .environment(appState)
            }
        }
        .sheet(isPresented: $showingAddSources) {
            if let ws = workspaces.first(where: { $0.id == selectedID }) { addSourcesSheet(ws) }
        }
        .confirmationDialog("Remove the last source?",
                            isPresented: Binding(get: { confirmRemoveLast != nil },
                                                 set: { if !$0 { confirmRemoveLast = nil } }),
                            titleVisibility: .visible) {
            Button("Remove source", role: .destructive) {
                if let c = confirmRemoveLast, let ws = workspaces.first(where: { $0.id == selectedID }) {
                    confirmRemoveLast = nil
                    Task { await removeSource(c, from: ws) }
                }
            }
            Button("Cancel", role: .cancel) { confirmRemoveLast = nil }
        } message: {
            Text("Removing this source will leave the workspace empty. The source and its evidence will remain in the archive.")
        }
    }

    // MARK: - Sources section (PA-UI-001)

    private func sourcesSection(_ ws: Workspace) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Sources", systemImage: "doc.on.doc").font(.headline)
                Spacer()
                Button {
                    Task { await openAddSources(ws) }
                } label: {
                    Label("Add sources…", systemImage: "plus.circle")
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
            }
            Text("The files this workspace may use. Reports draw only on these sources.")
                .font(.caption).foregroundStyle(.secondary)
            if sources.isEmpty {
                Text("No sources have been added. Add files from your archive to define what this workspace may use.")
                    .font(.caption).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            } else {
                ForEach(sources) { src in
                    HStack(spacing: 10) {
                        Image(systemName: "doc.text").foregroundStyle(.tint).frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(src.filename).font(.callout.weight(.medium)).lineLimit(1)
                                availabilityBadge(src.availability)
                            }
                            Text(src.parentPath).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            if let d = src.ingestedAt {
                                Text("\(src.sourceType.rawValue.uppercased()) · ingested \(d.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            } else {
                                Text(src.sourceType.rawValue.uppercased())
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        Spacer(minLength: 0)
                        Button(role: .destructive) {
                            if sources.count == 1 { confirmRemoveLast = src }
                            else { Task { await removeSource(src, from: ws) } }
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).controlSize(.small)
                        .help("Remove from workspace (keeps the file and its evidence)")
                    }
                    .padding(.vertical, 3)
                }
            }
            if let err = sourceError {
                Text(err).font(.caption2).foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .cardSurface(cornerRadius: 12)
    }

    @ViewBuilder
    private func availabilityBadge(_ a: FileAvailability) -> some View {
        let (text, color): (String, Color) = {
            switch a {
            case .available:   return ("available", .green)
            case .offlineRoot: return ("offline", .orange)
            case .missing:     return ("missing", .red)
            }
        }()
        Text(text).font(.caption2)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.15), in: .capsule)
            .foregroundStyle(color)
    }

    // MARK: - Add-sources sheet (PA-UI-001)

    private func addSourcesSheet(_ ws: Workspace) -> some View {
        let visible = candidates.filter {
            candidateSearch.isEmpty
                || $0.filename.localizedCaseInsensitiveContains(candidateSearch)
                || $0.parentPath.localizedCaseInsensitiveContains(candidateSearch)
        }
        return VStack(alignment: .leading, spacing: 12) {
            Text("Add sources to \(ws.title)").font(.title2.weight(.semibold))
            Text("Choose files already ingested into your archive. Adding a source lets this workspace's reports use it.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Search filename or path", text: $candidateSearch)
                .textFieldStyle(.roundedBorder)

            if loadingCandidates {
                ProgressView().frame(maxWidth: .infinity, minHeight: 160)
            } else if candidates.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray").font(.system(size: 26)).foregroundStyle(.secondary)
                    Text("No eligible files").font(.callout.weight(.medium))
                    Text("Every ingested file is already in this workspace, or nothing has been ingested yet. Add files to your archive from the Sources tab first.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(visible) { c in
                            Button {
                                if candidateSelection.contains(c.fileID) { candidateSelection.remove(c.fileID) }
                                else { candidateSelection.insert(c.fileID) }
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: candidateSelection.contains(c.fileID) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(candidateSelection.contains(c.fileID) ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                                    VStack(alignment: .leading, spacing: 1) {
                                        HStack(spacing: 6) {
                                            Text(c.filename).font(.callout).lineLimit(1)
                                            availabilityBadge(c.availability)
                                        }
                                        Text(c.parentPath).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                                .padding(.vertical, 3)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(minHeight: 200, maxHeight: 320)
                HStack(spacing: 12) {
                    Text("\(candidateSelection.count) selected").font(.caption).foregroundStyle(.secondary)
                    Button("Select All Visible") { candidateSelection.formUnion(visible.map(\.fileID)) }
                        .controlSize(.small)
                    Button("Clear Selection") { candidateSelection.removeAll() }
                        .controlSize(.small).disabled(candidateSelection.isEmpty)
                }
            }

            if let err = sourceError { Text(err).font(.caption2).foregroundStyle(.red) }

            HStack {
                Spacer()
                Button("Cancel") { showingAddSources = false }
                    .keyboardShortcut(.cancelAction)
                Button {
                    Task { await applyAddSources(ws) }
                } label: {
                    if applyingSources { ProgressView().controlSize(.small) }
                    else { Text("Add Sources") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(candidateSelection.isEmpty || applyingSources)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func screeningSection(_ ws: Workspace) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Research screening", systemImage: "list.bullet.clipboard").font(.headline)
            Text("A transparent screening log with PRISMA-compatible flow counts. Single-user v1 — not independent dual-review compliance, meta-analysis, or a final risk-of-bias judgment. No AI makes the final inclusion decision.")
                .font(.caption).foregroundStyle(.secondary)
            Button {
                showingScreening = true
            } label: {
                Label("Open screening log", systemImage: "arrow.up.forward.square")
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .cardSurface(cornerRadius: 12)
    }

    // MARK: - List column

    private var listColumn: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "folder.badge.gearshape").foregroundStyle(.tint)
                Text("Workspaces").font(Theme.display(20, .bold))
                Spacer()
                Button {
                    newTitle = ""; newDescription = ""; newTemplate = .general
                    showingNew = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("New workspace")
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            if workspaces.isEmpty {
                emptyList
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(workspaces) { ws in
                            workspaceRow(ws)
                        }
                    }
                    .padding(10)
                }
                .scrollContentBackground(.hidden)
            }
        }
    }

    private var emptyList: some View {
        VStack(spacing: 10) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 30)).foregroundStyle(.tint)
            Text("No workspaces yet")
                .font(.callout.weight(.medium))
            Text("Create one to organize a case, investigation, project, or personal matter as a focused view over your archive.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func workspaceRow(_ ws: Workspace) -> some View {
        Button {
            selectedID = ws.id
            Task { await reloadDetail() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: ws.template.symbolName)
                    .foregroundStyle(.tint)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(ws.title).font(.callout.weight(.medium)).lineLimit(1)
                    Text(ws.template.displayName).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if ws.status == .archived {
                    Text("Archived").font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.secondary.opacity(0.15), in: .capsule)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(
                selectedID == ws.id ? AnyShapeStyle(.tint.opacity(0.14)) : AnyShapeStyle(Color.clear),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Detail column

    @ViewBuilder
    private var detailColumn: some View {
        if let ws = workspaces.first(where: { $0.id == selectedID }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    detailHeader(ws)
                    membershipStrip
                    sourcesSection(ws)
                    templateSection(ws)
                    tagsSection(ws)
                    savedViewsSection(ws)
                    if ws.template == .researchReview { screeningSection(ws) }
                    reportsSection(ws)
                    Spacer(minLength: 8)
                }
                .padding(18)
                .frame(maxWidth: 720, alignment: .leading)
            }
            .scrollContentBackground(.hidden)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 28)).foregroundStyle(.secondary)
                Text("Select a workspace")
                    .font(.title3.weight(.medium)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func detailHeader(_ ws: Workspace) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: ws.template.symbolName).foregroundStyle(.tint)
                Text(ws.title).font(Theme.display(26, .bold)).textSelection(.enabled)
                Spacer()
                Menu {
                    Button(ws.status == .archived ? "Unarchive" : "Archive") {
                        Task { await toggleArchive(ws) }
                    }
                    Divider()
                    Button("Delete workspace", role: .destructive) {
                        Task { await delete(ws) }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 40)
            }
            Text(ws.template.displayName)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(.tint.opacity(0.15), in: .capsule)
                .foregroundStyle(.tint)
            if let d = ws.description, !d.isEmpty {
                Text(d).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Text("Created \(ws.createdAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private var membershipStrip: some View {
        HStack(spacing: 12) {
            countCard(title: "Sources", value: sourceCount, symbol: "doc.text")
            countCard(title: "People / Entities", value: entityCount, symbol: "person.2")
            countCard(title: "Tags", value: tags.count, symbol: "tag")
            countCard(title: "Saved Views", value: savedViews.count, symbol: "line.3.horizontal.decrease.circle")
        }
    }

    private func countCard(title: String, value: Int, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: symbol).foregroundStyle(.tint).imageScale(.small)
            Text("\(value)").font(Theme.display(22, .bold))
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .cardSurface(cornerRadius: 12)
    }

    private func templateSection(_ ws: Workspace) -> some View {
        let exports = PersonaTemplateCatalog.exportKinds(for: ws.template)
        let suggestedViews = PersonaTemplateCatalog.defaultViewTitles(for: ws.template)
        return VStack(alignment: .leading, spacing: 10) {
            Label("\(ws.template.displayName) template", systemImage: ws.template.symbolName)
                .font(.headline)
            // Disclaimer is load-bearing safety text — always shown, verbatim.
            Text(PersonaTemplateCatalog.disclaimer(for: ws.template))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Color.orange.opacity(0.25)))
            if !exports.isEmpty {
                Text("Work products this template offers (produced by the export engine):")
                    .font(.caption2).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 6, alignment: .leading)], alignment: .leading, spacing: 6) {
                    ForEach(exports, id: \.self) { kind in
                        Text(kind).font(.caption2)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.tint.opacity(0.10), in: .capsule).foregroundStyle(.tint)
                    }
                }
            }
            if !suggestedViews.isEmpty {
                Button {
                    Task { await seedSuggestedViews(ws, titles: suggestedViews) }
                } label: {
                    Label("Add \(suggestedViews.count) suggested views", systemImage: "plus.rectangle.on.folder")
                }
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .cardSurface(cornerRadius: 12)
    }

    private func tagsSection(_ ws: Workspace) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Review tags").font(.headline)
            Text("Classify sources and findings. Tags are shared across every persona; templates only rename them.")
                .font(.caption).foregroundStyle(.secondary)
            if !tags.isEmpty {
                FlowTags(tags: tags) { tag in
                    Task { await deleteTag(tag) }
                }
            }
            HStack(spacing: 8) {
                TextField("New tag name", text: $newTagName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await addTag(ws) } }
                Button("Add") { Task { await addTag(ws) } }
                    .disabled(newTagName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .cardSurface(cornerRadius: 12)
    }

    private func savedViewsSection(_ ws: Workspace) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Saved views").font(.headline)
            Text("Reopenable filter sets — e.g. \"disputed findings\" or \"privilege candidates\". Filters are wired to the review model as F2 lands more targets.")
                .font(.caption).foregroundStyle(.secondary)
            if savedViews.isEmpty {
                Text("No saved views yet.").font(.caption).foregroundStyle(.tertiary)
            } else {
                ForEach(savedViews) { view in
                    HStack {
                        Image(systemName: "line.3.horizontal.decrease.circle").foregroundStyle(.tint)
                        Text(view.title).font(.callout)
                        if !view.filters.isEmpty {
                            Text("\(view.filters.count) filter\(view.filters.count == 1 ? "" : "s")")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            Task { await deleteView(view) }
                        } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).controlSize(.small)
                    }
                    .padding(.vertical, 2)
                }
            }
            HStack(spacing: 8) {
                TextField("New view title", text: $newViewTitle)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await addView(ws) } }
                Button("Save view") { Task { await addView(ws) } }
                    .disabled(newViewTitle.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .cardSurface(cornerRadius: 12)
    }

    private func reportsSection(_ ws: Workspace) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Reports", systemImage: "doc.richtext").font(.headline)
            Text("Compose a source-cited work product deterministically from the ledger — dated events, contradictions, and gaps. No AI is used; every dated line cites its source, and conflicts and gaps are shown, not hidden.")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Picker("Report", selection: $reportTemplate) {
                    ForEach(WorkProductTemplate.allCases, id: \.self) { t in
                        Text(t.displayName).tag(t)
                    }
                }
                .frame(maxWidth: 260)
                Picker("Format", selection: $reportFormat) {
                    ForEach(ExportFormat.allCases, id: \.self) { f in
                        Text(f.displayName).tag(f)
                    }
                }
                .frame(maxWidth: 130)
                Button {
                    Task { await composeAndExport(ws) }
                } label: {
                    if composing { ProgressView().controlSize(.small) }
                    else { Label("Compose & Export…", systemImage: "square.and.arrow.up") }
                }
                .disabled(composing || sourceCount == 0)
                Button {
                    Task { await exportReceipt(ws) }
                } label: {
                    Label("Verifiable receipt…", systemImage: "checkmark.seal")
                }
                .disabled(composing || sourceCount == 0)
                .help("Export a tamper-evident receipt: each claim pinned to its cited source + custody hash, re-checkable offline.")
            }
            if sourceCount == 0 {
                Text("Add at least one source before creating a report.")
                    .font(.caption2).foregroundStyle(.orange)
            }
            if let status = reportStatus {
                Text(status).font(.caption2).foregroundStyle(.secondary)
            }
            Text("Scope: this report uses only sources added to this workspace. Claims with evidence outside the workspace are excluded.")
                .font(.caption2).foregroundStyle(.tertiary).italic()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .cardSurface(cornerRadius: 12)
    }

    // MARK: - New workspace sheet

    private var newWorkspaceSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New workspace").font(.title2.weight(.semibold))
            TextField("Title", text: $newTitle)
                .textFieldStyle(.roundedBorder)
            Picker("Template", selection: $newTemplate) {
                ForEach(WorkspaceTemplate.allCases, id: \.self) { t in
                    Label(t.displayName, systemImage: t.symbolName).tag(t)
                }
            }
            .pickerStyle(.menu)
            VStack(alignment: .leading, spacing: 4) {
                Text("Description (optional)").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $newDescription)
                    .frame(height: 70)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.2)))
            }
            Text("A workspace is a focused view over your existing archive. It never copies files — it filters them.")
                .font(.caption2).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { showingNew = false }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { Task { await createWorkspace() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    // MARK: - I/O

    private func reloadWorkspaces() async {
        guard let repo = appState.workspaces else { return }
        let list = (try? await repo.all()) ?? []
        await MainActor.run {
            self.workspaces = list
            if selectedID == nil { selectedID = list.first?.id }
        }
        await reloadDetail()
    }

    private func reloadDetail() async {
        guard let id = selectedID,
              let wsRepo = appState.workspaces,
              let reviewRepo = appState.review else { return }
        let sourceList = (try? await appState.workspaceSourceCoordinator?.currentSources(in: id)) ?? []
        let sources = (try? await wsRepo.sourceCount(in: id)) ?? sourceList.count
        let entities = ((try? await wsRepo.entityIDs(in: id)) ?? []).count
        let tagList = (try? await reviewRepo.tags(inWorkspace: id)) ?? []
        let viewList = (try? await reviewRepo.views(inWorkspace: id)) ?? []
        await MainActor.run {
            self.sources = sourceList
            self.sourceCount = sources
            self.entityCount = entities
            self.tags = tagList
            self.savedViews = viewList
        }
    }

    // MARK: - Source actions (PA-UI-001)

    private func openAddSources(_ ws: Workspace) async {
        await MainActor.run {
            sourceError = nil; candidateSelection = []; candidateSearch = ""
            candidates = []; loadingCandidates = true; showingAddSources = true
        }
        guard let coord = appState.workspaceSourceCoordinator else {
            await MainActor.run { loadingCandidates = false; sourceError = "Source service is not ready." }
            return
        }
        do {
            let list = try await coord.candidates(for: ws.id)
            await MainActor.run { candidates = list; loadingCandidates = false }
        } catch {
            await MainActor.run { loadingCandidates = false; sourceError = "Couldn't load files: \(error.localizedDescription)" }
        }
    }

    private func applyAddSources(_ ws: Workspace) async {
        guard let coord = appState.workspaceSourceCoordinator else {
            await MainActor.run { sourceError = "Source service is not ready." }; return
        }
        let selection = candidateSelection
        await MainActor.run { applyingSources = true; sourceError = nil }
        do {
            try await coord.addSources(selection, to: ws.id, at: Date())
            await MainActor.run { applyingSources = false; showingAddSources = false }
            await reloadDetail()
            await reloadWorkspaces()               // updated_at changed → list re-orders
        } catch {
            // Keep the sheet open and show an actionable error — never close silently.
            await MainActor.run { applyingSources = false; sourceError = "Couldn't add sources: \(error.localizedDescription)" }
        }
    }

    private func removeSource(_ src: WorkspaceSourceCandidate, from ws: Workspace) async {
        guard let coord = appState.workspaceSourceCoordinator else {
            await MainActor.run { sourceError = "Source service is not ready." }; return
        }
        do {
            try await coord.removeSource(src.fileID, from: ws.id, at: Date())
            await MainActor.run { sourceError = nil }
            await reloadDetail()
            await reloadWorkspaces()
        } catch {
            await MainActor.run { sourceError = "Couldn't remove source: \(error.localizedDescription)" }
        }
    }

    private func createWorkspace() async {
        guard let repo = appState.workspaces else { return }
        let ws = Workspace(
            title: newTitle.trimmingCharacters(in: .whitespaces),
            template: newTemplate,
            description: newDescription.isEmpty ? nil : newDescription
        )
        try? await repo.upsert(ws)
        // Seed the template's default tags (F6 groundwork; harmless if empty).
        if let reviewRepo = appState.review {
            for name in PersonaTemplateCatalog.defaultTags(for: newTemplate) {
                try? await reviewRepo.createTag(ReviewTag(workspaceID: ws.id, name: name, kind: "template"))
            }
        }
        await MainActor.run {
            showingNew = false
            selectedID = ws.id
        }
        await reloadWorkspaces()
    }

    private func toggleArchive(_ ws: Workspace) async {
        guard let repo = appState.workspaces else { return }
        try? await repo.setStatus(ws.id, to: ws.status == .archived ? .active : .archived)
        await reloadWorkspaces()
    }

    private func delete(_ ws: Workspace) async {
        guard let repo = appState.workspaces else { return }
        try? await repo.delete(ws.id)
        await MainActor.run { if selectedID == ws.id { selectedID = nil } }
        await reloadWorkspaces()
    }

    private func addTag(_ ws: Workspace) async {
        let name = newTagName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let repo = appState.review else { return }
        try? await repo.createTag(ReviewTag(workspaceID: ws.id, name: name))
        await MainActor.run { newTagName = "" }
        await reloadDetail()
    }

    private func deleteTag(_ tag: ReviewTag) async {
        guard let repo = appState.review else { return }
        try? await repo.deleteTag(tag.id)
        await reloadDetail()
    }

    private func addView(_ ws: Workspace) async {
        let title = newViewTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty, let repo = appState.review else { return }
        try? await repo.saveView(SavedView(workspaceID: ws.id, title: title))
        await MainActor.run { newViewTitle = "" }
        await reloadDetail()
    }

    private func deleteView(_ view: SavedView) async {
        guard let repo = appState.review else { return }
        try? await repo.deleteView(view.id)
        await reloadDetail()
    }

    /// F4 — deterministically compose a work product from the ledger and write
    /// it to disk in the chosen format (with its citation list + manifest).
    /// Build the single assembly service from the app's data store. The view itself no longer
    /// loads claims / events / reviews / evidence — the service owns selection + composition.
    private func makeAssemblyService() -> WorkProductAssemblyService? {
        guard let db = appState.database, let ev = appState.events,
              let cx = appState.contradictions, let gp = appState.gapNodes,
              let wsRepo = appState.workspaces else { return nil }
        do {
            return try WorkProductAssemblyService(database: db, events: ev, contradictions: cx, gaps: gp, workspaces: wsRepo)
        } catch {
            KalsmritikoshLog.storage.error("Assembly service construction failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private func composeAndExport(_ ws: Workspace) async {
        await MainActor.run { composing = true; reportStatus = nil }
        defer { Task { @MainActor in composing = false } }

        guard let assembly = makeAssemblyService() else {
            await MainActor.run { reportStatus = "Export unavailable — the data store is not ready." }
            return
        }
        let assembled: AssembledWorkProduct
        do {
            assembled = try await assembly.compose(
                workspace: ws, template: reportTemplate,
                subjectLabel: ws.title, corpusSnapshotID: nil,
                access: SensitiveAccessContext(scope: SensitiveScope(
                    workspaceID: ws.id,
                    maximumSensitivity: .restricted,
                    permitsPrivilegedMaterial: false,
                    purpose: .export)))
        } catch let WorkProductAssemblyError.evidenceIntegrity(count) {
            // Fail CLOSED — an unsupported material claim blocks the export; nothing written.
            KalsmritikoshLog.storage.error("Export blocked by evidence-integrity gate: \(count, privacy: .public) violation(s)")
            await MainActor.run { reportStatus = "Export blocked: \(count) material claim(s) cite a source that cannot be reopened. Nothing was written." }
            return
        } catch WorkProductAssemblyError.scopedAccessDenied {
            await MainActor.run { reportStatus = "Export blocked: a sensitivity scope error prevented access. Nothing was written." }
            return
        } catch {
            await MainActor.run { reportStatus = "Export failed: \(error.localizedDescription)" }
            return
        }

        let wp = assembled.workProduct
        let style: CitationStyle = ws.template == .researchReview ? .plainBibliography
            : (ws.template == .legalMatter ? .legalExhibit : .footnote)
        let doc = WorkProductComposer.exportable(wp, citationStyle: style, manifest: assembled.manifest)
        let text = WorkProductExporter.render(doc, as: reportFormat)
        // Use the manifest's deduplicated finding count — a claim rendered in both the summary
        // and the chronology is ONE finding, not two.
        let findingCount = assembled.manifest.selectedFindingCount

        #if canImport(AppKit)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(sanitized(ws.title))-\(reportTemplate.rawValue).\(reportFormat.fileExtension)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else {
            await MainActor.run { reportStatus = "Export cancelled." }
            return
        }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            await MainActor.run { reportStatus = "Exported \(findingCount) finding(s) to \(url.lastPathComponent)." }
        } catch {
            await MainActor.run { reportStatus = "Export failed: \(error.localizedDescription)" }
        }
        #else
        await MainActor.run { reportStatus = "Export is available on macOS." }
        #endif
    }

    /// F4 + wedge — export a tamper-evident receipt for the composed work
    /// product: each claim pinned to its cited source(s) + custody hash, chained
    /// so any later edit breaks the seal. Re-checkable offline via Verify Receipt.
    private func exportReceipt(_ ws: Workspace) async {
        await MainActor.run { composing = true; reportStatus = nil }
        defer { Task { @MainActor in composing = false } }

        guard let assembly = makeAssemblyService() else {
            await MainActor.run { reportStatus = "Receipt unavailable — the data store is not ready." }
            return
        }
        // SAME assembly method as the report export — a receipt is sealed over the identical
        // assembled work product, and shares its fail-closed evidence-integrity verdict.
        let assembled: AssembledWorkProduct
        do {
            assembled = try await assembly.compose(
                workspace: ws, template: reportTemplate,
                subjectLabel: ws.title, corpusSnapshotID: nil,
                access: SensitiveAccessContext(scope: SensitiveScope(
                    workspaceID: ws.id,
                    maximumSensitivity: .restricted,
                    permitsPrivilegedMaterial: false,
                    purpose: .export)))
        } catch let WorkProductAssemblyError.evidenceIntegrity(count) {
            KalsmritikoshLog.storage.error("Receipt blocked by evidence-integrity gate: \(count, privacy: .public) violation(s)")
            await MainActor.run { reportStatus = "Receipt blocked: \(count) material claim(s) cite a source that cannot be reopened. Nothing was sealed." }
            return
        } catch WorkProductAssemblyError.scopedAccessDenied {
            await MainActor.run { reportStatus = "Receipt blocked: a sensitivity scope error prevented access. Nothing was sealed." }
            return
        } catch {
            await MainActor.run { reportStatus = "Receipt export failed: \(error.localizedDescription)" }
            return
        }
        // Build the receipt from the assembled + custody-hash-enriched product. Fails CLOSED
        // when a material cited claim has no recorded source-version hash — before any panel.
        let sealed: SealedReceipt
        do {
            sealed = try WorkProductReceiptBuilder().build(from: assembled)
        } catch let WorkProductReceiptError.missingCustodyHashes(count) {
            await MainActor.run { reportStatus = "Receipt blocked: \(count) cited source version(s) have no recorded custody hash. Nothing was sealed." }
            return
        } catch {
            await MainActor.run { reportStatus = "Receipt export failed: \(error.localizedDescription)" }
            return
        }
        guard !sealed.entries.isEmpty else {
            await MainActor.run { reportStatus = "Nothing to receipt yet — compose finds no claims in scope." }
            return
        }
        let json = VerifiableReceipt.json(sealed)

        #if canImport(AppKit)
        let panel = NSSavePanel()
        if let jsonType = UTType(filenameExtension: "json") { panel.allowedContentTypes = [jsonType] }
        panel.nameFieldStringValue = "receipt-\(sanitized(ws.title))-\(reportTemplate.rawValue).json"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else {
            await MainActor.run { reportStatus = "Receipt export cancelled." }
            return
        }
        do {
            try json.write(to: url, atomically: true, encoding: .utf8)
            await MainActor.run { reportStatus = "Sealed \(sealed.entries.count) claim(s) into \(url.lastPathComponent) — verify it anytime in Verify Receipt." }
        } catch {
            await MainActor.run { reportStatus = "Receipt export failed: \(error.localizedDescription)" }
        }
        #else
        await MainActor.run { reportStatus = "Export is available on macOS." }
        #endif
    }

    private func sanitized(_ s: String) -> String {
        String(s.map { $0.isLetter || $0.isNumber ? $0 : "-" }).prefix(40).description
    }

    /// Seed the template's suggested views, skipping ones already present.
    private func seedSuggestedViews(_ ws: Workspace, titles: [String]) async {
        guard let repo = appState.review else { return }
        let existing = Set(savedViews.map(\.title))
        for title in titles where !existing.contains(title) {
            try? await repo.saveView(SavedView(workspaceID: ws.id, title: title))
        }
        await reloadDetail()
    }
}

/// Simple wrapping row of tag chips with a delete affordance.
private struct FlowTags: View {
    let tags: [ReviewTag]
    let onDelete: (ReviewTag) -> Void

    var body: some View {
        // A LazyVGrid with adaptive columns wraps chips without a custom layout.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 6, alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(tags) { tag in
                HStack(spacing: 4) {
                    Text(tag.name).font(.caption)
                    Button { onDelete(tag) } label: {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.tint.opacity(0.12), in: .capsule)
                .foregroundStyle(.tint)
            }
        }
    }
}
