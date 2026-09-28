//
//  PSTStructuralParser.swift
//  Kalsmritikosh
//
//  Outlook PST/OST → typed, exactly-located EvidenceBlocks, one group per
//  message. PSTReader (the ported [MS-PST] NDB walker) already produced
//  PSTMessage values; what was missing was the STRUCTURAL layer, so a PST fact
//  could cite its document but never "the From header of message 12".
//
//  PST is many-messages-per-file, so blocks follow the MBOX pattern: each
//  message's blocks carry a `messageIndex` attribute and a `folderPath` so the
//  originating mailbox folder stays citable. Ordinals are globally increasing
//  across the whole file.
//

import Foundation
import CryptoKit

public struct PSTStructuralParser: StructuralParser {
    public nonisolated var supportedTypes: Set<SourceType> { [.pst] }
    public nonisolated var parserName: String { "pst" }
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
                filename: filename, detectedType: .pst, mimeType: "application/vnd.ms-outlook-pst",
                contentHash: hash, metadata: metadata, blocks: blocks,
                warnings: warnings, extractionStatus: status)
        }

        // Bad magic / unsupported variant is honestly corrupt, never silently empty.
        let reader: PSTReader
        do { reader = try PSTReader(data: data) }
        catch {
            return result([], .corrupt, [ParserWarning(
                severity: .error, code: "pst.unreadable",
                message: "Not a readable PST/OST container: \(error)")])
        }

        let messages: [PSTReader.PSTMessage]
        do { messages = try reader.readAllMessages() }
        catch {
            return result([], .corrupt, [ParserWarning(
                severity: .error, code: "pst.walk_failed",
                message: "PST node walk failed: \(error)")])
        }

        guard !messages.isEmpty else {
            return result([], .empty, [ParserWarning(
                severity: .warning, code: "pst.no_messages",
                message: "Container parsed but held no messages.")])
        }

        var blocks: [EvidenceBlock] = []
        var ordinal = 0
        for (index, message) in messages.enumerated() {
            var attrs: [String: AnyCodable] = ["messageIndex": AnyCodable(.int(Int64(index)))]
            if !message.folderPath.isEmpty {
                attrs["folderPath"] = AnyCodable(.string(message.folderPath))
            }
            func add(_ kind: EvidenceBlockKind, _ text: String, _ locator: SourceLocator) {
                blocks.append(EvidenceBlock(
                    documentID: documentID, sourceVersionID: sourceVersionID, ordinal: ordinal,
                    kind: kind, rawText: text, locator: locator,
                    extractionMethod: .native, attributes: attrs))
                ordinal += 1
            }

            let messageID = message.internetMessageId
            for (field, value) in Self.headerFields(of: message) where !value.isEmpty {
                add(.emailHeader, value,
                    SourceLocator(messageID: messageID, emailHeaderField: field))
            }
            let body = Self.body(of: message)
            if !body.isEmpty {
                add(.emailBody, body, SourceLocator(messageID: messageID))
            }
        }

        let metadata: [String: AnyCodable] = ["messageCount": AnyCodable(.int(Int64(messages.count)))]
        return result(blocks, blocks.isEmpty ? .empty : .complete, [], metadata)
    }

    // MARK: - Pure field mapping

    /// Header fields in RFC-822 reading order. Sender name + address fold into
    /// one `from` value, matching the .eml / .msg shape exactly.
    static func headerFields(of m: PSTReader.PSTMessage) -> [(String, String)] {
        let from: String
        if !m.senderEmail.isEmpty && !m.senderName.isEmpty {
            from = "\(m.senderName) <\(m.senderEmail)>"
        } else if !m.senderEmail.isEmpty {
            from = m.senderEmail
        } else {
            from = m.senderName
        }
        let date = m.deliveryTime ?? m.creationTime
        return [
            ("from", from),
            ("to", m.displayTo),
            ("cc", m.displayCc),
            ("bcc", m.displayBcc),
            ("subject", m.subject),
            ("date", date.map { ISO8601DateFormatter().string(from: $0) } ?? "")
        ]
    }

    /// Plain text wins; HTML is tag-stripped as the fallback.
    static func body(of m: PSTReader.PSTMessage) -> String {
        if !m.bodyText.isEmpty { return m.bodyText }
        if !m.bodyHTML.isEmpty { return DocxLoader.stripTags(m.bodyHTML) }
        return ""
    }
}
