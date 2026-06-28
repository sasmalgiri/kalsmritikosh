//
//  MIMEParser.swift
//  Kalsmritikosh
//
//  Minimal RFC 5322 / 2045 multipart parser used by EmailLoader to:
//  (a) hand only the decoded text/plain or text/html body to extraction
//      (NEVER raw base64 or MIME-part bytes — T13.7), and
//  (b) surface real attachments as their own files so IngestCoordinator
//      can route them through the existing loader registry, with T7's
//      content-hash dedup catching the same attachment recurring across
//      many messages.
//
//  Handles multipart/mixed, multipart/alternative, multipart/related, and
//  unrolls nested multipart/* recursively. Base64 + quoted-printable
//  decoding. Folded headers. Anything more exotic falls through with
//  best-effort text decoding.
//

import Foundation

public nonisolated struct MIMEPart: Sendable {
    public let headers: [String: String]
    public let body: Data

    public nonisolated init(headers: [String: String], body: Data) {
        self.headers = headers
        self.body = body
    }

    /// Lower-cased major/minor type stripped of parameters
    /// ("text/plain", "application/pdf"). Defaults to text/plain if the
    /// part carries no Content-Type, per RFC 2045 §5.2.
    public var contentType: String {
        let raw = headers["content-type"] ?? "text/plain"
        let major = raw.split(separator: ";").first.map(String.init) ?? "text/plain"
        return major.trimmingCharacters(in: .whitespaces).lowercased()
    }

    public var isText: Bool { contentType.hasPrefix("text/") }

    public var filename: String? {
        if let cd = headers["content-disposition"],
           let name = Self.extractParam(cd, key: "filename") {
            return Self.unfold(name)
        }
        if let ct = headers["content-type"],
           let name = Self.extractParam(ct, key: "name") {
            return Self.unfold(name)
        }
        return nil
    }

    /// Extracts a parameter from a header value (e.g. `boundary` from
    /// `Content-Type: multipart/mixed; boundary="abc"`). Handles quoted
    /// values and unquoted runs separated by semicolons.
    public nonisolated static func extractParam(_ header: String, key: String) -> String? {
        let lower = header.lowercased()
        let needle = "\(key)="
        guard let range = lower.range(of: needle) else { return nil }
        let offset = lower.distance(from: lower.startIndex, to: range.upperBound)
        let startIdx = header.index(header.startIndex, offsetBy: offset)
        let rest = header[startIdx...]
        if rest.first == "\"" {
            let inner = rest.dropFirst()
            if let endQuote = inner.firstIndex(of: "\"") {
                return String(inner[..<endQuote])
            }
        }
        if let endParam = rest.firstIndex(of: ";") {
            return String(rest[..<endParam]).trimmingCharacters(in: .whitespaces)
        }
        return String(rest).trimmingCharacters(in: .whitespaces)
    }

    private static func unfold(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n ", with: "")
            .replacingOccurrences(of: "\n ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum MIMEParser {
    /// Returns a flat list of LEAF parts; multipart/* containers are
    /// recursively unrolled.
    public nonisolated static func parseMultipart(body: String, boundary: String) -> [MIMEPart] {
        let openMarker = "--\(boundary)"
        var pieces: [String] = []
        var current = ""
        var sawFirstBoundary = false
        for line in body.components(separatedBy: "\n") {
            if line.hasPrefix(openMarker) {
                if sawFirstBoundary, !current.isEmpty {
                    pieces.append(current)
                }
                current = ""
                sawFirstBoundary = true
                // End boundary (`--<boundary>--`) — stop.
                if line.hasPrefix(openMarker + "--") { break }
                continue
            }
            if sawFirstBoundary {
                current += line + "\n"
            }
        }
        if sawFirstBoundary, !current.isEmpty {
            pieces.append(current)
        }
        var out: [MIMEPart] = []
        for piece in pieces {
            let part = parseSinglePart(piece)
            if part.contentType.hasPrefix("multipart/"),
               let innerBoundary = part.headers["content-type"].flatMap({ MIMEPart.extractParam($0, key: "boundary") }),
               let innerBody = String(data: part.body, encoding: .utf8) {
                out.append(contentsOf: parseMultipart(body: innerBody, boundary: innerBoundary))
            } else {
                out.append(part)
            }
        }
        return out
    }

    private nonisolated static func parseSinglePart(_ text: String) -> MIMEPart {
        // Real-data audit (2026-06-28): CRLF emails ("\r\n" line
        // terminators, the vast majority of mail) were silently
        // failing attachment extraction because the previous
        // `text.range(of: "\n\n")` never matched — `\r\n\r\n` has no
        // two consecutive `\n` chars. Every multipart leaf then
        // parsed with empty headers, defaulted to text/plain,
        // landed in textPieces instead of being staged as an
        // attachment. The user's mbox had 221 attachments (incl.
        // patent grant PDFs) — zero were ingested.
        // Fix: accept both "\r\n\r\n" (CRLF) and "\n\n" (LF),
        // preferring whichever comes first.
        let crlfBlank = text.range(of: "\r\n\r\n")
        let lfBlank   = text.range(of: "\n\n")
        let blank: Range<String.Index>?
        switch (crlfBlank, lfBlank) {
        case (let c?, let l?): blank = (c.lowerBound < l.lowerBound) ? c : l
        case (let c?, nil):    blank = c
        case (nil, let l?):    blank = l
        default:               blank = nil
        }
        guard let blank else {
            return MIMEPart(headers: [:], body: text.data(using: .utf8) ?? Data())
        }
        let headerBlock = String(text[..<blank.lowerBound])
        let bodyText = String(text[blank.upperBound...])
        let headers = parseHeaders(headerBlock)
        let encoding = (headers["content-transfer-encoding"] ?? "7bit").lowercased()
        let charset = headers["content-type"].flatMap { MIMEPart.extractParam($0, key: "charset") }
        let decoded = decodeBody(bodyText, encoding: encoding, charset: charset)
        return MIMEPart(headers: headers, body: decoded)
    }

    private nonisolated static func parseHeaders(_ block: String) -> [String: String] {
        var headers: [String: String] = [:]
        var current: (String, String)?
        for line in block.split(separator: "\n", omittingEmptySubsequences: false) {
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
        return headers
    }

    private nonisolated static func decodeBody(_ text: String, encoding: String, charset: String?) -> Data {
        switch encoding {
        case "base64":
            let cleaned = text.filter { !$0.isWhitespace }
            return Data(base64Encoded: cleaned) ?? Data()
        case "quoted-printable":
            return decodeQuotedPrintable(text)
        default:
            // 7bit / 8bit / binary / unknown — best-effort raw bytes.
            if let cs = charset?.lowercased(), cs.contains("latin") || cs.contains("8859") {
                return text.data(using: .isoLatin1) ?? text.data(using: .utf8) ?? Data()
            }
            return text.data(using: .utf8) ?? Data()
        }
    }

    private nonisolated static func decodeQuotedPrintable(_ text: String) -> Data {
        var bytes: [UInt8] = []
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "=", i + 1 < chars.count {
                let nc = chars[i + 1]
                if nc == "\n" {
                    i += 2
                    continue
                }
                if nc == "\r", i + 2 < chars.count, chars[i + 2] == "\n" {
                    i += 3
                    continue
                }
                if i + 2 < chars.count {
                    let hex = String([chars[i + 1], chars[i + 2]])
                    if let byte = UInt8(hex, radix: 16) {
                        bytes.append(byte)
                        i += 3
                        continue
                    }
                }
            }
            // Pass through ASCII / UTF-8.
            for u in String(c).utf8 { bytes.append(u) }
            i += 1
        }
        return Data(bytes)
    }
}
