//
//  ContentDecoder.swift
//  Kalsmritikosh
//
//  Deterministic decoder for encoded blobs embedded in otherwise-plain
//  content — base64 (incl. wrapped/PEM-style blocks), hex, quoted-printable,
//  and percent/URL encoding. Runs AFTER the loader + Cleaner, so email MIME
//  transfer-encodings (handled in MIMEParser) are already decoded; this catches
//  the encoded text that hides inside PDFs, text files, chat logs, and pasted
//  payloads — content that would otherwise be opaque to search and extraction.
//
//  Non-destructive by contract: the original content is NEVER overwritten.
//  Decoded text is APPENDED under a labelled section so both the raw blob and
//  its readable form are searchable, and the transformation is auditable via
//  metadata. No model, no network — pure rules.
//

import Foundation

public nonisolated struct ContentDecoder: Sendable {
    public nonisolated init() {}

    /// A single decoded blob: which encoding produced it and the readable text.
    public struct Decoded: Sendable, Hashable {
        public let encoding: String   // "base64" | "hex" | "quoted-printable" | "percent"
        public let text: String
    }

    /// Marker that opens the appended decoded section. Kept stable so the UI /
    /// citations can recognise decoder-produced text.
    public static let sectionMarker = "── Decoded content (kalsmritikosh) ──"

    /// Decode embedded blobs in the object's content and append them under a
    /// labelled section. Returns the object unchanged when nothing decodes.
    public nonisolated func decode(_ object: KnowledgeObject) -> KnowledgeObject {
        // Guard against pathological inputs — scanning a multi-MB blob line by
        // line is wasteful, and giant base64 is almost always binary (images),
        // which we deliberately do NOT dump into the ledger.
        guard object.content.count <= 2_000_000 else { return object }

        let decoded = decodedSections(from: object.content)
        guard !decoded.isEmpty else { return object }

        var section = "\n\n\(Self.sectionMarker)\n"
        section += decoded.map { "[\($0.encoding)] \($0.text)" }.joined(separator: "\n\n")

        var meta = object.metadata
        meta["decodedBlobCount"] = AnyCodable(.int(Int64(decoded.count)))
        let encodings = Array(Set(decoded.map(\.encoding))).sorted().joined(separator: ",")
        meta["decodedEncodings"] = AnyCodable(.string(encodings))

        return KnowledgeObject(
            id: object.id,
            sourceFile: object.sourceFile,
            sourceType: object.sourceType,
            content: object.content + section,
            metadata: meta,
            entities: object.entities,
            events: object.events,
            relationships: object.relationships,
            summaries: object.summaries,
            confidence: object.confidence,
            createdAt: object.createdAt,
            updatedAt: object.updatedAt
        )
    }

    /// All distinct decoded blobs found in `text`, in discovery order. Exposed
    /// (internal) for unit verification.
    func decodedSections(from text: String) -> [Decoded] {
        var out: [Decoded] = []
        var seen: Set<String> = []
        func add(_ d: Decoded?) {
            guard let d, !seen.contains(d.text) else { return }
            seen.insert(d.text)
            out.append(d)
        }
        for b in base64AndHexBlobs(in: text) { add(b) }
        if let qp = quotedPrintableDecoded(text) { add(Decoded(encoding: "quoted-printable", text: qp)) }
        if let pct = percentDecoded(text) { add(Decoded(encoding: "percent", text: pct)) }
        return out
    }

    // MARK: - base64 / hex blobs

    private static let base64Chars = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
    private static let hexChars = Set("0123456789abcdefABCDEF")

    private func base64AndHexBlobs(in text: String) -> [Decoded] {
        var out: [Decoded] = []
        let lines = text.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if isBase64Line(trimmed) {
                // Gather a wrapped block of base64-only lines (PEM / MIME style).
                var block = [trimmed]
                var j = i + 1
                while j < lines.count {
                    let l = lines[j].trimmingCharacters(in: .whitespaces)
                    if isBase64Line(l) { block.append(l); j += 1 } else { break }
                }
                let joined = block.joined()
                if let d = tryHex(joined) ?? tryBase64(joined) { out.append(d) }
                i = j
            } else {
                // Inline: examine long whitespace-delimited tokens on this line.
                for token in trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
                    let s = String(token)
                    guard s.count >= 24 else { continue }
                    if let d = tryHex(s) ?? tryBase64(s) { out.append(d) }
                }
                i += 1
            }
        }
        return out
    }

    /// A line that is nothing but base64 characters and long enough to be a real
    /// payload rather than a stray word.
    private func isBase64Line(_ s: String) -> Bool {
        guard s.count >= 24 else { return false }
        return s.allSatisfy { Self.base64Chars.contains($0) }
    }

    /// Decode a base64 candidate only when it round-trips to meaningful,
    /// printable UTF-8 text. Requires MIXED case — base64 of natural text nearly
    /// always mixes upper and lower, which also excludes pure-hex and
    /// single-case words that would otherwise decode to garbage.
    private func tryBase64(_ raw: String) -> Decoded? {
        let s = raw.filter { $0 != "\n" && $0 != "\r" && $0 != " " }
        guard s.count >= 24, s.allSatisfy({ Self.base64Chars.contains($0) }) else { return nil }
        guard s.contains(where: { $0.isUppercase && $0.isLetter }),
              s.contains(where: { $0.isLowercase && $0.isLetter }) else { return nil }
        // Pad to a multiple of 4 so unpadded blobs still decode.
        var padded = s
        let rem = padded.count % 4
        if rem == 2 { padded += "==" } else if rem == 3 { padded += "=" } else if rem == 1 { return nil }
        guard let data = Data(base64Encoded: padded, options: [.ignoreUnknownCharacters]),
              data.count >= 6,
              let text = readableText(data) else { return nil }
        return Decoded(encoding: "base64", text: text)
    }

    /// Decode an all-hex, even-length run to printable UTF-8 text.
    private func tryHex(_ raw: String) -> Decoded? {
        let s = raw.filter { $0 != "\n" && $0 != "\r" && $0 != " " }
        guard s.count >= 32, s.count % 2 == 0, s.allSatisfy({ Self.hexChars.contains($0) }) else { return nil }
        var bytes = [UInt8](); bytes.reserveCapacity(s.count / 2)
        var idx = s.startIndex
        while idx < s.endIndex {
            let next = s.index(idx, offsetBy: 2)
            guard let b = UInt8(s[idx..<next], radix: 16) else { return nil }
            bytes.append(b)
            idx = next
        }
        guard let text = readableText(Data(bytes)) else { return nil }
        return Decoded(encoding: "hex", text: text)
    }

    // MARK: - quoted-printable / percent (whole-text transforms)

    /// Decode quoted-printable when the text carries a clear QP signature
    /// (several `=XX` escapes and/or soft line breaks). Email bodies are already
    /// decoded upstream; this rescues QP pasted into non-email documents.
    private func quotedPrintableDecoded(_ text: String) -> String? {
        let escapeCount = countMatches(of: "=[0-9A-Fa-f]{2}", in: text)
        let softBreaks = text.contains("=\n")
        guard escapeCount >= 4 || (escapeCount >= 3 && softBreaks) else { return nil }

        var unfolded = text.replacingOccurrences(of: "=\r\n", with: "")
        unfolded = unfolded.replacingOccurrences(of: "=\n", with: "")
        var bytes = [UInt8]()
        let scalars = Array(unfolded.unicodeScalars)
        var k = 0
        while k < scalars.count {
            let sc = scalars[k]
            if sc == "=" , k + 2 < scalars.count,
               let hi = hexValue(scalars[k + 1]), let lo = hexValue(scalars[k + 2]) {
                bytes.append(UInt8(hi * 16 + lo)); k += 3
            } else if sc.isASCII {
                bytes.append(UInt8(sc.value & 0xFF)); k += 1
            } else {
                bytes.append(contentsOf: Array(String(sc).utf8)); k += 1
            }
        }
        guard let decoded = readableText(Data(bytes)), decoded != text else { return nil }
        return decoded
    }

    /// Decode percent/URL encoding when several `%XX` escapes are present.
    private func percentDecoded(_ text: String) -> String? {
        guard countMatches(of: "%[0-9A-Fa-f]{2}", in: text) >= 3 else { return nil }
        guard let decoded = text.removingPercentEncoding, decoded != text,
              isMostlyPrintable(decoded) else { return nil }
        return decoded
    }

    // MARK: - Helpers

    /// Return the UTF-8 text of `data` only when it is valid and mostly
    /// printable — the gate that stops binary (images, keys) being dumped in.
    private func readableText(_ data: Data) -> String? {
        guard data.count <= 200_000, let s = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 8, isMostlyPrintable(s) else { return nil }
        return trimmed
    }

    /// True when at least 85% of scalars are printable (letters, digits,
    /// punctuation, symbols, or ordinary whitespace) — control-char soup fails.
    private func isMostlyPrintable(_ s: String) -> Bool {
        var printable = 0, total = 0
        for sc in s.unicodeScalars {
            total += 1
            if sc == "\n" || sc == "\t" || sc == "\r" || sc == " " {
                printable += 1
            } else if sc.value >= 0x20 && sc.value != 0x7F {
                printable += 1
            }
        }
        guard total > 0 else { return false }
        return Double(printable) / Double(total) >= 0.85
    }

    private func hexValue(_ sc: Unicode.Scalar) -> Int? {
        switch sc {
        case "0"..."9": return Int(sc.value - 48)
        case "A"..."F": return Int(sc.value - 55)
        case "a"..."f": return Int(sc.value - 87)
        default: return nil
        }
    }

    private func countMatches(of pattern: String, in text: String) -> Int {
        guard let rx = try? NSRegularExpression(pattern: pattern) else { return 0 }
        return rx.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }
}
