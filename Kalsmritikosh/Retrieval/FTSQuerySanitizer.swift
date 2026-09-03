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

    /// F4.1 — fixed stopword list: tokens that match everything and discriminate
    /// nothing. A stopword contributes ZERO recall (any document worth finding
    /// via "Khurana invoice amount" matches on the meaningful terms), but in an
    /// OR-join it FLOODS the candidate pool — live Q6 showed "there"/"from"/"and"
    /// displacing Khurana-specific content with résumé junk. Excluding them
    /// completes the stated join policy: recall-oriented OR of terms THAT CARRY
    /// INFORMATION. Deterministic, fixed — never tuned per-query.
    public static let stopwords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "if", "then", "else",
        "at", "by", "for", "with", "about", "against", "between", "into",
        "through", "during", "before", "after", "above", "below", "to", "from",
        "up", "down", "in", "out", "on", "off", "over", "under", "again", "once",
        "here", "there", "all", "any", "both", "each", "few", "more", "most",
        "other", "some", "such", "no", "nor", "not", "only", "own", "same",
        "so", "than", "too", "very", "can", "will", "just", "should", "now",
        "is", "are", "was", "were", "be", "been", "being",
        "have", "has", "had", "having", "do", "does", "did", "doing",
        "would", "could", "might", "must", "shall", "may",
        "of", "it", "its", "this", "that", "these", "those",
        "i", "we", "you", "he", "she", "they", "them", "his", "her", "their",
        "our", "your", "my", "me", "him", "us",
        "what", "which", "who", "whom", "whose", "why", "how", "where", "when",
        "whether", "while"
    ]

    /// Sanitize `query` into a valid FTS5 MATCH expression, or "" when no
    /// INFORMATIVE token remains (the caller treats "" as "keyword layer
    /// abstains" — counted, never a raw pass-through). Deterministic and offline.
    ///
    /// - tokenize on any non-alphanumeric boundary (drops all FTS5 syntax);
    /// - IDENTIFIER-SHAPED tokens (any digit) are ALWAYS kept, regardless of
    ///   length ("555489", "2024", "5" — the atoms this product is named for);
    /// - alpha tokens need length ≥2 AND must not be stopwords (F4.1);
    /// - dedupe, first-occurrence order (repeats add no recall);
    /// - double-quote each token as a literal FTS5 term (internal quotes escaped);
    /// - join with OR (recall — a document matching ANY informative term
    ///   surfaces; bm25 `rank` floats the rarest matched term to the top).
    public static func sanitize(_ query: String) -> String {
        var seen = Set<String>()
        let tokens = query
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { tok in
                if tok.contains(where: \.isNumber) { return true }
                return tok.count >= 2 && !stopwords.contains(tok)
            }
            .filter { seen.insert($0).inserted }
        guard !tokens.isEmpty else { return "" }
        return tokens
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
            .joined(separator: " OR ")
    }
}
