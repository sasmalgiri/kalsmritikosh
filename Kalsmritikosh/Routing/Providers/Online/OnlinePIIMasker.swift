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

    public func mask(_ input: String) -> Masked {
        var text = input
        var mapping: [String: String] = [:]
        var reverse: [String: String] = [:]
        var counters: [String: Int] = [:]

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

        for name in names {
            let escaped = NSRegularExpression.escapedPattern(for: name)
            replace(pattern: "\\b\(escaped)\\b", kind: "NAME", options: .caseInsensitive)
        }
        replace(pattern: PIIRedactor.emailPattern, kind: "EMAIL")
        replace(pattern: PIIRedactor.phonePattern, kind: "PHONE")
        // Identifiers: 6+ digit runs not already part of a placeholder or an ISO date.
        replace(pattern: #"(?<![\d\-_])\d{6,}(?![\d\-])"#, kind: "ID")
        return Masked(text: text, mapping: mapping)
    }

    public static func unmask(_ text: String, mapping: [String: String]) -> String {
        var out = text
        for (p, v) in mapping.sorted(by: { $0.key.count > $1.key.count }) {
            out = out.replacingOccurrences(of: p, with: v)
        }
        return out
    }
}
