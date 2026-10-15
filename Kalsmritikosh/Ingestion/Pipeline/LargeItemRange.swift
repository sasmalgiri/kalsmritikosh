//
//  LargeItemRange.swift
//  Kalsmritikosh
//
//  W2-8 — the leading byte range of an oversized record that fits the per-record
//  budget, cut at a paragraph (else line, else character) boundary so no UTF-8
//  sequence or word is split. The cut is reported with exact byte offsets by
//  the caller; nothing beyond it is claimed as read.
//

import Foundation

nonisolated enum LargeItemRange {
    /// The longest prefix of `text` within `maxBytes` UTF-8 bytes, ending at a clean boundary; nil if none fits.
    static func head(of text: String, maxBytes: Int) -> String? {
        guard maxBytes > 0 else { return nil }
        if text.utf8.count <= maxBytes { return text }
        // Largest character-aligned prefix within the budget.
        var end = text.startIndex
        var bytes = 0
        for i in text.indices {
            let next = text[i].utf8.count
            if bytes + next > maxBytes { break }
            bytes += next
            end = text.index(after: i)
        }
        guard end > text.startIndex else { return nil }
        let prefix = text[text.startIndex..<end]
        // Prefer a paragraph break, then a line break, in the last quarter of the prefix.
        let floor = prefix.index(prefix.startIndex, offsetBy: prefix.count * 3 / 4)
        for sep in ["\n\n", "\n"] {
            if let r = prefix.range(of: sep, options: .backwards), r.upperBound >= floor {
                return String(prefix[prefix.startIndex..<r.upperBound])
            }
        }
        return String(prefix)
    }
}
