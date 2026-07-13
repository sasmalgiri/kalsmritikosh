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
                    templateSection(ws)
                    tagsSection(ws)
                    savedViewsSection(ws)
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
        let sources = (try? await wsRepo.sourceCount(in: id)) ?? 0
        let entities = ((try? await wsRepo.entityIDs(in: id)) ?? []).count
        let tagList = (try? await reviewRepo.tags(inWorkspace: id)) ?? []
        let viewList = (try? await reviewRepo.views(inWorkspace: id)) ?? []
        await MainActor.run {
            self.sourceCount = sources
            self.entityCount = entities
            self.tags = tagList
            self.savedViews = viewList
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
