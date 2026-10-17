//
//  OrganiseView.swift
//  Kalsmritikosh
//
//  X-2 — your own folders (groups and sub-groups), with documents that can sit in several
//  groups at once. X-1 — "See Also" and filing suggestions for the selected document when
//  that module is on. Nothing here changes evidence; removals are stamps and can be undone.
//

import SwiftUI
import os

struct OrganiseView: View {
    @Environment(AppState.self) private var appState

    @State private var groups: [UserGroup] = []
    @State private var retired: [UserGroup] = []
    @State private var selectedGroup: UUID?
    @State private var showUnfiled = false
    @State private var members: [UUID] = []
    @State private var names: [UUID: String] = [:]
    @State private var memberships: [UUID: [UserGroup]] = [:]
    @State private var selectedDocument: UUID?
    @State private var newName = ""
    @State private var renameText = ""
    @State private var renaming: UUID?
    @State private var message: String?

    var body: some View {
        HSplitView {
            tree.frame(minWidth: 220, idealWidth: 260, maxWidth: 340)
            VStack(spacing: 0) {
                documents
                if ProductModuleFlags.isEnabled(.filingSuggestions), let doc = selectedDocument {
                    Divider()
                    SeeAlsoPanel(objectID: doc, groups: groups) { await reload() }
                        .frame(minHeight: 160, idealHeight: 220)
                }
            }
            .frame(minWidth: 380)
        }
        .frame(minWidth: 720, minHeight: 460)
        .task { await reload() }
    }

    // MARK: - Tree

    private func depth(_ g: UserGroup) -> Int {
        var d = 0, parent = g.parentID
        let byID = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
        while let p = parent, let pg = byID[p], d < 32 { d += 1; parent = pg.parentID }
        return d
    }

    private var tree: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your folders").font(.title3.bold())
            HStack {
                TextField(selectedGroup == nil ? "New group" : "New group inside the selected one", text: $newName)
                    .onSubmit { Task { await create() } }
                Button("Add") { Task { await create() } }
                    .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            List(selection: Binding(get: { showUnfiled ? nil : selectedGroup },
                                    set: { id in showUnfiled = false; selectedGroup = id; Task { await loadMembers() } })) {
                ForEach(groups) { g in
                    groupRow(g).tag(g.id)
                }
            }
            .overlay {
                if groups.isEmpty {
                    Text("No groups yet. Name one above, or build them from a source folder.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                }
            }
            HStack {
                Button {
                    showUnfiled = true; selectedGroup = nil; Task { await loadMembers() }
                } label: { Label("Not in any group", systemImage: "tray") }
                Spacer()
                Menu("Build from folder") {
                    ForEach(appState.bookmarks.roots) { root in
                        Button(root.displayName) { Task { await mirror(root) } }
                    }
                }
                .fixedSize()
                .help("Create groups that follow a source folder's sub-folders. Files on disk are never moved.")
            }
            if !retired.isEmpty {
                DisclosureGroup("Removed groups (\(retired.count))") {
                    ForEach(retired) { g in
                        HStack {
                            Text(g.name).lineLimit(1)
                            Spacer()
                            Button("Restore") { Task { await run { try await $0.restore(g.id) } } }
                        }
                    }
                }
                .font(.callout)
            }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(10)
    }

    @ViewBuilder
    private func groupRow(_ g: UserGroup) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "folder").foregroundStyle(.secondary)
            if renaming == g.id {
                TextField("Name", text: $renameText).onSubmit { Task { await rename(g.id) } }
            } else {
                Text(g.name).lineLimit(1)
            }
            Spacer()
            Text("\(g.memberCount)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.leading, CGFloat(depth(g)) * 14)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(g.name), \(g.memberCount) documents")
        .contextMenu {
            Button("Rename") { renameText = g.name; renaming = g.id }
            Menu("Move into") {
                Button("Top level") { Task { await run { try await $0.move(g.id, under: nil) } } }
                ForEach(groups.filter { $0.id != g.id }) { other in
                    Button(other.name) { Task { await run { try await $0.move(g.id, under: other.id) } } }
                }
            }
            Divider()
            Button("Remove group") { Task { await run { try await $0.retire(g.id) } } }
        }
    }

    // MARK: - Documents

    private var documents: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(showUnfiled ? "Not in any group" : (groups.first { $0.id == selectedGroup }?.name ?? "Choose a group"))
                .font(.headline)
            List(selection: $selectedDocument) {
                ForEach(members, id: \.self) { doc in
                    HStack {
                        Image(systemName: "doc.text").foregroundStyle(.secondary)
                        Text(names[doc] ?? "Document").lineLimit(1)
                        Spacer()
                        let n = memberships[doc]?.count ?? 0
                        if n > 1 {
                            Text("in \(n) groups").font(.caption2).foregroundStyle(.secondary)
                                .help((memberships[doc] ?? []).map(\.name).joined(separator: ", "))
                        }
                    }
                    .tag(doc)
                    .contextMenu { documentMenu(doc) }
                }
            }
            .overlay {
                if members.isEmpty, selectedGroup != nil || showUnfiled {
                    Text(showUnfiled ? "Every document is in a group." : "This group is empty.")
                        .foregroundStyle(.secondary)
                }
            }
            Text("Right-click a document to also put it in another group (it is not copied), move it, or take it out.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(10)
    }

    @ViewBuilder
    private func documentMenu(_ doc: UUID) -> some View {
        Menu("Also put in") {
            ForEach(groups) { g in
                Button(g.name) { Task { await run { try await $0.add(doc, to: g.id) } } }
            }
        }
        if let current = selectedGroup, !showUnfiled {
            Menu("Move to") {
                ForEach(groups.filter { $0.id != current }) { g in
                    Button(g.name) { Task { await run { try await $0.moveDocument(doc, from: current, to: g.id) } } }
                }
            }
            Button("Take out of this group") { Task { await run { try await $0.remove(doc, from: current) } } }
        }
    }

    // MARK: - Actions

    private func reload() async {
        guard let repo = appState.groupRepository else { return }
        do {
            groups = try await repo.all()
            retired = try await repo.all(includeRetired: true).filter(\.retired)
        } catch {
            KalsmritikoshLog.app.error("Groups read failed: \(error.localizedDescription, privacy: .public)")
            message = error.localizedDescription
        }
        await loadMembers()
    }

    private func loadMembers() async {
        guard let repo = appState.groupRepository else { return }
        do {
            if showUnfiled {
                members = try await repo.unfiled()
            } else if let g = selectedGroup {
                members = try await repo.members(of: g)
            } else {
                members = []
            }
            names = (try? await appState.objects?.sourceFilenames(for: Set(members))) ?? [:]
            var m: [UUID: [UserGroup]] = [:]
            for doc in members { m[doc] = try await repo.groups(containing: doc) }
            memberships = m
            if let d = selectedDocument, !members.contains(d) { selectedDocument = nil }
        } catch {
            KalsmritikoshLog.app.error("Group members read failed: \(error.localizedDescription, privacy: .public)")
            message = error.localizedDescription
        }
    }

    private func run(_ action: (GroupRepository) async throws -> Void) async {
        guard let repo = appState.groupRepository else { return }
        do {
            try await action(repo)
            message = nil
        } catch {
            KalsmritikoshLog.app.error("Group change failed: \(error.localizedDescription, privacy: .public)")
            message = error.localizedDescription
        }
        await reload()
    }

    private func create() async {
        let name = newName
        let parent = showUnfiled ? nil : selectedGroup
        await run { _ = try await $0.create(name: name, parent: parent) }
        if message == nil { newName = "" }
    }

    private func rename(_ id: UUID) async {
        let name = renameText
        await run { try await $0.rename(id, to: name) }
        renaming = nil
    }

    private func mirror(_ root: BookmarkStore.Root) async {
        if let r = await appState.mirrorFolders(of: root) {
            message = "Built \(r.groupsCreated) group\(r.groupsCreated == 1 ? "" : "s") and filed \(r.membershipsAdded) document\(r.membershipsAdded == 1 ? "" : "s")"
                + (r.skippedRetired > 0 ? "; \(r.skippedRetired) group\(r.skippedRetired == 1 ? " you had removed was" : "s you had removed were") left out." : ".")
        } else {
            message = "That folder could not be read."
        }
        let keep = message
        await reload()
        message = keep
    }
}
