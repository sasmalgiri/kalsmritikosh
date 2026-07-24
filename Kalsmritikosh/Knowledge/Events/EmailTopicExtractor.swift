//
//  EmailTopicExtractor.swift
//  Kalsmritikosh
//
//  PA-EXT-001B — conservative email TOPIC extraction. A meaningful Subject header always wins;
//  when the subject is absent, blank, or only a reply/forward marker, this picks the first
//  meaningful BODY sentence/line so the Event WHAT slot (and therefore the Event Claim statement)
//  is not left as the bare word "Email". Pure, deterministic, LLM-free. It never fabricates a
//  topic — if nothing safe qualifies it returns nil and the renderer keeps the neutral
//  "correspondence" fallback.
//
//  This is an extension of the EXISTING rule-based narrative-slot extraction, not a second
//  pipeline: RuleNarrativeSlotExtractor calls it during ingest with the cleaned KO content (the
//  loader has already stripped quoted reply regions before merge).
//

import Foundation

public struct EmailTopic: Equatable, Sendable {
    public enum Origin: Sendable { case structuredSubject; case bodySentence }
    public let text: String
    public let origin: Origin
    public nonisolated init(text: String, origin: Origin) { self.text = text; self.origin = origin }
}

public enum EmailTopicExtractor {
    static let minLength = 12
    static let maxLength = 180

    public nonisolated static func topic(subject: String?, cleanedContent: String) -> EmailTopic? {
        if let s = meaningfulSubject(subject) {
            return EmailTopic(text: capped(s), origin: .structuredSubject)
        }
        if let sentence = firstMeaningfulBodySentence(cleanedContent) {
            return EmailTopic(text: capped(sentence), origin: .bodySentence)
        }
        return nil
    }

    // MARK: - Subject

    /// A subject is meaningful unless it is blank or ONLY a reply/forward/placeholder marker.
    private nonisolated static func meaningfulSubject(_ subject: String?) -> String? {
        guard let raw = subject?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let stripped = stripReplyPrefixes(raw)
        let placeholders: Set<String> = ["", "(no subject)", "no subject", "email", "subject", "re", "fwd", "fw"]
        if placeholders.contains(stripped.lowercased()) { return nil }
        return normalizeWhitespace(stripped)
    }

    // MARK: - Body

    /// The first meaningful body sentence/line: after the prepended headers, within length bounds,
    /// and not a greeting / signature / disclaimer / footer / quoted-reply marker / MIME noise.
    private nonisolated static func firstMeaningfulBodySentence(_ content: String) -> String? {
        let lines = content.components(separatedBy: .newlines)
        var i = 0
        // Skip the prepended header block: leading "Key: value" lines (From/To/Subject/Date/Cc/…)
        // and blank lines, up to and including the first blank separator.
        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            if line.isEmpty { i += 1; break }
            if isHeaderLine(line) { i += 1; continue }
            break
        }
        while i < lines.count {
            let rawLine = lines[i].trimmingCharacters(in: .whitespacesAndNewlines)
            i += 1
            guard !rawLine.isEmpty else { continue }
            for candidate in sentences(in: rawLine) {
                let norm = normalizeWhitespace(candidate)
                guard norm.count >= minLength else { continue }
                if isRejectable(norm) { continue }
                return norm
            }
        }
        return nil
    }

    /// Split a line into candidate sentences on terminal punctuation, keeping the words unchanged.
    private nonisolated static func sentences(in line: String) -> [String] {
        var out: [String] = []
        var current = ""
        for ch in line {
            current.append(ch)
            if ch == "." || ch == "!" || ch == "?" {
                out.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { out.append(tail) }
        return out.isEmpty ? [line] : out
    }

    // MARK: - Filters (reject non-topic material)

    private nonisolated static func isHeaderLine(_ line: String) -> Bool {
        // "From: …", "To: …", "Subject: …", "X-Mailer: …" — a token of letters/dashes then a colon.
        guard let colon = line.firstIndex(of: ":") else { return false }
        let key = line[line.startIndex..<colon]
        return !key.isEmpty && key.allSatisfy { $0.isLetter || $0 == "-" }
    }

    private nonisolated static func isRejectable(_ s: String) -> Bool {
        let lower = s.lowercased()
        // Quoted-reply / forwarded markers.
        if s.hasPrefix(">") || lower.hasPrefix("on ") && lower.contains("wrote:") { return true }
        if lower.hasPrefix("-----original message-----") || lower.hasPrefix("________") { return true }
        if isHeaderLine(s) { return true }   // stray "Sent:"/"From:" inside a forwarded block
        // Greetings.
        let greetings = ["hi", "hello", "dear", "hey", "greetings", "good morning", "good afternoon", "good evening"]
        for g in greetings where lower == g || lower.hasPrefix(g + " ") || lower.hasPrefix(g + ",") {
            if s.count < 30 { return true }     // a short greeting line only
        }
        // Signatures.
        let sig = ["regards", "best regards", "kind regards", "thanks", "thank you", "sincerely",
                   "cheers", "best", "sent from my", "--", "warm regards"]
        for p in sig where lower == p || lower.hasPrefix(p + ",") || lower.hasPrefix(p + " ") {
            if s.count < 40 { return true }
        }
        // Confidentiality disclaimers.
        let disclaimer = ["confidential", "privileged", "intended recipient", "intended solely",
                          "disclaimer", "e-mail is intended", "email is intended"]
        if disclaimer.contains(where: lower.contains) { return true }
        // Unsubscribe / marketing footers.
        let footer = ["unsubscribe", "all rights reserved", "view this email", "manage preferences",
                      "©", "(c)", "privacy policy", "you are receiving this"]
        if footer.contains(where: lower.contains) { return true }
        // MIME / base64 noise.
        if lower.hasPrefix("content-type") || lower.hasPrefix("content-transfer-encoding")
            || lower.contains("boundary=") || lower.contains("=?utf-8?") || lower.contains("=?iso-") {
            return true
        }
        if looksLikeBase64(s) { return true }
        return false
    }

    /// A long run of base64-ish characters with almost no spaces — attachment / encoded noise.
    private nonisolated static func looksLikeBase64(_ s: String) -> Bool {
        guard s.count >= 24 else { return false }
        let spaceCount = s.filter { $0 == " " }.count
        guard spaceCount <= 1 else { return false }
        let b64 = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
        return s.unicodeScalars.allSatisfy { b64.contains($0) }
    }

    // MARK: - Text helpers

    private nonisolated static func stripReplyPrefixes(_ s: String) -> String {
        var result = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let markers = ["re:", "fwd:", "fw:", "re :", "fwd :", "fw :"]
        var changed = true
        while changed {
            changed = false
            for m in markers where result.lowercased().hasPrefix(m) {
                result = String(result.dropFirst(m.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                changed = true
            }
        }
        return result
    }

    private nonisolated static func normalizeWhitespace(_ s: String) -> String {
        s.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }).joined(separator: " ")
    }

    /// Deterministic cap at `maxLength`, trimming on a word boundary with a single ellipsis.
    private nonisolated static func capped(_ s: String) -> String {
        guard s.count > maxLength else { return s }
        let slice = s.prefix(maxLength)
        if let lastSpace = slice.lastIndex(of: " ") {
            return slice[slice.startIndex..<lastSpace].trimmingCharacters(in: .whitespaces) + "…"
        }
        return slice + "…"
    }
}
