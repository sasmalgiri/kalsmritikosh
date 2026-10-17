//
//  DeviceImportTests.swift
//  KalsmritikoshTests
//
//  P-3 — Import from iPhone or iPad: the type chosen for an item and the name it is saved under.
//

import Foundation
import UniformTypeIdentifiers
import Testing
@testable import Kalsmritikosh

@Suite("P-3 Import from iPhone or iPad")
struct DeviceImportTests {
    @Test("A scan is kept as its PDF; a photo as the best image type offered")
    func preferredType() {
        #expect(DeviceImport.preferredType(among: [UTType.png.identifier, UTType.pdf.identifier]) == .pdf)
        #expect(DeviceImport.preferredType(among: [UTType.png.identifier, UTType.heic.identifier]) == .heic)
        #expect(DeviceImport.preferredType(among: [UTType.jpeg.identifier]) == .jpeg)
        #expect(DeviceImport.preferredType(among: [UTType.plainText.identifier]) == nil)
        #expect(DeviceImport.preferredType(among: []) == nil)
    }

    @Test("Saved names say what the item is and carry the right extension")
    func fileName() {
        let date = Date(timeIntervalSince1970: 1_760_000_000)
        let scan = DeviceImport.fileName(for: .pdf, at: date)
        let photo = DeviceImport.fileName(for: .heic, at: date)
        #expect(scan.hasPrefix("Scan from iPhone or iPad ") && scan.hasSuffix(".pdf"))
        #expect(photo.hasPrefix("Photo from iPhone or iPad ") && photo.hasSuffix(".heic"))
        #expect(!scan.contains("/") && !scan.contains(":"))
    }
}
