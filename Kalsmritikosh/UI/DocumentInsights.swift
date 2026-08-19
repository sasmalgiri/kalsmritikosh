//
//  DocumentInsights.swift
//  Kalsmritikosh
//
//  COMPETITOR-DNA (2026-08-19) — the last two veteran patterns:
//  - "See also" (DEVONthink): related documents beside the one you're
//    reading — serendipitous connections you didn't search for. Vector
//    similarity in Full power; a term-overlap FTS fallback in Lightning.
//  - Entity chips (DocumentCloud): the people, organizations, and places
//    named in a document, one tap from searching them.
//
//  The pure ranking/term helpers live here so they are unit-testable; the
//  panel view reads only existing repositories (no new storage).
//

import Foundation
import SwiftUI

/// Pure helpers behind the See-Also panel.
public nonisolated enum SeeAlso {

    /// Rank vector hits into related DOCUMENTS: best score per document,
    /// the source document excluded, top-N by score.
    public static func rankDocuments(
        hits: [(objectID: KnowledgeObject.ID, score: Double)],
        excluding source: KnowledgeObject.ID,
        top: Int
    ) -> [(objectID: KnowledgeObject.ID, score: Double)] {
        var best: [KnowledgeObject.ID: Double] = [:]
        for hit in hits where hit.objectID != source {
            best[hit.objectID] = max(best[hit.objectID] ?? -1, hit.score)
        }
        return best.sorted { $0.value > $1.value }
            .prefix(top)
            .map { ($0.key, $0.value) }
    }

    /// Distinctive search terms from a passage — the Lightning-mode
    /// fallback: longest distinct words, stopwords and numbers dropped.
    public static func terms(from text: String, max: Int = 6) -> [String] {
        let stop: Set<String> = ["the", "and", "that", "this", "with", "from", "have", "were",
                                 "been", "their", "which", "would", "there", "about", "shall",
                                 "will", "your", "these", "those", "into", "other", "than",
                                 "them", "they", "when", "where", "what", "also", "such"]
        var seen = Set<String>()
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 5 && !stop.contains($0) && Int($0) == nil && seen.insert($0).inserted }
        // Prefer longer (more distinctive) words, keep first-seen order among equals.
        return Array(words.sorted { $0.count > $1.count }.prefix(max))
    }
}

/// One related document row.
struct RelatedDocument: Identifiable {
    let id: KnowledgeObject.ID
    let name: String
    let score: Double?
}

/// The expandable insights panel under a document row: entity chips +
/// See-Also. Loads once per appearance from the shared repositories.
struct DocumentInsightsPanel: View {
    @Environment(AppState.self) private var appState
    let objectID: KnowledgeObject.ID

    @State private var docEntities: [Entity] = []
    @State private var related: [RelatedDocument] = []
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if loading {
                ProgressView().controlSize(.small)
            } else {
                if !docEntities.isEmpty {
                    Text("NAMED IN THIS DOCUMENT")
                        .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    FlowLayoutChips(entities: docEntities)
                }
                if !related.isEmpty {
                    Text("SEE ALSO — RELATED DOCUMENTS")
                        .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.top, docEntities.isEmpty ? 0 : 2)
                    ForEach(related) { doc in
                        HStack(spacing: 8) {
                            Image(systemName: "doc.text").foregroundStyle(.secondary)
                            Text(doc.name).font(.caption).lineLimit(1)
                            Spacer()
                            if let score = doc.score {
                                Text("\(Int(score * 100))%")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                                    .help("Similarity to this document")
                            }
                        }
                    }
                }
                if docEntities.isEmpty && related.isEmpty {
                    Text("No connections yet — entities and related documents appear as background analysis completes.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
        .task(id: objectID) { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        // Entity chips (DocumentCloud pattern) — canonical entities named here.
        docEntities = Array(((try? await appState.entities?.findByMentionSource(objectID)) ?? []).prefix(15))

        // See also (DEVONthink pattern).
        guard let chunks = appState.chunks,
              let seed = try? await chunks.firstChunk(forObjectID: objectID) else {
            related = []; return
        }
        var rows: [RelatedDocument] = []
        // Full power: true vector similarity over the seed chunk.
        if FeatureFlags.fullPowerModeValue(),
           let embedder = appState.embedder, let store = appState.vectorStore {
            let embedding = await embedder.embed(seed.text)
            if !embedding.isEmpty,
               let hits = try? await store.nearest(to: embedding, limit: 30, candidateChunkIDs: nil) {
                let hitChunks = (try? await chunks.findByIDs(hits.map(\.chunkID))) ?? []
                let scoreByChunk = Dictionary(uniqueKeysWithValues: hits.map { ($0.chunkID, $0.score) })
                let pairs = hitChunks.map { (objectID: $0.objectID, score: scoreByChunk[$0.id] ?? 0) }
                for ranked in SeeAlso.rankDocuments(hits: pairs, excluding: objectID, top: 5) {
                    if let ko = try? await appState.objects?.load(id: ranked.objectID) {
                        rows.append(RelatedDocument(id: ranked.objectID,
                                                    name: ko.sourceFile.lastPathComponent,
                                                    score: ranked.score))
                    }
                }
            }
        }
        // Lightning (or empty vectors): term-overlap via FTS.
        if rows.isEmpty {
            let query = SeeAlso.terms(from: seed.text).joined(separator: " OR ")
            if !query.isEmpty, let hits = try? await chunks.searchFTS(query, limit: 40) {
                let pairs = hits.map { (objectID: $0.objectID, score: 0.0) }
                var counts: [KnowledgeObject.ID: Int] = [:]
                for pair in pairs where pair.objectID != objectID { counts[pair.objectID, default: 0] += 1 }
                for (id, _) in counts.sorted(by: { $0.value > $1.value }).prefix(5) {
                    if let ko = try? await appState.objects?.load(id: id) {
                        rows.append(RelatedDocument(id: id, name: ko.sourceFile.lastPathComponent, score: nil))
                    }
                }
            }
        }
        related = rows
    }
}

/// Wrapping chip row: tap an entity to search everywhere it appears.
private struct FlowLayoutChips: View {
    @Environment(AppState.self) private var appState
    let entities: [Entity]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(entities) { entity in
                Button {
                    // The chip is a question: "where else does this appear?"
                    appState.pendingSearchQuery = entity.value
                    SurfaceOpener.open(.search)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: icon(for: entity.kind)).font(.caption2)
                        Text(entity.value).font(.caption).lineLimit(1)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.tint.opacity(0.1), in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Search everywhere \"\(entity.value)\" appears")
            }
        }
    }

    private func icon(for kind: Entity.Kind) -> String {
        switch kind.rawValue.lowercased() {
        case let k where k.contains("person"): return "person"
        case let k where k.contains("org"):    return "building.2"
        case let k where k.contains("place"), let k where k.contains("location"): return "mappin"
        default: return "tag"
        }
    }
}

