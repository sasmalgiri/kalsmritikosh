//
//  MSGParserTests.swift
//  KalsmritikoshTests
//
//  Outlook .msg domain probes. The OLE2/MAPI read path shipped long ago but had
//  NO test of its own — the same blind spot that hid the quoted-printable
//  truncation in the mbox lane. These build a REAL OLE2 container in-test
//  (CFBFixtureWriter) and assert the fidelity property: a known fact in comes
//  back out verbatim, in typed, citable blocks.
//

import Testing
import Foundation
@testable import Kalsmritikosh

struct MSGParserTests {

    private static let subject = "Patent 555489 grant notice"
    private static let bodyText = "Patent 555489 was granted to Riyaz Ahmed on 12 March 2024."

    /// A single-message .msg with sender/recipient/subject/body properties.
    private func simpleMSG() -> Data {
        CFBFixtureWriter().build([
            CFBFixtureWriter.unicodeProperty(id: .senderName, "Riyaz Ahmed"),
            CFBFixtureWriter.unicodeProperty(id: .senderSmtpAddress, "riyaz@example.com"),
            CFBFixtureWriter.unicodeProperty(id: .displayTo, "sasmalgiri@gmail.com"),
            CFBFixtureWriter.unicodeProperty(id: .subject, Self.subject),
            CFBFixtureWriter.unicodeProperty(id: .body, Self.bodyText),
            CFBFixtureWriter.unicodeProperty(id: .internetMessageId, "<msg-1@example.com>")
        ])
    }

    private func parse(_ data: Data, _ name: String = "probe.msg") async throws -> ParsedDocument {
        try await MSGStructuralParser().parse(
            data: data, filename: name, type: .msg,
            logicalSourceID: UUID(), sourceVersionID: UUID())
    }

    // MARK: - The OLE2 fixture writer itself must produce a readable container

    @Test("The CFB fixture writer produces a container OLE2Reader can read")
    func fixtureWriterRoundTrips() throws {
        let data = CFBFixtureWriter().build([
            .stream("AlphaStream", Data("hello world".utf8)),
            .stream("BetaStream", Data("second value".utf8))
        ])
        let reader = try OLE2Reader(data: data)
        let names = reader.rootChildren().map(\.name)
        #expect(names.contains("AlphaStream"))
        #expect(names.contains("BetaStream"))
        // Mini-stream round-trip: bytes come back byte-exact.
        let alpha = reader.rootChildren().first { $0.name == "AlphaStream" }!
        #expect(String(data: reader.readEntryData(alpha), encoding: .utf8) == "hello world")
    }

    // MARK: - Fidelity

    @Test("MSG whole-file: subject/sender/recipient/body survive as typed blocks")
    func msgSentinelFidelity() async throws {
        let doc = try await parse(simpleMSG())
        #expect(doc.extractionStatus == .complete)
        #expect(doc.detectedType == .msg)

        let all = doc.blocks.map(\.rawText).joined(separator: " ")
        #expect(all.contains("555489"), "patent number lost — got: \(all.prefix(200))")
        #expect(all.contains("Riyaz Ahmed"), "sender lost — got: \(all.prefix(200))")
        #expect(all.contains("12 March 2024"), "date-in-body lost")
        #expect(all.contains("sasmalgiri@gmail.com"), "recipient lost")

        // Typed + citable: the subject is its own emailHeader block addressed by field.
        let subjectBlock = doc.blocks.first { $0.locator.emailHeaderField == "subject" }
        #expect(subjectBlock?.rawText == Self.subject)
        #expect(subjectBlock?.kind == .emailHeader)
        // From folds name + SMTP address into one RFC-822-ish value.
        let fromBlock = doc.blocks.first { $0.locator.emailHeaderField == "from" }
        #expect(fromBlock?.rawText == "Riyaz Ahmed <riyaz@example.com>")
        // Exactly one body block, carrying the message text.
        let bodies = doc.blocks.filter { $0.kind == .emailBody }
        #expect(bodies.count == 1)
        #expect(bodies.first?.rawText == Self.bodyText)
        // Ordinals are contiguous and strictly increasing.
        #expect(doc.blocks.map(\.ordinal) == Array(0..<doc.blocks.count))
    }

    @Test("MSG attachments become citable attachment blocks (the gap .eml already covered)")
    func msgAttachmentBlocks() async throws {
        let pdfBytes = Data("%PDF-1.4 fake attachment bytes".utf8)
        let data = CFBFixtureWriter().build([
            CFBFixtureWriter.unicodeProperty(id: .subject, Self.subject),
            CFBFixtureWriter.unicodeProperty(id: .body, Self.bodyText),
            .storage("__attach_version1.0_#00000000", [
                CFBFixtureWriter.unicodeProperty(id: .attachLongFilename, "grant-notice.pdf"),
                CFBFixtureWriter.unicodeProperty(id: .attachMimeTag, "application/pdf"),
                CFBFixtureWriter.binaryProperty(id: .attachDataBinary, pdfBytes)
            ])
        ])
        let doc = try await parse(data)
        let attachments = doc.blocks.filter { $0.kind == .attachment }
        #expect(attachments.count == 1, "attachment storage not read")
        #expect(attachments.first?.rawText == "grant-notice.pdf")
        #expect(attachments.first?.locator.attachmentID == "grant-notice.pdf")
        if case .string(let mime)? = attachments.first?.attributes["mimeType"]?.value {
            #expect(mime == "application/pdf")
        } else {
            Issue.record("attachment mimeType attribute missing")
        }
        if case .int(let bytes)? = attachments.first?.attributes["byteCount"]?.value {
            #expect(bytes == Int64(pdfBytes.count))
        } else {
            Issue.record("attachment byteCount attribute missing")
        }
    }

    @Test("HTML-only MSG body falls back to tag-stripped text")
    func htmlBodyFallback() async throws {
        let html = "<html><body><p>Patent 555489 granted to Riyaz Ahmed.</p></body></html>"
        let data = CFBFixtureWriter().build([
            CFBFixtureWriter.unicodeProperty(id: .subject, Self.subject),
            CFBFixtureWriter.binaryProperty(id: .htmlBody, Data(html.utf8))
        ])
        let doc = try await parse(data)
        let body = doc.blocks.first { $0.kind == .emailBody }?.rawText ?? ""
        #expect(body.contains("555489"), "HTML body lost — got: \(body)")
        #expect(!body.contains("<p>"), "HTML tags not stripped — got: \(body)")
    }

    // MARK: - Honest failure

    @Test("Non-OLE2 bytes named .msg are honestly corrupt, never a silent empty success")
    func nonOLE2IsCorrupt() async throws {
        let doc = try await parse(Data("From: a@b.com\n\nnot really a msg".utf8), "fake.msg")
        #expect(doc.extractionStatus == .corrupt)
        #expect(doc.blocks.isEmpty)
        #expect(doc.warnings.contains { $0.code == "msg.not_ole2" })
    }

    @Test("A valid container with no MAPI content is empty with a named warning")
    func emptyContainerIsEmpty() async throws {
        let data = CFBFixtureWriter().build([.stream("Unrelated", Data("x".utf8))])
        let doc = try await parse(data)
        #expect(doc.extractionStatus == .empty)
        #expect(doc.warnings.contains { $0.code == "msg.no_content" })
    }
}
