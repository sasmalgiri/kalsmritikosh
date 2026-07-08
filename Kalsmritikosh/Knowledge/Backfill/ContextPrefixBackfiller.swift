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
    public let id = "kalsmritikosh.contextPrefix.backfill"

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
    /// System 3 / Stage-2 "Document Card" mode. When true, the backfiller
    /// runs exactly ONE LLM call per file — on the file's FIRST chunk — to
    /// produce a document-level gist (and re-embeds it). It never touches
    /// the other chunks. This is the ledger-first "one document-card call
    /// per file" strategy; leave false for the full every-chunk sweep.
    private let firstChunkPerObjectOnly: Bool
    private var runTask: Task<Void, Never>?

    public init(
        chunks: ChunksRepository,
        objects: KnowledgeObjectRepository,
        generator: any ContextPrefixGenerator,
        embedder: (any Embedder)? = nil,
        vectors: (any VectorStore)? = nil,
        intervalSeconds: TimeInterval = 300, // 5 minutes
        batchSize: Int = 50,
        firstChunkPerObjectOnly: Bool = false
    ) {
        self.chunks = chunks
        self.objects = objects
        self.generator = generator
        self.embedder = embedder
        self.vectors = vectors
        self.intervalSeconds = intervalSeconds
        self.batchSize = batchSize
        self.firstChunkPerObjectOnly = firstChunkPerObjectOnly
    }

    public func start() async {
        guard runTask == nil else { return }
        KalsmritikoshLog.knowledge.info("ContextPrefixBackfiller: starting (interval=\(self.intervalSeconds, privacy: .public)s, batch=\(self.batchSize, privacy: .public))")
        runTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.runOnce()
                let ns = UInt64(self.intervalSeconds * 1_000_000_000)
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
            KalsmritikoshLog.knowledge.error("ContextPrefixBackfiller: query failed — \(String(describing: error), privacy: .public)")
            return 0
        }
        guard !pending.isEmpty else { return 0 }

        // System 3 / Stage-2: one document-card call per file, first chunk only.
        if firstChunkPerObjectOnly {
            return await runFirstChunkCardPass(pending)
        }

        KalsmritikoshLog.knowledge.info("ContextPrefixBackfiller: processing \(pending.count, privacy: .public) NULL chunks")

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
                            KalsmritikoshLog.knowledge.error("ContextPrefixBackfiller: re-embed failed for chunk \(c.id.uuidString.prefix(8), privacy: .public) — \(String(describing: error), privacy: .public)")
                        }
                    }
                    let updated = "Sections so far: \(result.text)\n" + runningContext
                    runningContext = String(updated.prefix(1_500))
                } catch {
                    KalsmritikoshLog.knowledge.error("ContextPrefixBackfiller: update failed for chunk \(c.id.uuidString.prefix(8), privacy: .public) — \(String(describing: error), privacy: .public)")
                }
            }
        }
        KalsmritikoshLog.knowledge.info("ContextPrefixBackfiller: filled \(filled, privacy: .public) / \(pending.count, privacy: .public)")
        return filled
    }

    /// Document-card pass (Systems 2 & 3): exactly ONE LLM call per file,
    /// on the file's first chunk, producing a document-level gist that is
    /// written + re-embedded. A file whose first chunk is already carded is
    /// skipped, so this stays one call per file no matter how often it runs.
    private func runFirstChunkCardPass(_ pending: [Chunk]) async -> Int {
        let koIDs = Set(pending.map(\.objectID))
        var carded = 0
        for koID in koIDs {
            // The true first chunk of the file — not just the first NULL
            // chunk that happened to land in this batch.
            guard let first = try? await chunks.firstChunk(forObjectID: koID) else { continue }
            if first.contextPrefix != nil { continue }   // already carded → one/file

            let content = (try? await objects.fetchContent(id: koID)) ?? ""
            let opening = String(content.prefix(1_500))
            let filename: String = await {
                if let url = try? await objects.fetchSourceURL(id: koID) {
                    return url.lastPathComponent
                }
                return String(koID.uuidString.prefix(8))
            }()
            let total = (try? await chunks.count(forObject: koID)) ?? 1

            let req = ContextPrefixRequest(
                chunkText: first.text,
                chunkOrdinal: first.ordinal,
                totalChunks: total,
                filename: filename,
                documentOpening: opening
            )
            guard let result = await generator.prefix(for: req) else { continue }
            do {
                try await chunks.updateContextPrefix(
                    first.id,
                    prefix: result.text,
                    source: "\(result.source)-card"
                )
                carded += 1
                // Re-embed so the card actually feeds retrieval.
                if let embedder, let vectors {
                    let combined = "\(result.text)\n---\n\(first.text)"
                    let vector = await embedder.embed(combined)
                    do {
                        try await vectors.upsert(chunkID: first.id, embedding: vector)
                    } catch {
                        KalsmritikoshLog.knowledge.error("ContextPrefixBackfiller(card): re-embed failed for \(koID.uuidString.prefix(8), privacy: .public) — \(String(describing: error), privacy: .public)")
                    }
                }
            } catch {
                KalsmritikoshLog.knowledge.error("ContextPrefixBackfiller(card): update failed for \(koID.uuidString.prefix(8), privacy: .public) — \(String(describing: error), privacy: .public)")
            }
        }
        if carded > 0 {
            KalsmritikoshLog.knowledge.info("ContextPrefixBackfiller(card): carded \(carded, privacy: .public) file(s), one LLM call each")
        }
        return carded
    }
}
