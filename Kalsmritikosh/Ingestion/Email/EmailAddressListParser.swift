//
//  EmailAddressListParser.swift
//  Kalsmritikosh
//
//  OPS-005 — deterministic state-machine RFC 2822 address-list parser.
//  Replaces scattered regex patterns in EmailLoader.structuredEntities().
//
//  Handles:
//    • bare addresses: user@example.com
//    • angle-bracket form: Name <user@example.com>
//    • quoted display names: "Last, First" <user@example.com>
//    • group syntax prefix: GroupName: addr1, addr2; (group name skipped)
//    • multiple entries separated by comma or semicolon
//
//  Inputs MUST be pre-decoded for RFC 2047 encoded-words.
//  EmailLoader.splitEMLHeaders already calls decodeRFC2047 on every
//  header value, so this parser receives plain Unicode strings.
//

import Foundation

public nonisolated enum EmailAddressListParser {

    public struct ParsedAddress: Sendable, Equatable {
        public let address: String
        public let displayName: String?
    }

    /// Parse an RFC 2822 address-list header value.
    /// Returns all individually recognised addresses in order.
    /// Empty or unparseable input returns an empty array.
    public static func parse(_ header: String) -> [ParsedAddress] {
        let s = header.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return [] }
        var results: [ParsedAddress] = []
        var pos = s.startIndex
        while pos < s.endIndex {
            skipIFS(s, pos: &pos)
            guard pos < s.endIndex else { break }
            if let addr = nextAddress(s, from: &pos) {
                results.append(addr)
            } else {
                // Unrecognised character — advance to prevent an infinite loop.
                pos = s.index(after: pos)
            }
        }
        return results
    }

    // MARK: - State machine

    private static func nextAddress(
        _ s: String,
        from pos: inout String.Index
    ) -> ParsedAddress? {
        guard pos < s.endIndex else { return nil }

        // Group syntax: detect "GroupName: ..." by looking for a colon
        // before any '<' or '@'. Skip the group name; the addresses
        // that follow it are parsed normally.
        if let colon = s[pos...].firstIndex(of: ":") {
            let segment = s[pos..<colon]
            let hasAngle = segment.contains("<")
            let hasAt    = segment.contains("@")
            if !hasAngle && !hasAt {
                pos = s.index(after: colon)
                skipIFS(s, pos: &pos)
                // Skip the closing semicolon of the group if present.
                if pos < s.endIndex && s[pos] == ";" { pos = s.index(after: pos) }
                return nextAddress(s, from: &pos)
            }
        }

        let c = s[pos]

        // "<addr>" — angle bracket with no preceding display name.
        if c == "<" { return parseAngle(s, from: &pos, name: nil) }

        // "\"Display Name\" <addr>" — quoted display name.
        if c == "\"" { return parseQuotedName(s, from: &pos) }

        // Peek: is there a '<' before the next separator?
        // If yes this is "Display Name <addr>".
        if let angleIdx = s[pos...].firstIndex(of: "<") {
            let sepIdx = firstSeparator(in: s, from: pos)
            if sepIdx == nil || angleIdx < sepIdx! {
                let rawName = String(s[pos..<angleIdx])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let name = rawName.isEmpty ? nil : rawName
                pos = angleIdx
                return parseAngle(s, from: &pos, name: name)
            }
        }

        // Bare address — read until a separator.
        return parseBare(s, from: &pos)
    }

    /// Parse `<addr>` — pos must point at `<` on entry.
    /// Advances pos past the `>` and any trailing separator.
    private static func parseAngle(
        _ s: String,
        from pos: inout String.Index,
        name: String?
    ) -> ParsedAddress? {
        guard pos < s.endIndex, s[pos] == "<" else { return nil }
        pos = s.index(after: pos)  // skip '<'
        guard let closeIdx = s[pos...].firstIndex(of: ">") else {
            // Unclosed bracket — skip to next separator.
            skipToAfterSeparator(s, pos: &pos)
            return nil
        }
        let addr = String(s[pos..<closeIdx])
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        pos = s.index(after: closeIdx)  // skip '>'
        skipToAfterSeparator(s, pos: &pos)
        guard isValidEmail(addr) else { return nil }
        return ParsedAddress(address: addr, displayName: name)
    }

    /// Parse `"Quoted Name" <addr>` — pos must point at `"` on entry.
    private static func parseQuotedName(
        _ s: String,
        from pos: inout String.Index
    ) -> ParsedAddress? {
        guard pos < s.endIndex, s[pos] == "\"" else { return nil }
        pos = s.index(after: pos)  // skip opening '"'
        var name = ""
        while pos < s.endIndex {
            let c = s[pos]
            if c == "\\" {
                let next = s.index(after: pos)
                if next < s.endIndex {
                    name.append(s[next])
                    pos = s.index(after: next)
                    continue
                }
            }
            if c == "\"" { pos = s.index(after: pos); break }
            name.append(c)
            pos = s.index(after: pos)
        }
        skipIFS(s, pos: &pos)
        guard pos < s.endIndex, s[pos] == "<" else { return nil }
        let displayName = name.trimmingCharacters(in: .whitespaces)
        return parseAngle(s, from: &pos, name: displayName.isEmpty ? nil : displayName)
    }

    /// Parse a bare address until the next separator.
    private static func parseBare(
        _ s: String,
        from pos: inout String.Index
    ) -> ParsedAddress? {
        var buf = ""
        while pos < s.endIndex {
            let c = s[pos]
            if c == "," || c == ";" || c == "\n" || c == "\r" { break }
            buf.append(c)
            pos = s.index(after: pos)
        }
        skipToAfterSeparator(s, pos: &pos)
        let addr = buf.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard isValidEmail(addr) else { return nil }
        return ParsedAddress(address: addr, displayName: nil)
    }

    // MARK: - Utilities

    /// Skip inter-field separators (whitespace, comma, semicolon).
    private static func skipIFS(_ s: String, pos: inout String.Index) {
        while pos < s.endIndex {
            let c = s[pos]
            if c == " " || c == "\t" || c == "\r" || c == "\n" || c == "," || c == ";" {
                pos = s.index(after: pos)
            } else { break }
        }
    }

    /// Advance past any trailing whitespace then consume a single
    /// separator (comma or semicolon) if present.
    private static func skipToAfterSeparator(_ s: String, pos: inout String.Index) {
        while pos < s.endIndex {
            let c = s[pos]
            if c == "," || c == ";" { pos = s.index(after: pos); return }
            if c != " " && c != "\t" { return }
            pos = s.index(after: pos)
        }
    }

    /// Index of the first comma or semicolon at or after `from`, or nil.
    private static func firstSeparator(in s: String, from start: String.Index) -> String.Index? {
        var i = start
        while i < s.endIndex {
            let c = s[i]
            if c == "," || c == ";" { return i }
            i = s.index(after: i)
        }
        return nil
    }

    /// Minimal validation: must contain '@' and be at least 3 chars.
    private static func isValidEmail(_ s: String) -> Bool {
        s.count >= 3 && s.contains("@")
    }
}
