//
//  NameSimilarity.swift
//  Kalsmritikosh
//
//  Pure string-similarity used by the on-device entity reconciler to spot
//  OCR / typo variants of the SAME name ("thirshendus sasmal" vs the
//  corroborated "shirshendu sasmal") without any model or network. Jaro-
//  Winkler is chosen because it rewards a shared prefix and tolerates the
//  single-character insertions/transpositions OCR produces, while staying
//  low on genuinely different names.
//

import Foundation

public enum NameSimilarity {
    /// Jaro-Winkler similarity in [0, 1]. 1.0 = identical.
    public static func jaroWinkler(_ s1: String, _ s2: String) -> Double {
        let a = Array(s1), b = Array(s2)
        if a.isEmpty && b.isEmpty { return 1 }
        if a.isEmpty || b.isEmpty { return 0 }
        if a == b { return 1 }

        let matchDistance = max(0, max(a.count, b.count) / 2 - 1)
        var aMatched = [Bool](repeating: false, count: a.count)
        var bMatched = [Bool](repeating: false, count: b.count)
        var matches = 0

        for i in 0..<a.count {
            let start = max(0, i - matchDistance)
            let end = min(i + matchDistance + 1, b.count)
            if start >= end { continue }
            for j in start..<end where !bMatched[j] && a[i] == b[j] {
                aMatched[i] = true
                bMatched[j] = true
                matches += 1
                break
            }
        }
        if matches == 0 { return 0 }

        // Count transpositions.
        var transpositions = 0.0
        var k = 0
        for i in 0..<a.count where aMatched[i] {
            while !bMatched[k] { k += 1 }
            if a[i] != b[k] { transpositions += 1 }
            k += 1
        }
        transpositions /= 2

        let m = Double(matches)
        let jaro = (m / Double(a.count) + m / Double(b.count) + (m - transpositions) / m) / 3

        // Winkler: boost for a common prefix up to 4 chars.
        var prefix = 0
        for i in 0..<min(4, min(a.count, b.count)) {
            if a[i] == b[i] { prefix += 1 } else { break }
        }
        return jaro + Double(prefix) * 0.1 * (1 - jaro)
    }
}
