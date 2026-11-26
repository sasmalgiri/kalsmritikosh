//
//  PlainTextSizeCap.swift
//  Kalsmritikosh
//
//  Unified path IN-27 (owner 2026-11-22, round 2) — not tested yet. C-6: the plain-text family
//  (txt/markdown/rtf, chat and discussion exports, csv, Apple Mail .emlx) read the whole file into
//  memory with NO size cap, while .msg/.pst/.nsf and archives refuse oversized files. These loaders
//  now take the same refusal path — `IngestorError.parseFailure(…, "file too large …")` — checked
//  from the file's size BEFORE any byte is read. (mbox is streamed by byte range and needs no cap.)
//

import Foundation

nonisolated enum PlainTextSizeCap {
    /// Text-like files larger than this are refused (whole-file decode would need several times this in memory).
    static let maxBytes: Int64 = 512 * 1024 * 1024
    /// RTF goes through NSAttributedString, which needs far more memory per byte.
    static let maxRTFBytes: Int64 = 128 * 1024 * 1024

    /// Throws the shared "too large" refusal when the file exceeds the cap for its kind.
    static func check(_ url: URL, kind: String, limit: Int64 = maxBytes) throws {
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
        guard size > limit else { return }
        throw IngestorError.parseFailure(
            url, reason: "\(kind): file too large (\(size / 1_000_000) MB; limit \(limit / 1_000_000) MB)")
    }
}
