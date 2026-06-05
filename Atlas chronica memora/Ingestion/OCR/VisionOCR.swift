//
//  VisionOCR.swift
//  Atlas chronica memora
//
//  Vision-backed OCR variants: printed text, table layout, form fields.
//  M5 implements printed text; handwritten + table + form recognition
//  are wired but use the same printed pipeline until VNRecognize
//  DocumentRequest is paired with a custom layout pass.
//

import Foundation
#if canImport(Vision)
import Vision
#endif
#if canImport(AppKit)
import AppKit
#endif

public actor VisionOCR {
    public init() {}

    public func recognizePrinted(at url: URL) async -> [String] {
        #if canImport(Vision) && canImport(AppKit)
        guard let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        } catch {
            return []
        }
        #else
        return []
        #endif
    }

    public func recognizeHandwritten(at url: URL) async -> [String] {
        await recognizePrinted(at: url)
    }

    public func recognizeTable(at url: URL) async -> [[String]] {
        let lines = await recognizePrinted(at: url)
        return lines.map { $0.split(separator: "\t").map(String.init) }
    }
}
