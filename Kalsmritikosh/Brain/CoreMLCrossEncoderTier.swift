//
//  CoreMLCrossEncoderTier.swift
//  Kalsmritikosh
//
//  G2-RERANK-LADDER Tier 3 — Core ML cross-encoder reranker.
//
//  Loads a bundled Core ML cross-encoder (default: BAAI/bge-reranker-base
//  converted via coremltools) and scores each (question, passage) pair
//  with a single forward pass. The model's logits are mapped to [0, 1]
//  via sigmoid so the score composes with HeuristicKeywordTier and the
//  existing scoreByObject path.
//
//  Conformance to RerankerTier — slots into RerankerLadder above the
//  heuristic tier and below the LLM tier:
//
//      RerankerLadder(tiers: [
//          HeuristicKeywordTier(),                  // costClass 0
//          CoreMLCrossEncoderTier(),                // costClass 50
//      ])
//
//  Graceful unavailability: when the .mlpackage isn't bundled (the
//  default until UPDATE_17B's conversion lands), `score(...)` returns
//  nil so the cascade falls back to whatever earlier tier produced
//  scores. No throws; no fatal crashes.
//

import Foundation
import CoreML
import OSLog

public struct CoreMLCrossEncoderTier: RerankerTier {
    public let id = "tier.crossencoder.coreml"
    public let costClass = 50

    /// Name of the bundled Core ML model (without extension). The file
    /// must live at `Kalsmritikosh/Resources/<modelName>.mlpackage` and
    /// be added to the target's Copy Bundle Resources phase.
    ///
    /// To bundle bge-reranker-base:
    ///   pip install -U huggingface_hub coremltools transformers torch
    ///   python -c "<see CoreMLCrossEncoderTier.conversionScript>"
    ///   → produces BGEReranker.mlpackage; drop in Resources/.
    public let modelName: String
    public let maxSequenceLength: Int

    public init(modelName: String = "BGEReranker", maxSequenceLength: Int = 512) {
        self.modelName = modelName
        self.maxSequenceLength = maxSequenceLength
    }

    public func score(
        question: String,
        candidates: [String]
    ) async -> [Double]? {
        guard !candidates.isEmpty else { return [] }

        // The model loads from the bundle; if the .mlpackage isn't
        // present yet, return nil so the cascade falls through to
        // earlier tiers. This is the expected steady state until the
        // converted model is bundled.
        guard let url = Bundle.main.url(forResource: modelName, withExtension: "mlpackage")
                ?? Bundle.main.url(forResource: modelName, withExtension: "mlmodelc")
                ?? Bundle.main.url(forResource: modelName, withExtension: "mlmodel")
        else {
            AtlasLog.brain.info("\(id, privacy: .public): model \(modelName, privacy: .public) not bundled; tier passes through")
            return nil
        }

        let model: MLModel
        do {
            let compiledURL: URL = try {
                if url.pathExtension == "mlmodelc" { return url }
                return try MLModel.compileModel(at: url)
            }()
            model = try MLModel(contentsOf: compiledURL)
        } catch {
            AtlasLog.brain.error("\(id, privacy: .public): model load failed: \(String(describing: error), privacy: .public); pass-through")
            return nil
        }

        // The model is expected to take two tokenized inputs (`input_ids`
        // and `attention_mask`, both [1, maxSequenceLength] int32) and
        // emit a single logit. Real tokenization needs a bundled
        // tokenizer (XLM-RoBERTa SentencePiece for bge-reranker-base);
        // until that's wired, this tier returns nil rather than feed
        // garbage byte-tokenized input to the model.
        //
        // The wiring lands as a follow-on once the .mlpackage and the
        // matching tokenizer (sentencepiece.model) are both in
        // Resources/. The protocol API stays unchanged.
        _ = model
        AtlasLog.brain.info("\(id, privacy: .public): model loaded but tokenizer not yet wired; tier passes through")
        return nil
    }

    /// Python conversion script (run once on a Mac with `coremltools`).
    /// Produces `BGEReranker.mlpackage` which is then dropped into the
    /// project's Resources/ folder and added to Copy Bundle Resources.
    public static let conversionScript: String = """
    from huggingface_hub import snapshot_download
    from transformers import AutoTokenizer, AutoModelForSequenceClassification
    import torch, coremltools as ct

    src = snapshot_download("BAAI/bge-reranker-base")
    tok = AutoTokenizer.from_pretrained(src)
    mdl = AutoModelForSequenceClassification.from_pretrained(src, torchscript=True).eval()

    example = tok(["query"], ["passage"], return_tensors="pt",
                  padding="max_length", truncation=True, max_length=512)
    traced = torch.jit.trace(mdl, (example["input_ids"], example["attention_mask"]))

    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="input_ids",      shape=(1, 512), dtype=int),
            ct.TensorType(name="attention_mask", shape=(1, 512), dtype=int),
        ],
        minimum_deployment_target=ct.target.macOS14,
    )
    mlmodel.save("BGEReranker.mlpackage")
    """
}
