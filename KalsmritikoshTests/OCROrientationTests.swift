//
//  OCROrientationTests.swift
//  KalsmritikoshTests
//
//  Case bench 2026-10-20: a scanned page cost eight full OCR passes (four orientations for the
//  printed text, four more for the table reader). An upright page now stops after the first;
//  a page scanned upside down must still be read the right way up.
//

import AppKit
import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("OCR orientation — upright stops early, upside-down still reads", .serialized)
struct OCROrientationTests {

    private static let lines = (1...14).map { "Line \($0): The employee was hospitalized after the press closed on his hand." }

    /// A page of text at 150 dpi, optionally turned upside down, written as a PNG.
    private func page(upsideDown: Bool) throws -> URL {
        let size = CGSize(width: 1275, height: 1650)
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw CocoaError(.fileWriteUnknown) }
        ctx.setFillColor(NSColor.white.cgColor); ctx.fill(CGRect(origin: .zero, size: size))
        if upsideDown { ctx.translateBy(x: size.width, y: size.height); ctx.rotate(by: .pi) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let font = NSFont(name: "Times New Roman", size: 30) ?? .systemFont(ofSize: 30)
        NSAttributedString(string: Self.lines.joined(separator: "\n"), attributes: [.font: font, .foregroundColor: NSColor.black])
            .draw(in: CGRect(x: 90, y: 90, width: size.width - 180, height: size.height - 180))
        NSGraphicsContext.restoreGraphicsState()
        guard let image = ctx.makeImage(),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ocr-orient-\(UUID().uuidString).png")
        try png.write(to: url)
        return url
    }

    @Test("Both an upright and an upside-down page read as the text")
    func readsBothWays() async throws {
        for upsideDown in [false, true] {
            let url = try page(upsideDown: upsideDown)
            defer { try? FileManager.default.removeItem(at: url) }
            let text = await VisionOCR().recognizePrinted(at: url).joined(separator: "\n").lowercased()
            #expect(text.contains("hospitalized"), "upsideDown=\(upsideDown): \(text.prefix(200))")
        }
    }

    @Test("The upright threshold needs a dense, confident read")
    func threshold() {
        #expect(VisionOCR.readsUpright(lines: 14, confidence: 0.95))
        #expect(!VisionOCR.readsUpright(lines: 3, confidence: 0.99))
        #expect(!VisionOCR.readsUpright(lines: 30, confidence: 0.5))
    }
}
