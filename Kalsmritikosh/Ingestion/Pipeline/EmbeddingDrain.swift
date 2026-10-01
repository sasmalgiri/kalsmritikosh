//
//  EmbeddingDrain.swift
//  Kalsmritikosh
//
//  F10 — one full, fair pass over every chunk still missing a vector. The old drain re-read the
//  newest 256 missing chunks each time and filtered known-unembeddable ones AFTER the LIMIT, so a
//  front page made entirely of chunks the embedder can't vectorize looked "drained" and every
//  older, perfectly embeddable chunk starved. The pass pages by rowid keyset instead: a page that
//  yields nothing moves the cursor past it, so every missing chunk is reached once per pass.
//

import Foundation
import os

enum EmbeddingDrain {

    struct PassResult: Equatable {
        var embedded = 0
        var newlyFailed: Set<Chunk.ID> = []
        var pages = 0
    }

    /// Walk every missing chunk once, newest first.
    ///  • `fetch(beforeRowID)` — one keyset page (`ChunksRepository.findChunksMissingVectorPage`);
    ///  • `skip` — chunks already known unembeddable this session (never re-sent);
    ///  • `betweenPages` — pause / priority-gate hook; returning false stops the pass early;
    ///  • `embed` — vectorize + store one batch, returning how many were stored and which chunks the
    ///    embedder could not vectorize.
    static func pass(
        isolation: isolated (any Actor)? = #isolation,
        fetch: (Int64?) async throws -> (chunks: [Chunk], lastRowID: Int64?),
        skip: Set<Chunk.ID>,
        betweenPages: () async -> Bool = { true },
        embed: ([Chunk]) async -> (stored: Int, unembeddable: [Chunk.ID])
    ) async -> PassResult {
        var result = PassResult()
        var cursor: Int64? = nil
        var known = skip
        while await betweenPages() {
            let page: (chunks: [Chunk], lastRowID: Int64?)
            do { page = try await fetch(cursor) } catch {
                KalsmritikoshLog.ingestion.error("Embedding drain page fetch failed: \(String(describing: error), privacy: .public)")
                break
            }
            guard let next = page.lastRowID else { break }  // no rows left → the pass is complete
            result.pages += 1
            cursor = next                                   // always move PAST this page
            let batch = page.chunks.filter { !known.contains($0.id) }
            guard !batch.isEmpty else { continue }          // an all-unembeddable page no longer blocks
            let outcome = await embed(batch)
            result.embedded += outcome.stored
            for id in outcome.unembeddable where known.insert(id).inserted { result.newlyFailed.insert(id) }
        }
        return result
    }
}
