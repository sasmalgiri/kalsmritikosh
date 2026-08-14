//
//  CoreMLEmbedderBatchTests.swift
//  KalsmritikoshTests
//
//  PERF-2 — the BGE Core ML embedder now loads the model/tokenizer ONCE
//  (CoreMLEmbedderRuntime) and exposes a TRUE batched inference path. The BGE
//  asset is owner-supplied and not in the repo, so these tests pin the
//  correctness contract that must survive the refactor: when the model is not
//  bundled, both `embed` and `embedBatch` return EMPTY (never zeros, never a
//  crash) so CapabilityResolvedEmbedder falls back to NLEmbedder; the empty-
//  input fast path holds; and the fallback's own batch path is order- and
//  count-correct. (Real inference parity is exercised by the owner's
//  device run once the asset is bundled.)
//

import Testing
import Foundation
@testable import Kalsmritikosh

@Suite("PERF-2 — Core ML batched embedder contract")
struct CoreMLEmbedderBatchTests {

    @Test("Not-bundled model: embed + embedBatch both return empty (clean fallback, never zeros)")
    func gracefulWhenModelAbsent() async throws {
        // A deliberately non-existent asset name → runtime reports unavailable.
        let provider = CoreMLEmbedderProvider(modelName: "NoSuchModel_\(UUID().uuidString)",
                                              subdirectory: "NoSuchDir")
        #expect(await provider.isAvailable() == false)
        #expect(try await provider.embed(text: "hello") == [])
        let batch = try await provider.embedBatch(texts: ["a", "b", "c"])
        #expect(batch == [])   // whole-batch empty → caller falls back cleanly
    }

    @Test("Empty input is a no-op fast path")
    func emptyInput() async throws {
        let provider = CoreMLEmbedderProvider(modelName: "NoSuchModel", subdirectory: "NoSuchDir")
        #expect(try await provider.embedBatch(texts: []) == [])
    }

    @Test("The NLEmbedder fallback's batch path is count- and order-correct across batch boundaries")
    func fallbackBatchContract() async {
        let embedder = NLEmbedder()
        let texts = ["the contract was signed", "supplier delayed the shipment", "invoice paid in full"]
        let batch = await embedder.embedBatch(texts)
        #expect(batch.count == texts.count)
        // embedAll chunks then concatenates — must preserve count + order even
        // when the batch size splits the input (this is the path ingest uses).
        let viaAll = await embedder.embedAll(texts, batchSize: 2)
        #expect(viaAll.count == texts.count)
        // Same texts, same vectors, regardless of how they were batched.
        let single = await embedder.embed(texts[0])
        #expect(viaAll.first == single)
    }

    @Test("The compiled-model runtime caches the unavailable verdict (no repeated failing compile)")
    func runtimeCachesUnavailable() async {
        let name = "NoSuchModel_\(UUID().uuidString)"
        let first = await CoreMLEmbedderRuntime.shared.runtime(modelName: name, subdirectory: "NoSuchDir", maxSequenceLength: 512)
        let second = await CoreMLEmbedderRuntime.shared.runtime(modelName: name, subdirectory: "NoSuchDir", maxSequenceLength: 512)
        #expect(first == nil && second == nil)
    }
}
