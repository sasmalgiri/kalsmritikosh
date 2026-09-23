//
//  PSTNSFParserTests.swift
//  KalsmritikoshTests
//
//  Outlook .pst/.ost and Lotus/HCL Notes .nsf domain probes. Both readers were
//  ported from the sibling mailin project and shipped with NO tests; these are
//  the first.
//
//  NSF is probed WHOLE-FILE: the reader's text-scan fallback accepts a
//  synthesizable database, so a real sentinel fact round-trips end to end.
//  PST's NDB B-tree format cannot be synthesized faithfully in-test (that would
//  mean writing a PST writer), so its probes cover the pure field-mapping layer
//  plus the honest-failure contract. Full PST byte-level fidelity needs one real
//  .pst fixture — recorded as the remaining gap rather than faked here.
//

import Testing
import Foundation
@testable import Kalsmritikosh

struct PSTNSFParserTests {

    // MARK: - NSF whole-file fidelity

    /// A Notes database the scan pass accepts: NSF-ish header (so the format
    /// check passes), padding past the 256-byte floor, then one `Form: Memo`
    /// note whose fields carry the sentinel fact.
    private func syntheticNSF() -> Data {
        var text = "Lotus Notes NSF database\n"
        text += String(repeating: "-", count: 300) + "\n"
        text += """
        Form: Memo
        From: Riyaz Ahmed <riyaz@example.com>
        SendTo: sasmalgiri@gmail.com
        CopyTo: counsel@example.com
        Subject: Patent 555489 grant notice
        DeliveredDate: 12 March 2024
        Body: Patent 555489 was granted to Riyaz Ahmed on 12 March 2024.
        Categories: patents, grants
        """
        return Data(text.utf8)
    }

    @Test("NSF whole-file: a mail note's fields survive as typed, citable blocks")
    func nsfSentinelFidelity() async throws {
        let doc = try await NSFStructuralParser().parse(
            data: syntheticNSF(), filename: "mail.nsf", type: .nsf,
            logicalSourceID: UUID(), sourceVersionID: UUID())

        #expect(doc.extractionStatus == .complete, "status was \(doc.extractionStatus)")
        #expect(doc.detectedType == .nsf)

        let all = doc.blocks.map(\.rawText).joined(separator: " ")
        #expect(all.contains("555489"), "patent number lost — got: \(all.prefix(200))")
        #expect(all.contains("Riyaz Ahmed"), "sender lost")
        #expect(all.contains("sasmalgiri@gmail.com"), "recipient lost")

        // Notes' own field names are mapped to the shared RFC-822 vocabulary.
        #expect(doc.blocks.first { $0.locator.emailHeaderField == "subject" }?.rawText
                == "Patent 555489 grant notice")
        #expect(doc.blocks.first { $0.locator.emailHeaderField == "to" }?.rawText
                == "sasmalgiri@gmail.com")          // from SendTo
        #expect(doc.blocks.first { $0.locator.emailHeaderField == "cc" }?.rawText
                == "counsel@example.com")           // from CopyTo
        let body = doc.blocks.first { $0.kind == .emailBody }?.rawText ?? ""
        #expect(body.contains("granted to Riyaz Ahmed"))
        // Ordinals contiguous; the note index is carried for citation.
        #expect(doc.blocks.map(\.ordinal) == Array(0..<doc.blocks.count))
        if case .int(let idx)? = doc.blocks.first?.attributes["noteIndex"]?.value {
            #expect(idx == 0)
        } else {
            Issue.record("noteIndex attribute missing")
        }
    }

    @Test("NSF: non-Notes bytes are honestly corrupt, never a silent empty success")
    func nsfGarbageIsCorrupt() async throws {
        let doc = try await NSFStructuralParser().parse(
            data: Data(repeating: 0x7A, count: 600), filename: "fake.nsf", type: .nsf,
            logicalSourceID: UUID(), sourceVersionID: UUID())
        #expect(doc.blocks.isEmpty)
        #expect(doc.extractionStatus == .corrupt || doc.extractionStatus == .empty)
        #expect(doc.warnings.contains { $0.code == "nsf.unreadable" || $0.code == "nsf.no_notes" })
    }

    // MARK: - PST field mapping (pure layer)

    @Test("PST field mapping: sender folds to one From; plain body wins over HTML")
    func pstFieldMapping() {
        var m = PSTReader.PSTMessage()
        m.senderName = "Riyaz Ahmed"
        m.senderEmail = "riyaz@example.com"
        m.displayTo = "sasmalgiri@gmail.com"
        m.subject = "Patent 555489 grant notice"
        m.bodyText = "Patent 555489 was granted to Riyaz Ahmed on 12 March 2024."
        m.bodyHTML = "<p>ignored when plain text exists</p>"

        let fields = Dictionary(uniqueKeysWithValues: PSTStructuralParser.headerFields(of: m))
        #expect(fields["from"] == "Riyaz Ahmed <riyaz@example.com>")
        #expect(fields["to"] == "sasmalgiri@gmail.com")
        #expect(fields["subject"] == "Patent 555489 grant notice")
        #expect(PSTStructuralParser.body(of: m).contains("555489"))
        #expect(!PSTStructuralParser.body(of: m).contains("ignored"))
    }

    @Test("PST field mapping: HTML-only body is tag-stripped; address-only sender needs no angle brackets")
    func pstHTMLAndAddressOnly() {
        var m = PSTReader.PSTMessage()
        m.senderEmail = "riyaz@example.com"      // no display name
        m.bodyHTML = "<html><body><p>Patent 555489 granted.</p></body></html>"
        let fields = Dictionary(uniqueKeysWithValues: PSTStructuralParser.headerFields(of: m))
        #expect(fields["from"] == "riyaz@example.com")
        let body = PSTStructuralParser.body(of: m)
        #expect(body.contains("555489"))
        #expect(!body.contains("<p>"))
    }

    @Test("PST: non-PST bytes are honestly corrupt with a named warning")
    func pstGarbageIsCorrupt() async throws {
        let doc = try await PSTStructuralParser().parse(
            data: Data("not a pst at all".utf8), filename: "fake.pst", type: .pst,
            logicalSourceID: UUID(), sourceVersionID: UUID())
        #expect(doc.extractionStatus == .corrupt)
        #expect(doc.blocks.isEmpty)
        #expect(doc.warnings.contains { $0.code == "pst.unreadable" || $0.code == "pst.walk_failed" })
    }

    // MARK: - Registry ownership

    @Test("The email containers all own a structural parser now (msg / pst / nsf included)")
    func structuralParsersRegistered() {
        let registry = StructuralParserRegistry.standard
        for type in [SourceType.eml, .mbox, .appleMail, .msg, .pst, .nsf] {
            #expect(registry.parser(for: type) != nil, "no structural parser for \(type.rawValue)")
        }
        #expect(registry.parser(for: .msg)?.parserName == "msg")
        #expect(registry.parser(for: .pst)?.parserName == "pst")
        #expect(registry.parser(for: .nsf)?.parserName == "nsf")
    }
}
