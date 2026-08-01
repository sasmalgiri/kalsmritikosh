//
//  CompoundContainerDetectionTests.swift
//  KalsmritikoshTests
//
//  USF-M2 §1/§33 — compound-container disambiguation. DOCX/XLSX/PPTX/ODT/ODS/EPUB are themselves ZIP
//  containers, so a bare ZIP magic sniff reports `.zip` for all of them. The ONE authoritative intake
//  detector now disambiguates the logical container subtype using the declared extension while keeping
//  the detection BASIS as magic bytes (the extension is a subtype selector, not proof the package
//  parses). RAR/7z get unambiguous signatures so an extensionless archive is classified correctly even
//  though its contents cannot yet be decoded. Synthetic bytes only.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("USF-M2 — compound container type detection", .serialized)
struct CompoundContainerDetectionTests {

    private let zipMagic: [UInt8] = [0x50, 0x4B, 0x03, 0x04]
    private let rarMagic: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00]
    private let sevenZMagic: [UInt8] = [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]

    /// Capture a synthetic file and return its recorded (detectedType, detectionBasis).
    private func detect(name: String, magic: [UInt8]) throws -> (SourceType, SourceDetectionBasis) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("usfm2-detect-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var bytes = Data(magic)
        bytes.append(Data(repeating: 0x00, count: 64))   // padding so the file is a plausible container
        let url = dir.appendingPathComponent(name)
        try bytes.write(to: url)
        let (captured, _) = try SourceByteCapture.captureToSnapshot(url, snapshotDirectory: dir.appendingPathComponent("snap", isDirectory: true))
        return (captured.detectedType, captured.detectionBasis)
    }

    @Test("A ZIP-magic .docx is detected as docx via magic bytes, not zip")
    func docxNotZip() throws {
        let (t, b) = try detect(name: "report.docx", magic: zipMagic)
        #expect(t == .docx); #expect(b == .magicBytes)
    }

    @Test("A ZIP-magic .xlsx is detected as xlsx, not zip")
    func xlsxNotZip() throws {
        #expect(try detect(name: "sheet.xlsx", magic: zipMagic).0 == .xlsx)
    }

    @Test("A ZIP-magic .pptx is detected as pptx, not zip")
    func pptxNotZip() throws {
        #expect(try detect(name: "deck.pptx", magic: zipMagic).0 == .pptx)
    }

    @Test("A ZIP-magic .odt is detected as odt")
    func odtNotZip() throws {
        #expect(try detect(name: "doc.odt", magic: zipMagic).0 == .odt)
    }

    @Test("A ZIP-magic .ods is detected as ods")
    func odsNotZip() throws {
        #expect(try detect(name: "book.ods", magic: zipMagic).0 == .ods)
    }

    @Test("A ZIP-magic .epub is detected as epub")
    func epubNotZip() throws {
        #expect(try detect(name: "book.epub", magic: zipMagic).0 == .epub)
    }

    @Test("An ordinary .zip stays zip")
    func ordinaryZip() throws {
        let (t, b) = try detect(name: "bundle.zip", magic: zipMagic)
        #expect(t == .zip); #expect(b == .magicBytes)
    }

    @Test("An extensionless ZIP stays zip")
    func extensionlessZip() throws {
        #expect(try detect(name: "bundle", magic: zipMagic).0 == .zip)
    }

    @Test("A RAR signature is detected as rar even without an extension")
    func rarSignature() throws {
        let (t, b) = try detect(name: "archive", magic: rarMagic)
        #expect(t == .rar); #expect(b == .magicBytes)
    }

    @Test("A 7z signature is detected as sevenZip even without an extension")
    func sevenZSignature() throws {
        let (t, b) = try detect(name: "archive", magic: sevenZMagic)
        #expect(t == .sevenZip); #expect(b == .magicBytes)
    }

    @Test("The subtype selector is pure and defaults unknown extensions to zip")
    func subtypeSelectorPurity() {
        #expect(SourceType.zipSubtype(forDeclaredExtension: "DOCX") == .docx)   // case-insensitive
        #expect(SourceType.zipSubtype(forDeclaredExtension: "bin") == .zip)
        #expect(SourceType.zipSubtype(forDeclaredExtension: "") == .zip)
    }
}
