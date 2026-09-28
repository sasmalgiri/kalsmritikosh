//
//  MSGStructuralParser.swift
//  Kalsmritikosh
//
//  Outlook .msg → typed, exactly-located EvidenceBlocks. The OLE2/MAPI READ
//  path already existed (OLE2Reader + EmailLoader's .msg branch); what was
//  missing was the STRUCTURAL layer, so a .msg fact could cite its document but
//  never "the From header" or "the body" the way .eml/.mbox/.emlx facts can.
//
//  Block shapes deliberately mirror EmailStructuralParser (emailHeader per
//  field with `emailHeaderField` in the locator, one emailBody, one attachment
//  block per attachment) so nothing downstream has to branch on the container.
//
//  Never throws for merely-empty/partial input: unreadable bytes come back as
//  `.corrupt` with a named warning (honest failure, per the A1/§7.7 contract).
//

import Foundation
import CryptoKit

public struct MSGStructuralParser: StructuralParser {
    public nonisolated var supportedTypes: Set<SourceType> { [.msg] }
    public nonisolated var parserName: String { "msg" }
    public nonisolated var parserVersion: String { "1" }

    public nonisolated init() {}

    /// Header fields emitted as their own citable block, in RFC-822 reading order.
    private static let headerOrder = ["from", "to", "cc", "bcc", "subject", "date"]

    public func parse(
        data: Data,
        filename: String,
        type: SourceType,
        logicalSourceID: UUID,
        sourceVersionID: UUID
    ) async throws -> ParsedDocument {
        let documentID = UUID()
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()

        func failed(_ code: String, _ message: String) -> ParsedDocument {
            ParsedDocument(
                id: documentID, logicalSourceID: logicalSourceID, sourceVersionID: sourceVersionID,
                filename: filename, detectedType: .msg, mimeType: "application/vnd.ms-outlook",
                contentHash: hash, blocks: [],
                warnings: [ParserWarning(severity: .error, code: code, message: message)],
                extractionStatus: .corrupt)
        }

        // A mis-extensioned file (an .eml or ZIP renamed .msg) is honestly
        // corrupt here rather than silently empty.
        let ole2: OLE2Reader
        do { ole2 = try OLE2Reader(data: data) }
        catch { return failed("msg.not_ole2", "Not an OLE2 compound file: \(error)") }

        let props = ole2.readMAPIProperties()
        let fields = Self.headerFields(from: props)
        let body = Self.body(from: props)

        var blocks: [EvidenceBlock] = []
        var ordinal = 0
        let messageID = props.stringProperty(.internetMessageId)

        func add(_ kind: EvidenceBlockKind, _ text: String, _ locator: SourceLocator,
                 _ attrs: [String: AnyCodable] = [:]) {
            blocks.append(EvidenceBlock(
                documentID: documentID, sourceVersionID: sourceVersionID, ordinal: ordinal,
                kind: kind, rawText: text, locator: locator, extractionMethod: .native,
                attributes: attrs))
            ordinal += 1
        }

        for key in Self.headerOrder {
            guard let value = fields[key], !value.isEmpty else { continue }
            add(.emailHeader, value, SourceLocator(messageID: messageID, emailHeaderField: key))
        }
        if !body.isEmpty {
            add(.emailBody, body, SourceLocator(messageID: messageID))
        }

        // One block per attachment, named like the EML path (filename only —
        // the bytes are staged and ingested as a CHILD document by the loader).
        for storage in ole2.attachmentStorages() {
            let attachProps = ole2.readMAPIProperties(inStorageAt: storage.index)
            guard let name = Self.attachmentName(from: attachProps) else { continue }
            var attrs: [String: AnyCodable] = [:]
            if let mime = attachProps.stringProperty(.attachMimeTag) {
                attrs["mimeType"] = AnyCodable(.string(mime))
            }
            if let bytes = attachProps.binaryProperty(.attachDataBinary) {
                attrs["byteCount"] = AnyCodable(.int(Int64(bytes.count)))
            }
            add(.attachment, name,
                SourceLocator(messageID: messageID, attachmentID: name), attrs)
        }

        var metadata: [String: AnyCodable] = [:]
        for (key, value) in fields where !value.isEmpty {
            metadata[key] = AnyCodable(.string(value))
        }
        if let messageID { metadata["message-id"] = AnyCodable(.string(messageID)) }

        // No headers AND no body = nothing a reader could cite. Report `.empty`
        // (not corrupt — the container parsed fine) so source health is honest.
        if blocks.isEmpty {
            return ParsedDocument(
                id: documentID, logicalSourceID: logicalSourceID, sourceVersionID: sourceVersionID,
                filename: filename, detectedType: .msg, mimeType: "application/vnd.ms-outlook",
                contentHash: hash, metadata: metadata, blocks: [],
                warnings: [ParserWarning(severity: .warning, code: "msg.no_content",
                                         message: "No MAPI headers or body found.")],
                extractionStatus: .empty)
        }

        return ParsedDocument(
            id: documentID, logicalSourceID: logicalSourceID, sourceVersionID: sourceVersionID,
            filename: filename, detectedType: .msg, mimeType: "application/vnd.ms-outlook",
            contentHash: hash, metadata: metadata, blocks: blocks, extractionStatus: .complete)
    }

    // MARK: - MAPI → RFC-822-ish fields (pure; shared shape with the loader)

    /// Lower-cased header dictionary mirroring what the EML path produces, so
    /// metadata consumers see one shape regardless of container. Sender SMTP
    /// wins over `senderEmailAddress` (the latter is often an Exchange LDAP DN
    /// the entity layer can't ground to a real address).
    static func headerFields(from props: MAPIPropertySet) -> [String: String] {
        let addr = props.stringProperty(.senderSmtpAddress)
            ?? props.stringProperty(.senderEmailAddress) ?? ""
        let name = props.stringProperty(.senderName) ?? ""
        let from: String
        if !addr.isEmpty && !name.isEmpty { from = "\(name) <\(addr)>" }
        else if !addr.isEmpty            { from = addr }
        else                             { from = name }

        let date = props.dateProperty(.messageDeliveryTime)
            ?? props.dateProperty(.clientSubmitTime)
            ?? props.dateProperty(.creationTime)

        var out: [String: String] = [:]
        out["from"] = from
        out["to"] = props.stringProperty(.displayTo) ?? ""
        out["cc"] = props.stringProperty(.displayCc) ?? ""
        out["bcc"] = props.stringProperty(.displayBcc) ?? ""
        out["subject"] = props.stringProperty(.subject) ?? ""
        out["date"] = date.map { ISO8601DateFormatter().string(from: $0) } ?? ""
        return out
    }

    /// Body precedence: plain → HTML (tags stripped) → decompressed RTF. Some
    /// Outlook senders ship only the RTF stream, so all three are tried.
    static func body(from props: MAPIPropertySet) -> String {
        if let plain = props.stringProperty(.body), !plain.isEmpty { return plain }
        if let htmlBytes = props.binaryProperty(.htmlBody),
           let html = String(data: htmlBytes, encoding: .utf8), !html.isEmpty {
            return DocxLoader.stripTags(html)
        }
        if let rtfBytes = props.binaryProperty(.rtfCompressed),
           let rtf = decompressRTFLZFu(rtfBytes), !rtf.isEmpty {
            return rtf
        }
        return ""
    }

    /// Long filename wins; short 8.3 name is the fallback.
    static func attachmentName(from props: MAPIPropertySet) -> String? {
        let name = props.stringProperty(.attachLongFilename)
            ?? props.stringProperty(.attachFilename)
            ?? props.stringProperty(.displayName)
        guard let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return name
    }
}
