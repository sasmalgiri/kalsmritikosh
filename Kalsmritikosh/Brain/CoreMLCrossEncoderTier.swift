//
//  CoreMLCrossEncoderTier.swift
//  Kalsmritikosh
//
//  G2-RERANK-LADDER Tier 3 — Core ML cross-encoder reranker.
//
//  Loads the bundled bge-reranker-base Core ML model + a pure-Swift
//  greedy Unigram tokenizer (BGETokenizer), tokenizes each
//  (question, passage) pair, runs a single forward pass, and maps
//  the logit through sigmoid to [0, 1].
//
//  Conformance to RerankerTier — slots between the heuristic tier
//  (costClass 0) and the LLM tier (costClass 90):
//
//      RerankerLadder(tiers: [
//          HeuristicKeywordTier(),                  // costClass 0
//          CoreMLCrossEncoderTier(),                // costClass 50
//      ])
//
//  Graceful unavailability cascade:
//    • model not bundled  → return nil (pass-through)
//    • tokenizer json not bundled → return nil (pass-through)
//    • Core ML init throws → return nil + log
//    • prediction throws on any candidate → that candidate scores 0.5
//

import Foundation
import CoreML
import OSLog

public struct CoreMLCrossEncoderTier: RerankerTier {
    public let id = "tier.crossencoder.coreml"
    public let costClass = 50

    /// Name of the bundled Core ML model (without extension). The file
    /// must live at `Resources/BGEReranker/<modelName>.mlpackage` and
    /// be added to the target's Copy Bundle Resources phase.
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
        guard let modelURL = locateModelURL() else {
            KalsmritikoshLog.brain.info("\(id, privacy: .public): model \(modelName, privacy: .public) not bundled; pass-through")
            return nil
        }
        guard let tokenizer = BGETokenizer(maxLength: maxSequenceLength) else {
            KalsmritikoshLog.brain.info("\(id, privacy: .public): tokenizer.json not bundled; pass-through")
            return nil
        }
        let model: MLModel
        do {
            let compiledURL: URL = try {
                if modelURL.pathExtension == "mlmodelc" { return modelURL }
                return try MLModel.compileModel(at: modelURL)
            }()
            model = try MLModel(contentsOf: compiledURL)
        } catch {
            KalsmritikoshLog.brain.error("\(id, privacy: .public): model load failed: \(String(describing: error), privacy: .public); pass-through")
            return nil
        }

        var scores: [Double] = []
        scores.reserveCapacity(candidates.count)
        for passage in candidates {
            let out = tokenizer.encode(question: question, passage: passage)
            do {
                let logit = try Self.runForward(
                    model: model,
                    inputIDs: out.inputIDs,
                    attentionMask: out.attentionMask,
                    length: maxSequenceLength
                )
                scores.append(Self.sigmoid(logit))
            } catch {
                KalsmritikoshLog.brain.error("\(id, privacy: .public): forward pass failed: \(String(describing: error), privacy: .public); 0.5 score")
                scores.append(0.5)
            }
        }
        KalsmritikoshLog.brain.info("\(id, privacy: .public): scored \(scores.count, privacy: .public) candidates")
        return scores
    }

    private func locateModelURL() -> URL? {
        // The bundled location is `Resources/BGEReranker/BGEReranker.mlpackage`.
        // Try variants Xcode might pick up depending on whether it
        // compiled the .mlpackage to .mlmodelc.
        if let url = Bundle.main.url(forResource: modelName, withExtension: "mlmodelc", subdirectory: "BGEReranker") {
            return url
        }
        if let url = Bundle.main.url(forResource: modelName, withExtension: "mlpackage", subdirectory: "BGEReranker") {
            return url
        }
        if let url = Bundle.main.url(forResource: modelName, withExtension: "mlmodelc") {
            return url
        }
        if let url = Bundle.main.url(forResource: modelName, withExtension: "mlpackage") {
            return url
        }
        return nil
    }

    private static func runForward(
        model: MLModel,
        inputIDs: [Int32],
        attentionMask: [Int32],
        length: Int
    ) throws -> Float {
        let shape: [NSNumber] = [1, NSNumber(value: length)]
        let inputIDsArray = try MLMultiArray(shape: shape, dataType: .int32)
        let maskArray = try MLMultiArray(shape: shape, dataType: .int32)
        for i in 0..<length {
            inputIDsArray[i] = NSNumber(value: i < inputIDs.count ? inputIDs[i] : Int32(BGETokenizer.padID))
            maskArray[i] = NSNumber(value: i < attentionMask.count ? attentionMask[i] : 0)
        }
        let inputs: [String: MLFeatureValue] = [
            "input_ids": MLFeatureValue(multiArray: inputIDsArray),
            "attention_mask": MLFeatureValue(multiArray: maskArray)
        ]
        let provider = try MLDictionaryFeatureProvider(dictionary: inputs)
        let result = try model.prediction(from: provider)

        // bge-reranker emits a single logit. The Core ML conversion
        // may name it 'logits' / 'output' / something else — probe
        // the available feature names.
        for name in result.featureNames {
            if let val = result.featureValue(for: name)?.multiArrayValue,
               val.count >= 1 {
                return Float(truncating: val[0])
            }
        }
        throw NSError(
            domain: "CoreMLCrossEncoderTier",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Model produced no numeric output"]
        )
    }

    private static func sigmoid(_ x: Float) -> Double {
        Double(1.0 / (1.0 + exp(-x)))
    }

    /// Reference Python conversion script (run once with the bundled
    /// venv at ~/coreml-bge/.venv). Kept inline as documentation; the
    /// actual file used was ~/coreml-bge/convert.py.
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
    ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="input_ids",      shape=(1, 512), dtype=int),
            ct.TensorType(name="attention_mask", shape=(1, 512), dtype=int),
        ],
        minimum_deployment_target=ct.target.macOS14,
    ).save("BGEReranker.mlpackage")
    """
}
