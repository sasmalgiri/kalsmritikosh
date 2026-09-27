//
//  UniversalHygieneTests.swift
//  KalsmritikoshTests
//
//  L2 — "perfect = universal": a value that is transport plumbing, a style
//  sheet, a list enumerator or a form placeholder is never a fact about the
//  world, whatever the domain; an entity is typed by its SHAPE; a file with no
//  extension is recognised by its bytes. Every case below was seen on the
//  owner's real ledger on 2026-09-25/26.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("L2 — universal fact hygiene")
struct UniversalFactHygieneTests {

    @Test("Transport headers and style sheets are not facts; real fields still are")
    func plumbingRejected() {
        #expect(!FactValuePlausibility.isAcceptable(field: "contenttype", value: "multipart/mixed; boundary=089e0115f36e59fa9b051e72df6b"))
        #expect(!FactValuePlausibility.isAcceptable(field: "arcseal", value: "i=1; a=rsa-sha256; t=1710769832; cv=none;"))
        #expect(!FactValuePlausibility.isAcceptable(field: "backgroundcolor", value: "#ffffff;"))
        #expect(!FactValuePlausibility.isAcceptable(field: "color", value: "blue;"))
        #expect(!FactValuePlausibility.isAcceptable(field: "board", value: "&#43;91 22 41114777  | (Fax): &#43;91 22 41114754 |"))
        #expect(!FactValuePlausibility.isAcceptable(field: "bankdetails", value: "(To be filled in only on joining)\t\t\tBank Transfer* / Demand Draft ________"))
        #expect(FactValuePlausibility.isAcceptable(field: "applicant", value: "Shirshendu Sasmal"))
        #expect(FactValuePlausibility.isAcceptable(field: "amount", value: "Rs.1500"))
        #expect(FactValuePlausibility.isAcceptable(field: "colour", value: "blue"), "a product colour is a fact; a CSS colour is not")
        #expect(FactValuePlausibility.isAcceptable(field: "employer", value: "Fresenius Kabi Oncology Ltd."))
    }

    @Test("A list item or fee-table row is not a field label")
    func enumeratorsAreNotLabels() {
        #expect(!OpenFieldExtractor.isLabelLike("1. Use of permanent magnets"))
        #expect(!OpenFieldExtractor.isLabelLike("(a) Hybrid design"))
        #expect(!OpenFieldExtractor.isLabelLike("iv) Enhanced cooling"))
        #expect(!OpenFieldExtractor.isLabelLike("16th year"))
        #expect(OpenFieldExtractor.isLabelLike("24 hours helpline Mumbai"), "a leading number that is not an enumerator is fine")
        #expect(OpenFieldExtractor.isLabelLike("Line 2 Address"))
        #expect(OpenFieldExtractor.isLabelLike("Date of Birth"))
    }

    @Test("A bilingual label keeps its Latin word; a native-script-only label keeps its own")
    func bilingualLabels() {
        #expect(OpenFieldExtractor.normalizeLabel("संलग्न / Enclosed") == "enclosed")
        #expect(OpenFieldExtractor.normalizeLabel("पेषण िदनांक / Date of Dispatch") == "dateofdispatch")
        #expect(OpenFieldExtractor.normalizeLabel("Date of Birth") == "dateofbirth")
        #expect(OpenFieldExtractor.normalizeLabel("संलग्न") == "संलग्न", "no Latin word → the label stays itself")
    }
}

@Suite("L2 — universal entity shape typing")
struct UniversalEntityShapeTests {
    let gate = EntityQualityGate.bundled()

    private func entity(_ kind: Entity.Kind, _ value: String) -> Entity {
        Entity(kind: kind, value: value, sourceObjectID: UUID(), confidence: .medium)
    }

    @Test("A phone is phone-shaped; a padded record number or a bare 12-digit run is not")
    func phoneShapes() {
        for real in ["+91-120-4296878", "1800 22 6655", "(022) 6662 0808", "9960270472", "+1 510 552 9897", "011429057"] {
            #expect(EntityQualityGate.isPhoneShaped(real), "\(real) is a phone")
            #expect(gate.classify(entity(.phoneNumber, real)) == nil)
        }
        for junk in ["0000254722", "0000079140", "434981693797", "0000000000", "911020027981671"] {
            #expect(!EntityQualityGate.isPhoneShaped(junk), "\(junk) is not a phone")
            #expect(gate.classify(entity(.phoneNumber, junk)) == "not-phone-shaped")
        }
        #expect(!NLEntityExtractor.isPlausiblePhone("0000254722"), "the extractor applies the same law at the source")
        #expect(NLEntityExtractor.isPlausiblePhone("+91 8975533075"))
    }

    @Test("Only fragments are retired: bare suffixes and sub-3-letter names; acronyms and mixed-case brands pass")
    func organisationShapes() {
        #expect(gate.classify(entity(.organization, "Ltd")) == "bare-legal-suffix")
        #expect(gate.classify(entity(.organization, "Pvt.")) == "bare-legal-suffix")
        #expect(["too-short-name", "bare-legal-suffix"].contains(gate.classify(entity(.organization, "Ag")) ?? ""), "Ag is both a legal suffix and too short — either class retires it")
        #expect(["too-short", "too-short-name"].contains(gate.classify(entity(.organization, "X")) ?? ""))
        #expect(gate.classify(entity(.organization, "Xy")) == "too-short-name")
        // Mixed-case tokens are NOT retired by shape — "DuPont" and "EtOAc" are real.
        for real in ["AOL", "PPIC", "Google", "Khurana & Khurana", "Auro Laboratories Ltd", "IIPRD", "Movers Limited",
                     "DuPont", "EtOAc", "McKesson", "EU", "MS"] {
            #expect(gate.classify(entity(.organization, real)) == nil, "\(real) must pass")
        }
        // People are untouched by the organisation rules.
        #expect(gate.classify(entity(.person, "Anil")) == nil)
    }
}

@Suite("L2 — text formats recognised by their bytes")
struct TextSignatureSniffTests {
    private func head(_ s: String) -> Data { Data(s.utf8) }

    @Test("Extension-less parts are typed by their opener; binary is not claimed")
    func sniffs() {
        #expect(SourceType.sniffTextSignature(head("<!DOCTYPE HTML PUBLIC \"-//W3C//DTD HTML 3.2//EN\">\r\n<HTML>")) == .html)
        #expect(SourceType.sniffTextSignature(head("  <html><body>x</body></html>")) == .html)
        #expect(SourceType.sniffTextSignature(head("<?xml version=\"1.0\"?><svg>")) == .xml)
        #expect(SourceType.sniffTextSignature(head("{\\rtf1\\ansi")) == .rtf)
        #expect(SourceType.sniffTextSignature(head("Return-Path: <a@b.com>\nReceived: from x")) == .eml)
        #expect(SourceType.sniffTextSignature(head("From a@b.com Fri Jul 04 09:24:30 2008\nSubject: hi")) == .mbox)
        #expect(SourceType.sniffTextSignature(head("{\"a\": 1}")) == .json)
        #expect(SourceType.sniffTextSignature(head("Dear Sir,\nPlease find the fee structure.")) == .txt)
        #expect(SourceType.sniffTextSignature(Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x00, 0x01])) == nil, "JPEG is for the magic sniffer")
        #expect(SourceType.sniffTextSignature(Data()) == nil)
        // P1.7 — generic RFC 822 header blocks (owner copy: returned originals, delivery reports)
        #expect(SourceType.sniffTextSignature(head("DKIM-Signature: v=1; a=rsa-sha256;\r\n        d=gmail.com\r\nX-Received: by 10.1\r\nSubject: resume\r\n")) == .eml)
        #expect(SourceType.sniffTextSignature(head("Reporting-MTA: dns; googlemail.com\r\nArrival-Date: Sat, 12 May 2018\r\n\r\nFinal-Recipient: rfc822; a@b.com\r\nAction: failed\r\nStatus: 5.1.1\r\n")) == .eml)
        // …but a form of labelled lines is not a message, and prose is not either
        #expect(SourceType.sniffTextSignature(head("Name: Jane Roe\nAge: 30\nCity: Pune\nPhone: 98765\n")) == .txt)
        #expect(SourceType.sniffTextSignature(head("Note: see below\nDear Sir, the fee is due.")) == .txt)
    }
}
