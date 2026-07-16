//
//  TextLoader.swift
//  Kalsmritikosh
//
//  Plain-text, Markdown, and RTF. RTF uses NSAttributedString to peel
//  formatting; the others read as UTF-8 with replacement fallback.
//

import Foundation
#if canImport(AppKit)
import AppKit
#endif

public struct TextLoader: Ingestor {
    public let supportedTypes: Set<SourceType> = [.txt, .markdown, .rtf]

    public nonisolated init() {}

    public func ingest(fileAt url: URL, type: SourceType) async throws -> KnowledgeObject {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw IngestorError.unreadable(url, underlying: error)
        }

        let content: String
        var encodingTag = "utf-8"
        switch type {
        case .rtf:
            #if canImport(AppKit)
            if let attr = try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
            ) {
                content = attr.string
                encodingTag = "rtf-attributed"
            } else {
                let (s, e) = Self.decodeWithDetectedEncoding(data)
                content = s
                encodingTag = e
            }
            #else
            let (s, e) = Self.decodeWithDetectedEncoding(data)
            content = s
            encodingTag = e
            #endif
        default:
            let (s, e) = Self.decodeWithDetectedEncoding(data)
            content = s
            encodingTag = e
        }

        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw IngestorError.empty(url)
        }

        // File-level binary guard. `.unknown`-type files (e.g. a `.3gp` video or
        // an opaque `attachment-*` blob from an mbox) get routed here and lossy-
        // decoded into mojibake dominated by the Unicode replacement character
        // (U+FFFD), which real text never contains at scale. Reject such content
        // so it is not ingested as garbage text chunks. Nothing is deleted — the
        // file record + ingest attempt are still tracked and the bytes on disk
        // are untouched; we simply decline to fabricate garbage from binary.
        // Verified on the real corpus: genuine text KOs sit at <1% replacement
        // chars, binary blobs at 10-30%, with an EMPTY gap between — a 5% cutoff
        // has zero false positives on real text.
        let scalarCount = content.unicodeScalars.count
        if scalarCount >= 200 {
            let replacements = content.unicodeScalars.reduce(0) { $0 + ($1 == "\u{FFFD}" ? 1 : 0) }
            if Double(replacements) / Double(scalarCount) > 0.05 {
                throw IngestorError.unreadable(url, underlying: NSError(
                    domain: "Kalsmritikosh.TextLoader", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "content is binary / undecodable (\(replacements) replacement chars in \(scalarCount)); not ingested as text"]
                ))
            }
        }

        return KnowledgeObject(
            sourceFile: url,
            sourceType: type,
            content: content,
            metadata: [
                "filename": AnyCodable(.string(url.lastPathComponent)),
                "encoding": AnyCodable(.string(encodingTag))
            ]
        )
    }

    /// chardet-equivalent decoding: detect the encoding from BOMs,
    /// then strict UTF-8, then fall back to Apple's built-in detector
    /// (`NSString.stringEncoding(for:...)`) which tries the common
    /// Western single-byte families. Finally, lossy UTF-8 with
    /// replacement characters so we never throw — silent mojibake is
    /// preferred to losing the whole file.
    nonisolated static func decodeWithDetectedEncoding(_ data: Data) -> (String, String) {
        // 1. BOM detection — fastest path; deterministic for files
        //    saved by Notepad / Visual Studio / iCloud.
        if data.count >= 3, data[0] == 0xEF, data[1] == 0xBB, data[2] == 0xBF {
            let body = data.dropFirst(3)
            if let s = String(data: body, encoding: .utf8) {
                return (s, "utf-8-bom")
            }
        }
        if data.count >= 2, data[0] == 0xFF, data[1] == 0xFE {
            if let s = String(data: data, encoding: .utf16LittleEndian) {
                return (s, "utf-16-le")
            }
        }
        if data.count >= 2, data[0] == 0xFE, data[1] == 0xFF {
            if let s = String(data: data, encoding: .utf16BigEndian) {
                return (s, "utf-16-be")
            }
        }
        // 2. Strict UTF-8 — succeeds for any ASCII-only file too.
        if let s = String(data: data, encoding: .utf8) {
            return (s, "utf-8")
        }
        // 3. Apple's encoding detector — tries Windows-1252,
        //    MacRoman, ISO-8859-1, and a handful of Asian families.
        #if canImport(AppKit) || canImport(UIKit)
        var converted: NSString? = nil
        let encoding = NSString.stringEncoding(
            for: data,
            encodingOptions: nil,
            convertedString: &converted,
            usedLossyConversion: nil
        )
        if encoding != 0, let s = converted as String? {
            let tag = String.localizedName(of: String.Encoding(rawValue: encoding))
            return (s, tag.lowercased())
        }
        #endif
        // 4. Last resort — Windows-1252 covers everything in the
        //    first 256 byte values that ISO-8859-1 + ASCII miss
        //    (smart quotes, em dashes, euros). Then UTF-8 with
        //    replacement so the file is never empty.
        if let s = String(data: data, encoding: .windowsCP1252) {
            return (s, "windows-1252")
        }
        return (String(decoding: data, as: UTF8.self), "utf-8-lossy")
    }
}
