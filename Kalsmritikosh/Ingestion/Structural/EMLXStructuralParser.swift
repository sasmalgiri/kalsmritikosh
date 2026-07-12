//
//  EMLXStructuralParser.swift
//  Kalsmritikosh
//
//  A3 — Apple Mail `.emlx` into structured EvidenceBlocks. The emlx wrapper is
//  "<decimal byte length>\n<RFC-822 message>\n<optional Apple plist trailer>".
//  We peel the length prefix + trailer and hand the message to the shared
//  EmailStructuralParser.messageBlocks, so header/body/attachment handling
//  matches .eml / .mbox exactly. Replaces the legacy flattened-KO path.
//  Deterministic, no LLM.
//

import Foundation
import CryptoKit

public struct EMLXStructuralParser: StructuralParser {
    public nonisolated var supportedTypes: Set<SourceType> { [.appleMail] }
    public nonisolated var parserName: String { "emlx-apple-mail" }
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

        guard let message = Self.peelMessage(data) else {
            return ParsedDocument(
                id: documentID, logicalSourceID: logicalSourceID, sourceVersionID: sourceVersionID,
                filename: filename, detectedType: .appleMail, mimeType: "message/rfc822",
                contentHash: hash, blocks: [],
                warnings: [ParserWarning(severity: .error, code: "emlx.bad_prefix",
                                         message: "Missing or invalid emlx byte-length prefix.")],
                extractionStatus: .corrupt
            )
        }

        var (blocks, warnings, _) = EmailStructuralParser.messageBlocks(
            raw: message, documentID: documentID, sourceVersionID: sourceVersionID,
            filename: filename, ordinalStart: 0, messageIndex: nil
        )
        if blocks.isEmpty {
            warnings.append(ParserWarning(severity: .warning, code: "emlx.empty",
                                          message: "No headers or body extracted."))
        }
        return ParsedDocument(
            id: documentID, logicalSourceID: logicalSourceID, sourceVersionID: sourceVersionID,
            filename: filename, detectedType: .appleMail, mimeType: "message/rfc822",
            contentHash: hash, blocks: blocks, warnings: warnings,
            extractionStatus: blocks.isEmpty ? .empty : .complete
        )
    }

    // MARK: - emlx wrapper peel (pure)

    /// Extract the RFC-822 message from an emlx: the first line is a decimal
    /// byte count; the next `length` bytes are the message; a plist trailer
    /// after it is discarded. Returns nil when the prefix is absent/invalid.
    static func peelMessage(_ data: Data) -> String? {
        guard let newline = data.firstIndex(of: 0x0A) else { return nil }
        let prefix = String(decoding: data[data.startIndex..<newline], as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
        guard let length = Int(prefix), length > 0 else { return nil }
        let start = data.index(after: newline)
        let end = data.index(start, offsetBy: length, limitedBy: data.endIndex) ?? data.endIndex
        return String(decoding: data[start..<end], as: UTF8.self)
    }
}
