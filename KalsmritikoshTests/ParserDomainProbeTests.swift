//
//  ParserDomainProbeTests.swift
//  KalsmritikoshTests
//
//  Domain-parser probes for the exact defect class found in the owner's live
//  archive (2026-09-22): a SINGLE-PART email body with Content-Transfer-Encoding
//  quoted-printable is never transfer-decoded (applyMultipartIfNeeded only
//  handles multipart/*), so a QP soft break (`=` at end-of-line) that splits an
//  email address leaves the fragment (`algiri@gmail.com`) in the stored text —
//  which the whole-document email regex then extracts as a real address.
//  These probes feed the parsers the same shape synthetically and assert the
//  FULL address survives.
//

import Testing
import Foundation
@testable import Kalsmritikosh

struct ParserDomainProbeTests {

    /// A single-part message whose QP soft break splits an address across lines
    /// exactly like the owner's Gmail Sent.mbox (47k soft breaks, 396 QP parts).
    private let qpMessage = """
    From: sasmalgiri@gmail.com
    To: vishu_rani2821@yahoo.com
    Subject: Probe
    MIME-Version: 1.0
    Content-Type: text/plain; charset=UTF-8
    Content-Transfer-Encoding: quoted-printable

    Please write to sasm=
    algiri@gmail.com regarding the matter, and copy vishu=5Frani2821@yahoo.com.
    """

    @Test("EML path: single-part quoted-printable body is transfer-decoded (no split address)")
    func emlSinglePartQuotedPrintable() {
        let (blocks, _, _) = EmailStructuralParser.messageBlocks(
            raw: qpMessage, documentID: UUID(), sourceVersionID: UUID(),
            filename: "probe.eml", ordinalStart: 0, messageIndex: nil)
        let body = blocks.first { $0.kind == .emailBody }?.rawText ?? ""
        #expect(body.contains("sasmalgiri@gmail.com"),
                "QP soft break must be unfolded — got: \(body.prefix(200))")
        #expect(body.contains("vishu_rani2821@yahoo.com"),
                "QP =5F must decode to underscore — got: \(body.prefix(200))")
    }

    @Test("MBOX path: single-part quoted-printable body is transfer-decoded (no split address)")
    func mboxSinglePartQuotedPrintable() async throws {
        let mbox = "From sasmalgiri@gmail.com Mon Jan 01 00:00:00 2024\n" + qpMessage
        let doc = try await MBOXStructuralParser().parse(
            data: Data(mbox.utf8), filename: "Sent.mbox", type: .mbox,
            logicalSourceID: UUID(), sourceVersionID: UUID())
        let body = doc.blocks.first { $0.kind == .emailBody }?.rawText ?? ""
        #expect(body.contains("sasmalgiri@gmail.com"),
                "QP soft break must be unfolded — got: \(body.prefix(200))")
    }

    @Test("EML path: single-part base64 body is transfer-decoded to text")
    func emlSinglePartBase64() {
        let plain = "Meeting with sasmalgiri@gmail.com on 12 March 2024."
        let b64 = Data(plain.utf8).base64EncodedString()
        let msg = """
        From: a@b.com
        Subject: B64 probe
        MIME-Version: 1.0
        Content-Type: text/plain; charset=UTF-8
        Content-Transfer-Encoding: base64

        \(b64)
        """
        let (blocks, _, _) = EmailStructuralParser.messageBlocks(
            raw: msg, documentID: UUID(), sourceVersionID: UUID(),
            filename: "probe.eml", ordinalStart: 0, messageIndex: nil)
        let body = blocks.first { $0.kind == .emailBody }?.rawText ?? ""
        #expect(body.contains("sasmalgiri@gmail.com"),
                "base64 body must decode to text — got: \(body.prefix(200))")
    }
}
