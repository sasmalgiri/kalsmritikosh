//
//  CoreMLEmbedderProvider.swift
//  Kalsmritikosh
//
//  P6.2 — on-device sentence-embedding provider backed by a bundled Core ML
//  model (candidate: BGE-small-en-v1.5, 384-dim). Registered against the
//  `.embedding` capability so CapabilityResolvedEmbedder resolves it OVER the
//  Apple NLEmbedding fallback whenever the model is bundled — and falls back
//  gracefully (returns unavailable / empty) when it is NOT, so the app's
//  behaviour is UNCHANGED until the model asset is supplied.
//
//  The model name lives here, in Routing/Providers, per the capability-
//  discipline rule (grep guard): no other layer names a model.
//
//  Bundling: drop the converted model + its tokenizer at
//      Resources/BGESmallEmbedder/<modelName>.mlpackage   (or .mlmodelc)
//      Resources/BGESmallEmbedder/tokenizer.json
//  and add them to the target's Copy Bundle Resources phase. See
//  docs/EMBEDDER_SWAP.md for the exact coremltools conversion + verify steps.
//
//  Correctness note: this reuses BGETokenizer (a greedy pure-Swift tokenizer).
//  The bundled tokenizer.json MUST match the converted model's tokenizer. The
//  conversion doc exports a compatible pair. Output handling covers both a
//  pre-pooled sentence vector ([1, dim]) and token-level output ([1, seq,
//  hidden]) — the latter is mean-pooled over the attention mask — then
//  L2-normalized. Empty vector on any failure (CONTRACT T15: never zeros).
//

import Foundation
import CoreML
import OSLog

public struct CoreMLEmbedderProvider: ModelProvider {
    public nonisolated let id: String
    public nonisolated let capabilities: Set<ModelCapability> = [.embedding]
    public nonisolated let manifest: ModelManifest

    /// Declared output dimension. MUST match the converted model's embedding
    /// size (384 for bge-small-en-v1.5). The re-embedding reconciliation uses
    /// this to decide when stored vectors are stale and must be rebuilt.
    public nonisolated let dimension: Int

    /// Bundled model basename + its Resources subdirectory + tokenizer.
    private let modelName: String
    private let subdirectory: String
    private let maxSequenceLength: Int

    public init(
        id: String = "provider.local.coreml.embedder",
        modelName: String = "BGESmallEmbedder",
        subdirectory: String = "BGESmallEmbedder",
        dimension: Int = 384,
        maxSequenceLength: Int = 512
    ) {
        self.id = id
        self.modelName = modelName
        self.subdirectory = subdirectory
        self.dimension = dimension
        self.maxSequenceLength = maxSequenceLength
        self.manifest = ModelManifest(
            id: id,
            displayName: "On-device sentence embedder",
            capabilities: [.embedding],
            minRAMBytes: 512 * 1_048_576,
            diskBytes: 140_000_000,
            contextWindow: maxSequenceLength,
            privacyLevel: .onDevice,
            requiresDownload: false,
            tier: .small
        )
    }

    // MARK: - Availability

    public func isAvailable() async -> Bool {
        locateModelURL() != nil && BERTWordPieceTokenizer(subdirectory: subdirectory) != nil
    }

    // MARK: - Generation (not supported)

    public func generate(prompt: String, options: GenerationOptions) async throws -> String {
        throw ModelProviderError.capabilityMissing(providerID: id, capability: .textGeneration)
    }

    // MARK: - Embedding

    public func embed(text: String) async throws -> [Float] {
        // PERF-2: the compiled model + tokenizer are loaded ONCE and cached
        // process-wide (see CoreMLEmbedderRuntime) instead of recompiled and
        // reloaded on every call — the dominant cost on a large ingest.
        guard let runtime = await CoreMLEmbedderRuntime.shared.runtime(
            modelName: modelName, subdirectory: subdirectory, maxSequenceLength: maxSequenceLength) else {
            return []   // not bundled → let the caller fall back to NLEmbedder
        }
        let encoded = runtime.tokenizer.encode(text: text)
        return (try? Self.runForward(
            model: runtime.model,
            inputIDs: encoded.inputIDs,
            attentionMask: encoded.attentionMask,
            length: maxSequenceLength
        )) ?? []
    }

    /// PERF-2: TRUE batched Core ML inference. Tokenizes every text, submits
    /// them as ONE `MLArrayBatchProvider`, and lets Core ML run the batch in a
    /// single dispatch (far fewer per-call boundaries than N single predictions
    /// — and the model/tokenizer are loaded once). Each output is pooled +
    /// L2-normalized identically to the single path, so stored vectors are
    /// byte-for-byte the same. Order is preserved. On any failure the whole
    /// batch returns [] so the caller falls back cleanly.
    public func embedBatch(texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        guard let runtime = await CoreMLEmbedderRuntime.shared.runtime(
            modelName: modelName, subdirectory: subdirectory, maxSequenceLength: maxSequenceLength) else {
            return []
        }
        let length = maxSequenceLength
        var providers: [MLFeatureProvider] = []
        var masks: [[Int32]] = []
        providers.reserveCapacity(texts.count)
        masks.reserveCapacity(texts.count)
        do {
            for text in texts {
                let encoded = runtime.tokenizer.encode(text: text)
                let shape: [NSNumber] = [1, NSNumber(value: length)]
                let ids = try MLMultiArray(shape: shape, dataType: .int32)
                let mask = try MLMultiArray(shape: shape, dataType: .int32)
                for i in 0..<length {
                    ids[i] = NSNumber(value: i < encoded.inputIDs.count ? encoded.inputIDs[i] : Int32(BGETokenizer.padID))
                    mask[i] = NSNumber(value: i < encoded.attentionMask.count ? encoded.attentionMask[i] : 0)
                }
                masks.append(encoded.attentionMask)
                providers.append(try MLDictionaryFeatureProvider(dictionary: [
                    "input_ids": MLFeatureValue(multiArray: ids),
                    "attention_mask": MLFeatureValue(multiArray: mask)
                ]))
            }
            let batch = MLArrayBatchProvider(array: providers)
            let results = try runtime.model.predictions(fromBatch: batch)
            guard results.count == texts.count else { return [] }
            var out: [[Float]] = []
            out.reserveCapacity(texts.count)
            for i in 0..<results.count {
                let r = results.features(at: i)
                guard let name = r.featureNames.first(where: { r.featureValue(for: $0)?.multiArrayValue != nil }),
                      let arr = r.featureValue(for: name)?.multiArrayValue else { return [] }
                out.append(Self.l2normalize(Self.poolIfNeeded(arr, mask: masks[i], seqLength: length)))
            }
            return out
        } catch {
            KalsmritikoshLog.routing.error("CoreMLEmbedderProvider: batch inference failed: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    // MARK: - Model location

    private func locateModelURL() -> URL? {
        for ext in ["mlmodelc", "mlpackage"] {
            if let url = Bundle.main.url(forResource: modelName, withExtension: ext, subdirectory: subdirectory) {
                return url
            }
            if let url = Bundle.main.url(forResource: modelName, withExtension: ext) {
                return url
            }
        }
        return nil
    }

    // MARK: - Forward pass

    /// Runs the model and returns an L2-normalized sentence embedding. Handles
    /// both a pre-pooled output ([1, dim]) and token-level output ([1, seq,
    /// hidden]) — the latter mean-pooled over the attention mask.
    private static func runForward(
        model: MLModel,
        inputIDs: [Int32],
        attentionMask: [Int32],
        length: Int
    ) throws -> [Float] {
        let shape: [NSNumber] = [1, NSNumber(value: length)]
        let idsArray = try MLMultiArray(shape: shape, dataType: .int32)
        let maskArray = try MLMultiArray(shape: shape, dataType: .int32)
        for i in 0..<length {
            idsArray[i] = NSNumber(value: i < inputIDs.count ? inputIDs[i] : Int32(BGETokenizer.padID))
            maskArray[i] = NSNumber(value: i < attentionMask.count ? attentionMask[i] : 0)
        }
        let inputs: [String: MLFeatureValue] = [
            "input_ids": MLFeatureValue(multiArray: idsArray),
            "attention_mask": MLFeatureValue(multiArray: maskArray)
        ]
        let result = try model.prediction(from: try MLDictionaryFeatureProvider(dictionary: inputs))

        // Pick the first multi-array output feature.
        guard let name = result.featureNames.first(where: {
            result.featureValue(for: $0)?.multiArrayValue != nil
        }), let out = result.featureValue(for: name)?.multiArrayValue else {
            throw ModelProviderError.generationFailed(reason: "embedder produced no array output")
        }

        let pooled = poolIfNeeded(out, mask: attentionMask, seqLength: length)
        return l2normalize(pooled)
    }

    /// If the output is already [.., dim] (a pooled sentence vector), return it
    /// flat. If it is token-level [1, seq, hidden], mean-pool over the tokens
    /// where attention_mask == 1.
    private static func poolIfNeeded(_ array: MLMultiArray, mask: [Int32], seqLength: Int) -> [Float] {
        let shape = array.shape.map { $0.intValue }
        let flat = (0..<array.count).map { Float(truncating: array[$0]) }
        // Token-level output: last dim = hidden, middle dim = seq length.
        if shape.count == 3, shape[1] == seqLength {
            let seq = shape[1], hidden = shape[2]
            var sum = [Float](repeating: 0, count: hidden)
            var live = 0
            for t in 0..<seq where (t < mask.count && mask[t] == 1) {
                live += 1
                let base = t * hidden
                for h in 0..<hidden { sum[h] += flat[base + h] }
            }
            if live > 0 { for h in 0..<hidden { sum[h] /= Float(live) } }
            return sum
        }
        // Otherwise treat the whole flat array as the sentence vector.
        return flat
    }

    private static func l2normalize(_ v: [Float]) -> [Float] {
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return [] }
        return v.map { $0 / norm }
    }
}

// MARK: - PERF-2 — process-wide compiled-model + tokenizer cache

/// Loads and compiles the Core ML embedder ONCE per (modelName, subdirectory)
/// and keeps the compiled MLModel + tokenizer resident for the process. Before
/// this, CoreMLEmbedderProvider recompiled + reloaded the model and rebuilt the
/// tokenizer on EVERY embed call — thousands of times during a large ingest.
/// An actor so concurrent lanes share one warm model without a data race.
actor CoreMLEmbedderRuntime {
    static let shared = CoreMLEmbedderRuntime()

    struct Runtime {
        let model: MLModel
        let tokenizer: BERTWordPieceTokenizer
    }

    private var cache: [String: Runtime] = [:]
    /// Keys that were tried and found unavailable (not bundled / load failed),
    /// so we don't repeatedly pay a failing compile on the fallback path.
    private var unavailable: Set<String> = []

    func runtime(modelName: String, subdirectory: String, maxSequenceLength: Int) async -> Runtime? {
        let key = "\(subdirectory)/\(modelName)#\(maxSequenceLength)"
        if let hit = cache[key] { return hit }
        if unavailable.contains(key) { return nil }

        guard let modelURL = Self.locate(modelName: modelName, subdirectory: subdirectory),
              let tokenizer = BERTWordPieceTokenizer(subdirectory: subdirectory, maxLength: maxSequenceLength) else {
            unavailable.insert(key)
            return nil
        }
        do {
            let compiled = modelURL.pathExtension == "mlmodelc"
                ? modelURL : try await MLModel.compileModel(at: modelURL)
            let model = try MLModel(contentsOf: compiled)
            let runtime = Runtime(model: model, tokenizer: tokenizer)
            cache[key] = runtime
            return runtime
        } catch {
            KalsmritikoshLog.routing.error("CoreMLEmbedderRuntime: model load failed: \(String(describing: error), privacy: .public)")
            unavailable.insert(key)
            return nil
        }
    }

    private static func locate(modelName: String, subdirectory: String) -> URL? {
        for ext in ["mlmodelc", "mlpackage"] {
            if let url = Bundle.main.url(forResource: modelName, withExtension: ext, subdirectory: subdirectory) {
                return url
            }
            if let url = Bundle.main.url(forResource: modelName, withExtension: ext) {
                return url
            }
        }
        return nil
    }
}
