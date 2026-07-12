//
//  EmailStructuralParser.swift
//  Kalsmritikosh
//
//  A3 — .eml into typed EvidenceBlocks. Emits a distinct emailHeader block per
//  key field (From/To/Cc/Subject/Date/Message-ID/In-Reply-To/References), the
//  emailBody, and one attachment block per attached file — each with a
//  message-id + header-field/attachment locator. Reuses EmailLoader's multipart
//  decoding and quoted-region stripping. Deterministic, no LLM.
//
//  (MBOX / EMLX / multi-message containers stay on the existing loader for now;
//  a structural MBOX pass that yields one ParsedDocument per message is a
//  follow-up.)
//

import Foundation
import CryptoKit

public struct EmailStructuralParser: StructuralParser {
    public nonisolated var supportedTypes: Set<SourceType> { [.eml] }
    public nonisolated var parserName: String { "eml" }
    public nonisolated var parserVersion: String { "1" }

    public nonisolated init() {}

    private static let headerBlockKeys = ["from", "to", "cc", "bcc", "subject", "date", "message-id", "in-reply-to", "references"]

    public func parse(
        data: Data,
        filename: String,
        type: SourceType,
        logicalSourceID: UUID,
        sourceVersionID: UUID
    ) async throws -> ParsedDocument {
        let documentID = UUID()
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let raw = String(decoding: data, as: UTF8.self)

        var (blocks, warnings, _) = Self.messageBlocks(
            raw: raw, documentID: documentID, sourceVersionID: sourceVersionID,
            filename: filename, ordinalStart: 0, messageIndex: nil
        )
        if blocks.isEmpty {
            warnings.append(ParserWarning(severity: .warning, code: "eml.empty",
                                          message: "No headers or body extracted."))
        }
        let status: ExtractionStatus = blocks.isEmpty ? .empty : .complete
        return ParsedDocument(
            id: documentID, logicalSourceID: logicalSourceID, sourceVersionID: sourceVersionID,
            filename: filename, detectedType: .eml, mimeType: "message/rfc822",
            contentHash: hash, blocks: blocks, warnings: warnings, extractionStatus: status
        )
    }

    /// Build the evidence blocks for ONE RFC-822 message. Shared by the .eml
    /// parser and the MBOX parser (which calls it once per contained message),
    /// so header/body/attachment handling has a single source of truth.
    /// `messageIndex` (when non-nil) is stamped on each block's attributes so
    /// messages inside a multi-message container stay distinguishable.
    static func messageBlocks(
        raw: String, documentID: UUID, sourceVersionID: UUID?, filename: String,
        ordinalStart: Int, messageIndex: Int?
    ) -> (blocks: [EvidenceBlock], warnings: [ParserWarning], nextOrdinal: Int) {
        let (headers, rawBody) = splitHeadersAndBody(raw)
        let sourceURL = URL(fileURLWithPath: filename)
        let (textBody, attachmentURLs) = EmailLoader.applyMultipartIfNeeded(
            headers: headers, body: rawBody, for: sourceURL
        )
        let (cleanedBody, quotedBytes) = EmailLoader.stripQuotedRegions(textBody)
        let messageID = headers["message-id"]

        var blocks: [EvidenceBlock] = []
        var ordinal = ordinalStart
        let indexAttr: [String: AnyCodable] = messageIndex.map {
            ["messageIndex": AnyCodable(.int(Int64($0)))]
        } ?? [:]

        func add(_ kind: EvidenceBlockKind, _ text: String, _ locator: SourceLocator, _ attrs: [String: AnyCodable] = [:]) {
            blocks.append(EvidenceBlock(
                documentID: documentID, sourceVersionID: sourceVersionID, ordinal: ordinal,
                kind: kind, rawText: text, locator: locator, extractionMethod: .native,
                attributes: attrs.merging(indexAttr) { a, _ in a }
            ))
            ordinal += 1
        }

        for key in headerBlockKeys {
            guard let value = headers[key], !value.isEmpty else { continue }
            add(.emailHeader, EmailLoader.decodeRFC2047(value),
                SourceLocator(messageID: messageID, emailHeaderField: key))
        }
        let body = cleanedBody.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty {
            add(.emailBody, body, SourceLocator(messageID: messageID),
                ["quotedBytesRemoved": AnyCodable(.int(Int64(quotedBytes)))])
        }
        for url in attachmentURLs {
            add(.attachment, url.lastPathComponent,
                SourceLocator(messageID: messageID, attachmentID: url.lastPathComponent),
                ["path": AnyCodable(.string(url.path))])
        }
        return (blocks, [], ordinal)
    }

    // MARK: - RFC-822 header/body split (pure)

    /// Split raw message into (lowercased-keyed headers, body). Unfolds
    /// continuation lines (leading space/tab). Keys are lowercased; the first
    /// occurrence of a key wins for the block set.
    static func splitHeadersAndBody(_ raw: String) -> ([String: String], String) {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        guard let sep = normalized.range(of: "\n\n") else {
            // No blank line — treat the whole thing as headers.
            return (parseHeaderLines(normalized), "")
        }
        let headerText = String(normalized[..<sep.lowerBound])
        let body = String(normalized[sep.upperBound...])
        return (parseHeaderLines(headerText), body)
    }

    private static func parseHeaderLines(_ headerText: String) -> [String: String] {
        var headers: [String: String] = [:]
        var currentKey: String?
        var currentValue = ""
        func flush() {
            if let k = currentKey, headers[k] == nil {
                headers[k] = currentValue.trimmingCharacters(in: .whitespaces)
            }
            currentKey = nil; currentValue = ""
        }
        for line in headerText.split(separator: "\n", omittingEmptySubsequences: false) {
            if let first = line.first, first == " " || first == "\t" {
                currentValue += " " + line.trimmingCharacters(in: .whitespaces)   // folded continuation
            } else if let colon = line.firstIndex(of: ":") {
                flush()
                currentKey = line[..<colon].lowercased().trimmingCharacters(in: .whitespaces)
                currentValue = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        flush()
        return headers
    }
}
