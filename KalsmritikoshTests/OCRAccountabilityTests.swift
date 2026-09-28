//
//  OCRAccountabilityTests.swift
//  KalsmritikoshTests
//
//  U-4 — the pure OCR accountability core: identifier-shape policy (drives
//  correction-off) and confidence banding (drives low-confidence markers).
//  Vision itself needs an image and is exercised by the fixture harness;
//  these prove the deterministic decisions. Fast tier.
//

import Testing
import Foundation
import CoreGraphics
@testable import Kalsmritikosh

@Suite("U-4 OCR accountability")
struct OCRAccountabilityTests {

    @Test func identifierLinesTurnCorrectionOff() {
        #expect(OCRTextPolicy.isIdentifierShaped("202331019665"))
        #expect(OCRTextPolicy.isIdentifierShaped("Application No. 202331019665"))
        #expect(OCRTextPolicy.isIdentifierShaped("IN202331019665A"))
        #expect(OCRTextPolicy.isIdentifierShaped("Case No: CS/1234/2023"))
    }

    @Test func proseLinesKeepCorrectionOn() {
        #expect(!OCRTextPolicy.isIdentifierShaped("The patent was granted to the applicant"))
        #expect(!OCRTextPolicy.isIdentifierShaped("Dear Sir or Madam"))
        #expect(!OCRTextPolicy.isIdentifierShaped("Shirshendu Sasmal"))
    }

    @Test func confidenceBandsDriveMarkers() {
        let box = CGRect(x: 0, y: 0, width: 1, height: 0.1)
        #expect(OCRLine(text: "x", confidence: 0.3, boundingBox: box).band == .low)
        #expect(OCRLine(text: "x", confidence: 0.3, boundingBox: box).isLowConfidence)
        #expect(OCRLine(text: "x", confidence: 0.65, boundingBox: box).band == .medium)
        #expect(OCRLine(text: "x", confidence: 0.95, boundingBox: box).band == .high)
        #expect(!OCRLine(text: "x", confidence: 0.95, boundingBox: box).isLowConfidence)
    }

    @Test func lineCarriesItsRegion() {
        let box = CGRect(x: 0.1, y: 0.8, width: 0.5, height: 0.05)
        let line = OCRLine(text: "202331019665", confidence: 0.9, boundingBox: box)
        #expect(line.boundingBox == box)   // region survives for click-to-highlight
    }
}
