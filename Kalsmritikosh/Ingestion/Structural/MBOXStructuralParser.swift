//
//  MBOXStructuralParser.swift
//  Kalsmritikosh
//
//  A3 — MBOX (a concatenation of RFC-822 messages separated by "From " lines)
//  into structured EvidenceBlocks. Splits the mailbox into individual messages
//  and runs each through EmailStructuralParser.messageBlocks, so every message's
//  headers / body / attachments become typed blocks with a message-id locator
//  and a messageIndex attribute — one ParsedDocument covering the whole mailbox.
//  Replaces the legacy per-message flattened-KO path. Deterministic, no LLM.
//

import Foundation
import CryptoKit

public struct MBOXStructuralParser: StructuralParser {
    public nonisolated var supportedTypes: Set<SourceType> { [.mbox] }
    public nonisolated var parserName: String { "mbox" }
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
        let raw = String(decoding: data, as: UTF8.self)

        let messages = Self.splitMessages(raw)
        guard !messages.isEmpty else {
            return ParsedDocument(
                id: documentID, logicalSourceID: logicalSourceID, sourceVersionID: sourceVersionID,
                filename: filename, detectedType: .mbox, mimeType: "application/mbox",
                contentHash: hash, blocks: [],
                warnings: [ParserWarning(severity: .warning, code: "mbox.empty", message: "No messages found.")],
                extractionStatus: .empty
            )
        }

        var blocks: [EvidenceBlock] = []
        var ordinal = 0
        for (i, message) in messages.enumerated() {
            let (msgBlocks, _, next) = EmailStructuralParser.messageBlocks(
                raw: message, documentID: documentID, sourceVersionID: sourceVersionID,
                filename: filename, ordinalStart: ordinal, messageIndex: i
            )
            blocks.append(contentsOf: msgBlocks)
            ordinal = next
        }

        return ParsedDocument(
            id: documentID, logicalSourceID: logicalSourceID, sourceVersionID: sourceVersionID,
            filename: filename, detectedType: .mbox, mimeType: "application/mbox",
            contentHash: hash,
            metadata: ["messageCount": AnyCodable(.int(Int64(messages.count)))],
            blocks: blocks, extractionStatus: blocks.isEmpty ? .empty : .complete
        )
    }

    // MARK: - MBOX framing (pure)

    /// Split an mbox into its constituent messages. Each message starts at a
    /// line beginning with "From " (the mbox separator). The separator line
    /// itself is dropped; everything up to the next separator is one message.
    static func splitMessages(_ raw: String) -> [String] {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        var messages: [String] = []
        var current: [Substring] = []
        var started = false
        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("From ") {
                if started, !current.isEmpty {
                    messages.append(current.joined(separator: "\n"))
                }
                current = []
                started = true
                continue   // drop the separator line
            }
            if started { current.append(line) }
        }
        if started, !current.isEmpty {
            messages.append(current.joined(separator: "\n"))
        }
        // Keep only messages that actually have content.
        return messages.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}
