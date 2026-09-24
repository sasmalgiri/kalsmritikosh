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
    /// First-character buckets, built ON DEMAND and never stored.
    ///
    /// These were a load-time `let`, which cost ~250,000 (String, Int32) tuples
    /// of resident memory for the life of the process. Nothing on the answer
    /// path reads them any more — only the legacy parity reference does — so
    /// paying that permanently to support a comparison run a handful of times
    /// would be the wrong trade. Rebuilding is O(vocab) and happens only when
    /// the parity reference is actually exercised.
    ///
    /// The doc comment they used to carry claimed each bucket held "~hundreds
    /// of tokens that could possibly match". That was the assumption behind the
    /// slow path and it was wrong by three orders of magnitude: 61% of this
    /// vocab shares the "▁" word-boundary first character, so the hot bucket
    /// held ~152,000.
    private var tokensByFirstChar: [Character: [(String, Int32)]] {
        var buckets: [Character: [(String, Int32)]] = [:]
        for (token, id) in vocab {
            guard let head = token.first else { continue }
            buckets[head, default: []].append((token, id))
        }
        for k in buckets.keys {
            buckets[k]?.sort { $0.0.count > $1.0.count }
        }
        return buckets
    }
    /// Longest vocab piece in characters, measured at load (16 for the
    /// bundled bge-reranker vocab). Bounds how much input the greedy
    /// scan can ever consume: ≤ maxLength × maxPieceLength characters.
    private let maxPieceLength: Int
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
        var maxPieceLength = 1
        for (index, pair) in rawVocab.enumerated() {
            guard pair.count >= 1, let token = pair[0] as? String, !token.isEmpty else { continue }
            vocab[token] = Int32(index)
            maxPieceLength = max(maxPieceLength, token.count)
        }
        self.vocab = vocab
        self.maxPieceLength = maxPieceLength
        self.maxLength = maxLength
        KalsmritikoshLog.brain.info("BGETokenizer loaded \(vocab.count, privacy: .public) tokens, longest piece \(maxPieceLength, privacy: .public) chars (length-descending lookup)")
    }

    /// The PROVABLY NEUTRAL input bound: characters beyond this can never
    /// influence the output, because the scan emits at most `maxLength − 2`
    /// tokens and each consumes at least one and at most `maxPieceLength`
    /// characters. Exposed (rather than recomputed by callers from an assumed
    /// piece length) so a test asserting cap neutrality asserts it at the REAL
    /// bound — a test that hardcodes the wrong bound can pass for the wrong
    /// reason.
    var inputCharacterBound: Int { maxLength * maxPieceLength }

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

    /// Greedy longest-prefix tokenization — by LENGTH-DESCENDING VOCAB LOOKUP.
    ///
    /// Identical output to the first-character-bucket scan it replaces (see
    /// `tokenizeLegacyGreedy`, kept only so the parity check below can compare
    /// them), and vastly cheaper.
    ///
    /// WHY THE BUCKET SCAN WAS SLOW, which was not obvious. Buckets were keyed
    /// on the token's FIRST CHARACTER, which is a reasonable index for ordinary
    /// word lists. This is a SentencePiece vocab: every word-initial piece
    /// begins with the "▁" boundary marker, so the overwhelming majority of
    /// 250k tokens live in ONE bucket. At every word boundary — which is most
    /// positions in prose — the scan walked that bucket doing `hasPrefix`
    /// against tens of thousands of tokens.
    ///
    /// Bucketing was not the wrong idea; keying it on a character that nearly
    /// every token shares made it a linear scan of the whole vocab wearing an
    /// index's clothing. This is also why the earlier O(N²) input-length fix
    /// did not solve the latency: it correctly bounded how much INPUT was read,
    /// while the per-position cost stayed proportional to the vocab.
    ///
    /// The replacement asks the opposite question. Instead of "which of these
    /// thousands of tokens is a prefix here?", it asks "is this exact substring
    /// a token?" for each candidate length from `maxPieceLength` down to 1 —
    /// at most 16 hash lookups per position, each O(1). Same greedy-longest
    /// semantics, because the longest matching length IS the longest matching
    /// token.
    ///
    /// Characters are materialised into an array ONCE. `String.Index` walking
    /// costs O(offset) per step, so the old `index(idx, offsetBy:)` per emitted
    /// token was itself superlinear; array indices are O(1).
    private func tokenize(_ text: String) -> [Int32] {
        let capBound = maxLength * maxPieceLength
        let capped = text.count > capBound ? String(text.prefix(capBound)) : text
        let normalized = "\(Self.wordBoundary)" + capped
            .replacingOccurrences(of: " ", with: "\(Self.wordBoundary)")
        let chars = Array(normalized)
        var out: [Int32] = []
        out.reserveCapacity(min(maxLength, chars.count))
        var i = 0
        let limit = maxLength - 2
        while i < chars.count {
            var matchedLength = 0
            var matchedID: Int32 = 0
            var length = min(maxPieceLength, chars.count - i)
            while length >= 1 {
                if let id = vocab[String(chars[i..<(i + length)])] {
                    matchedLength = length
                    matchedID = id
                    break
                }
                length -= 1
            }
            if matchedLength > 0 {
                out.append(matchedID)
                i += matchedLength
            } else {
                out.append(Self.unkID)
                i += 1
            }
            if out.count >= limit { break }
        }
        return out
    }

    /// The previous implementation. Retained ONLY as the parity reference for
    /// `tokenizationMatchesLegacy(_:)` — never called on the answer path. It is
    /// kept rather than deleted because a rerank score shift caused by a
    /// tokenizer change would be invisible in any test that does not compare
    /// the two directly, and "it looked the same in a few spot checks" is not
    /// the standard for a component that feeds a scoring model.
    func tokenizeLegacyGreedy(_ text: String,
                              buckets: [Character: [(String, Int32)]]) -> [Int32] {
        // Provably neutral input cap: the loop below emits at most
        // maxLength − 2 tokens and every emitted token consumes at least
        // 1 and at most maxPieceLength characters, so only the first
        // maxLength × maxPieceLength characters can ever be read. Chunks
        // beyond that (the ledger's oversized/SVG noise) previously cost
        // O(N²) wall-clock for output-identical results.
        let capBound = maxLength * maxPieceLength
        let capped = text.count > capBound ? String(text.prefix(capBound)) : text
        let normalized = "\(Self.wordBoundary)" + capped
            .replacingOccurrences(of: " ", with: "\(Self.wordBoundary)")
        var out: [Int32] = []
        var idx = normalized.startIndex
        while idx < normalized.endIndex {
            let remaining = normalized[idx...]
            // Only consider tokens whose first char matches the
            // current position. Within that bucket they're already
            // sorted by descending length so the first hasPrefix hit
            // is the longest valid match. (No length pre-check:
            // Substring.count walks the whole remaining tail — O(N)
            // per comparison — while hasPrefix alone is O(token) and
            // already returns false for tokens longer than the tail.)
            var matched: (String, Int32)?
            if let firstChar = remaining.first,
               let bucket = buckets[firstChar] {
                for (token, id) in bucket {
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

    /// Samples where the fast path and the legacy scan DISAGREE. Empty is the
    /// property that had to hold for this optimisation to be shippable: the
    /// reranker feeds these ids to a scoring model, so any difference would
    /// silently reorder evidence.
    ///
    /// Takes the whole sample set rather than one string at a time because the
    /// legacy path needs the first-character buckets, which are no longer
    /// stored — building them per call made a 12-sample comparison take longer
    /// than ten minutes. Built once here, reused for every sample.
    ///
    /// Asserted against the REAL bundled vocab, not a synthetic one: the "▁"
    /// bucket holding 61% of tokens is a property of a genuine SentencePiece
    /// vocab, and a fixture would reproduce neither the bug nor the fix.
    ///
    /// KEEP SAMPLES SHORT. Parity is a property of the tokenization RULES, and
    /// the legacy scan costs seconds per kilobyte of prose by construction —
    /// that is what was fixed. A few hundred characters exercises every rule
    /// (word boundaries, unknown characters, non-Latin script, the cap) in
    /// milliseconds.
    func parityMismatches(in samples: [String]) -> [String] {
        let buckets = tokensByFirstChar
        return samples.filter { tokenize($0) != tokenizeLegacyGreedy($0, buckets: buckets) }
    }

    /// A sample set covering each tokenization rule, deliberately short.
    static let paritySamples: [String] = [
        "", "a", "  ",
        "What is the contract value?",
        "Patent No. 555489 was granted on 12 March 2021 to Acme Pvt Ltd.",
        "Roll No.: 7OO32l",                      // OCR-mangled identifier
        "\u{936}\u{94D}\u{930}\u{940} \u{930}\u{93E}\u{92E}",   // non-Latin script
        "e=mc^2 & <svg><path d=\"M0 0\"/></svg>",  // punctuation / markup
        "CamelCaseWordsRunTogether",
        "THE PARTIES HEREBY AGREE TO THE TOTAL CONSIDERATION.",
        String(repeating: "x", count: 9_000),    // past the neutral input cap
    ]

    /// Vocab-shape facts the guard test and the perf note both refer to.
    ///
    /// `largestBucketShare` is the measurement that explains the old latency:
    /// for the bundled vocab it is 0.61, i.e. the hot bucket held 61% of
    /// 249,973 tokens. Computed rather than asserted so the claim stays true
    /// if the vocab is ever replaced.
    var vocabDiagnostics: (tokens: Int, maxPiece: Int, largestBucketShare: Double) {
        var largest = 0
        for (_, bucket) in tokensByFirstChar { largest = max(largest, bucket.count) }
        return (vocab.count, maxPieceLength,
                vocab.isEmpty ? 0 : Double(largest) / Double(vocab.count))
    }
}
