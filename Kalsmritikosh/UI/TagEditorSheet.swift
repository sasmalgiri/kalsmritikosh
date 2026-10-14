//
//  TagEditorSheet.swift
//  Kalsmritikosh
//
//  W1-4 — tag a document, remove a tag (soft), and manage tags (rename, merge).
//  Tags are the user's organisation only; they never change the evidence.
//

import SwiftUI
import os

extension AppState {
    /// W1-4 — tags repository (stateless actor over the ledger), nil before boot or when the module is off.
    public var tagsRepository: TagsRepository? {
        guard ProductModuleFlags.isEnabled(.userTags), let database else { return nil }
        return TagsRepository(database: database)
    }
}

struct TagEditorSheet: View {
    let subjectKind: TagSubjectKind
    let subjectID: UUID
    let subjectLabel: String

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var current: [UserTag] = []
    @State private var all: [UserTag] = []
    @State private var newName = ""
    @State private var message: String?
    @State private var renaming: UserTag?
    @State private var renameText = ""
    @State private var mergeSource: UserTag?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tags").font(.title3.bold())
            Text(subjectLabel).font(.caption).foregroundStyle(.secondary).lineLimit(2)

            HStack {
                TextField("Add a tag", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await add(newName) } }
                Button("Add") { Task { await add(newName) } }
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if !current.isEmpty {
                Text("On this item").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                FlowRow(items: current) { tag in
                    HStack(spacing: 4) {
                        Text(tag.name)
                        Button { Task { await remove(tag) } } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove tag \(tag.name)")
                    }
                    .font(.caption)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.quaternary, in: Capsule())
                }
            }

            let others = all.filter { t in !current.contains(where: { $0.id == t.id }) }
            if !others.isEmpty {
                Text("Your tags").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(others) { tag in
                            HStack {
                                Button { Task { await add(tag.name) } } label: {
                                    Label("\(tag.name) (\(tag.count))", systemImage: "tag")
                                }
                                .buttonStyle(.borderless)
                                Spacer()
                                Menu {
                                    Button("Rename…") { renaming = tag; renameText = tag.name }
                                    Menu("Merge into") {
                                        ForEach(all.filter { $0.id != tag.id }) { target in
                                            Button(target.name) { Task { await merge(tag, into: target) } }
                                        }
                                    }
                                } label: { Image(systemName: "ellipsis.circle") }
                                .menuStyle(.borderlessButton)
                                .fixedSize()
                            }
                        }
                    }
                }
                .frame(maxHeight: 180)
            }

            if let message {
                Text(message).font(.caption).foregroundStyle(.orange)
            }
            Text("Tags organise your work. They never change what the evidence says, and removing a tag keeps its history.")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(18)
        .frame(width: 420)
        .task { await reload() }
        .sheet(item: $renaming) { tag in
            VStack(alignment: .leading, spacing: 10) {
                Text("Rename “\(tag.name)”").font(.headline)
                TextField("New name", text: $renameText).textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button("Cancel") { renaming = nil }
                    Button("Rename") { Task { await rename(tag, renameText); renaming = nil } }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16).frame(width: 320)
        }
    }

    private func reload() async {
        guard let repo = appState.tagsRepository else { message = "Tags are switched off in Settings ▸ Modules."; return }
        do {
            current = try await repo.tags(for: subjectKind, subjectID)
            all = try await repo.allTags()
        } catch {
            message = error.localizedDescription
            KalsmritikoshLog.app.error("Tags load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func add(_ name: String) async {
        guard let repo = appState.tagsRepository else { return }
        do {
            let id = try await repo.tag(named: name)
            try await repo.attach(tagID: id, to: subjectKind, subjectID)
            newName = ""
            await reload()
        } catch {
            message = error.localizedDescription
            KalsmritikoshLog.app.error("Tag add failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func remove(_ tag: UserTag) async {
        guard let repo = appState.tagsRepository else { return }
        do { try await repo.detach(tagID: tag.id, from: subjectKind, subjectID); await reload() }
        catch {
            message = error.localizedDescription
            KalsmritikoshLog.app.error("Tag remove failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func rename(_ tag: UserTag, _ name: String) async {
        guard let repo = appState.tagsRepository else { return }
        do { try await repo.rename(tagID: tag.id, to: name); await reload() }
        catch {
            message = error.localizedDescription
            KalsmritikoshLog.app.error("Tag rename failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func merge(_ source: UserTag, into target: UserTag) async {
        guard let repo = appState.tagsRepository else { return }
        do { try await repo.merge(source.id, into: target.id); await reload() }
        catch {
            message = error.localizedDescription
            KalsmritikoshLog.app.error("Tag merge failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Minimal wrapping row for tag chips.
struct FlowRow<Item: Identifiable, Content: View>: View {
    let items: [Item]
    @ViewBuilder let content: (Item) -> Content
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { ForEach(items) { content($0) } }
            VStack(alignment: .leading, spacing: 6) { ForEach(items) { content($0) } }
        }
    }
}
