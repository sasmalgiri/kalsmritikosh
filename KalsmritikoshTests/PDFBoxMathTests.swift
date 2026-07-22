//
//  PDFBoxMathTests.swift
//  KalsmritikoshTests
//
//  PAR-004 — the pure geometry that turns sampled character bounds into one locator box
//  for exact-highlight citations.
//

import Foundation
import CoreGraphics
import Testing
@testable import Kalsmritikosh

@Suite("PDF box math (PAR-004)")
struct PDFBoxMathTests {

    @Test("Union bounds all rects; nil for empty")
    func union() {
        #expect(PDFBoxMath.union([]) == nil)
        let u = PDFBoxMath.union([CGRect(x: 10, y: 20, width: 5, height: 5),
                                  CGRect(x: 0, y: 0, width: 2, height: 2)])
        #expect(u == CGRect(x: 0, y: 0, width: 15, height: 25))
    }

    @Test("Locator array is [x, y, w, h]")
    func array() {
        #expect(PDFBoxMath.array(CGRect(x: 1, y: 2, width: 3, height: 4)) == [1, 2, 3, 4])
    }

    @Test("Sample offsets: whole range when short, evenly spaced when long, in-bounds")
    func sampleOffsets() {
        #expect(PDFBoxMath.sampleOffsets(location: 0, length: 0, samples: 6) == [])
        // length ≤ samples → the whole range
        #expect(PDFBoxMath.sampleOffsets(location: 5, length: 3, samples: 6) == [5, 6, 7])
        // long range → first…last, all within [loc, loc+len-1], strictly increasing
        let s = PDFBoxMath.sampleOffsets(location: 100, length: 50, samples: 6)
        #expect(s.first == 100)
        #expect(s.last == 149)
        #expect(s == s.sorted())
        #expect(Set(s).count == s.count)                 // no duplicates
        #expect(s.allSatisfy { $0 >= 100 && $0 <= 149 })
    }
}
