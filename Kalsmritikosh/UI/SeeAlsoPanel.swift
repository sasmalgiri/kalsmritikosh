//
//  SeeAlsoPanel.swift
//  Kalsmritikosh
//
//  X-1 — for one document: the documents most like it (with the closest pair of passages as
//  the reason) and the groups or tags it most resembles. Suggestions only: filing happens
//  when the person presses "File here".
//

import SwiftUI
import os

extension AppState {
    /// The similarity engine over the active embedding model, or nil before boot / with the module off.
    var documentSimilarity: DocumentSimilarity? {
        guard ProductModuleFlags.isEnabled(.filingSuggestions), let database, let vectorStore else { return nil }
        return DocumentSimilarity(database: database, modelID: vectorStore.embeddingModelID)
    }
}

struct SeeAlsoPanel: View {
    @Environment(AppState.self) private var appState
    let objectID: UUID
    let groups: [UserGroup]
    let onFiled: () async -> Void

    @State private var similar: [SimilarDocument] = []
    @State private var suggestions: [FilingSuggestion] = []
    @State private var names: [UUID: String] = [:]
    @State private var status: String?
    @State private var loading = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("See Also").font(.headline)
                    if loading { ProgressView().controlSize(.small) }
                }
                if let status { Text(status).font(.callout).foregroundStyle(.secondary) }
                ForEach(suggestions, id: \.self) { s in
                    HStack {
                        Label(s.name, systemImage: s.isGroup ? "folder" : "tag")
                        Text(String(format: "%.0f%% alike", s.score * 100)).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("File here") { Task { await file(s) } }
                    }
                }
                ForEach(similar, id: \.self) { d in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(names[d.objectID] ?? "Document").font(.callout.weight(.medium)).lineLimit(1)
                            Spacer()
                            Text(String(format: "%.0f%%", d.score * 100)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                        if let r = d.reason {
                            Text("\u{201C}\(r.theirs)\u{201D}").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
        .task(id: objectID) { await load() }
    }

    private func load() async {
        guard let engine = appState.documentSimilarity else { return }
        loading = true
        defer { loading = false }
        let authorizer = appState.screenAuthorizer
        do {
            switch try await engine.seeAlso(objectID, allowed: { id in
                await authorizer?.authorize(id, boundary: .globalOwner) ?? false
            }) {
            case .results(let r):
                similar = r
                status = r.isEmpty ? "No other document is close enough to show." : nil
            case .notYetEmbedded:
                similar = []
                status = "This document has not been read for meaning yet; suggestions appear once it has."
            case .noConfidentSuggestion:
                similar = []
            }
            if case .results(let s) = try await engine.suggestFiling(objectID) { suggestions = s } else { suggestions = [] }
            names = (try? await appState.objects?.sourceFilenames(for: Set(similar.map(\.objectID)))) ?? [:]
        } catch {
            KalsmritikoshLog.app.error("See Also failed: \(error.localizedDescription, privacy: .public)")
            status = "Suggestions could not be worked out: \(error.localizedDescription)"
        }
    }

    private func file(_ s: FilingSuggestion) async {
        guard let database = appState.database else { return }
        do {
            switch s.target {
            case .group(let id): try await GroupRepository(database: database).add(objectID, to: id)
            case .tag(let id): try await TagsRepository(database: database).attach(tagID: id, to: .object, objectID)
            }
            await onFiled()
            await load()
        } catch {
            KalsmritikoshLog.app.error("Filing failed: \(error.localizedDescription, privacy: .public)")
            status = error.localizedDescription
        }
    }
}

extension FilingSuggestion {
    var isGroup: Bool { if case .group = target { return true } else { return false } }
}
