//
//  EmailLoader.swift
//  Kalsmritikosh
//
//  EML / .emlx → one KO per file. MBOX → one KO per message (T13.1
//  paid off the M5 debt). PST / MSG land in Gate 3 via GS-MAIL —
//  they require third-party decoders or AppKit-level Mail.app access.
//
//  Header parsing pulls From / To / Cc / Date out of structured fields
//  and emits them as high-confidence Entity rows on the KO (T13.2);
//  routing headers (Received, Message-ID, Return-Path, DKIM, SPF, X-*,
//  server names) never reach NER because the loader only prepends the
//  human-relevant headers (From / To / Cc / Subject / Date) to the
//  body that gets chunked.
//

import Foundation
import CryptoKit

public struct EmailLoader: Ingestor {
    public let supportedTypes: Set<SourceType> = [.eml, .mbox, .pst, .msg, .appleMail, .nsf]
    // .eml + .msg = cheap CPU MIME parsing. .pst / .nsf are rare and
    // big but still single-file workloads — they don't benefit from
    // parallel scheduling against themselves. Pick .cpu since that's
    // the heavy hitter on real corpora (Gmail Takeout = thousands of
    // .eml files, no PST/NSF).
    public let primaryLane: ResourceLane = .cpu

    /// Move-A feature flag. When `true`, mbox ingest emits one KO per
    /// reply-chain thread via ThreadCoalescer. When `false` (default),
    /// mbox ingest emits one KO per message — the pre-Move-A path that
    /// the 435 MB production DB was built with.
    ///
    /// Held at `false` until the per-message extraction fanout lands
    /// in `IngestCoordinator.processKnowledgeObject` so events,
    /// mentions, and memory subjects don't degrade on thread KOs.
    /// Flip to `true` only when the fanout is in place AND a fresh
    /// re-ingest is acceptable. ThreadCoalescer.swift stays in the
    /// tree either way — the helper is ready when we are.
    /// Move A — collapse a reply chain into one KO per thread.
    /// Defaults OFF (the safe, validated pre-Move-A behavior). The
    /// user can flip via UserDefaults key
    /// `"kalsmritikosh.moveA.threadCoalescing"` (Settings → Privacy
    /// & ingestion → Coalesce email threads), no rebuild required.
    ///
    /// Pre-flip checklist (documented for reuse):
    ///   1. ThreadCoalescer's 14-day subject-fallback window is
    ///      validated against the user's real archive (over-merge
    ///      bug from prior 180-day window is fixed)
    ///   2. A fresh re-ingest of the affected mailbox is acceptable
    ///      — Move A changes the KO shape, so the file-hash dedup
    ///      will re-extract messages even though file rows already
    ///      exist
    ///   3. Downstream IngestCoordinator.processKnowledgeObject
    ///      fanout (entity / event / mention extraction over the
    ///      thread KO body, not per-message) is healthy — currently
    ///      tested by smoke; the per-thread KOs produce richer
    ///      memory_objects at the cost of slightly larger chunks.
    public nonisolated static var threadCoalescingEnabled: Bool {
        UserDefaults.standard.bool(forKey: "kalsmritikosh.moveA.threadCoalescing")
    }

    public nonisolated init() {}

    public func ingest(fileAt url: URL, type: SourceType) async throws -> KnowledgeObject {
        switch type {
        case .eml:
            return try ingestEML(at: url)
        case .mbox:
            // For a single-KO entry point, keep the legacy concatenated
            // KO so any caller that doesn't use `ingestMany` still gets
            // something coherent. The modern path (IngestCoordinator)
            // uses `ingestMany` so it gets per-message KOs.
            return try ingestMBOX(at: url)
        case .appleMail:
            return try ingestAppleEMLX(at: url)
        case .msg:
            // G4.9 — native Outlook .msg parsing via OLE2 + MAPI.
            // Previously fell through to the binary stub.
            return try ingestMSG(at: url)
        case .pst:
            // G4.9 — PST is many-messages-per-file. The single-KO
            // entry point only used by callers that don't iterate
            // via ingestMany; collapse all messages into one KO so
            // they still get something coherent.
            return try ingestPSTConcatenated(at: url)
        case .nsf:
            // G4.9 — Lotus Notes NSF: same many-per-file shape as PST,
            // same legacy single-KO fallback strategy.
            return try ingestNSFConcatenated(at: url)
        default:
            return try binaryStub(at: url, type: type)
        }
    }

    /// T13.1 — mbox produces one KO per message; other formats fall
    /// through to the single-KO path. G4.9 — PST and NSF are also
    /// per-message.
    public func ingestMany(fileAt url: URL, type: SourceType) async throws -> [KnowledgeObject] {
        if type == .mbox {
            return try ingestMBOXAsMessages(at: url)
        }
        if type == .pst {
            return try ingestPSTAsMessages(at: url)
        }
        if type == .nsf {
            return try ingestNSFAsMessages(at: url)
        }
        return [try await ingest(fileAt: url, type: type)]
    }

    /// Apple Mail's `.emlx` is "<decimal byte length>\n<RFC822 message>\n
    /// <optional Apple plist trailer>". We peel the length prefix and the
    /// trailer, then delegate to the EML path.
    private func ingestAppleEMLX(at url: URL) throws -> KnowledgeObject {
        let raw: Data
        do { raw = try Data(contentsOf: url) }
        catch { throw IngestorError.unreadable(url, underlying: error) }

        // Scan up to the first newline for the byte-count prefix.
        guard let newlineIdx = raw.firstIndex(of: 0x0A) else {
            throw IngestorError.parseFailure(url, reason: "emlx: missing length prefix")
        }
        let prefix = raw[raw.startIndex..<newlineIdx]
        let prefixString = String(decoding: prefix, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        guard let length = Int(prefixString), length > 0 else {
            throw IngestorError.parseFailure(url, reason: "emlx: invalid length prefix '\(prefixString)'")
        }
        let messageStart = raw.index(after: newlineIdx)
        let messageEnd = raw.index(messageStart, offsetBy: length, limitedBy: raw.endIndex) ?? raw.endIndex
        let messageData = raw[messageStart..<messageEnd]
        let messageString = String(decoding: messageData, as: UTF8.self)
        let (headers, body) = splitEMLHeaders(messageString)

        var meta: [String: AnyCodable] = [
            "filename": AnyCodable(.string(url.lastPathComponent)),
            "loader": AnyCodable(.string("emlx-apple-mail"))
        ]
        for (key, value) in headers { meta[key] = AnyCodable(.string(value)) }
        let (textBody, attachmentURLs) = Self.applyMultipartIfNeeded(
            headers: headers,
            body: body,
            for: url
        )
        let (cleanedBody, quotedBytesRemoved) = Self.stripQuotedRegions(textBody)
        meta["quotedBytesRemoved"] = AnyCodable(.int(Int64(quotedBytesRemoved)))
        if let json = Self.encodeAttachmentURLs(attachmentURLs) {
            meta[Self.attachmentURLsMetaKey] = AnyCodable(.string(json))
        }

        var headerLines: [String] = []
        for key in ["from", "to", "cc", "subject", "date"] {
            if let value = headers[key], !value.isEmpty {
                headerLines.append("\(key.capitalized): \(value)")
            }
        }
        let merged = headerLines.isEmpty
            ? cleanedBody
            : headerLines.joined(separator: "\n") + "\n\n" + cleanedBody

        if merged.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw IngestorError.empty(url)
        }
        let koID = UUID()
        let structured = Self.structuredEntities(from: headers, sourceObjectID: koID)
        if let json = Self.encodeStructuredEntities(structured) {
            meta[Self.structuredEntitiesMetaKey] = AnyCodable(.string(json))
        }
        return KnowledgeObject(
            id: koID,
            sourceFile: url,
            sourceType: .appleMail,
            content: merged,
            metadata: meta,
            confidence: .high
        )
    }

    private func ingestEML(at url: URL) throws -> KnowledgeObject {
        let raw: String
        do {
            raw = try String(contentsOf: url, encoding: .utf8)
        } catch {
            // EMLs sometimes ship as latin1; fall back.
            do {
                raw = try String(contentsOf: url, encoding: .isoLatin1)
            } catch {
                throw IngestorError.unreadable(url, underlying: error)
            }
        }
        let (headers, body) = splitEMLHeaders(raw)
        var meta: [String: AnyCodable] = [
            "filename": AnyCodable(.string(url.lastPathComponent)),
            "loader": AnyCodable(.string("eml"))
        ]
        for (key, value) in headers {
            meta[key] = AnyCodable(.string(value))
        }

        // T13.7 — If the message is multipart, hand only the decoded
        // text part to the chunker and stage attachments for recursive
        // ingest. Raw base64 / MIME bytes NEVER reach NER or chunking.
        let (textBody, attachmentURLs) = Self.applyMultipartIfNeeded(
            headers: headers,
            body: body,
            for: url
        )

        // T7 — Strip quoted regions before chunking. Stored bytes-removed
        // metric flows into the completeness report.
        let (cleanedBody, quotedBytesRemoved) = Self.stripQuotedRegions(textBody)
        meta["quotedBytesRemoved"] = AnyCodable(.int(Int64(quotedBytesRemoved)))
        if let json = Self.encodeAttachmentURLs(attachmentURLs) {
            meta[Self.attachmentURLsMetaKey] = AnyCodable(.string(json))
        }

        // Prepend the human-relevant headers (From / To / Cc / Subject / Date)
        // so the entity extractor + summarizer see the participants and topic.
        var headerLines: [String] = []
        for key in ["from", "to", "cc", "subject", "date"] {
            if let value = headers[key], !value.isEmpty {
                headerLines.append("\(key.capitalized): \(value)")
            }
        }
        let merged = headerLines.isEmpty
            ? cleanedBody
            : headerLines.joined(separator: "\n") + "\n\n" + cleanedBody
        let koID = UUID()
        let structured = Self.structuredEntities(from: headers, sourceObjectID: koID)
        if let json = Self.encodeStructuredEntities(structured) {
            meta[Self.structuredEntitiesMetaKey] = AnyCodable(.string(json))
        }
        return KnowledgeObject(
            id: koID,
            sourceFile: url,
            sourceType: .eml,
            content: merged,
            metadata: meta,
            confidence: .high
        )
    }

    /// T13.1 — split an mbox file by `From ` separators and return one
    /// fully-populated KnowledgeObject per message. Each per-message KO
    /// carries its own structured From/To/Cc/Date entities (T13.2) and
    /// goes through the standard chunker / NER / event-extraction
    /// pipeline from IngestCoordinator independently.
    private func ingestMBOXAsMessages(at url: URL) throws -> [KnowledgeObject] {
        // Byte-level scan for "\nFrom " message boundaries. Avoids the
        // String.components(separatedBy:) path that silently flattens
        // very large mbox files (~94MB observed: 525 boundaries seen by
        // /bin/grep, but `components` returned a 1-element array,
        // melting the whole archive into one giant KO). Reading as Data
        // keeps the file out of Swift String's bridging-heavy
        // representation while we look for the 6-byte separator
        // 0x0A 'F' 'r' 'o' 'm' ' '.
        let data: Data
        do { data = try Data(contentsOf: url, options: .mappedIfSafe) }
        catch { throw IngestorError.unreadable(url, underlying: error) }
        let separator: [UInt8] = [0x0A, 0x46, 0x72, 0x6F, 0x6D, 0x20]
        var boundaries: [Int] = [0]
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            let count = raw.count
            var i = 0
            // Treat the leading "From " (no preceding \n) as a synthetic boundary.
            if count >= 5 && base[0] == 0x46 && base[1] == 0x72 && base[2] == 0x6F && base[3] == 0x6D && base[4] == 0x20 {
                // boundaries already includes 0.
                i = 5
            }
            while i + separator.count <= count {
                if base[i] == 0x0A &&
                   base[i+1] == 0x46 && base[i+2] == 0x72 && base[i+3] == 0x6F &&
                   base[i+4] == 0x6D && base[i+5] == 0x20 {
                    // Message body for the NEXT piece starts at i+1 (skip the \n).
                    boundaries.append(i + 1)
                    i += separator.count
                } else {
                    i += 1
                }
            }
        }
        boundaries.append(data.count)
        var pieces: [String] = []
        for k in 0..<(boundaries.count - 1) {
            let slice = data[boundaries[k]..<boundaries[k + 1]]
            let messageString = String(data: slice, encoding: .utf8)
                ?? String(data: slice, encoding: .isoLatin1)
                ?? ""
            let trimmed = messageString.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { pieces.append(trimmed) }
        }
        // Move-A switch — when the flag is OFF (default), emit one KO
        // per message (the pre-Move-A path that the 435 MB production
        // DB was built with). When ON, fall through to the thread
        // coalescer below.
        if !Self.threadCoalescingEnabled {
            return emitPerMessageKOs(from: pieces, url: url)
        }
        // First pass — parse each mbox piece into a structured record
        // (cleaned body + headers + date). We don't emit a KO yet
        // because Move A coalesces these into threads first.
        struct ParsedRecord {
            let index: Int
            let headers: [String: String]
            let cleanedBody: String
            let quotedBytesRemoved: Int
            let attachmentURLs: [URL]
            let date: Date?
        }
        var parsed: [ParsedRecord] = []
        parsed.reserveCapacity(pieces.count)
        for (idx, message) in pieces.enumerated() {
            // Drop the "From <sender> <date>" envelope line — not a
            // real header, leaks into the parser. `.isNewline` (not
            // `$0 == "\n"`) catches CRLF-terminated mbox from Gmail
            // Takeout where Swift treats "\r\n" as ONE grapheme.
            let messageBody: String
            if let firstLineEnd = message.firstIndex(where: { $0.isNewline }) {
                messageBody = String(message[message.index(after: firstLineEnd)...])
            } else {
                messageBody = message
            }
            let (headers, body) = splitEMLHeaders(messageBody)
            // T13.7 — decode multipart, T7 — strip quoted regions.
            let (textBody, attachmentURLs) = Self.applyMultipartIfNeeded(
                headers: headers, body: body, for: url
            )
            let (cleanedBody, quoted) = Self.stripQuotedRegions(textBody)
            if cleanedBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && headers["subject"] == nil { continue }
            parsed.append(ParsedRecord(
                index: idx,
                headers: headers,
                cleanedBody: cleanedBody,
                quotedBytesRemoved: quoted,
                attachmentURLs: attachmentURLs,
                date: Self.parseRFC2822Date(headers["date"])
            ))
        }

        // Second pass — thread coalescing. ParsedRecord → ParsedMessage.
        let parsedMessages = parsed.map { rec in
            ThreadCoalescer.ParsedMessage(
                index: rec.index,
                headers: rec.headers,
                body: rec.cleanedBody,
                date: rec.date
            )
        }
        let threads = ThreadCoalescer.coalesce(parsedMessages)

        // Third pass — emit one KO per thread. Singletons take the same
        // shape so callers don't need to special-case them.
        var out: [KnowledgeObject] = []
        out.reserveCapacity(threads.count)
        let attachmentsByIndex: [Int: [URL]] = Dictionary(
            uniqueKeysWithValues: parsed.map { ($0.index, $0.attachmentURLs) }
        )
        let quotedByIndex: [Int: Int] = Dictionary(
            uniqueKeysWithValues: parsed.map { ($0.index, $0.quotedBytesRemoved) }
        )
        let isoDate = ISO8601DateFormatter()
        for thread in threads {
            let koID = UUID()

            // Build the concatenated thread content + structured
            // per-message offsets so the Evidence gate can still cite
            // an individual message.
            var content = ""
            var perMessage: [[String: AnyCodable]] = []
            var attachmentsAccum: [URL] = []
            var totalQuotedRemoved = 0
            for (n, m) in thread.messages.enumerated() {
                let from = m.headers["from"] ?? ""
                let dateText = m.date.map { isoDate.string(from: $0) }
                    ?? (m.headers["date"] ?? "")
                let banner = "--- MSG \(n + 1) sent \(dateText) by \(from) ---"
                if !content.isEmpty {
                    content += "\n\n"
                }
                let messageStart = content.utf8.count
                content += banner + "\n"
                // Header lines first so NER / chunker see participants.
                var headerLines: [String] = []
                for key in ["from", "to", "cc", "subject", "date"] {
                    if let value = m.headers[key], !value.isEmpty {
                        headerLines.append("\(key.capitalized): \(value)")
                    }
                }
                if !headerLines.isEmpty {
                    content += headerLines.joined(separator: "\n") + "\n\n"
                }
                content += m.body
                let messageEnd = content.utf8.count

                // Per-message structured record. Keys mirror the EML
                // path so the dossier / completeness panels read the
                // same shape.
                var msgRec: [String: AnyCodable] = [
                    "messageIndex": AnyCodable(.int(Int64(m.index))),
                    "byteStart": AnyCodable(.int(Int64(messageStart))),
                    "byteEnd": AnyCodable(.int(Int64(messageEnd))),
                ]
                for (k, v) in m.headers {
                    msgRec[k] = AnyCodable(.string(v))
                }
                perMessage.append(msgRec)

                if let attaches = attachmentsByIndex[m.index] {
                    attachmentsAccum.append(contentsOf: attaches)
                }
                totalQuotedRemoved += quotedByIndex[m.index] ?? 0
            }

            if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continue
            }

            // Pick representative headers for the KO's flat metadata
            // bag (first message wins) so existing consumers that
            // look up "from"/"subject"/"date" still get a value
            // without needing to walk the per-message array.
            let rep = thread.messages.first?.headers ?? [:]
            var meta: [String: AnyCodable] = [
                "filename": AnyCodable(.string(url.lastPathComponent)),
                "loader": AnyCodable(.string("mbox-thread")),
                "threadMessageCount": AnyCodable(.int(Int64(thread.messages.count))),
                "threadSubject": AnyCodable(.string(thread.canonicalSubject)),
                "quotedBytesRemoved": AnyCodable(.int(Int64(totalQuotedRemoved)))
            ]
            for (k, v) in rep {
                meta[k] = AnyCodable(.string(v))
            }
            if let thrid = rep["x-gm-thrid"] {
                meta["threadID"] = AnyCodable(.string(thrid))
            }
            // Smuggle the per-message array as JSON so the schema
            // stays untouched but downstream code can de-serialize.
            if let bag = Self.encodeMessagesBag(perMessage) {
                meta[Self.threadMessagesMetaKey] = AnyCodable(.string(bag))
            }
            if let json = Self.encodeAttachmentURLs(attachmentsAccum) {
                meta[Self.attachmentURLsMetaKey] = AnyCodable(.string(json))
            }
            // Structured From/To/Cc/Date entities computed over the
            // FIRST message so the entity extractor sees a single
            // sender/recipient set per thread KO. Per-message entity
            // mentions still emerge from the chunker's NER pass over
            // the concatenated content.
            let structuredEntities = Self.structuredEntities(from: rep, sourceObjectID: koID)
            if let json = Self.encodeStructuredEntities(structuredEntities) {
                meta[Self.structuredEntitiesMetaKey] = AnyCodable(.string(json))
            }
            out.append(KnowledgeObject(
                id: koID,
                sourceFile: url,
                sourceType: .mbox,
                content: content,
                metadata: meta,
                confidence: .high
            ))
        }
        return out
    }

    /// Metadata key carrying the JSON-encoded per-message array
    /// (`[[String: AnyCodable]]`) for a thread KO. The Dossier /
    /// SourceViewer / Evidence gate read this to extract per-message
    /// citation offsets.
    nonisolated static let threadMessagesMetaKey = "t_threadMessages"

    /// Pre-Move-A path. One KO per mbox message. Active when
    /// `threadCoalescingEnabled == false`. Preserved verbatim from
    /// commit dd93c9e so the production DB shape (526 per-message
    /// KOs from Sent.mbox) is reproducible on a fresh re-ingest.
    private func emitPerMessageKOs(from pieces: [String], url: URL) -> [KnowledgeObject] {
        var out: [KnowledgeObject] = []
        for (idx, message) in pieces.enumerated() {
            // Drop the "From <sender> <date>" envelope line — not a
            // real header, leaks into the parser. `.isNewline` (not
            // `$0 == "\n"`) catches CRLF-terminated mbox from Gmail
            // Takeout where Swift treats "\r\n" as ONE grapheme.
            let messageBody: String
            if let firstLineEnd = message.firstIndex(where: { $0.isNewline }) {
                messageBody = String(message[message.index(after: firstLineEnd)...])
            } else {
                messageBody = message
            }
            let (headers, body) = splitEMLHeaders(messageBody)

            var meta: [String: AnyCodable] = [
                "filename": AnyCodable(.string(url.lastPathComponent)),
                "loader": AnyCodable(.string("mbox-per-message")),
                "messageIndex": AnyCodable(.int(Int64(idx)))
            ]
            for (key, value) in headers { meta[key] = AnyCodable(.string(value)) }

            // T13.6 — Gmail Takeout: surface X-GM-THRID + X-Gmail-Labels
            // as first-class metadata.
            if let thrid = headers["x-gm-thrid"] {
                meta["threadID"] = AnyCodable(.string(thrid))
            }
            if let labels = headers["x-gmail-labels"] {
                meta["gmailLabels"] = AnyCodable(.string(labels))
            }

            // T13.7 — decode multipart so chunking sees text only.
            let (textBody, attachmentURLs) = Self.applyMultipartIfNeeded(
                headers: headers,
                body: body,
                for: url
            )

            // T7 — strip quoted regions from the per-message body before
            // anything else sees it.
            let (cleanedBody, quotedBytesRemoved) = Self.stripQuotedRegions(textBody)
            meta["quotedBytesRemoved"] = AnyCodable(.int(Int64(quotedBytesRemoved)))
            if let json = Self.encodeAttachmentURLs(attachmentURLs) {
                meta[Self.attachmentURLsMetaKey] = AnyCodable(.string(json))
            }

            var headerLines: [String] = []
            for key in ["from", "to", "cc", "subject", "date"] {
                if let value = headers[key], !value.isEmpty {
                    headerLines.append("\(key.capitalized): \(value)")
                }
            }
            let merged = headerLines.isEmpty
                ? cleanedBody
                : headerLines.joined(separator: "\n") + "\n\n" + cleanedBody
            if merged.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }

            let koID = UUID()
            let structuredEntities = Self.structuredEntities(from: headers, sourceObjectID: koID)
            if let json = Self.encodeStructuredEntities(structuredEntities) {
                meta[Self.structuredEntitiesMetaKey] = AnyCodable(.string(json))
            }
            out.append(KnowledgeObject(
                id: koID,
                sourceFile: url,
                sourceType: .mbox,
                content: merged,
                metadata: meta,
                confidence: .high
            ))
        }
        return out
    }

    private static func encodeMessagesBag(_ bag: [[String: AnyCodable]]) -> String? {
        let encoded = bag.map { AnyCodable(.array($0.mapValues { $0.value }.map { _ in
            AnyCodable.AnySendable.null  // not used; see below
        })) }
        _ = encoded
        // The simplest faithful encoding is to wrap the per-message
        // dicts in AnyCodable's array/object case and JSON-serialize.
        let asAnyCodable = AnyCodable(
            .array(bag.map { dict in
                AnyCodable.AnySendable.object(dict.mapValues { $0.value })
            })
        )
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(asAnyCodable) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Parse an RFC 2822 / 5322 Date header. Tries the strict format
    /// first then a small handful of timezone-name variants seen on
    /// real mbox archives. Returns nil on unparseable input — the
    /// coalescer treats nil dates as "merge if subject matches".
    nonisolated static func parseRFC2822Date(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let formats: [String] = [
            "EEE, d MMM yyyy HH:mm:ss Z",
            "d MMM yyyy HH:mm:ss Z",
            "EEE, d MMM yyyy HH:mm:ss zzz",
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        ]
        for fmt in formats {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = fmt
            if let d = f.date(from: raw) { return d }
        }
        return nil
    }

    /// Metadata key under which T13.2's structured From/To/Cc/Date
    /// entities are smuggled to IngestCoordinator as a JSON-encoded
    /// [Entity] string. KnowledgeObject.entities holds IDs only, so we
    /// piggyback on metadata instead of changing the schema.
    nonisolated static let structuredEntitiesMetaKey = "t13_structuredEntities"

    /// Metadata key under which T13.7's attachment file URLs are
    /// surfaced — a JSON-encoded [String] of file:// paths. After the
    /// parent email KO finishes ingestion, IngestCoordinator recursively
    /// calls `ingest(fileAt:)` on each URL so attachments become their
    /// own KnowledgeObjects (and T7's content-hash dedup folds recurring
    /// attachments onto a single canonical KO with alias file rows).
    nonisolated static let attachmentURLsMetaKey = "t13_attachmentURLs"

    /// Top-level helper called from each ingest path. If the message
    /// is multipart, replaces the body with the decoded text and returns
    /// the staged attachment URLs; otherwise passes the body through
    /// unchanged with no attachments.
    static func applyMultipartIfNeeded(
        headers: [String: String],
        body: String,
        for sourceURL: URL
    ) -> (textBody: String, attachmentURLs: [URL]) {
        guard let ct = headers["content-type"],
              ct.lowercased().hasPrefix("multipart/") else {
            return (body, [])
        }
        let baseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kalsmritikosh-email-attachments", isDirectory: true)
            .appendingPathComponent(sourceURL.lastPathComponent + "-" + UUID().uuidString.prefix(8), isDirectory: true)
        guard let decoded = decodeMultipart(body: body, contentType: ct, attachmentDir: baseDir) else {
            return (body, [])
        }
        return (decoded.text, decoded.attachmentURLs)
    }

    /// Decode a multipart body into (textBody, attachmentURLs) — the
    /// text replaces the email body that gets handed to extraction,
    /// and the attachment URLs go into KO metadata for recursive
    /// ingest. Returns `nil` when the part can't be parsed; the caller
    /// then falls back to the raw body so we never block ingestion on
    /// a parsing edge case.
    static func decodeMultipart(
        body: String,
        contentType: String,
        attachmentDir: URL
    ) -> (text: String, attachmentURLs: [URL])? {
        guard contentType.lowercased().hasPrefix("multipart/"),
              let boundary = MIMEPart.extractParam(contentType, key: "boundary") else {
            return nil
        }
        let parts = MIMEParser.parseMultipart(body: body, boundary: boundary)
        var textPieces: [String] = []
        var attachmentURLs: [URL] = []
        var didWriteAttachmentDir = false
        for part in parts {
            if part.isText {
                // Prefer text/plain; fall back to text/html with the
                // tags stripped (cheap). Multiple text parts get
                // concatenated so we never lose body content.
                let text = String(data: part.body, encoding: .utf8) ?? ""
                if part.contentType == "text/html" {
                    textPieces.append(stripHTML(text))
                } else {
                    textPieces.append(text)
                }
            } else {
                // Real attachment. Write to disk and record the URL.
                // 2026-06-30 fix — prepend a short content-hash to the
                // filename so two messages in the same mbox that
                // attach files with identical filenames but DIFFERENT
                // bytes don't overwrite each other's staged file.
                // Identical bytes across multiple emails still produce
                // the same on-disk filename (correct — T7's hash-first
                // dedup folds them into one canonical KO downstream).
                let raw = part.filename ?? "attachment-\(UUID().uuidString.prefix(8))"
                let safe = sanitizeFilename(raw)
                let hashTag = Self.shortContentHash(part.body)
                let uniqueName: String = {
                    if let dot = safe.lastIndex(of: ".") {
                        return safe[safe.startIndex..<dot] + "-" + hashTag + safe[dot...]
                    }
                    return safe + "-" + hashTag
                }()
                if !didWriteAttachmentDir {
                    try? FileManager.default.createDirectory(at: attachmentDir, withIntermediateDirectories: true)
                    didWriteAttachmentDir = true
                }
                let url = attachmentDir.appendingPathComponent(uniqueName)
                if (try? part.body.write(to: url, options: .atomic)) != nil {
                    attachmentURLs.append(url)
                }
            }
        }
        return (textPieces.joined(separator: "\n\n"), attachmentURLs)
    }

    private static func stripHTML(_ s: String) -> String {
        // Very naive — good enough to remove `<tag>` chrome without
        // pulling in a full HTML parser. Anything richer is Gate 3.
        guard let re = try? NSRegularExpression(pattern: "<[^>]+>") else { return s }
        let ns = s as NSString
        let stripped = re.stringByReplacingMatches(
            in: s, range: NSRange(location: 0, length: ns.length), withTemplate: " "
        )
        return stripped
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }

    private static func sanitizeFilename(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        return name.components(separatedBy: bad).joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 8-char SHA-256 prefix used to disambiguate two attachments
    /// with the same filename but different bytes (Bug fix
    /// 2026-06-30 — without this, two messages in one mbox attaching
    /// "receipt.pdf" with different contents would overwrite each
    /// other on disk before recursive ingest reads either).
    private static func shortContentHash(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        let hex = digest.compactMap { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(8))
    }

    static func encodeAttachmentURLs(_ urls: [URL]) -> String? {
        guard !urls.isEmpty else { return nil }
        let strings = urls.map(\.absoluteString)
        guard let data = try? JSONEncoder().encode(strings) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    nonisolated static func decodeAttachmentURLs(from json: String) -> [URL] {
        guard let data = json.data(using: .utf8),
              let strings = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return strings.compactMap { URL(string: $0) }
    }

    static func encodeStructuredEntities(_ entities: [Entity]) -> String? {
        guard !entities.isEmpty else { return nil }
        guard let data = try? JSONEncoder().encode(entities) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    nonisolated static func decodeStructuredEntities(from json: String) -> [Entity] {
        guard let data = json.data(using: .utf8),
              let arr = try? JSONDecoder().decode([Entity].self, from: data) else {
            return []
        }
        return arr
    }

    /// T13.2 — pull structured emailAddress / person / date entities out
    /// of the parsed RFC 5322 headers so downstream extractors don't
    /// have to re-discover them via NER.
    static func structuredEntities(
        from headers: [String: String],
        sourceObjectID: KnowledgeObject.ID
    ) -> [Entity] {
        var out: [Entity] = []
        let emailRegex = try? NSRegularExpression(
            pattern: "[A-Za-z0-9._%+\\-]+@[A-Za-z0-9.\\-]+\\.[A-Za-z]{2,}",
            options: []
        )
        let nameInAngleRegex = try? NSRegularExpression(
            pattern: "\"?([^<\"]+?)\"?\\s*<[^>]+>",
            options: []
        )

        func addEmailsAndNames(from header: String?) {
            guard let header, !header.isEmpty else { return }
            let ns = header as NSString
            let range = NSRange(location: 0, length: ns.length)
            if let emailRegex {
                for match in emailRegex.matches(in: header, range: range) {
                    let addr = ns.substring(with: match.range).lowercased()
                    out.append(Entity(
                        kind: .emailAddress,
                        value: addr,
                        normalizedValue: addr,
                        sourceObjectID: sourceObjectID,
                        confidence: .high
                    ))
                }
            }
            if let nameInAngleRegex {
                for match in nameInAngleRegex.matches(in: header, range: range) {
                    if match.numberOfRanges > 1 {
                        let nameRange = match.range(at: 1)
                        let raw = ns.substring(with: nameRange)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        // Skip empty / obviously non-name values; let
                        // EntityQualityGate decide on edge cases.
                        if raw.count >= 2, raw.contains(where: \.isLetter) {
                            out.append(Entity(
                                kind: .person,
                                value: raw,
                                sourceObjectID: sourceObjectID,
                                confidence: .high
                            ))
                        }
                    }
                }
            }
        }

        addEmailsAndNames(from: headers["from"])
        addEmailsAndNames(from: headers["to"])
        addEmailsAndNames(from: headers["cc"])

        // Date header → date entity (best-effort RFC 2822 / 5322 parsing).
        if let dateString = headers["date"], !dateString.isEmpty {
            if let date = parseRFC2822DateOrNil(dateString) {
                let iso = ISO8601DateFormatter().string(from: date)
                out.append(Entity(
                    kind: .date,
                    value: dateString,
                    normalizedValue: iso,
                    sourceObjectID: sourceObjectID,
                    confidence: .high
                ))
            }
        }
        return out
    }

    private static func parseRFC2822DateOrNil(_ s: String) -> Date? {
        let formats = [
            "EEE, d MMM yyyy HH:mm:ss Z",
            "d MMM yyyy HH:mm:ss Z",
            "EEE, d MMM yyyy HH:mm:ss zzz"
        ]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for f in formats {
            formatter.dateFormat = f
            if let date = formatter.date(from: s) { return date }
        }
        return nil
    }

    private func ingestMBOX(at url: URL) throws -> KnowledgeObject {
        let raw: String
        do { raw = try String(contentsOf: url, encoding: .utf8) }
        catch { throw IngestorError.unreadable(url, underlying: error) }

        var combined = ""
        var messageCount = 0
        for chunk in raw.components(separatedBy: "\nFrom ") {
            if chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            messageCount += 1
            let (_, body) = splitEMLHeaders(chunk)
            combined.append(body)
            combined.append("\n\n---\n\n")
        }
        if combined.isEmpty { throw IngestorError.empty(url) }
        return KnowledgeObject(
            sourceFile: url,
            sourceType: .mbox,
            content: combined,
            metadata: [
                "filename": AnyCodable(.string(url.lastPathComponent)),
                "messageCount": AnyCodable(.int(Int64(messageCount))),
                "loader": AnyCodable(.string("mbox"))
            ],
            confidence: .medium
        )
    }

    /// G4.9 — parse an Outlook `.msg` (OLE2 compound file w/ MAPI
    /// properties) and emit a KO shaped exactly like the EML path:
    /// human-relevant headers prepended to the plain-text body, the
    /// full header map in `metadata`, and structured From/To/Cc/Date
    /// entities pre-built. Ported from the sibling mailin/MSGParser.
    private func ingestMSG(at url: URL) throws -> KnowledgeObject {
        let raw: Data
        do { raw = try Data(contentsOf: url, options: .mappedIfSafe) }
        catch { throw IngestorError.unreadable(url, underlying: error) }
        // Sanity cap — the OLE2 reader is robust but mapping a 4 GB blob
        // and walking its FAT chains is not a workload we want at ingest
        // time. The historical .msg corpora cap out well under 100 MB.
        if raw.count > 500_000_000 {
            throw IngestorError.parseFailure(
                url,
                reason: "msg: file too large (\(raw.count / 1_000_000) MB; limit 500 MB)"
            )
        }
        let ole2: OLE2Reader
        do { ole2 = try OLE2Reader(data: raw) }
        catch { throw IngestorError.parseFailure(url, reason: "msg: \(error)") }

        let props = ole2.readMAPIProperties()

        // MAPI property → RFC822-ish header. Sender SMTP wins over the
        // legacy `senderEmailAddress` because the latter often carries
        // Exchange-internal LDAP DNs (e.g. /O=ORG/OU=.../CN=user) that
        // the entity layer can't ground to a real address.
        let senderAddr = props.stringProperty(.senderSmtpAddress)
            ?? props.stringProperty(.senderEmailAddress)
            ?? ""
        let senderName = props.stringProperty(.senderName) ?? ""
        let from: String
        if !senderAddr.isEmpty && !senderName.isEmpty {
            from = "\(senderName) <\(senderAddr)>"
        } else if !senderAddr.isEmpty {
            from = senderAddr
        } else {
            from = senderName
        }
        let to = props.stringProperty(.displayTo) ?? ""
        let cc = props.stringProperty(.displayCc) ?? ""
        let bcc = props.stringProperty(.displayBcc) ?? ""
        let subject = props.stringProperty(.subject) ?? ""

        // Date precedence: delivery time > client-submit > creation. All
        // are FILETIME → Date in the OLE2 reader.
        let date = props.dateProperty(.messageDeliveryTime)
            ?? props.dateProperty(.clientSubmitTime)
            ?? props.dateProperty(.creationTime)
        let dateString = date.map { ISO8601DateFormatter().string(from: $0) } ?? ""

        // Body precedence: plain → HTML stripped → decompressed RTF.
        // Some Outlook senders ship only the RTF stream.
        let plainBody = props.stringProperty(.body) ?? ""
        let htmlBody: String
        if let bytes = props.binaryProperty(.htmlBody) {
            htmlBody = String(data: bytes, encoding: .utf8) ?? ""
        } else {
            htmlBody = ""
        }
        let rtfBody: String
        if let rtfBytes = props.binaryProperty(.rtfCompressed) {
            rtfBody = decompressRTFLZFu(rtfBytes) ?? ""
        } else {
            rtfBody = ""
        }
        let body: String
        if !plainBody.isEmpty {
            body = plainBody
        } else if !htmlBody.isEmpty {
            // Reuse the existing tag stripper from the EML path.
            body = DocxLoader.stripTags(htmlBody)
        } else {
            body = rtfBody
        }

        // Build a lower-cased header dict that mirrors what
        // `splitEMLHeaders` produces, so structuredEntities() and
        // downstream metadata callers see the same shape as EML.
        var headers: [String: String] = [:]
        if !from.isEmpty { headers["from"] = from }
        if !to.isEmpty { headers["to"] = to }
        if !cc.isEmpty { headers["cc"] = cc }
        if !bcc.isEmpty { headers["bcc"] = bcc }
        if !subject.isEmpty { headers["subject"] = subject }
        if !dateString.isEmpty { headers["date"] = dateString }
        if let msgID = props.stringProperty(.internetMessageId) {
            headers["message-id"] = msgID
        }
        if let inReplyTo = props.stringProperty(.inReplyToId) {
            headers["in-reply-to"] = inReplyTo
        }
        if let references = props.stringProperty(.references) {
            headers["references"] = references
        }
        if let replyTo = props.stringProperty(.replyToAddress) {
            headers["reply-to"] = replyTo
        }
        if let topic = props.stringProperty(.conversationTopic) {
            headers["thread-topic"] = topic
        }

        var meta: [String: AnyCodable] = [
            "filename": AnyCodable(.string(url.lastPathComponent)),
            "loader": AnyCodable(.string("msg-ole2-mapi"))
        ]
        for (key, value) in headers {
            meta[key] = AnyCodable(.string(value))
        }

        let (cleanedBody, quotedBytesRemoved) = Self.stripQuotedRegions(body)
        meta["quotedBytesRemoved"] = AnyCodable(.int(Int64(quotedBytesRemoved)))

        // Prepend human-relevant headers to the body so NER + summarizer
        // see participants and topic, matching the EML path exactly.
        var headerLines: [String] = []
        for key in ["from", "to", "cc", "subject", "date"] {
            if let value = headers[key], !value.isEmpty {
                headerLines.append("\(key.capitalized): \(value)")
            }
        }
        let merged = headerLines.isEmpty
            ? cleanedBody
            : headerLines.joined(separator: "\n") + "\n\n" + cleanedBody
        if merged.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw IngestorError.empty(url)
        }
        let koID = UUID()
        let structured = Self.structuredEntities(from: headers, sourceObjectID: koID)
        if let json = Self.encodeStructuredEntities(structured) {
            meta[Self.structuredEntitiesMetaKey] = AnyCodable(.string(json))
        }
        return KnowledgeObject(
            id: koID,
            sourceFile: url,
            sourceType: .msg,
            content: merged,
            metadata: meta,
            confidence: .high
        )
    }

    /// G4.9 — read a PST/OST and emit one KO per message. The KO
    /// shape mirrors the EML path: human headers prepended to body,
    /// structured From/To/Cc/Date entities, full header dictionary
    /// stored in metadata. Errors on individual messages are skipped
    /// inside PSTReader; here we just adapt each surviving PSTMessage
    /// into a KnowledgeObject.
    private func ingestPSTAsMessages(at url: URL) throws -> [KnowledgeObject] {
        let messages = try loadPSTMessages(at: url)
        var out: [KnowledgeObject] = []
        out.reserveCapacity(messages.count)
        for msg in messages {
            guard let ko = buildKO(fromPSTMessage: msg, source: url) else { continue }
            out.append(ko)
        }
        return out
    }

    /// G4.9 — single-KO legacy path: every PST message concatenated
    /// in chronological-ish order (whatever ordering the NDB walk
    /// produces, which is approximately insertion order). Used only
    /// by callers that don't iterate via ingestMany.
    private func ingestPSTConcatenated(at url: URL) throws -> KnowledgeObject {
        let messages = try loadPSTMessages(at: url)
        guard !messages.isEmpty else { throw IngestorError.empty(url) }

        var blocks: [String] = []
        for msg in messages {
            blocks.append(pstMessageMarkdown(msg))
        }
        let content = blocks.joined(separator: "\n\n---\n\n")
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let size = (attrs[.size] as? Int64) ?? 0
        return KnowledgeObject(
            sourceFile: url,
            sourceType: .pst,
            content: content,
            metadata: [
                "filename": AnyCodable(.string(url.lastPathComponent)),
                "loader": AnyCodable(.string("pst-ole-ndb")),
                "messageCount": AnyCodable(.int(Int64(messages.count))),
                "binarySize": AnyCodable(.int(size))
            ],
            confidence: .medium
        )
    }

    private func loadPSTMessages(at url: URL) throws -> [PSTReader.PSTMessage] {
        let raw: Data
        do { raw = try Data(contentsOf: url, options: .mappedIfSafe) }
        catch { throw IngestorError.unreadable(url, underlying: error) }
        // Same sanity cap as MSG — PSTs in the wild routinely run into
        // multi-GB territory but mapping them at ingest time is
        // expensive. Bigger archives should be split externally.
        if raw.count > 2_000_000_000 {
            throw IngestorError.parseFailure(
                url,
                reason: "pst: file too large (\(raw.count / 1_000_000) MB; limit 2 GB)"
            )
        }
        let reader: PSTReader
        do { reader = try PSTReader(data: raw) }
        catch { throw IngestorError.parseFailure(url, reason: "pst: \(error)") }
        return try reader.readAllMessages()
    }

    /// Adapt one PSTMessage into a KnowledgeObject. Returns nil when
    /// the message has no displayable body and no headers worth
    /// keeping (which happens for placeholder NDB rows).
    private func buildKO(fromPSTMessage msg: PSTReader.PSTMessage, source url: URL) -> KnowledgeObject? {
        let from: String
        if !msg.senderEmail.isEmpty && !msg.senderName.isEmpty {
            from = "\(msg.senderName) <\(msg.senderEmail)>"
        } else if !msg.senderEmail.isEmpty {
            from = msg.senderEmail
        } else {
            from = msg.senderName
        }
        let date = msg.deliveryTime ?? msg.creationTime
        let dateString = date.map { ISO8601DateFormatter().string(from: $0) } ?? ""

        var headers: [String: String] = [:]
        if !from.isEmpty { headers["from"] = from }
        if !msg.displayTo.isEmpty { headers["to"] = msg.displayTo }
        if !msg.displayCc.isEmpty { headers["cc"] = msg.displayCc }
        if !msg.displayBcc.isEmpty { headers["bcc"] = msg.displayBcc }
        if !msg.subject.isEmpty { headers["subject"] = msg.subject }
        if !dateString.isEmpty { headers["date"] = dateString }
        if let mid = msg.internetMessageId { headers["message-id"] = mid }
        if let irt = msg.inReplyToId { headers["in-reply-to"] = irt }
        if let refs = msg.references { headers["references"] = refs }
        if let rt = msg.replyToAddress, !rt.isEmpty { headers["reply-to"] = rt }
        if let topic = msg.conversationTopic { headers["thread-topic"] = topic }
        if let ct = msg.contentType { headers["content-type"] = ct }

        // Body precedence: plain text → tag-stripped HTML.
        let body: String
        if !msg.bodyText.isEmpty {
            body = msg.bodyText
        } else if !msg.bodyHTML.isEmpty {
            body = DocxLoader.stripTags(msg.bodyHTML)
        } else {
            body = ""
        }

        // If there's no usable signal at all, drop it — these are
        // empty NDB rows that would only waste downstream cycles.
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && headers.count <= 1 {
            return nil
        }

        let (cleanedBody, quotedBytesRemoved) = Self.stripQuotedRegions(body)

        var headerLines: [String] = []
        for key in ["from", "to", "cc", "subject", "date"] {
            if let value = headers[key], !value.isEmpty {
                headerLines.append("\(key.capitalized): \(value)")
            }
        }
        let merged = headerLines.isEmpty
            ? cleanedBody
            : headerLines.joined(separator: "\n") + "\n\n" + cleanedBody

        var meta: [String: AnyCodable] = [
            "filename": AnyCodable(.string(url.lastPathComponent)),
            "loader": AnyCodable(.string("pst-message")),
            "quotedBytesRemoved": AnyCodable(.int(Int64(quotedBytesRemoved)))
        ]
        for (k, v) in headers {
            meta[k] = AnyCodable(.string(v))
        }

        let koID = UUID()
        let structured = Self.structuredEntities(from: headers, sourceObjectID: koID)
        if let json = Self.encodeStructuredEntities(structured) {
            meta[Self.structuredEntitiesMetaKey] = AnyCodable(.string(json))
        }
        return KnowledgeObject(
            id: koID,
            sourceFile: url,
            sourceType: .pst,
            content: merged,
            metadata: meta,
            confidence: .high
        )
    }

    /// Stringify a PSTMessage as a markdown block for the concatenated
    /// fallback path. Used only when a caller can't iterate the
    /// per-message KO stream.
    private func pstMessageMarkdown(_ msg: PSTReader.PSTMessage) -> String {
        var lines: [String] = []
        if !msg.senderName.isEmpty || !msg.senderEmail.isEmpty {
            let from = msg.senderEmail.isEmpty
                ? msg.senderName
                : (msg.senderName.isEmpty ? msg.senderEmail : "\(msg.senderName) <\(msg.senderEmail)>")
            lines.append("From: \(from)")
        }
        if !msg.displayTo.isEmpty { lines.append("To: \(msg.displayTo)") }
        if !msg.displayCc.isEmpty { lines.append("Cc: \(msg.displayCc)") }
        if !msg.subject.isEmpty { lines.append("Subject: \(msg.subject)") }
        if let d = msg.deliveryTime ?? msg.creationTime {
            lines.append("Date: \(ISO8601DateFormatter().string(from: d))")
        }
        let body: String
        if !msg.bodyText.isEmpty {
            body = msg.bodyText
        } else if !msg.bodyHTML.isEmpty {
            body = DocxLoader.stripTags(msg.bodyHTML)
        } else {
            body = ""
        }
        if !body.isEmpty {
            lines.append("")
            lines.append(body)
        }
        return lines.joined(separator: "\n")
    }

    /// G4.9 — Lotus Notes NSF database → one KO per mail-shaped note.
    private func ingestNSFAsMessages(at url: URL) throws -> [KnowledgeObject] {
        let notes = try loadNSFNotes(at: url)
        var out: [KnowledgeObject] = []
        out.reserveCapacity(notes.count)
        for note in notes where note.isMailNote {
            guard let ko = buildKO(fromNSFNote: note, source: url) else { continue }
            out.append(ko)
        }
        return out
    }

    /// G4.9 — concatenated NSF KO: every mail note as a markdown block.
    private func ingestNSFConcatenated(at url: URL) throws -> KnowledgeObject {
        let notes = try loadNSFNotes(at: url)
        let mailNotes = notes.filter(\.isMailNote)
        guard !mailNotes.isEmpty else { throw IngestorError.empty(url) }
        let content = mailNotes
            .map { nsfNoteMarkdown($0) }
            .joined(separator: "\n\n---\n\n")
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let size = (attrs[.size] as? Int64) ?? 0
        return KnowledgeObject(
            sourceFile: url,
            sourceType: .nsf,
            content: content,
            metadata: [
                "filename": AnyCodable(.string(url.lastPathComponent)),
                "loader": AnyCodable(.string("nsf-domino")),
                "messageCount": AnyCodable(.int(Int64(mailNotes.count))),
                "binarySize": AnyCodable(.int(size))
            ],
            confidence: .medium
        )
    }

    private func loadNSFNotes(at url: URL) throws -> [NSFReader.NSFNote] {
        let raw: Data
        do { raw = try Data(contentsOf: url, options: .mappedIfSafe) }
        catch { throw IngestorError.unreadable(url, underlying: error) }
        // NSF can run very large; cap at 4 GB like the original mailin
        // parser to keep mapping cost predictable.
        if raw.count > 4_000_000_000 {
            throw IngestorError.parseFailure(
                url,
                reason: "nsf: file too large (\(raw.count / 1_000_000) MB; limit 4 GB)"
            )
        }
        let reader = NSFReader(data: raw)
        do { return try reader.readNotes() }
        catch { throw IngestorError.parseFailure(url, reason: "nsf: \(error)") }
    }

    private func buildKO(fromNSFNote note: NSFReader.NSFNote, source url: URL) -> KnowledgeObject? {
        // NSF stores SMTP-shaped addresses under multiple field names
        // depending on the form variant.
        let from = note.items["From"]
            ?? note.items["$From"]
            ?? note.items["SMTPOriginator"]
            ?? ""
        let to = note.items["SendTo"] ?? note.items["EnterSendTo"] ?? ""
        let cc = note.items["CopyTo"] ?? note.items["EnterCopyTo"] ?? ""
        let bcc = note.items["BlindCopyTo"] ?? ""
        let subject = note.items["Subject"] ?? ""
        let dateRaw = note.items["DeliveredDate"] ?? note.items["PostedDate"] ?? ""
        let messageID = note.items["$MessageID"] ?? note.items["UNID"]

        // Body precedence: plain Body → $HtmlBody/Body_HTML (stripped).
        let plainBody = note.items["Body"] ?? ""
        let htmlBody = note.items["$HtmlBody"] ?? note.items["Body_HTML"] ?? ""
        let body: String
        if !plainBody.isEmpty {
            body = plainBody
        } else if !htmlBody.isEmpty {
            body = DocxLoader.stripTags(htmlBody)
        } else {
            body = ""
        }

        // Normalize the delivered-date string into ISO8601 when we can
        // recognize the format. Notes ships in several locale-specific
        // shapes — keep the raw string as a fallback when none parse.
        let dateString = Self.normalizeNotesDate(dateRaw)

        var headers: [String: String] = [:]
        if !from.isEmpty { headers["from"] = from }
        if !to.isEmpty { headers["to"] = to }
        if !cc.isEmpty { headers["cc"] = cc }
        if !bcc.isEmpty { headers["bcc"] = bcc }
        if !subject.isEmpty { headers["subject"] = subject }
        if !dateString.isEmpty { headers["date"] = dateString }
        if let mid = messageID, !mid.isEmpty { headers["message-id"] = mid }
        if let irt = note.items["$Ref"], !irt.isEmpty { headers["in-reply-to"] = irt }
        if let form = note.items["Form"], !form.isEmpty { headers["x-notes-form"] = form }
        headers["x-source-format"] = "NSF"

        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && headers.count <= 2 {
            return nil
        }

        let (cleanedBody, quotedBytesRemoved) = Self.stripQuotedRegions(body)
        var headerLines: [String] = []
        for key in ["from", "to", "cc", "subject", "date"] {
            if let value = headers[key], !value.isEmpty {
                headerLines.append("\(key.capitalized): \(value)")
            }
        }
        let merged = headerLines.isEmpty
            ? cleanedBody
            : headerLines.joined(separator: "\n") + "\n\n" + cleanedBody

        var meta: [String: AnyCodable] = [
            "filename": AnyCodable(.string(url.lastPathComponent)),
            "loader": AnyCodable(.string("nsf-note")),
            "quotedBytesRemoved": AnyCodable(.int(Int64(quotedBytesRemoved)))
        ]
        for (k, v) in headers { meta[k] = AnyCodable(.string(v)) }
        if !note.categories.isEmpty {
            meta["nsfCategories"] = AnyCodable(.string(note.categories.joined(separator: ",")))
        }

        let koID = UUID()
        let structured = Self.structuredEntities(from: headers, sourceObjectID: koID)
        if let json = Self.encodeStructuredEntities(structured) {
            meta[Self.structuredEntitiesMetaKey] = AnyCodable(.string(json))
        }
        return KnowledgeObject(
            id: koID,
            sourceFile: url,
            sourceType: .nsf,
            content: merged,
            metadata: meta,
            confidence: .high
        )
    }

    private func nsfNoteMarkdown(_ note: NSFReader.NSFNote) -> String {
        var lines: [String] = []
        let from = note.items["From"]
            ?? note.items["$From"]
            ?? note.items["SMTPOriginator"]
            ?? ""
        if !from.isEmpty { lines.append("From: \(from)") }
        if let to = note.items["SendTo"] ?? note.items["EnterSendTo"], !to.isEmpty {
            lines.append("To: \(to)")
        }
        if let cc = note.items["CopyTo"], !cc.isEmpty { lines.append("Cc: \(cc)") }
        if let subject = note.items["Subject"], !subject.isEmpty {
            lines.append("Subject: \(subject)")
        }
        if let d = note.items["DeliveredDate"] ?? note.items["PostedDate"], !d.isEmpty {
            lines.append("Date: \(d)")
        }
        let body = note.items["Body"]
            ?? (note.items["$HtmlBody"].map(DocxLoader.stripTags))
            ?? ""
        if !body.isEmpty {
            lines.append("")
            lines.append(body)
        }
        return lines.joined(separator: "\n")
    }

    /// Lotus Notes ships dates in a small handful of locale-specific
    /// shapes. Walk the candidates in order and return the first
    /// that parses; otherwise pass the raw string through so callers
    /// can still see something in the `date` header.
    private static func normalizeNotesDate(_ raw: String) -> String {
        if raw.isEmpty { return "" }
        let candidates = [
            "MM/dd/yyyy hh:mm:ss a",
            "yyyy-MM-dd'T'HH:mm:ss",
            "MM/dd/yyyy HH:mm:ss",
            "dd/MM/yyyy HH:mm:ss",
            "yyyy/MM/dd HH:mm:ss",
            "EEE, dd MMM yyyy HH:mm:ss Z"
        ]
        for format in candidates {
            let formatter = DateFormatter()
            formatter.dateFormat = format
            formatter.locale = Locale(identifier: "en_US_POSIX")
            if let date = formatter.date(from: raw) {
                return ISO8601DateFormatter().string(from: date)
            }
        }
        return raw
    }

    private func binaryStub(at url: URL, type: SourceType) throws -> KnowledgeObject {
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let size = (attrs[.size] as? Int64) ?? 0
        return KnowledgeObject(
            sourceFile: url,
            sourceType: type,
            content: "Binary email archive; native parsing lands in a later milestone.",
            metadata: [
                "filename": AnyCodable(.string(url.lastPathComponent)),
                "binarySize": AnyCodable(.int(size)),
                "loaderStub": AnyCodable(.string("email-binary"))
            ],
            confidence: .low
        )
    }

    /// Strip quoted regions from an email body and report the bytes
    /// removed for the completeness report.
    /// Removed:
    ///   - lines prefixed with `>`
    ///   - blocks following `On <when> <who> wrote:` headers
    ///   - HTML `gmail_quote` / `<blockquote>` containers
    ///   - `-----Original Message-----` / `_____` separator blocks
    static func stripQuotedRegions(_ body: String) -> (stripped: String, bytesRemoved: Int) {
        let originalBytes = body.utf8.count
        var working = body

        // 1. HTML quote containers — drop the entire region (greedy by tag).
        let htmlPatterns = [
            "<div[^>]*class=\"gmail_quote\"[\\s\\S]*?</div>",
            "<blockquote[\\s\\S]*?</blockquote>"
        ]
        for pattern in htmlPatterns {
            if let re = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive]
            ) {
                let ns = working as NSString
                working = re.stringByReplacingMatches(
                    in: working,
                    options: [],
                    range: NSRange(location: 0, length: ns.length),
                    withTemplate: ""
                )
            }
        }

        // 2. "-----Original Message-----" and similar separators —
        //    everything from the marker to EOF is the quoted history.
        let separators = [
            "-----Original Message-----",
            "________________________________",
            "----- Forwarded message -----"
        ]
        for marker in separators {
            if let range = working.range(of: marker) {
                working = String(working[..<range.lowerBound])
            }
        }

        // 3. "On <when>, <who> wrote:" — header before the quote block.
        //    Drop the header line and everything that follows.
        if let onWroteRe = try? NSRegularExpression(
            pattern: "^On .{5,200} wrote:$",
            options: [.anchorsMatchLines]
        ) {
            let ns = working as NSString
            let matches = onWroteRe.matches(in: working, range: NSRange(location: 0, length: ns.length))
            if let first = matches.first {
                let cutoff = first.range.location
                working = ns.substring(to: cutoff)
            }
        }

        // 4. Lines prefixed with `>` (and `> > `, etc.) — drop them outright.
        let lines = working.split(separator: "\n", omittingEmptySubsequences: false)
        let kept = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.hasPrefix(">")
        }
        working = kept.joined(separator: "\n")

        let stripped = working.trimmingCharacters(in: .whitespacesAndNewlines)
        let removed = max(0, originalBytes - stripped.utf8.count)
        return (stripped, removed)
    }

    /// RFC 2047 encoded-word decoder. Real-world Subject / From / To
    /// headers often arrive as
    ///   `Subject: =?UTF-8?B?5pel5pys6Kqe?=`
    /// or
    ///   `From: =?ISO-8859-1?Q?Andr=E9?= <andre@example.com>`
    /// without decoding, the strings poison NER and the UI.
    ///
    /// Format: `=?charset?encoding?encoded-text?=` where encoding is
    /// `B` (base64) or `Q` (quoted-printable, with `_` standing in
    /// for space). Multiple encoded words back-to-back are concatenated
    /// without intervening whitespace per the spec.
    static func decodeRFC2047(_ raw: String) -> String {
        let pattern = "=\\?([^?]+)\\?([BbQq])\\?([^?]*)\\?="
        guard let re = try? NSRegularExpression(pattern: pattern) else { return raw }
        let ns = raw as NSString
        let matches = re.matches(in: raw, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return raw }

        var out = ""
        var lastEnd = 0
        var lastWasEncoded = false
        for match in matches {
            let r = match.range
            let inBetween = ns.substring(with: NSRange(location: lastEnd, length: r.location - lastEnd))
            // Per RFC 2047 §6.2: whitespace between two encoded words is dropped.
            let trimmedBetween = lastWasEncoded
                ? inBetween.trimmingCharacters(in: .whitespacesAndNewlines)
                : inBetween
            out += trimmedBetween
            let charset = ns.substring(with: match.range(at: 1))
            let encoding = ns.substring(with: match.range(at: 2)).uppercased()
            let payload = ns.substring(with: match.range(at: 3))
            if let decoded = decodeEncodedWord(payload, encoding: encoding, charset: charset) {
                out += decoded
            } else {
                out += ns.substring(with: r)
            }
            lastEnd = r.location + r.length
            lastWasEncoded = true
        }
        if lastEnd < ns.length {
            out += ns.substring(with: NSRange(location: lastEnd, length: ns.length - lastEnd))
        }
        return out
    }

    private static func decodeEncodedWord(_ payload: String, encoding: String, charset: String) -> String? {
        let cf = stringEncoding(for: charset) ?? .utf8
        let data: Data?
        switch encoding {
        case "B":
            data = Data(base64Encoded: payload.filter { !$0.isWhitespace })
        case "Q":
            // Q-encoding: `_` → space, `=XX` → byte XX (hex).
            var bytes: [UInt8] = []
            let chars = Array(payload)
            var i = 0
            while i < chars.count {
                let c = chars[i]
                if c == "_" {
                    bytes.append(0x20)
                    i += 1
                    continue
                }
                if c == "=", i + 2 < chars.count {
                    let hex = String([chars[i + 1], chars[i + 2]])
                    if let byte = UInt8(hex, radix: 16) {
                        bytes.append(byte)
                        i += 3
                        continue
                    }
                }
                for u in String(c).utf8 { bytes.append(u) }
                i += 1
            }
            data = Data(bytes)
        default:
            data = nil
        }
        guard let data else { return nil }
        return String(data: data, encoding: cf)
    }

    private static func stringEncoding(for charset: String) -> String.Encoding? {
        switch charset.uppercased() {
        case "UTF-8", "UTF8": return .utf8
        case "US-ASCII", "ASCII": return .ascii
        case "ISO-8859-1", "LATIN1": return .isoLatin1
        case "ISO-8859-2", "LATIN2": return .isoLatin2
        case "WINDOWS-1252", "CP1252": return .windowsCP1252
        case "SHIFT_JIS", "SHIFT-JIS", "SJIS": return .shiftJIS
        case "EUC-JP": return .japaneseEUC
        case "ISO-2022-JP": return .iso2022JP
        case "GB2312", "GBK", "GB18030": return .init(rawValue: 0x80000632) // GB18030 superset
        case "BIG5": return .init(rawValue: 0x80000A03)
        case "KOI8-R": return .init(rawValue: 0x80000A02)
        default: return nil
        }
    }

    private func splitEMLHeaders(_ raw: String) -> ([String: String], String) {
        // Accept both LF (Unix) and CRLF (Windows / Gmail Takeout) blank-line
        // boundaries. The original \n\n-only path silently dropped every
        // header on CRLF-terminated mbox files (Gmail Takeout), turning
        // From/To/Subject/Date into wall-of-text body content the rest of
        // the pipeline could only NER-recover, not structure-recover.
        let crlfBoundary = raw.range(of: "\r\n\r\n")
        let lfBoundary = raw.range(of: "\n\n")
        let blankLine: Range<String.Index>?
        switch (crlfBoundary, lfBoundary) {
        case (let crlf?, let lf?):
            blankLine = crlf.lowerBound <= lf.lowerBound ? crlf : lf
        case (let crlf?, nil):
            blankLine = crlf
        case (nil, let lf?):
            blankLine = lf
        default:
            blankLine = nil
        }
        guard let boundary = blankLine else {
            return ([:], raw)
        }
        let headerBlock = String(raw[..<boundary.lowerBound])
        let body = String(raw[boundary.upperBound...])

        var headers: [String: String] = [:]
        var current: (String, String)?
        // Normalize CRLF→LF before splitting. `headerBlock.split(separator: "\n")`
        // operates on Character (grapheme cluster), and Swift treats "\r\n" as
        // a SINGLE cluster distinct from "\n", so the bare Character split
        // collapses the whole CRLF header block to one "line" — every header
        // value would inherit every subsequent header as a continuation.
        let normalized = headerBlock.replacingOccurrences(of: "\r\n", with: "\n")
        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.first == " " || line.first == "\t" {
                if let (k, v) = current {
                    current = (k, v + " " + line.trimmingCharacters(in: .whitespaces))
                }
            } else if let colon = line.firstIndex(of: ":") {
                if let (k, v) = current { headers[k] = v }
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                current = (key, value)
            }
        }
        if let (k, v) = current { headers[k] = v }
        // RFC 2047 — decode encoded-words in every header value so the
        // downstream pipeline (NER, KO metadata, UI) sees real text
        // instead of `=?UTF-8?B?...?=` strings.
        var decoded: [String: String] = [:]
        for (k, v) in headers {
            decoded[k] = Self.decodeRFC2047(v)
        }
        return (decoded, body)
    }
}
