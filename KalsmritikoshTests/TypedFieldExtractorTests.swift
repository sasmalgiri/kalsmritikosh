//
//  TypedFieldExtractorTests.swift
//  KalsmritikoshTests
//
//  MMI-FINAL — the deterministic typed-field extractor: labeled + pattern rules over
//  EvidenceBlocks, provenance pinned to the exact block + locator, confidence scaled by the
//  block's extraction method (native > OCR/vision), boilerplate skipped, and NO guessing.
//  A typed field is never a Claim. Synthetic only.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("MMI-FINAL — typed-field extractor")
struct TypedFieldExtractorTests {

    private let sv = UUID()
    private let ex = TypedFieldExtractor()

    private func block(_ text: String, kind: EvidenceBlockKind = .paragraph,
                       method: ExtractionMethod = .native, conf: Double = 1.0, bbox: [Double]? = nil) -> EvidenceBlock {
        EvidenceBlock(documentID: UUID(), sourceVersionID: sv, ordinal: 0, kind: kind, rawText: text,
                      locator: SourceLocator(page: 1, boundingBox: bbox), extractionMethod: method, extractionConfidence: conf)
    }
    private func fields(_ text: String, kind: EvidenceBlockKind = .paragraph,
                        method: ExtractionMethod = .native, conf: Double = 1.0, bbox: [Double]? = nil) -> [TypedField] {
        ex.extract(blocks: [block(text, kind: kind, method: method, conf: conf, bbox: bbox)], sourceVersionID: sv)
    }
    private func value(_ fs: [TypedField], _ t: TypedFieldType) -> String? {
        fs.first { $0.fieldType == t }?.normalizedValue
    }

    @Test("Email is extracted, labeled or bare, and normalized to lowercase")
    func email() {
        #expect(value(fields("Contact: JANE.ROE@Example.COM"), .email) == "jane.roe@example.com")
        #expect(value(fields("email: a@b.co"), .email) == "a@b.co")
    }

    @Test("A phone number is extracted and normalized to digits")
    func phone() {
        let v = value(fields("Mobile: +91 98765 43210"), .phone)
        #expect(v == "+919876543210")
    }

    @Test("An amount and its currency are extracted together")
    func amount() {
        let f = fields("Total due: INR 14,72,500.00")
        #expect(value(f, .amount) == "1472500.00")
        #expect(value(f, .currency) == "INR")
    }

    @Test("Date of birth, issue and expiry are extracted from their labels")
    func dates() {
        #expect(value(fields("Date of Birth: 14/03/1990"), .dateOfBirth) == "14/03/1990")
        #expect(value(fields("Date of Issue: 01 Jan 2020"), .issueDate) == "01 Jan 2020")
        #expect(value(fields("Valid Until: 31/12/2030"), .expiryDate) == "31/12/2030")
    }

    @Test("A labeled person name is extracted")
    func personName() {
        #expect(value(fields("Name: Jane Roe"), .personName) == "Jane Roe")
        #expect(value(fields("Full Name: John Michael Doe"), .personName) == "John Michael Doe")
    }

    @Test("A document number is extracted and normalized to uppercase")
    func documentNumber() {
        #expect(value(fields("Passport No: a1234567"), .documentNumber) == "A1234567")
    }

    @Test("Organization, address, invoice, reference, account, tax identifiers extract from labels")
    func otherLabeled() {
        #expect(value(fields("Issued by: Reserve Bank"), .organizationName) == "Reserve Bank")
        #expect(value(fields("Address: 12 High Street, Pune"), .address) == "12 High Street, Pune")
        #expect(value(fields("Invoice No: INV-2024-88"), .invoiceNumber) == "INV-2024-88")
        #expect(value(fields("Reference: REF9931"), .referenceNumber) == "REF9931")
        #expect(value(fields("Account No: 001234567890"), .accountIdentifier) == "001234567890")
        #expect(value(fields("PAN: abcde1234f"), .taxIdentifier) == "ABCDE1234F")
    }

    @Test("An OCR block scales confidence down and records ocrConfidence")
    func ocrConfidence() {
        let f = fields("Name: Jane Roe", method: .ocr, conf: 0.5)
        let name = try? #require(f.first { $0.fieldType == .personName })
        #expect((name?.confidence ?? 1) < 0.9)          // scaled by the 0.5 block confidence
        #expect(name?.ocrConfidence == 0.5)
        #expect(name?.extractionMethod == .ocr)
    }

    @Test("Every field carries provenance: exact block id, locator, and bounding box")
    func provenance() {
        let b = block("Name: Jane Roe", bbox: [10, 20, 100, 15])
        let f = ex.extract(blocks: [b], sourceVersionID: sv).first { $0.fieldType == .personName }
        #expect(f?.evidenceBlockID == b.id)
        #expect(f?.locator.evidenceBlockID == b.id)
        #expect(f?.locator.page == 1)
        #expect(f?.boundingBox == [10, 20, 100, 15])
        #expect(f?.sourceVersionID == sv)
    }

    @Test("Boilerplate blocks (page footer / disclaimer) are skipped")
    func boilerplateSkipped() {
        #expect(fields("email: noreply@bank.com", kind: .pageFooter).isEmpty)
    }

    @Test("A title-cased header without digits is a LOW-confidence name candidate")
    func titleNameHeuristic() {
        let f = fields("Jane Mary Roe", kind: .documentTitle)
        let name = f.first { $0.fieldType == .personName }
        #expect(name != nil)
        #expect((name?.confidence ?? 1) <= 0.5)         // never asserted with high confidence
    }

    @Test("A header containing digits is not treated as a person name")
    func digitsNotAName() {
        #expect(fields("Report 2024 Summary", kind: .documentTitle).contains { $0.fieldType == .personName } == false)
    }

    @Test("A value repeated in one block yields a single deduplicated field")
    func dedup() {
        let f = fields("email: a@b.co and again a@b.co")
        #expect(f.filter { $0.fieldType == .email }.count == 1)
    }
}
