//
//  BGETokenizer.swift
//  Kalsmritikosh
//
//  G2-RERANK-LADDER Tier 3 — pure-Swift Unigram SentencePiece tokenizer
//  for bge-reranker-base. Loads the 250k-token vocab from the bundled
//  tokenizer.json once, then greedily segments input text by longest-
//  prefix match per position.
//
//  IMPORTANT TRADE-OFF: this is a SIMPLIFIED Unigram tokenizer. It
//  uses greedy longest-prefix instead of Viterbi-optimal segmentation,
//  and skips SentencePiece's Precompiled NFKC charsmap normalization.
//  Output tokens may differ from the model's reference tokenizer for
//  some inputs (multi-byte chars, ambiguous segmentations). For
//  English short queries — the bulk of Kalsmritikosh use — the output is
//  close enough that the cross-encoder produces useful relative
//  scores. For multilingual / non-ASCII heavy inputs, accuracy
//  degrades; that's the known cost of avoiding a SentencePiece
//  C++ dependency.
//
//  Upgrade path: when CLAUDE.md unblocks third-party deps, swap to
//  `huggingface/swift-transformers` (one-line dep) for full XLM-R
//  fidelity. The Tokenizer protocol below is shaped to make that
//  swap a single-file edit in CoreMLCrossEncoderTier.
//

import Foundation
import OSLog

/// Tokenizes (question, passage) pairs for the bge-reranker model.
/// Output is an int32 array of token ids padded/truncated to
/// `maxLength`, plus an attention-mask of the same shape.
public final class BGETokenizer: @unchecked Sendable {
    public struct Output: Sendable {
        public let inputIDs: [Int32]
        public let attentionMask: [Int32]
    }

    private struct VocabEntry {
        let token: String
        let id: Int32
        let score: Float
    }

    public static let clsID: Int32 = 0   // <s>
    public static let padID: Int32 = 1   // <pad>
    public static let sepID: Int32 = 2   // </s>
    public static let unkID: Int32 = 3   // <unk>
    private static let wordBoundary: Character = "\u{2581}"  // ▁ — SentencePiece word marker

    private let vocab: [String: Int32]
    /// Bucketed by first character so the greedy scan only considers
    /// the ~hundreds of tokens that could possibly match the current
    /// position. Each bucket is pre-sorted by descending length so
    /// the first hasPrefix hit is the longest.
    private let tokensByFirstChar: [Character: [(String, Int32)]]
    public let maxLength: Int

    /// Loads the bundled `tokenizer.json` and prepares the vocab.
    /// Returns nil when the JSON isn't bundled — the caller (the
    /// cross-encoder tier) treats this as "tokenizer not ready" and
    /// passes through without scoring.
    public init?(resourceName: String = "tokenizer", subdirectory: String = "BGEReranker", maxLength: Int = 512) {
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "json", subdirectory: subdirectory)
                ?? Bundle.main.url(forResource: resourceName, withExtension: "json"),
              let data = try? Data(contentsOf: url)
        else {
            return nil
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = json["model"] as? [String: Any],
              let rawVocab = model["vocab"] as? [[Any]]
        else {
            return nil
        }
        // tokenizer.json's vocab is a list of [token, score] pairs;
        // the id is the index. Build a dict for O(1) id lookup AND
        // a length-sorted list for greedy-prefix scanning.
        var vocab: [String: Int32] = [:]
        vocab.reserveCapacity(rawVocab.count)
        var buckets: [Character: [(String, Int32)]] = [:]
        for (index, pair) in rawVocab.enumerated() {
            guard pair.count >= 1, let token = pair[0] as? String, !token.isEmpty else { continue }
            let id = Int32(index)
            vocab[token] = id
            let head = token.first!
            buckets[head, default: []].append((token, id))
        }
        // Pre-sort each bucket by length descending so the first
        // matching prefix is the longest.
        for k in buckets.keys {
            buckets[k]?.sort { $0.0.count > $1.0.count }
        }
        self.vocab = vocab
        self.tokensByFirstChar = buckets
        self.maxLength = maxLength
        KalsmritikoshLog.brain.info("BGETokenizer loaded \(vocab.count, privacy: .public) tokens in \(buckets.count, privacy: .public) buckets (greedy mode)")
    }

    /// Tokenize a (question, passage) pair into the model's expected
    /// input shape: <s> q_tokens </s> </s> p_tokens </s> padded to
    /// maxLength. attention_mask is 1 over real tokens, 0 over pad.
    public func encode(question: String, passage: String) -> Output {
        let qIDs = tokenize(question)
        let pIDs = tokenize(passage)

        var ids: [Int32] = [Self.clsID] + qIDs + [Self.sepID, Self.sepID] + pIDs + [Self.sepID]
        if ids.count > maxLength {
            // Truncate the passage side first; preserve the question.
            let qSlice = ids.prefix(min(qIDs.count + 3, maxLength / 2))
            let remaining = maxLength - qSlice.count - 1
            let pSlice = Array(pIDs.prefix(max(0, remaining)))
            ids = Array(qSlice) + pSlice + [Self.sepID]
            if ids.count > maxLength {
                ids = Array(ids.prefix(maxLength))
            }
        }
        let attention: [Int32] = Array(repeating: 1, count: ids.count)
        let padCount = maxLength - ids.count
        if padCount > 0 {
            ids.append(contentsOf: Array(repeating: Self.padID, count: padCount))
        }
        let mask = attention + Array(repeating: 0, count: max(0, maxLength - attention.count))
        return Output(inputIDs: ids, attentionMask: mask)
    }

    /// Tokenize a SINGLE sequence for a sentence embedder: <s> tokens </s>,
    /// padded/truncated to maxLength, with a matching attention mask. Used by
    /// CoreMLEmbedderProvider. (The reranker path uses `encode(question:passage:)`.)
    public func encode(text: String) -> Output {
        var ids: [Int32] = [Self.clsID] + tokenize(text) + [Self.sepID]
        if ids.count > maxLength { ids = Array(ids.prefix(maxLength)) }
        let attention = Array(repeating: Int32(1), count: ids.count)
        let padCount = max(0, maxLength - ids.count)
        ids.append(contentsOf: Array(repeating: Self.padID, count: padCount))
        let mask = attention + Array(repeating: Int32(0), count: padCount)
        return Output(inputIDs: ids, attentionMask: mask)
    }

    /// Greedy longest-prefix tokenization of a single string.
    /// Prepends SentencePiece's "▁" word-boundary marker and then
    /// scans char-by-char, picking the longest vocab match.
    private func tokenize(_ text: String) -> [Int32] {
        let normalized = "\(Self.wordBoundary)" + text
            .replacingOccurrences(of: " ", with: "\(Self.wordBoundary)")
        var out: [Int32] = []
        var idx = normalized.startIndex
        while idx < normalized.endIndex {
            let remaining = normalized[idx...]
            // Only consider tokens whose first char matches the
            // current position. Within that bucket they're already
            // sorted by descending length so the first hasPrefix hit
            // is the longest valid match.
            var matched: (String, Int32)?
            if let firstChar = remaining.first,
               let bucket = tokensByFirstChar[firstChar] {
                for (token, id) in bucket {
                    if token.count > remaining.count { continue }
                    if remaining.hasPrefix(token) {
                        matched = (token, id)
                        break
                    }
                }
            }
            if let (token, id) = matched {
                out.append(id)
                idx = normalized.index(idx, offsetBy: token.count)
            } else {
                out.append(Self.unkID)
                idx = normalized.index(after: idx)
            }
            if out.count >= maxLength - 2 { break }  // safety cap
        }
        return out
    }
}
