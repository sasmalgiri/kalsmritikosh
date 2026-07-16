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
        locateModelURL() != nil && BGETokenizer(resourceName: "tokenizer", subdirectory: subdirectory) != nil
    }

    // MARK: - Generation (not supported)

    public func generate(prompt: String, options: GenerationOptions) async throws -> String {
        throw ModelProviderError.capabilityMissing(providerID: id, capability: .textGeneration)
    }

    // MARK: - Embedding

    public func embed(text: String) async throws -> [Float] {
        guard let modelURL = locateModelURL(),
              let tokenizer = BGETokenizer(resourceName: "tokenizer",
                                           subdirectory: subdirectory,
                                           maxLength: maxSequenceLength) else {
            return []   // not bundled → let the caller fall back to NLEmbedder
        }
        let model: MLModel
        do {
            let compiled = try modelURL.pathExtension == "mlmodelc"
                ? modelURL : await MLModel.compileModel(at: modelURL)
            model = try MLModel(contentsOf: compiled)
        } catch {
            KalsmritikoshLog.routing.error("CoreMLEmbedderProvider: model load failed: \(String(describing: error), privacy: .public)")
            return []
        }
        let encoded = tokenizer.encode(text: text)
        return (try? Self.runForward(
            model: model,
            inputIDs: encoded.inputIDs,
            attentionMask: encoded.attentionMask,
            length: maxSequenceLength
        )) ?? []
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
