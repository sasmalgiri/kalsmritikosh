//
//  OnlinePIIMasker.swift
//  Kalsmritikosh
//
//  N-10 — before anything goes online, replace personal details with stable
//  placeholders ([NAME_1], [EMAIL_1], [PHONE_1], [ID_1]) and restore them in the
//  reply on this Mac. Names come from the ledger's own people and organisations
//  (so the masker knows the names that actually matter here); emails and phones
//  use the PIIRedactor patterns; long digit runs are treated as identifiers.
//  The preview shows the masked text — exactly what is sent.
//

import Foundation

public nonisolated struct OnlinePIIMasker: Sendable {
    public struct Masked: Sendable {
        public let text: String
        public let mapping: [String: String]   // placeholder → original
        public var count: Int { mapping.count }
    }

    let names: [String]

    public init(names: [String]) {
        // Longest first so "Jane Doe Smith" is masked before "Jane Doe".
        self.names = names.filter { $0.count >= 4 }.sorted { $0.count > $1.count }
    }

    /// `prior`: the mapping of text masked before this one in the same request (plan A: the case's
    /// documents are masked first, the question after them). The same detail keeps its placeholder and
    /// new ones are numbered after the prior ones — so the masked case text, the cached prefix, does
    /// not change with the question.
    public func mask(_ input: String, continuing prior: [String: String] = [:]) -> Masked {
        var text = input
        var mapping: [String: String] = prior
        var reverse: [String: String] = [:]
        var counters: [String: Int] = [:]
        for (p, v) in prior {
            reverse[v.lowercased()] = p
            let inner = p.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            if let cut = inner.lastIndex(of: "_"), let n = Int(inner[inner.index(after: cut)...]) {
                let kind = String(inner[..<cut])
                counters[kind] = max(counters[kind] ?? 0, n)
            }
        }

        func placeholder(_ kind: String, for value: String) -> String {
            if let existing = reverse[value.lowercased()] { return existing }
            counters[kind, default: 0] += 1
            let p = "[\(kind)_\(counters[kind]!)]"
            mapping[p] = value
            reverse[value.lowercased()] = p
            return p
        }
        func replace(pattern: String, kind: String, options: NSRegularExpression.Options = []) {
            guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return }
            let ns = text as NSString
            let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed()
            var out = text
            for m in matches {
                guard let r = Range(m.range, in: out) else { continue }
                let value = String(out[r])
                out.replaceSubrange(r, with: placeholder(kind, for: value))
            }
            text = out
        }

        // Deep dive batch 4 — names are found in a copy of the text folded for case and accents, with any run of spaces or
        // line breaks between a name's parts: a protected "José Núñez" written "Jose Nunez", or "Jane\nDoe", is masked too.
        // Longest name first; a shorter name never matches inside a longer one already found. The original spelling is
        // what the placeholder restores.
        if !names.isEmpty {
            let folded = FoldedText(text)
            var taken = IndexSet()
            var edits: [(range: NSRange, placeholder: String)] = []
            for name in names {
                guard let pattern = Self.namePattern(name), let re = try? NSRegularExpression(pattern: pattern) else { continue }
                let found = re.matches(in: folded.text, range: NSRange(location: 0, length: (folded.text as NSString).length))
                for m in found.reversed() {
                    guard let original = folded.originalRange(m.range) else { continue }
                    let span = original.location..<(original.location + original.length)
                    guard !taken.intersects(integersIn: span) else { continue }
                    let value = (text as NSString).substring(with: original)
                    taken.insert(integersIn: span)
                    edits.append((original, placeholder("NAME", for: value)))
                }
            }
            let out = NSMutableString(string: text)
            for e in edits.sorted(by: { $0.range.location > $1.range.location }) { out.replaceCharacters(in: e.range, with: e.placeholder) }
            text = out as String
        }
        replace(pattern: PIIRedactor.emailPattern, kind: "EMAIL")
        replace(pattern: PIIRedactor.phonePattern, kind: "PHONE")
        // Identifiers: 6+ digit runs not already part of a placeholder or an ISO date.
        replace(pattern: #"(?<![\d\-_])\d{6,}(?![\d\-])"#, kind: "ID")
        return Masked(text: text, mapping: mapping)
    }

    /// A name as a pattern over folded text: its parts folded, any whitespace run between them, whole words.
    static func namePattern(_ name: String) -> String? {
        let parts = FoldedText.fold(name).split(whereSeparator: { $0.isWhitespace }).map { NSRegularExpression.escapedPattern(for: String($0)) }
        guard !parts.isEmpty else { return nil }
        return "\\b" + parts.joined(separator: "\\s+") + "\\b"
    }

    /// Text folded for case and accents (each character on its own, so every folded unit knows the character it came from).
    nonisolated struct FoldedText {
        let text: String
        /// For each UTF-16 unit of `text`: the original character's UTF-16 start and end (empty when the text is ASCII:
        /// then folding is lowercasing and every unit maps to itself).
        private let starts: [Int32]
        private let ends: [Int32]
        private let identity: Bool

        static func fold(_ s: String) -> String { s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil) }

        init(_ original: String) {
            if original.utf8.allSatisfy({ $0 < 0x80 }) {
                self.text = original.lowercased(); self.starts = []; self.ends = []; self.identity = true
                return
            }
            var out = ""
            var starts: [Int32] = [], ends: [Int32] = []
            let count = original.utf16.count
            starts.reserveCapacity(count); ends.reserveCapacity(count)
            var at = 0
            for ch in original {
                let width = ch.utf16.count
                var units = 1
                if let a = ch.asciiValue {
                    // One unit appended ("\r\n" is one Character whose asciiValue is "\n").
                    out.append(Character(Unicode.Scalar(a >= 0x41 && a <= 0x5A ? a + 0x20 : a)))
                } else {
                    let piece = Self.fold(String(ch))
                    out += piece
                    units = piece.utf16.count
                }
                for _ in 0..<units { starts.append(Int32(at)); ends.append(Int32(at + width)) }
                at += width
            }
            self.text = out; self.starts = starts; self.ends = ends; self.identity = false
        }

        /// The original UTF-16 range a folded match covers.
        func originalRange(_ r: NSRange) -> NSRange? {
            guard r.location != NSNotFound, r.length > 0 else { return nil }
            if identity { return r }
            guard r.location + r.length <= starts.count else { return nil }
            let lo = Int(starts[r.location]), hi = Int(ends[r.location + r.length - 1])
            return hi > lo ? NSRange(location: lo, length: hi - lo) : nil
        }
    }

    public static func unmask(_ text: String, mapping: [String: String]) -> String {
        var out = text
        for (p, v) in mapping.sorted(by: { $0.key.count > $1.key.count }) {
            out = out.replacingOccurrences(of: p, with: v)
        }
        return out
    }
}
