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

public struct EmailLoader: Ingestor {
    public let supportedTypes: Set<SourceType> = [.eml, .mbox, .pst, .msg, .appleMail]

    public init() {}

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
        default:
            return try binaryStub(at: url, type: type)
        }
    }

    /// T13.1 — mbox produces one KO per message; other formats fall
    /// through to the single-KO path.
    public func ingestMany(fileAt url: URL, type: SourceType) async throws -> [KnowledgeObject] {
        if type == .mbox {
            return try ingestMBOXAsMessages(at: url)
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
        let raw: String
        do { raw = try String(contentsOf: url, encoding: .utf8) }
        catch {
            do { raw = try String(contentsOf: url, encoding: .isoLatin1) }
            catch { throw IngestorError.unreadable(url, underlying: error) }
        }
        var pieces: [String] = []
        for chunk in raw.components(separatedBy: "\nFrom ") {
            let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { pieces.append(trimmed) }
        }
        var out: [KnowledgeObject] = []
        for (idx, message) in pieces.enumerated() {
            // Re-prepend the "From " line removed by splitting (except
            // the first piece, which never carried the prefix).
            let messageBody = idx == 0 ? message : "From " + message
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

            // Each per-message KO is its own row; KnowledgeObjectRepository
            // generates a fresh id at construction.
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

    /// Metadata key under which T13.2's structured From/To/Cc/Date
    /// entities are smuggled to IngestCoordinator as a JSON-encoded
    /// [Entity] string. KnowledgeObject.entities holds IDs only, so we
    /// piggyback on metadata instead of changing the schema.
    static let structuredEntitiesMetaKey = "t13_structuredEntities"

    /// Metadata key under which T13.7's attachment file URLs are
    /// surfaced — a JSON-encoded [String] of file:// paths. After the
    /// parent email KO finishes ingestion, IngestCoordinator recursively
    /// calls `ingest(fileAt:)` on each URL so attachments become their
    /// own KnowledgeObjects (and T7's content-hash dedup folds recurring
    /// attachments onto a single canonical KO with alias file rows).
    static let attachmentURLsMetaKey = "t13_attachmentURLs"

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
                let fname = part.filename ?? "attachment-\(UUID().uuidString.prefix(8))"
                if !didWriteAttachmentDir {
                    try? FileManager.default.createDirectory(at: attachmentDir, withIntermediateDirectories: true)
                    didWriteAttachmentDir = true
                }
                let url = attachmentDir.appendingPathComponent(sanitizeFilename(fname))
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

    static func encodeAttachmentURLs(_ urls: [URL]) -> String? {
        guard !urls.isEmpty else { return nil }
        let strings = urls.map(\.absoluteString)
        guard let data = try? JSONEncoder().encode(strings) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decodeAttachmentURLs(from json: String) -> [URL] {
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

    static func decodeStructuredEntities(from json: String) -> [Entity] {
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
        guard let blankLine = raw.range(of: "\n\n") else {
            return ([:], raw)
        }
        let headerBlock = String(raw[..<blankLine.lowerBound])
        let body = String(raw[blankLine.upperBound...])

        var headers: [String: String] = [:]
        var current: (String, String)?
        for line in headerBlock.split(separator: "\n", omittingEmptySubsequences: false) {
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
