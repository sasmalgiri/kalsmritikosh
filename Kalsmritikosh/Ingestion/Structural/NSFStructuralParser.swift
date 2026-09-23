//
//  NSFStructuralParser.swift
//  Kalsmritikosh
//
//  Lotus/HCL Notes .nsf → typed, exactly-located EvidenceBlocks, one group per
//  mail note. NSFReader (structured item-record pass with a text-scan fallback)
//  already produced NSFNote values; this adds the STRUCTURAL layer so an NSF
//  fact can cite "the SendTo field of note 3", not just the document.
//
//  Notes names its fields differently from RFC-822 (SendTo / CopyTo /
//  DeliveredDate / $HtmlBody …). They are mapped to the SAME lower-cased header
//  vocabulary the .eml / .msg / .pst lanes emit, so nothing downstream has to
//  know the container. Field aliases follow the loader's existing precedence.
//

import Foundation
import CryptoKit

public struct NSFStructuralParser: StructuralParser {
    public nonisolated var supportedTypes: Set<SourceType> { [.nsf] }
    public nonisolated var parserName: String { "nsf" }
    public nonisolated var parserVersion: String { "1" }

    public nonisolated init() {}

    public func parse(
        data: Data,
        filename: String,
        type: SourceType,
        logicalSourceID: UUID,
        sourceVersionID: UUID
    ) async throws -> ParsedDocument {
        let documentID = UUID()
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()

        func result(_ blocks: [EvidenceBlock], _ status: ExtractionStatus,
                    _ warnings: [ParserWarning] = [],
                    _ metadata: [String: AnyCodable] = [:]) -> ParsedDocument {
            ParsedDocument(
                id: documentID, logicalSourceID: logicalSourceID, sourceVersionID: sourceVersionID,
                filename: filename, detectedType: .nsf, mimeType: "application/vnd.lotus-notes",
                contentHash: hash, metadata: metadata, blocks: blocks,
                warnings: warnings, extractionStatus: status)
        }

        let notes: [NSFReader.NSFNote]
        do { notes = try NSFReader(data: data).readNotes() }
        catch {
            return result([], .corrupt, [ParserWarning(
                severity: .error, code: "nsf.unreadable",
                message: "Not a readable NSF database: \(error)")])
        }

        guard !notes.isEmpty else {
            return result([], .empty, [ParserWarning(
                severity: .warning, code: "nsf.no_notes",
                message: "Database parsed but held no mail notes.")])
        }

        var blocks: [EvidenceBlock] = []
        var ordinal = 0
        for (index, note) in notes.enumerated() {
            var attrs: [String: AnyCodable] = ["noteIndex": AnyCodable(.int(Int64(index)))]
            if !note.categories.isEmpty {
                attrs["categories"] = AnyCodable(.string(note.categories.joined(separator: ", ")))
            }
            func add(_ kind: EvidenceBlockKind, _ text: String, _ locator: SourceLocator) {
                blocks.append(EvidenceBlock(
                    documentID: documentID, sourceVersionID: sourceVersionID, ordinal: ordinal,
                    kind: kind, rawText: text, locator: locator,
                    extractionMethod: .native, attributes: attrs))
                ordinal += 1
            }

            let messageID = note.items["$MessageID"] ?? note.items["UNID"]
            for (field, value) in Self.headerFields(of: note) where !value.isEmpty {
                add(.emailHeader, value,
                    SourceLocator(messageID: messageID, emailHeaderField: field))
            }
            let body = Self.body(of: note)
            if !body.isEmpty {
                add(.emailBody, body, SourceLocator(messageID: messageID))
            }
        }

        let metadata: [String: AnyCodable] = ["noteCount": AnyCodable(.int(Int64(notes.count)))]
        return result(blocks, blocks.isEmpty ? .empty : .complete, [], metadata)
    }

    // MARK: - Notes field vocabulary → RFC-822 header names (pure)

    static func headerFields(of note: NSFReader.NSFNote) -> [(String, String)] {
        func item(_ keys: [String]) -> String {
            for key in keys {
                if let value = note.items[key], !value.isEmpty { return value }
            }
            return ""
        }
        return [
            ("from", item(["From", "$From", "SMTPOriginator", "Principal"])),
            ("to", item(["SendTo", "EnterSendTo"])),
            ("cc", item(["CopyTo", "EnterCopyTo"])),
            ("bcc", item(["BlindCopyTo"])),
            ("subject", item(["Subject"])),
            ("date", item(["DeliveredDate", "PostedDate"]))
        ]
    }

    /// Plain `Body` wins; the HTML variants are tag-stripped as fallback.
    static func body(of note: NSFReader.NSFNote) -> String {
        if let plain = note.items["Body"], !plain.isEmpty { return plain }
        for key in ["$HtmlBody", "Body_HTML"] {
            if let html = note.items[key], !html.isEmpty { return DocxLoader.stripTags(html) }
        }
        return ""
    }
}
