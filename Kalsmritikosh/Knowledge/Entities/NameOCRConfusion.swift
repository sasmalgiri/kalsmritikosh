//
//  NameOCRConfusion.swift
//  Kalsmritikosh
//
//  V3 3d (F2) — person-name OCR confusion at the LETTER-GROUP level. The
//  identifier detector (IdentifierAnchorReview) uses single-character classes;
//  scanned NAMES also swap letter GROUPS that share a glyph shape: "rn"→"m",
//  "cl"→"d", "vv"→"w". The reconciler's license to fold two surnames must come
//  from an EXPLAINABLE substitution (mechanism), never a similarity score
//  (shape) — Jaro-Winkler may only VETO, never qualify. So "Sasmal"/"Sasrnal"
//  folds (rn↔m explains it) while "Nair"/"Singh" and "Sharma"/"Verma" never do
//  (no confusion class explains them).
//

import Foundation

public enum NameOCRConfusion {

    /// Bidirectional OCR confusions — letter groups first, then the single-letter
    /// classes the identifier set uses (names carry digits rarely, but a scanned
    /// "l"/"1" in a name is the same corruption).
    public static let confusions: [(String, String)] = [
        ("rn", "m"), ("cl", "d"), ("vv", "w"), ("li", "u"), ("nn", "m"),
        ("5", "s"), ("0", "o"), ("1", "l"), ("1", "i"), ("8", "b"), ("2", "z")
    ]

    /// True iff surname `a` becomes `b` by EXACTLY ONE substring substitution from
    /// the confusion set (either direction) — a fully-explained OCR corruption,
    /// not a similarity judgement. Case-insensitive. Distinct inputs required.
    public static func surnameExplainable(_ a: String, _ b: String) -> Bool {
        let la = a.lowercased(), lb = b.lowercased()
        guard la != lb else { return false }
        for (x, y) in confusions {
            if replacingOneOccurrence(la, of: x, with: y, yields: lb) { return true }
            if replacingOneOccurrence(la, of: y, with: x, yields: lb) { return true }
        }
        return false
    }

    /// Does replacing exactly one occurrence of `from` with `to` in `s` yield
    /// `target`? Tries each occurrence position (so "nn"→"m" in "annna" is tested
    /// at each site).
    private static func replacingOneOccurrence(_ s: String, of from: String, with to: String, yields target: String) -> Bool {
        guard !from.isEmpty else { return false }
        var searchStart = s.startIndex
        while let r = s.range(of: from, range: searchStart..<s.endIndex) {
            var candidate = s
            candidate.replaceSubrange(r, with: to)
            if candidate == target { return true }
            searchStart = r.upperBound
        }
        return false
    }
}
