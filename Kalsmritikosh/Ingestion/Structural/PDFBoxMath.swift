//
//  PDFBoxMath.swift
//  Kalsmritikosh
//
//  PAR-004 — pure geometry helpers for turning a paragraph's sampled character bounds
//  into one locator box, so a citation opens the exact region on the page. Kept
//  dependency-free (CoreGraphics only) so the math is unit-testable without PDFKit.
//

import Foundation
import CoreGraphics

public enum PDFBoxMath {
    /// The smallest rect containing all `rects`, or nil when empty.
    public nonisolated static func union(_ rects: [CGRect]) -> CGRect? {
        guard var u = rects.first else { return nil }
        for r in rects.dropFirst() { u = u.union(r) }
        return u
    }

    /// A SourceLocator boundingBox array [x, y, w, h] (page points) for a rect.
    public nonisolated static func array(_ r: CGRect) -> [Double] {
        [Double(r.minX), Double(r.minY), Double(r.width), Double(r.height)]
    }

    /// Character offsets to sample across a range: first, evenly-spaced interior, last.
    /// Deterministic and clamped to the range; never returns duplicates out of order.
    public nonisolated static func sampleOffsets(location: Int, length: Int, samples: Int) -> [Int] {
        guard length > 0 else { return [] }
        let n = max(2, samples)
        let last = location + length - 1
        if length <= n { return Array(location...last) }
        var out: [Int] = []
        for i in 0..<n {
            let frac = Double(i) / Double(n - 1)          // 0…1
            out.append(location + Int((Double(length - 1) * frac).rounded()))
        }
        // De-dup while preserving order (rounding can collide on short ranges).
        var seen = Set<Int>()
        return out.filter { seen.insert($0).inserted }
    }
}
