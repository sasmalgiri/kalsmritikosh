//
//  FTSQuerySanitizer.swift
//  Kalsmritikosh
//
//  V1.1 U2.5 — turn arbitrary user query text into a SAFE FTS5 MATCH expression.
//
//  THE BUG THIS CLOSES (task #40): ChunksRepository.searchFTS passed raw question
//  text straight to `chunks_fts MATCH ?`, so any punctuation FTS5 reads as syntax
//  (a bare ".", "?", an unbalanced quote, a leading "-") raised a logic error —
//  and, before the no-silent-drop fix, that error was swallowed and FTS returned
//  []. For every ordinary punctuated question — including the identifier
//  questions this product is named for — the keyword layer was silently dead.
//
//  The fix, ruled deterministic + explainable: tokenize to alphanumeric runs,
//  QUOTE every token (so no token can ever be an FTS5 operator), and OR them —
//  recall-oriented by design; the reranker and the lawful cuts handle precision.
//  The sanitized string is what enters the retrieval receipt (NF-1 honesty).
//

import Foundation

public enum FTSQuerySanitizer {

    /// Sanitize `query` into a valid FTS5 MATCH expression, or "" when no usable
    /// token remains (the caller treats "" as "no keyword results", never a raw
    /// pass-through). Deterministic and offline.
    ///
    /// - tokenize on any non-alphanumeric boundary (drops all FTS5 syntax);
    /// - drop single-character tokens (noise) but KEEP short all-numeric tokens
    ///   (a year, a short id fragment);
    /// - double-quote each token as a literal FTS5 term (internal quotes escaped);
    /// - join with OR (recall — a document matching ANY term surfaces; bm25 `rank`
    ///   then floats the rarest matched term, i.e. the identifier, to the top).
    public static func sanitize(_ query: String) -> String {
        let tokens = query
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 2 || $0.allSatisfy(\.isNumber) }
        guard !tokens.isEmpty else { return "" }
        return tokens
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
            .joined(separator: " OR ")
    }
}
