//
//  NonWorkflowFeatureHardeningTests.swift
//  KalsmritikoshTests
//
//  Edge-case / ship-hardening coverage for the non-workflow features:
//  multi-page + scanned-page redaction, multi-term + case sensitivity,
//  real EXIF image authenticity, more citation templates, and fund-flow
//  limit/order.
//

import Foundation
import Testing
import PDFKit
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
@testable import Kalsmritikosh

@Suite("Non-workflow features — hardening")
struct NonWorkflowFeatureHardeningTests {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - PDF builders

    enum PageSpec { case text(String); case imageOnly }

    private func makePDF(_ pages: [PageSpec]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kx-h-\(UUID().uuidString).pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            throw NSError(domain: "test", code: 1)
        }
        for page in pages {
            ctx.beginPDFPage(nil)
            switch page {
            case .text(let s):
                let font = CTFontCreateWithName("Helvetica" as CFString, 22, nil)
                let attr = NSAttributedString(string: s, attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0, green: 0, blue: 0, alpha: 1)
                ])
                let fs = CTFramesetterCreateWithAttributedString(attr)
                let path = CGPath(rect: CGRect(x: 54, y: 54, width: 504, height: 684), transform: nil)
                CTFrameDraw(CTFramesetterCreateFrame(fs, CFRange(location: 0, length: 0), path, nil), ctx)
            case .imageOnly:
                ctx.setFillColor(CGColor(red: 0.4, green: 0.4, blue: 0.4, alpha: 1))
                ctx.fill(CGRect(x: 100, y: 100, width: 300, height: 300))
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
        try (data as Data).write(to: url)
        return url
    }

    private func makeJPEG(software: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kx-h-\(UUID().uuidString).jpg")
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let img = { () -> CGImage? in
                  ctx.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
                  ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
                  return ctx.makeImage()
              }() else { throw NSError(domain: "test", code: 2) }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw NSError(domain: "test", code: 3)
        }
        let props: [CFString: Any] = [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFSoftware: software],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2022:01:01 10:00:00"]
        ]
        CGImageDestinationAddImage(dest, img, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw NSError(domain: "test", code: 4) }
        return url
    }

    // MARK: - Redaction edge cases

    @Test("Multi-term redaction removes every listed term across the document")
    func redactionMultiTerm() throws {
        let url = try makePDF([.text("Alpha stays? no. Alpha and Bravo are both secret. Bravo again.")])
        defer { try? FileManager.default.removeItem(at: url) }
        let r = try PDFRedactionService().redact(source: url, terms: ["Alpha", "Bravo"])
        #expect(r.matchCount >= 3) // Alpha x2 + Bravo x2 (at least 3 detected)
        let out = PDFDocument(data: r.data)
        #expect(out?.findString("Alpha", withOptions: [.caseInsensitive]).isEmpty ?? false)
        #expect(out?.findString("Bravo", withOptions: [.caseInsensitive]).isEmpty ?? false)
    }

    @Test("A scanned/image-only page is counted as a redaction caveat")
    func redactionScannedPageCaveat() throws {
        let url = try makePDF([.text("Page one has the SECRETWORD here."), .imageOnly])
        defer { try? FileManager.default.removeItem(at: url) }
        let r = try PDFRedactionService().redact(source: url, terms: ["SECRETWORD"])
        #expect(r.pageCount == 2)
        #expect(r.matchCount >= 1)
        #expect(r.scannedPageCount >= 1, "the image-only page must be flagged")
        #expect(r.verified)
        #expect(PDFDocument(data: r.data)?.findString("SECRETWORD", withOptions: [.caseInsensitive]).isEmpty ?? false)
    }

    @Test("Case-sensitive redaction does not match a differently-cased term")
    func redactionCaseSensitive() throws {
        let url = try makePDF([.text("The word Confidential appears once.")])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: PDFRedactionError.self) {
            _ = try PDFRedactionService().redact(source: url, terms: ["confidential"], caseSensitive: true)
        }
        // Case-insensitive (default) DOES match.
        let r = try PDFRedactionService().redact(source: url, terms: ["confidential"])
        #expect(r.matchCount >= 1)
    }

    // MARK: - Authenticity with real EXIF

    // Note: ImageIO does not round-trip a synthesized TIFF/Software (tag 305)
    // through a minimal generated JPEG — only the EXIF block persists — so the
    // editing-software path can't be exercised with a fabricated file here (it
    // reads the standard TIFF-305 location real cameras/editors write, and is
    // covered by review). This test validates the EXIF capture-time path, which
    // does round-trip, and the fingerprint.
    @Test("A JPEG with EXIF capture metadata surfaces the capture-time signal")
    func authenticityCaptureTime() throws {
        let url = try makeJPEG(software: "Adobe Photoshop 24.0")
        defer { try? FileManager.default.removeItem(at: url) }
        let report = try FileAuthenticityInspector().analyze(url: url)
        #expect(report.sha256.count == 64)
        #expect(report.signals.contains { $0.title.localizedCaseInsensitiveContains("capture time") })
        // A plain generated JPEG must not be flagged as having no EXIF at all.
        #expect(!report.signals.contains { $0.title.localizedCaseInsensitiveContains("no exif") })
    }

    // MARK: - More citation templates

    @Test("Census, vital-record, and online templates are well-formed")
    func citationTemplates() {
        let census = EvidenceExplainedFormatter.format(.censusUS, values: [
            "year": "1880", "county": "Cook County", "state": "Illinois",
            "locality": "Chicago, ED 12", "page": "p. 4B, dwelling 55, family 60",
            "person": "John Smith household", "provider": "digital image, Ancestry.com",
            "citing": "citing NARA microfilm T9, roll 190"
        ])
        #expect(census.first.contains("1880 U.S. census"))
        #expect(!census.first.contains(".."))

        let vital = EvidenceExplainedFormatter.format(.vitalRecord, values: [
            "jurisdiction": "Ohio, Hamilton County", "rectype": "death certificate",
            "number": "no. 45123", "year": "1921", "person": "Mary Smith",
            "repository": "Ohio Dept. of Health", "place": "Columbus"
        ])
        #expect(vital.first.contains("Mary Smith"))
        #expect(!vital.sourceList.contains(".."))

        let online = EvidenceExplainedFormatter.format(.onlineDatabase, values: [
            "dbtitle": "England Births", "website": "FamilySearch",
            "url": "https://familysearch.org/x", "accessed": "21 August 2026",
            "entry": "John Smith, 1841"
        ])
        #expect(online.first.contains("FamilySearch"))
        #expect(online.first.contains("accessed 21 August 2026"))
    }

    // MARK: - Fund flow limit + order

    @Test("fundFlowEdges honors the limit and orders by weight descending")
    func fundFlowLimitOrder() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 0)
        try await SchemaMigrations.migrate(db)
        let fileID = UUID(), koID = UUID()
        try await db.exec("INSERT INTO files (id, url, source_type) VALUES (?,?,?);",
                          [.uuid(fileID), .text("file://\(fileID)"), .text("pdf")])
        try await db.exec("""
        INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at)
        VALUES (?,?,?,?,?,?);
        """, [.uuid(koID), .uuid(fileID), .text("pdf"), .text("x"), .date(t0), .date(t0)])
        let payer = UUID()
        try await db.exec("""
        INSERT INTO entities (id, kind, value, normalized, source_object_id, confidence, attributes_json)
        VALUES (?, 'organization', 'Payer', 'payer', ?, 0.8, '{}');
        """, [.uuid(payer), .uuid(koID)])
        for (i, w) in [5, 3, 1].enumerated() {
            let payee = UUID()
            try await db.exec("""
            INSERT INTO entities (id, kind, value, normalized, source_object_id, confidence, attributes_json)
            VALUES (?, 'vendor', ?, ?, ?, 0.8, '{}');
            """, [.uuid(payee), .text("Payee \(i)"), .text("payee \(i)"), .uuid(koID)])
            try await db.exec("""
            INSERT INTO relationships (id, kind, from_entity_id, to_entity_id, via_event_id,
                                       source_object_id, confidence, attributes_json, weight, evidence_object_ids_json)
            VALUES (?, 'paid', ?, ?, NULL, ?, 0.8, '{}', ?, '[]');
            """, [.uuid(UUID()), .uuid(payer), .uuid(payee), .uuid(koID), .integer(Int64(w))])
        }
        let repo = RelationshipsRepository(database: db)
        let all = try await repo.fundFlowEdges()
        #expect(all.count == 3)
        #expect(all.map { $0.weight } == [5, 3, 1], "must be weight-descending")
        let capped = try await repo.fundFlowEdges(limit: 2)
        #expect(capped.count == 2)
        #expect(capped.first?.weight == 5)
    }
}
