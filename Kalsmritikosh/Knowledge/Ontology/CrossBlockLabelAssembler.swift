//
//  CrossBlockLabelAssembler.swift
//  Kalsmritikosh
//
//  C-4 — rejoins a field LABEL to its VALUE when a page break separated them.
//
//  THE DEFECT THIS CLOSES. A grant letter that reads
//
//      … the following particulars are recorded. Patent No.
//      --- PAGE 2 ---
//      700321
//
//  produced NO patent-number fact at all. Every extractor here runs on one
//  block's text, so the label was read in a block with no value after it and
//  the value in a block with no label before it, and neither half is a fact.
//  This is not exotic: it is what any paginated PDF, scan, or printed letter
//  does when a field lands at the foot of a page.
//
//  HOW IT WORKS. Each block's text is cut into SEGMENTS at page furniture
//  ("--- PAGE 2 ---", "Page 3 of 9", a form feed), and adjacent segments are
//  examined in reading order. Where one segment ENDS in a dangling field label
//  and the next BEGINS with an identifier-shaped token, the two are offered to
//  the domain packs as one joined string. This covers both shapes of the defect
//  with one rule: the halves may sit in two different blocks (a paragraph-split
//  parse) or in one block either side of a page-break line (a plain-text
//  parse).
//
//  WHAT IT REFUSES, AND WHY THAT MATTERS MOST. Joining text across a boundary
//  can invent a fact, so the label must look like a LABEL and not like prose
//  that happens to end in the right word. The archive's own noise fixture ends
//  a sentence with "…in all correspondence about the patent number." — and if
//  the next block opened with any number, a naive rule would mint it as the
//  patent number. So a label qualifies only when it starts its own line or
//  follows a sentence terminator: a form field, never the tail of a clause.
//
//  Facts built this way are marked `.crossBlockAssembled` and cite EVERY block
//  they were assembled from, because neither half supports the claim alone.
//
//  Pure, deterministic, offline.
//

import Foundation

public struct CrossBlockLabelAssembler: Sendable {

    /// One block's identity and text, in document order.
    public struct Block: Sendable {
        public let id: UUID
        public let text: String
        public nonisolated init(id: UUID, text: String) {
            self.id = id
            self.text = text
        }
    }

    /// A label and value rejoined, with every block that contributed.
    public struct Assembly: Sendable {
        /// The joined text handed to the domain packs ("Patent No. 700321").
        public let text: String
        /// Blocks this was assembled from — one when the break was inside a
        /// single block, two when the halves were in different blocks.
        public let blockIDs: [UUID]
        /// The label half, verbatim, for the receipt.
        public let label: String
        /// The value half, verbatim, for the receipt.
        public let value: String
    }

    public nonisolated init() {}

    // MARK: - Tunables

    /// A dangling field label at the END of a segment. The `no.`/`number`/`#`
    /// token is REQUIRED, not optional: a segment ending in the bare word
    /// "patent" is prose ("…filed by X for a patent"), never a field name
    /// awaiting a value.
    nonisolated static let danglingLabelPattern =
        #"(?:patent|application|publication|invoice|case|account|reference|ref)\s*(?:no\.?|number|nos\.?|#)\s*[:\-—]?\s*$"#

    /// Characters that may precede a label for it to count as a FIELD label.
    /// A label starts its own line or follows the end of a sentence; anything
    /// else ("about the patent number.") is prose and is refused.
    nonisolated static let labelPreamble: Set<Character> = [".", ":", ";", "!", "?", "\n", "\r"]

    /// How many furniture-only segments may sit between the halves. One page
    /// break is the case; a long run of intervening content means the value
    /// does not belong to the label.
    nonisolated static let maximumInterveningSegments = 1

    /// Value-token bounds, matching the identifier atoms the packs store.
    nonisolated static let valueLengthRange = 5...24

    // MARK: - Entry point

    /// Every label/value pair worth rejoining, in document order.
    public nonisolated func assemblies(in blocks: [Block]) -> [Assembly] {
        let segments = Self.segments(in: blocks)
        guard segments.count >= 2 else { return [] }

        var out: [Assembly] = []
        for (index, segment) in segments.enumerated() {
            guard let label = Self.danglingLabel(endingIn: segment.text) else { continue }
            // Look ahead past at most one furniture gap. `segments` already
            // drops furniture lines, so a gap shows up as a segment that
            // carries no usable leading token; the bound stops the search from
            // wandering down the page.
            let lastCandidate = min(index + 1 + Self.maximumInterveningSegments, segments.count - 1)
            guard index + 1 <= lastCandidate else { continue }
            for next in (index + 1)...lastCandidate {
                guard let value = Self.leadingValueToken(of: segments[next].text) else { continue }
                var blockIDs = [segment.blockID]
                if segments[next].blockID != segment.blockID {
                    blockIDs.append(segments[next].blockID)
                }
                out.append(Assembly(text: "\(label) \(value)", blockIDs: blockIDs,
                                    label: label, value: value))
                break   // one value per dangling label — the nearest one
            }
        }
        return out
    }

    // MARK: - Segmentation

    nonisolated struct Segment {
        let blockID: UUID
        let text: String
    }

    /// Blocks cut into segments at page furniture, in reading order. A block
    /// that is nothing but furniture contributes no segments, which is what
    /// makes a separate "--- PAGE 2 ---" block transparent to the scan.
    nonisolated static func segments(in blocks: [Block]) -> [Segment] {
        var out: [Segment] = []
        for block in blocks {
            var current: [String] = []
            func flush() {
                let joined = current.joined(separator: "\n")
                current.removeAll()
                guard !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                out.append(Segment(blockID: block.id, text: joined))
            }
            for line in block.text.components(separatedBy: .newlines) {
                if isPageFurniture(line) { flush() } else { current.append(line) }
            }
            flush()
        }
        return out
    }

    /// A page marker rather than content: "--- PAGE 2 ---", "Page 3 of 9",
    /// "[Page 4]", "- 12 -", a form feed. Tested on the line's ALPHANUMERIC
    /// residue, so the surrounding dashes, brackets and pipes used to decorate
    /// these markers do not each need their own rule.
    nonisolated static func isPageFurniture(_ line: String) -> Bool {
        // The form feed is tested BEFORE trimming: it is itself whitespace, so
        // trimming would erase the only evidence that this line is a page break.
        if line.unicodeScalars.contains("\u{000C}") { return true }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }
        let residue = trimmed.lowercased().filter { $0.isLetter || $0.isNumber }
        if residue.isEmpty {
            // Punctuation-only rules ("———", "***") are page furniture only if
            // they are a real rule, not a stray hyphen.
            return trimmed.count >= 3
        }
        // "page2", "page3of9", "2of9" — and a bare number on its own decorated
        // line ("- 12 -"), which is a folio, not a value.
        let patterns = [#"^page\d*$"#, #"^page\d+of\d+$"#, #"^\d+of\d+$"#, #"^p\d+$"#]
        if patterns.contains(where: { residue.range(of: $0, options: .regularExpression) != nil }) {
            return true
        }
        if residue.allSatisfy(\.isNumber), residue.count <= 4,
           trimmed.contains(where: { !$0.isNumber && !$0.isWhitespace }) {
            return true
        }
        return false
    }

    // MARK: - The two halves

    /// The dangling label at the end of `text`, or nil.
    ///
    /// The positional gate lives here: a match is a field label only when it
    /// opens a line or follows a sentence terminator. Without it, the trailing
    /// clause "…correspondence about the patent number." would qualify and the
    /// next block's first number would be minted as a patent number.
    nonisolated static func danglingLabel(endingIn text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let regex = try? NSRegularExpression(pattern: danglingLabelPattern,
                                                   options: [.caseInsensitive]) else { return nil }
        let ns = trimmed as NSString
        guard let match = regex.firstMatch(in: trimmed,
                                           range: NSRange(location: 0, length: ns.length))
        else { return nil }

        // Walk back over whitespace from the match: what precedes it decides
        // whether this is a form field or the tail of a sentence.
        var cursor = match.range.location - 1
        while cursor >= 0, let scalar = ns.substring(with: NSRange(location: cursor, length: 1)).first,
              scalar.isWhitespace, !labelPreamble.contains(scalar) {
            cursor -= 1
        }
        if cursor >= 0 {
            guard let preceding = ns.substring(with: NSRange(location: cursor, length: 1)).first,
                  labelPreamble.contains(preceding) else { return nil }
        }
        return ns.substring(with: match.range).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The identifier-shaped token at the START of `text`, or nil.
    ///
    /// Anchored at the start on purpose: a value continuing from the previous
    /// page is the first thing on the next one. A token found further in
    /// belongs to its own line and has its own label.
    nonisolated static func leadingValueToken(of text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var token = ""
        for character in trimmed {
            if character.isLetter || character.isNumber || character == "," || character == "/" {
                token.append(character)
            } else {
                break
            }
        }
        let atom = token.replacingOccurrences(of: ",", with: "")
        guard valueLengthRange.contains(atom.count) else { return nil }
        // A value must carry digits — a leading WORD is the next sentence, not
        // the number that belongs to the label left hanging.
        guard atom.contains(where: \.isNumber) else { return nil }
        // A slash survives capture above only so a date is recognizable HERE
        // and refused: "22/03/2023" following a dangling label is a date line,
        // not an identifier.
        guard !PatentDomainPack.isDateShapedNumber(token) else { return nil }
        guard !atom.contains("/") else { return nil }
        return token
    }
}
