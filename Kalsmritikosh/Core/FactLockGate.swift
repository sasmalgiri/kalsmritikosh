//
//  FactLockGate.swift
//  Kalsmritikosh
//
//  Numeric fact-lock pre-gate for model-polished prose (ReCreateHistory port
//  review, TAKE 2 — `timelineComposer.ts` polishIsFactLocked). Wherever a
//  language model REWRITES deterministic or evidence-bound text, every
//  number/date token in the rewrite must already exist in the source
//  material; otherwise the rewrite invented a fact and the caller ships the
//  original. O(n), deterministic, unfoolable for digits. This sits IN FRONT
//  of the semantic gates (ClaimEvaluator / EvidenceVerifier), never instead
//  of them — a hallucinated NAME passes this gate by design.
//
//  Wired today at AnswerSynthesizer's refine acceptance; also the designated
//  gate for the History renderer's Level-3 rephrase plug point and the Story
//  Engine composer when those land.
//

import Foundation

public enum FactLockGate {

    /// Number/date tokens: runs of digits with internal `,` `.` `/` `-`
    /// separators, normalized by dropping commas/whitespace and trailing
    /// punctuation — so "1,200.50", "2024-03-14", "14/03/2024" each become
    /// one comparable token. Devanagari digits are mapped to ASCII first so
    /// future Hindi content is covered by the same gate.
    public nonisolated static func numberTokens(_ text: String) -> [String] {
        let ascii = normalizeDigits(text)
        guard let regex = try? NSRegularExpression(pattern: #"\d[\d,./-]*\d|\d"#) else { return [] }
        let ns = ascii as NSString
        return regex.matches(in: ascii, range: NSRange(location: 0, length: ns.length)).map { m in
            var token = ns.substring(with: m.range)
            token = token.replacingOccurrences(of: ",", with: "")
                         .replacingOccurrences(of: " ", with: "")
            while let last = token.last, "./-".contains(last) { token.removeLast() }
            return token
        }
    }

    /// True when every number token in `candidate` already appears in at
    /// least one of `sources`. A candidate with no numbers passes trivially.
    public nonisolated static func isFactLocked(candidate: String, sources: [String]) -> Bool {
        let candidateTokens = Set(numberTokens(candidate))
        guard !candidateTokens.isEmpty else { return true }
        let allowed = Set(sources.flatMap(numberTokens))
        return candidateTokens.isSubset(of: allowed)
    }

    /// Devanagari → ASCII digit mapping (०१२३४५६७८९ → 0123456789).
    nonisolated static func normalizeDigits(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { (0x0966...0x096F).contains($0.value) }) else {
            return text
        }
        return String(text.unicodeScalars.map { scalar -> Character in
            if (0x0966...0x096F).contains(scalar.value),
               let ascii = Unicode.Scalar(scalar.value - 0x0966 + 0x30) {
                return Character(ascii)
            }
            return Character(scalar)
        })
    }
}
