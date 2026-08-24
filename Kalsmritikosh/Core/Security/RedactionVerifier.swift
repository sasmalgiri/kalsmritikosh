//
//  RedactionVerifier.swift
//  Kalsmritikosh
//
//  RED-002 — the verification gate for redacted exports (13_PRIVACY §5/§7). A black
//  rectangle over live text is NOT redaction: the protected value must be UNRECOVERABLE
//  from the exported artifact by text, OCR-text or package inspection. This verifier
//  re-reads the redacted output and fails if any protected value survives — not just as
//  an exact match, but through the common leak channels a naive redaction misses:
//
//    • exact substring;
//    • case difference ("John" vs "john");
//    • collapsed whitespace ("J o h n", "John\nSmith" → "johnsmith");
//    • tag/markup interruption ("Jo<b>hn</b> Smith");
//    • punctuation noise.
//
//  Deterministic, offline. The export pipeline runs this before writing a package and
//  refuses to emit any artifact that leaks. Pairs with PIIRedactor (RED-001), which
//  produces the redacted text; this proves the redaction actually held.
//

import Foundation

public nonisolated struct RedactionVerifier: Sendable {
    public nonisolated init() {}

    public enum LeakChannel: String, Sendable, Hashable {
        case exact               // the value appears verbatim
        case caseInsensitive     // appears ignoring case
        case whitespaceCollapsed // appears once spacing/newlines are removed
        case alphanumericOnly    // appears once tags/punctuation are stripped
    }

    public struct Leak: Sendable, Hashable {
        public let term: String
        public let artifact: String   // which output file/section leaked
        public let channel: LeakChannel
        public nonisolated init(term: String, artifact: String, channel: LeakChannel) {
            self.term = term; self.artifact = artifact; self.channel = channel
        }
    }

    /// Every way `protectedTerms` remain recoverable from `output`. Empty ⇒ clean.
    public nonisolated func leaks(in output: String, protectedTerms: [String],
                                  artifact: String = "export") -> [Leak] {
        var found: [Leak] = []
        let lowerExact = output
        let lowerCI = output.lowercased()
        let noSpace = Self.collapseWhitespace(lowerCI)
        // Strip whole markup tags (<...>) BEFORE reducing to alphanumerics — otherwise
        // tag names (b, i, em) stay interleaved and hide "Jo<b>hn</b>" from the check.
        let alnum = Self.alphanumericOnly(Self.stripTags(lowerCI))
        for raw in protectedTerms {
            let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard term.count >= 2 else { continue }   // 1-char "terms" aren't meaningful to protect
            let t = term.lowercased()
            let tNoSpace = Self.collapseWhitespace(t)
            let tAlnum = Self.alphanumericOnly(t)
            if lowerExact.contains(term) {
                found.append(Leak(term: term, artifact: artifact, channel: .exact))
            } else if lowerCI.contains(t) {
                found.append(Leak(term: term, artifact: artifact, channel: .caseInsensitive))
            } else if !tNoSpace.isEmpty, noSpace.contains(tNoSpace) {
                found.append(Leak(term: term, artifact: artifact, channel: .whitespaceCollapsed))
            } else if tAlnum.count >= 3, alnum.contains(tAlnum) {
                // Only trust the alphanumeric channel for terms with real substance (≥3
                // chars) so short tokens don't false-positive against unrelated text.
                found.append(Leak(term: term, artifact: artifact, channel: .alphanumericOnly))
            }
        }
        return found
    }

    public nonisolated func isClean(_ output: String, of protectedTerms: [String]) -> Bool {
        leaks(in: output, protectedTerms: protectedTerms).isEmpty
    }

    /// Verify a whole export package (filename → text/OCR-text content). Returns all leaks
    /// across every artifact so the exporter can refuse the package.
    public nonisolated func verifyPackage(_ artifacts: [String: String],
                                          protectedTerms: [String]) -> [Leak] {
        artifacts.sorted { $0.key < $1.key }
            .flatMap { leaks(in: $0.value, protectedTerms: protectedTerms, artifact: $0.key) }
    }

    // MARK: - Normalizers (pure)

    static func collapseWhitespace(_ s: String) -> String {
        String(s.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
    }

    static func alphanumericOnly(_ s: String) -> String {
        String(s.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// Remove whole `<...>` markup spans so tag names can't hide a value.
    static func stripTags(_ s: String) -> String {
        s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }
}
