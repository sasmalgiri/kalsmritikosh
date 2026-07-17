//
//  BERTWordPieceTokenizer.swift
//  Kalsmritikosh
//
//  P6.2 — a small, dependency-free BERT WordPiece tokenizer for the bundled
//  sentence embedder (BGE-small-en-v1.5, which uses a bert-base-uncased
//  vocabulary). This is DISTINCT from BGETokenizer, which is the reranker's
//  Unigram/SentencePiece tokenizer — the two model families tokenize
//  differently, so the embedder needs its own.
//
//  Loads `vocab.txt` (one token per line; id = line index — the standard BERT
//  vocab file that `save_pretrained` emits). Uncased pipeline: lowercase, strip
//  accents, split on whitespace + punctuation, then greedy longest-match
//  WordPiece with "##" continuation. Emits [CLS] … [SEP] padded to maxLength
//  with a matching attention mask. Deterministic; unit-testable without the
//  model.
//

import Foundation
import OSLog

public final class BERTWordPieceTokenizer: @unchecked Sendable {
    public struct Output: Sendable {
        public let inputIDs: [Int32]
        public let attentionMask: [Int32]
    }

    private let vocab: [String: Int32]
    private let clsID: Int32
    private let sepID: Int32
    private let padID: Int32
    private let unkID: Int32
    public let maxLength: Int
    private let maxCharsPerWord = 200

    /// Loads `vocab.txt` from the given Resources subdirectory. Returns nil when
    /// the file is missing or the required special tokens aren't present.
    public init?(resourceName: String = "vocab", subdirectory: String = "BGESmallEmbedder", maxLength: Int = 512) {
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "txt", subdirectory: subdirectory)
                ?? Bundle.main.url(forResource: resourceName, withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        var vocab: [String: Int32] = [:]
        var i: Int32 = 0
        text.enumerateLines { line, _ in
            // vocab.txt tokens never contain leading/trailing whitespace except
            // the newline we've already stripped; keep the token verbatim.
            vocab[line] = i
            i += 1
        }
        guard let cls = vocab["[CLS]"], let sep = vocab["[SEP]"],
              let pad = vocab["[PAD]"], let unk = vocab["[UNK]"] else {
            return nil
        }
        self.vocab = vocab
        self.clsID = cls; self.sepID = sep; self.padID = pad; self.unkID = unk
        self.maxLength = maxLength
        KalsmritikoshLog.routing.info("BERTWordPieceTokenizer loaded \(vocab.count, privacy: .public) tokens")
    }

    /// Test-only initializer with an in-memory vocab (no bundle).
    init(testVocab: [String: Int32], maxLength: Int = 512) {
        self.vocab = testVocab
        self.clsID = testVocab["[CLS]"] ?? 101
        self.sepID = testVocab["[SEP]"] ?? 102
        self.padID = testVocab["[PAD]"] ?? 0
        self.unkID = testVocab["[UNK]"] ?? 100
        self.maxLength = maxLength
    }

    public func encode(text: String) -> Output {
        var ids: [Int32] = [clsID]
        for word in Self.basicTokenize(text) {
            ids.append(contentsOf: wordpiece(word))
            if ids.count >= maxLength - 1 { break }
        }
        ids.append(sepID)
        if ids.count > maxLength { ids = Array(ids.prefix(maxLength)) }
        let attention = Array(repeating: Int32(1), count: ids.count)
        let padCount = max(0, maxLength - ids.count)
        ids.append(contentsOf: Array(repeating: padID, count: padCount))
        let mask = attention + Array(repeating: Int32(0), count: padCount)
        return Output(inputIDs: ids, attentionMask: mask)
    }

    // MARK: - Basic tokenization (uncased + strip accents + split punctuation)

    static func basicTokenize(_ text: String) -> [String] {
        // Lowercase + strip accents (NFD, drop combining marks) — the
        // bert-base-uncased pipeline BGE-small-en inherits.
        let folded = text.lowercased().decomposedStringWithCanonicalMapping
        let stripped = String(folded.unicodeScalars.filter { !$0.properties.isDiacritic })
        var words: [String] = []
        var current = ""
        for scalar in stripped.unicodeScalars {
            let ch = Character(scalar)
            if ch.isWhitespace {
                if !current.isEmpty { words.append(current); current = "" }
            } else if isPunctuation(scalar) {
                if !current.isEmpty { words.append(current); current = "" }
                words.append(String(ch))   // punctuation is its own token
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    static func isPunctuation(_ s: Unicode.Scalar) -> Bool {
        // BERT treats ASCII punctuation AND any Unicode punctuation category as
        // splittable, standalone tokens.
        let v = s.value
        if (33...47).contains(v) || (58...64).contains(v) || (91...96).contains(v) || (123...126).contains(v) {
            return true
        }
        return s.properties.generalCategory == .otherPunctuation
            || s.properties.generalCategory == .dashPunctuation
            || s.properties.generalCategory == .openPunctuation
            || s.properties.generalCategory == .closePunctuation
            || s.properties.generalCategory == .initialPunctuation
            || s.properties.generalCategory == .finalPunctuation
            || s.properties.generalCategory == .connectorPunctuation
    }

    // MARK: - WordPiece (greedy longest-match)

    private func wordpiece(_ word: String) -> [Int32] {
        let chars = Array(word)
        if chars.count > maxCharsPerWord { return [unkID] }
        var pieces: [Int32] = []
        var start = 0
        while start < chars.count {
            var end = chars.count
            var matched: Int32? = nil
            while start < end {
                var sub = String(chars[start..<end])
                if start > 0 { sub = "##" + sub }
                if let id = vocab[sub] { matched = id; break }
                end -= 1
            }
            guard let id = matched else { return [unkID] }  // whole word is OOV
            pieces.append(id)
            start = end
        }
        return pieces
    }
}
