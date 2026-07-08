//
//  TableOCR.swift
//  Kalsmritikosh
//
//  Structured table extraction from scanned pages — an Apple-native Swift
//  port of the `ocr-table-pipeline` (Python: OpenCV + PaddleOCR) algorithm:
//
//      deskew → detect table structure → split columns → group rows →
//      OCR each cell → structured rows.
//
//  Equivalences / improvements vs. the original:
//    • PaddleOCR/pytesseract  → Apple Vision (VNRecognizeTextRequest). No
//      third-party dependency; stronger printed-text recognition; multi-
//      language (set recognitionLanguages, e.g. ["de-DE"] for the original's
//      German logistics docs).
//    • OpenCV 90° OSD          → Vision run at all four right-angle
//      orientations, best mean-confidence wins (as VisionOCR already does).
//    • OpenCV minAreaRect fine skew → skew estimated from the slope of the
//      recognized text-line boxes (least-squares), then the page is rotated
//      once and re-recognized. No pixel-level morphology needed.
//    • OpenCV vertical-line morphology for column edges → column boundaries
//      derived from a 1-D clustering of word-box x-centres. This generalises
//      the original (which required printed ruling lines) to ALSO handle
//      borderless tables, while giving the same column split on ruled tables.
//    • group_rows(Y_GAP_THRESHOLD) → adaptive y-gap grouping (threshold from
//      the median line height, so it scales with DPI instead of a magic 80px).
//
//  Output is a generic row×column grid (not the original's fixed Type-1/Type-2
//  German headers), so any table maps onto it; the caller can render TSV for a
//  chunk or hand rows to DocumentExporter.xlsx.
//

import Foundation
#if canImport(Vision)
import Vision
#endif
#if canImport(AppKit)
import AppKit
#endif
import CoreGraphics
import OSLog

/// Result of a table extraction: a row-major grid plus mean OCR confidence.
public struct TableExtractionResult: Sendable {
    public let rows: [[String]]
    public let columnCount: Int
    public let confidence: Float
    /// Skew angle (degrees) that was corrected, for diagnostics.
    public let deskewApplied: Double

    public var isEmpty: Bool { rows.allSatisfy { $0.allSatisfy(\.isEmpty) } }

    /// Tab-separated rendering — the shape the OCREngine.recognizeTable
    /// contract returns and a clean way to store a table in a chunk.
    public func asRows() -> [[String]] { rows }

    public func asTSV() -> String {
        rows.map { $0.joined(separator: "\t") }.joined(separator: "\n")
    }
}

public actor TableOCR {
    private let recognitionLanguages: [String]
    /// Below this estimated skew (degrees) the page is left as-is.
    private static let minSkewToCorrect: Double = 0.75
    /// Skew search is clamped to ±this (a page more tilted than this is a
    /// 90°-orientation problem, handled by the orientation pass, not fine skew).
    private static let maxFineSkew: Double = 20.0

    public init(recognitionLanguages: [String] = ["en-US"]) {
        self.recognitionLanguages = recognitionLanguages
    }

    // MARK: - Entry points

    public func extract(at url: URL) async -> TableExtractionResult {
        #if canImport(Vision) && canImport(AppKit)
        guard let image = NSImage(contentsOf: url),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return .init(rows: [], columnCount: 0, confidence: 0, deskewApplied: 0) }
        return extract(cgImage: cg)
        #else
        return .init(rows: [], columnCount: 0, confidence: 0, deskewApplied: 0)
        #endif
    }

    #if canImport(Vision)
    public nonisolated func extract(cgImage: CGImage) -> TableExtractionResult {
        // Pass 1 — pick the best right-angle orientation and get word boxes.
        var (boxes, orientation, _) = bestOrientation(cgImage)
        guard !boxes.isEmpty else {
            return .init(rows: [], columnCount: 0, confidence: 0, deskewApplied: 0)
        }

        // Fine deskew — estimate tilt from text-line slope; if significant,
        // rotate the page and re-recognize so cells align to a grid.
        var deskew = 0.0
        let skew = estimateSkewDegrees(boxes)
        if abs(skew) >= Self.minSkewToCorrect, abs(skew) <= Self.maxFineSkew,
           let rotated = rotate(cgImage, byDegrees: -skew) {
            let redo = recognize(cgImage: rotated, orientation: orientation)
            if !redo.boxes.isEmpty {
                boxes = redo.boxes
                deskew = skew
            }
        }

        let cols = columnBoundaries(boxes)
        let rowGroups = groupRows(boxes)
        let grid = assembleGrid(rowGroups: rowGroups, columnCenters: cols)
        let meanConf = boxes.isEmpty ? 0 : boxes.map(\.confidence).reduce(0, +) / Float(boxes.count)
        KalsmritikoshLog.knowledge.info("TableOCR: \(grid.count, privacy: .public) rows × \(cols.count, privacy: .public) cols (deskew \(String(format: "%.1f", deskew), privacy: .public)°, conf \(String(format: "%.2f", meanConf), privacy: .public))")
        return .init(rows: grid, columnCount: cols.count, confidence: meanConf, deskewApplied: deskew)
    }
    #endif

    // MARK: - Vision recognition

    #if canImport(Vision)
    /// A recognized word with its pixel-space rectangle (top-left origin).
    private struct WordBox: Sendable {
        let text: String
        let minX: CGFloat, midX: CGFloat, maxX: CGFloat
        let minY: CGFloat, midY: CGFloat   // top-left origin (y grows downward)
        let height: CGFloat
        let width: CGFloat
        let confidence: Float
    }

    private nonisolated func bestOrientation(_ cg: CGImage) -> (boxes: [WordBox], orientation: CGImagePropertyOrientation, confidence: Float) {
        let orientations: [CGImagePropertyOrientation] = [.up, .right, .down, .left]
        var best: (boxes: [WordBox], orientation: CGImagePropertyOrientation, confidence: Float) = ([], .up, -1)
        for o in orientations {
            let r = recognize(cgImage: cg, orientation: o)
            let mean = r.boxes.isEmpty ? 0 : r.boxes.map(\.confidence).reduce(0, +) / Float(r.boxes.count)
            // Prefer the orientation that both reads more text and reads it
            // confidently (count × mean), matching the original's OSD intent.
            let score = mean * Float(r.boxes.count)
            let bestScore = best.confidence * Float(best.boxes.count)
            if score > bestScore { best = (r.boxes, o, mean) }
        }
        return best
    }

    private nonisolated func recognize(cgImage cg: CGImage, orientation: CGImagePropertyOrientation) -> (boxes: [WordBox], mean: Float) {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = recognitionLanguages
        request.usesLanguageCorrection = true
        if #available(macOS 13.0, *) { request.automaticallyDetectsLanguage = false }

        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let handler = VNImageRequestHandler(cgImage: cg, orientation: orientation, options: [:])
        do {
            try handler.perform([request])
            var boxes: [WordBox] = []
            for obs in request.results ?? [] {
                guard let top = obs.topCandidates(1).first else { continue }
                // Vision boundingBox: normalized, origin BOTTOM-left.
                let bb = obs.boundingBox
                let px = bb.origin.x * w
                let pw = bb.width * w
                let ph = bb.height * h
                // Convert to top-left origin.
                let yTop = (1 - bb.origin.y - bb.height) * h
                boxes.append(WordBox(
                    text: top.string,
                    minX: px, midX: px + pw / 2, maxX: px + pw,
                    minY: yTop, midY: yTop + ph / 2,
                    height: ph, width: pw,
                    confidence: top.confidence
                ))
            }
            let mean = boxes.isEmpty ? 0 : boxes.map(\.confidence).reduce(0, +) / Float(boxes.count)
            return (boxes, mean)
        } catch {
            return ([], 0)
        }
    }

    // MARK: - Geometry (deskew / rows / columns)

    /// Estimate text skew (degrees) from the slope of word-box centres within
    /// each detected row. Least-squares slope per row, median across rows.
    private nonisolated func estimateSkewDegrees(_ boxes: [WordBox]) -> Double {
        let rows = groupRowsRaw(boxes)
        var angles: [Double] = []
        for row in rows where row.count >= 3 {
            let xs = row.map { Double($0.midX) }
            let ys = row.map { Double($0.midY) }
            let n = Double(xs.count)
            let sx = xs.reduce(0, +), sy = ys.reduce(0, +)
            let sxx = zip(xs, xs).map(*).reduce(0, +)
            let sxy = zip(xs, ys).map(*).reduce(0, +)
            let denom = n * sxx - sx * sx
            guard abs(denom) > 1e-6 else { continue }
            let slope = (n * sxy - sx * sy) / denom   // dy/dx, y downward
            angles.append(atan(slope) * 180 / .pi)
        }
        guard !angles.isEmpty else { return 0 }
        return median(angles)
    }

    /// Row grouping used for skew estimation (looser — just needs co-lines).
    private nonisolated func groupRowsRaw(_ boxes: [WordBox]) -> [[WordBox]] {
        guard !boxes.isEmpty else { return [] }
        let medianH = median(boxes.map { Double($0.height) })
        let gap = max(medianH * 0.6, 6)
        let sorted = boxes.sorted { $0.midY < $1.midY }
        var rows: [[WordBox]] = []
        var current: [WordBox] = []
        var lastY = sorted[0].midY
        for b in sorted {
            if !current.isEmpty, Double(abs(b.midY - lastY)) > gap {
                rows.append(current); current = []
            }
            current.append(b); lastY = b.midY
        }
        if !current.isEmpty { rows.append(current) }
        return rows
    }

    /// Final row grouping (same adaptive y-gap idea as the original
    /// group_rows, but the threshold scales with median line height).
    private nonisolated func groupRows(_ boxes: [WordBox]) -> [[WordBox]] {
        groupRowsRaw(boxes)
    }

    /// Column centres via 1-D clustering of word-box x-centres. Splits where
    /// the gap between consecutive sorted centres exceeds a width-scaled
    /// threshold — the borderless-table generalisation of the original's
    /// vertical-line edge detection.
    private nonisolated func columnBoundaries(_ boxes: [WordBox]) -> [CGFloat] {
        guard !boxes.isEmpty else { return [] }
        let medianW = CGFloat(median(boxes.map { Double($0.width) }))
        let pageW = (boxes.map(\.maxX).max() ?? 1) - (boxes.map(\.minX).min() ?? 0)
        // A column break needs a horizontal gap wider than a typical word.
        let colGap = max(medianW * 1.5, pageW * 0.04)
        let centers = boxes.map(\.midX).sorted()
        var clusters: [[CGFloat]] = [[centers[0]]]
        for c in centers.dropFirst() {
            if c - (clusters[clusters.count - 1].last ?? c) > colGap {
                clusters.append([c])
            } else {
                clusters[clusters.count - 1].append(c)
            }
        }
        // Column centre = mean of its cluster.
        return clusters.map { $0.reduce(0, +) / CGFloat($0.count) }
    }

    /// Place each row's words into the nearest column, join per cell.
    private nonisolated func assembleGrid(rowGroups: [[WordBox]], columnCenters: [CGFloat]) -> [[String]] {
        guard !columnCenters.isEmpty else {
            return rowGroups.map { [$0.sorted { $0.midX < $1.midX }.map(\.text).joined(separator: " ")] }
        }
        var grid: [[String]] = []
        for row in rowGroups {
            var cells = [[WordBox]](repeating: [], count: columnCenters.count)
            for b in row {
                let col = nearestIndex(of: b.midX, in: columnCenters)
                cells[col].append(b)
            }
            let line = cells.map { bucket in
                bucket.sorted { $0.midX < $1.midX }.map(\.text).joined(separator: " ")
            }
            if line.contains(where: { !$0.isEmpty }) { grid.append(line) }
        }
        return grid
    }

    private nonisolated func nearestIndex(of x: CGFloat, in centers: [CGFloat]) -> Int {
        var best = 0
        var bestD = CGFloat.greatestFiniteMagnitude
        for (i, c) in centers.enumerated() {
            let d = abs(c - x)
            if d < bestD { bestD = d; best = i }
        }
        return best
    }

    private nonisolated func median(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted()
        let m = s.count / 2
        return s.count % 2 == 0 ? (s[m - 1] + s[m]) / 2 : s[m]
    }

    /// Rotate a CGImage by `degrees` (counter-clockwise positive), expanding
    /// the canvas so nothing is clipped — the equivalent of the original's
    /// padded warpAffine.
    private nonisolated func rotate(_ image: CGImage, byDegrees degrees: Double) -> CGImage? {
        let radians = CGFloat(degrees * .pi / 180)
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let newW = abs(w * cos(radians)) + abs(h * sin(radians))
        let newH = abs(w * sin(radians)) + abs(h * cos(radians))
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: Int(newW.rounded()),
            height: Int(newH.rounded()),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))   // white padding
        ctx.fill(CGRect(x: 0, y: 0, width: newW, height: newH))
        ctx.translateBy(x: newW / 2, y: newH / 2)
        ctx.rotate(by: radians)
        ctx.draw(image, in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
        return ctx.makeImage()
    }
    #endif
}
