//
//  QualityTierClassifier.swift
//  Kalsmritikosh
//
//  HISTORY Phase A — assigns every extracted fact a quality_tier
//  ('T1' / 'T2' / 'T3') so the brain can DEMOTE noise at query time
//  without ever deleting it. Direct response to the "preserve all
//  data; arrange, don't filter" directive.
//
//  Tiers:
//    T1 — structured header-derived (EmailLoader's structuredEntities
//         from From / To / Cc / Date fields; calendar ICS attendees;
//         vCard rows). Highest trust.
//    T2 — body-text extraction via NER / NLTagger. Historical default.
//    T3 — shape-flagged noise (hostname-shape, vowel-less consonant
//         runs, mid-cap clumps, base64-ish, numeric). Preserved on
//         disk; demoted at retrieval.
//
//  Pure value-typed; no actor, no I/O. Cheap enough to call per-row
//  during ingest. Re-runnable as a backfill if the rules evolve.
//

import Foundation

public enum QualityTier: String, Sendable, Equatable, CaseIterable {
    case t1 = "T1"
    case t2 = "T2"
    case t3 = "T3"

    /// Score multiplier applied at retrieval time. Adjustable via
    /// Settings (TODO Phase A.7 wiring); current defaults from the
    /// HISTORY plan.
    public var defaultWeight: Double {
        switch self {
        case .t1: return 1.0
        case .t2: return 0.6
        case .t3: return 0.15
        }
    }
}

public enum QualityTierClassifier {

    /// Classify an entity. `source` is the loader / extractor that
    /// produced it — passing `.structuredHeader` short-circuits to
    /// T1; everything else runs through the shape rules.
    public enum Source: Sendable {
        case structuredHeader   // EmailLoader From/To/Cc/Date, ICS, vCard
        case ner                // NLTagger over body text
        case llm                // Future LLM-guided extraction
        case other
    }

    public static func tier(
        value: String,
        kind: Entity.Kind,
        source: Source = .ner
    ) -> QualityTier {
        // T1 fast path — structured headers are trusted by construction.
        if source == .structuredHeader { return .t1 }

        // Normalize for shape checks.
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .t3 }

        // T3 shape rules — order matters; any match demotes to T3.
        if isPurelyNumeric(trimmed) { return .t3 }
        if looksLikeHostname(trimmed) { return .t3 }
        if looksBase64ish(trimmed) { return .t3 }
        if isMostlyConsonants(trimmed) { return .t3 }
        if isMidCapClump(trimmed) { return .t3 }
        if isSingleLowercaseGeneric(trimmed, kind: kind) { return .t3 }

        // No T3 flags fired — historical default.
        return .t2
    }

    // MARK: - Shape detectors

    private static func isPurelyNumeric(_ s: String) -> Bool {
        s.unicodeScalars.allSatisfy { CharacterSet.decimalDigits.contains($0) }
    }

    /// "tyzpr01mb4530", "seqmbx01", "d22rediffmail" — mail server
    /// names blended with digits. Heuristic: ≥ 1 digit AND no spaces
    /// AND length 4-32 AND no @ AND not a UUID.
    private static func looksLikeHostname(_ s: String) -> Bool {
        guard s.count >= 4, s.count <= 32 else { return false }
        guard !s.contains(" "), !s.contains("@") else { return false }
        let hasDigit = s.unicodeScalars.contains { CharacterSet.decimalDigits.contains($0) }
        guard hasDigit else { return false }
        // Skip UUIDs (which contain hyphens at specific positions).
        if UUID(uuidString: s) != nil { return false }
        return true
    }

    /// Long mostly-alphanumeric string with no separators — looks
    /// like an encoded blob (DKIM keys, message IDs sans angle
    /// brackets, attachment Content-IDs).
    private static func looksBase64ish(_ s: String) -> Bool {
        guard s.count >= 12 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "+/="))
        let ratio = s.unicodeScalars.filter { allowed.contains($0) }.count
        return ratio == s.unicodeScalars.count && !s.contains(" ")
    }

    /// "Tkkn", "Mrkt", "Gnrl" — vowel-less consonant runs. Likely
    /// abbreviations or noise tokens, not real proper nouns.
    private static func isMostlyConsonants(_ s: String) -> Bool {
        let letters = s.filter { $0.isLetter }
        guard letters.count >= 4 else { return false }
        let vowels: Set<Character> = ["a","e","i","o","u","A","E","I","O","U"]
        let vowelCount = letters.filter { vowels.contains($0) }.count
        let ratio = Double(vowelCount) / Double(letters.count)
        return ratio < 0.15
    }

    /// "abCDef", "xYz123" — mid-token capitals (likely an encoded
    /// blob, identifier, or NER noise). Apply per-token so legitimate
    /// multi-word proper nouns ("Shabana Khan", "Project Delta") pass
    /// — each space-separated token is checked independently. The
    /// flag fires if ANY single token has a lowercase letter followed
    /// by an uppercase letter inside it.
    private static func isMidCapClump(_ s: String) -> Bool {
        for token in s.split(separator: " ") {
            var sawLower = false
            for ch in token {
                if ch.isLowercase { sawLower = true }
                else if sawLower && ch.isUppercase { return true }
            }
        }
        return false
    }

    /// "tuesday", "monday", "smtp", "mail" — single lowercase tokens
    /// that the user's NER predicted as a name. Bounded list of
    /// known nuisance tokens — the editable Resources stoplist is
    /// covered by `EntityQualityGate.bundled()` already; this is
    /// the demote-not-delete tier counterpart.
    private static func isSingleLowercaseGeneric(_ s: String, kind: Entity.Kind) -> Bool {
        // Allow hyphens / underscores in the single-token check
        // ("mailer-daemon", "no_reply") — split on whitespace only.
        guard !s.contains(" ") else { return false }
        guard s.first?.isLowercase == true else { return false }
        let known: Set<String> = [
            "smtp", "mail", "mailer", "mailer-daemon", "mailbox",
            "reply", "noreply", "no-reply", "notifications", "alerts",
            "messageid", "message-id",
            "monday", "tuesday", "wednesday", "thursday", "friday",
            "saturday", "sunday",
            "january", "february", "march", "april", "may", "june",
            "july", "august", "september", "october", "november",
            "december",
            "urls", "category", "ref", "id", "uuid", "localhost"
        ]
        if known.contains(s) { return true }
        // Single lowercase token of fewer than 4 chars is suspicious
        // when the kind is person / organization.
        if (kind == .person || kind == .organization) && s.count < 4 {
            return true
        }
        return false
    }
}
