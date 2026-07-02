//
//  ContextPrefixBackfiller.swift
//  Kalsmritikosh
//
//  G2-3 — background service that periodically re-runs the LLM
//  context-prefix generator on chunks where it timed out during
//  ingest (rows with `context_prefix IS NULL` and a multi-chunk KO).
//
//  Pairs with the "quality or nothing" rule from commit b6302e4 —
//  during ingest we ONLY accept LLM-sourced prefixes. The ones that
//  miss the budget land as NULL. This backfiller catches them when
//  the system is idle (and presumably Ollama is responsive),
//  populating them retroactively without compromising the rule.
//
//  Behaviour:
//    - Drains a batch of NULL chunks every `intervalSeconds`
//    - Groups by parent KO so each KO's prefix-generation pass
//      can reuse the same opening text + running context
//    - Updates the row via ChunksRepository.updateContextPrefix
//    - Source label is `llm-backfill` so the operator can tell a
//      backfilled row from an at-ingest-time row in the data
//

import Foundation
import OSLog

public actor ContextPrefixBackfiller: BackgroundService {
    public let id = "atlas.contextPrefix.backfill"

    private let chunks: ChunksRepository
    private let objects: KnowledgeObjectRepository
    private let generator: any ContextPrefixGenerator
    /// Re-embedding pair (Ledger-AI): after a prefix is written, the
    /// chunk's vector is recomputed from `prefix + text` and upserted,
    /// so the expensive LLM prefix actually improves semantic retrieval
    /// instead of only changing a text column. Optional — when nil the
    /// backfiller only writes the prefix (legacy behaviour).
    private let embedder: (any Embedder)?
    private let vectors: (any VectorStore)?
    private let intervalSeconds: TimeInterval
    private let batchSize: Int
    private var runTask: Task<Void, Never>?

    public init(
        chunks: ChunksRepository,
        objects: KnowledgeObjectRepository,
        generator: any ContextPrefixGenerator,
        embedder: (any Embedder)? = nil,
        vectors: (any VectorStore)? = nil,
        intervalSeconds: TimeInterval = 300, // 5 minutes
        batchSize: Int = 50
    ) {
        self.chunks = chunks
        self.objects = objects
        self.generator = generator
        self.embedder = embedder
        self.vectors = vectors
        self.intervalSeconds = intervalSeconds
        self.batchSize = batchSize
    }

    public func start() async {
        guard runTask == nil else { return }
        AtlasLog.knowledge.info("ContextPrefixBackfiller: starting (interval=\(self.intervalSeconds, privacy: .public)s, batch=\(self.batchSize, privacy: .public))")
        runTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.runOnce()
                let ns = await UInt64(self.intervalSeconds * 1_000_000_000)
                try? await Task.sleep(nanoseconds: ns)
            }
        }
    }

    public func stop() async {
        runTask?.cancel()
        runTask = nil
    }

    /// One drain pass. Public so an admin command (Settings button)
    /// can also invoke it on demand without waiting for the timer.
    @discardableResult
    public func runOnce() async -> Int {
        let pending: [Chunk]
        do {
            pending = try await chunks.findChunksMissingContextPrefix(limit: batchSize)
        } catch {
            AtlasLog.knowledge.error("ContextPrefixBackfiller: query failed — \(String(describing: error), privacy: .public)")
            return 0
        }
        guard !pending.isEmpty else { return 0 }
        AtlasLog.knowledge.info("ContextPrefixBackfiller: processing \(pending.count, privacy: .public) NULL chunks")

        // Group by parent KO so we read each KO's content + KO-level
        // metadata only once, then iterate its chunks sequentially.
        let byKO = Dictionary(grouping: pending, by: \.objectID)
        var filled = 0
        var runningContext = ""
        var lastKO: KnowledgeObject.ID? = nil

        for (koID, koChunks) in byKO {
            // Refresh running context for each KO. Same shape as the
            // at-ingest-time path: first 1500 chars of the KO body,
            // updated as successful prefixes are produced.
            if lastKO != koID {
                let content = (try? await objects.fetchContent(id: koID)) ?? ""
                runningContext = String(content.prefix(1_500))
                lastKO = koID
            }
            // Resolve the source filename for the request. Falls
            // back to the KO's UUID prefix when the row is missing.
            let filename: String = await {
                if let url = try? await objects.fetchSourceURL(id: koID) {
                    return url.lastPathComponent
                }
                return String(koID.uuidString.prefix(8))
            }()
            // Determine the total chunk count for this KO so the
            // generator's prompt has accurate "section N of M" data.
            // We use the in-batch ordering as N; M is the total in
            // batch (best-effort). For full accuracy we'd query
            // ChunksRepository.count(forObject:); skipped here to
            // avoid extra DB traffic — the prompt label is cosmetic.
            let total = koChunks.count

            let sortedChunks = koChunks.sorted { $0.ordinal < $1.ordinal }
            for c in sortedChunks {
                let req = ContextPrefixRequest(
                    chunkText: c.text,
                    chunkOrdinal: c.ordinal,
                    totalChunks: total,
                    filename: filename,
                    documentOpening: runningContext
                )
                guard let result = await generator.prefix(for: req) else {
                    continue
                }
                // Tag this row as backfilled regardless of which
                // source label the generator used, so analytics can
                // tell ingest-time from backfill-time rows apart.
                let backfillSource = "\(result.source)-backfill"
                do {
                    try await chunks.updateContextPrefix(
                        c.id,
                        prefix: result.text,
                        source: backfillSource
                    )
                    filled += 1
                    // Re-embed the chunk from prefix + text so the new
                    // prefix actually feeds vector retrieval. Mirrors the
                    // at-ingest embedding format ("<prefix>\n---\n<text>").
                    // Best-effort: a failed re-embed leaves the old
                    // vector in place; the prefix text is still written.
                    if let embedder, let vectors {
                        let combined = "\(result.text)\n---\n\(c.text)"
                        let vector = await embedder.embed(combined)
                        do {
                            try await vectors.upsert(chunkID: c.id, embedding: vector)
                        } catch {
                            AtlasLog.knowledge.error("ContextPrefixBackfiller: re-embed failed for chunk \(c.id.uuidString.prefix(8), privacy: .public) — \(String(describing: error), privacy: .public)")
                        }
                    }
                    let updated = "Sections so far: \(result.text)\n" + runningContext
                    runningContext = String(updated.prefix(1_500))
                } catch {
                    AtlasLog.knowledge.error("ContextPrefixBackfiller: update failed for chunk \(c.id.uuidString.prefix(8), privacy: .public) — \(String(describing: error), privacy: .public)")
                }
            }
        }
        AtlasLog.knowledge.info("ContextPrefixBackfiller: filled \(filled, privacy: .public) / \(pending.count, privacy: .public)")
        return filled
    }
}
