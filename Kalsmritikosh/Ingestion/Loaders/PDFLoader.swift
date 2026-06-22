//
//  PDFLoader.swift
//  Kalsmritikosh
//
//  PDFKit-backed text extraction with per-page OCR fallback. Pages whose
//  native text is empty are rendered to NSImage and handed to VisionOCR.
//

import Foundation
#if canImport(PDFKit)
import PDFKit
#endif
#if canImport(AppKit)
import AppKit
#endif

public struct PDFLoader: Ingestor {
    public let supportedTypes: Set<SourceType> = [.pdf]
    private let ocr: VisionOCR

    public nonisolated init(ocr: VisionOCR = VisionOCR()) {
        self.ocr = ocr
    }

    public func ingest(fileAt url: URL, type: SourceType) async throws -> KnowledgeObject {
        #if canImport(PDFKit)
        guard let document = PDFDocument(url: url) else {
            throw IngestorError.unreadable(url, underlying: nil)
        }
        var combined = ""
        var pageOffsets: [Int] = []
        var ocrPagesUsed = 0

        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            pageOffsets.append(combined.count)

            let nativeText = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !nativeText.isEmpty {
                combined.append(nativeText)
                if !nativeText.hasSuffix("\n") { combined.append("\n") }
                continue
            }

            // Fallback: render the page and OCR it.
            #if canImport(AppKit)
            let ocrText = await renderAndOCR(page: page, index: index)
            if !ocrText.isEmpty {
                combined.append(ocrText)
                if !ocrText.hasSuffix("\n") { combined.append("\n") }
                ocrPagesUsed += 1
            }
            #endif
        }

        if combined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw IngestorError.empty(url)
        }

        return KnowledgeObject(
            sourceFile: url,
            sourceType: type,
            content: combined,
            metadata: [
                "filename": AnyCodable(.string(url.lastPathComponent)),
                "pageCount": AnyCodable(.int(Int64(document.pageCount))),
                "ocrPagesUsed": AnyCodable(.int(Int64(ocrPagesUsed)))
            ]
        )
        #else
        throw IngestorError.unsupportedType(type)
        #endif
    }

    #if canImport(AppKit) && canImport(PDFKit)
    private func renderAndOCR(page: PDFPage, index: Int) async -> String {
        let bounds = page.bounds(for: .mediaBox)
        let size = NSSize(width: bounds.width * 2, height: bounds.height * 2)
        let image = NSImage(size: size)
        image.lockFocus()
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.saveGState()
            ctx.translateBy(x: 0, y: size.height)
            ctx.scaleBy(x: 2.0, y: -2.0)
            page.draw(with: .mediaBox, to: ctx)
            ctx.restoreGState()
        }
        image.unlockFocus()

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("atlas-pdfpage-\(UUID().uuidString).png")
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            return ""
        }
        do { try png.write(to: tmp) } catch { return "" }
        defer { try? FileManager.default.removeItem(at: tmp) }
        return (await ocr.recognizePrinted(at: tmp)).joined(separator: "\n")
    }
    #endif
}
