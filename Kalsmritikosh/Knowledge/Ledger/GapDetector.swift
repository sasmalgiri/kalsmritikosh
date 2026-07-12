//
//  GapDetector.swift
//  Kalsmritikosh
//
//  System 3 — Gap / "missing link" detection, the rule-based engine.
//  This is the historiographical "argument from silence" done with
//  discipline: it flags an item as missing ONLY when a concrete,
//  observed pattern (a numbered run, an explicit reference, a reply
//  header) implies the item should exist. There is NO LLM here and NO
//  database access — it is a pure function over already-extracted text,
//  returning low-confidence, individually-reasoned GapNodes for a
//  repository or scanner to persist.
//
//  Design guards baked in:
//    * Every returned GapNode is low-confidence (absence is an
//      inference, never a fact) and carries a specific reason.
//    * Sparse "sequences" are rejected — if the holes outnumber the
//      present items, it isn't really a sequence, it's noise.
//    * Output is capped so one pathological input can't flood the UI.
//

import Foundation

/// Pure, stateless, rule-based detector of expected-but-missing items.
public nonisolated struct GapDetector: Sendable {

    public nonisolated init() {}

    // MARK: Compiled regex (compiled once, reused)

    /// Any run of digits.
    private static let digitsRegex: NSRegularExpression? =
        try? NSRegularExpression(pattern: #"\d+"#)

    /// Reply/forward subject prefixes.
    private static let replyPrefixRegex: NSRegularExpression? =
        try? NSRegularExpression(
            pattern: #"^\s*(re|fwd?)\s*:"#,
            options: [.caseInsensitive]
        )

    // MARK: Sequence holes

    /// Detect holes in a numbered sequence pulled from labels.
    ///
    /// Extracts integers embedded in each label, and if the present set
    /// spans a run (≥3 values) with missing members, emits one
    /// `.sequenceHole` per absent integer. Rejects runs where more than
    /// half the range is missing (too sparse to be a real sequence).
    public func detectSequenceGaps(labels: [String], kindHint: String) -> [GapNode] {
        guard let regex = Self.digitsRegex else { return [] }

        var present = Set<Int>()
        for label in labels {
            let range = NSRange(label.startIndex..<label.endIndex, in: label)
            regex.enumerateMatches(in: label, range: range) { match, _, _ in
                guard let match, let r = Range(match.range, in: label),
                      let n = Int(label[r]) else { return }
                present.insert(n)
            }
        }

        guard present.count >= 3, let lo = present.min(), let hi = present.max(),
              hi > lo else { return [] }

        let missing = (lo...hi).filter { !present.contains($0) }
        guard !missing.isEmpty else { return [] }

        // Too sparse to be a genuine sequence.
        let rangeSize = hi - lo + 1
        if missing.count * 2 > rangeSize { return [] }

        let sortedPresent = present.sorted()
        let previewList = sortedPresent.prefix(10)
            .map(String.init)
            .joined(separator: ", ")

        return missing.prefix(25).map { n in
            GapNode(
                kind: .sequenceHole,
                description: "\(kindHint) #\(n) appears missing",
                reason: "present: \(previewList) — \(n) is absent from the sequence",
                confidence: 0.35
            )
        }
    }

    // MARK: Dangling references

    /// Detect references to documents (e.g. "invoice #42") that are not
    /// in the set of known numbers. Deduped by referenced number.
    public func detectDanglingReferences(
        texts: [(objectID: UUID, text: String)],
        knownNumbers: Set<Int>,
        referenceKeyword: String = "invoice"
    ) -> [GapNode] {
        let escaped = NSRegularExpression.escapedPattern(for: referenceKeyword)
        guard let regex = try? NSRegularExpression(
            pattern: "\(escaped)\\s*#?\\s*(\\d+)",
            options: [.caseInsensitive]
        ) else { return [] }

        var seen = Set<Int>()
        var gaps: [GapNode] = []

        outer: for entry in texts {
            let text = entry.text
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in regex.matches(in: text, range: range) {
                guard match.numberOfRanges > 1,
                      let r = Range(match.range(at: 1), in: text),
                      let n = Int(text[r]) else { continue }
                if knownNumbers.contains(n) || seen.contains(n) { continue }
                seen.insert(n)
                gaps.append(GapNode(
                    kind: .danglingReference,
                    description: "Referenced \(referenceKeyword) #\(n) not found in the archive",
                    reason: "mentioned in an ingested document but no matching \(referenceKeyword) was ingested",
                    confidence: 0.3,
                    evidenceObjectID: entry.objectID
                ))
                if gaps.count >= 25 { break outer }
            }
        }
        return gaps
    }

    // MARK: Referenced attachments (A5.7)

    /// Affirmative "there is an attachment" phrases. Deliberately excludes bare
    /// "attachment" (too many false hits like "email attachment policy").
    private static let attachmentPhrases: [String] = [
        "see attached", "please find attached", "find attached", "attached please find",
        "i have attached", "i've attached", "we have attached", "we've attached",
        "attached is", "attached are", "attached you will find", "attached herewith",
        "as attached", "the attached", "enclosed please find", "please find enclosed",
        "please see the attached", "attaching"
    ]

    /// A5.7 — flag messages that reference an attachment in their body but were
    /// ingested with no attachment. Absence ≠ wrongdoing: the export may simply
    /// have omitted the file. Low confidence, individually reasoned. Skips
    /// messages whose text explicitly negates the attachment ("no attachment").
    ///
    /// - Parameter emails: per-message (objectID, body text, whether an
    ///   attachment was ingested with it).
    public func detectMissingAttachments(
        emails: [(objectID: UUID, body: String, hasAttachment: Bool)],
        limit: Int = 50
    ) -> [GapNode] {
        var gaps: [GapNode] = []
        for email in emails {
            guard !email.hasAttachment else { continue }
            let lower = email.body.lowercased()
            // Explicit negation guard — "no attachment", "not attached".
            if lower.contains("no attachment") || lower.contains("not attached")
                || lower.contains("without attachment") { continue }
            guard let phrase = Self.attachmentPhrases.first(where: { lower.contains($0) }) else { continue }
            gaps.append(GapNode(
                kind: .referencedAttachment,
                description: "A message references an attachment that isn't in the archive",
                reason: "the body says \"\(phrase)\" but no attachment was ingested with this message — it matters because the referenced file may hold the actual evidence (an invoice, contract, or signed page). Absence here is not proof of wrongdoing; the export may have omitted it.",
                confidence: 0.3,
                evidenceObjectID: email.objectID
            ))
            if gaps.count >= limit { break }
        }
        return gaps
    }

    // MARK: Cadence windows (A5.7)

    /// A5.7 — flag a skipped period in a regular series. Items sharing a series
    /// key (e.g. a recurring subject like "Weekly status") that arrive on a
    /// recognizable cadence (weekly / fortnightly / monthly) but have a gap
    /// roughly twice the usual interval imply a missing occurrence. Neutral:
    /// the item may have been sent outside the archive.
    ///
    /// - Parameter items: (seriesKey, date, objectID) for candidate series members.
    public func detectCadenceBreaks(
        items: [(seriesKey: String, date: Date, objectID: UUID)],
        limit: Int = 50
    ) -> [GapNode] {
        var groups: [String: [(date: Date, objectID: UUID)]] = [:]
        for i in items {
            let key = i.seriesKey.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard key.count >= 4 else { continue }
            groups[key, default: []].append((i.date, i.objectID))
        }

        let day = 86_400.0
        var gaps: [GapNode] = []
        for (key, members) in groups {
            guard members.count >= 3 else { continue }
            let sorted = members.sorted { $0.date < $1.date }
            let deltas = zip(sorted.dropFirst(), sorted).map { $0.0.date.timeIntervalSince($0.1.date) }
            guard let median = Self.median(deltas), median >= 5 * day, median <= 40 * day else { continue }
            // A recognizable cadence band (weekly 5-9d, fortnightly 12-16d,
            // monthly 26-33d); other medians are treated as irregular.
            let d = median / day
            let cadence: String? = (5...9).contains(d) ? "weekly"
                : (12...16).contains(d) ? "fortnightly"
                : (26...33).contains(d) ? "monthly" : nil
            guard let cadence else { continue }

            for pair in zip(sorted, sorted.dropFirst()) {
                let gap = pair.1.date.timeIntervalSince(pair.0.date)
                guard gap > median * 1.8 else { continue }
                gaps.append(GapNode(
                    kind: .cadenceBreak,
                    description: "A \(cadence) \"\(key)\" appears to be missing",
                    reason: "\"\(key)\" arrived on a \(cadence) cadence, but there is a \(Int((gap/day).rounded()))-day gap where one occurrence would be expected — it matters because a break in an established routine can be significant. The item may have been sent outside this archive.",
                    confidence: 0.35,
                    evidenceObjectID: pair.0.objectID
                ))
                if gaps.count >= limit { return gaps }
            }
        }
        return gaps
    }

    /// Normalize a title/subject into a stable recurring-series key: lowercase,
    /// drop digits (dates/counters vary per occurrence), strip punctuation,
    /// collapse whitespace. So "Weekly Report #12" and "Weekly Report #13"
    /// share the key "weekly report".
    static func normalizeSeriesKey(_ title: String) -> String {
        let lowered = title.lowercased()
        let kept = lowered.map { ch -> Character in
            (ch.isLetter || ch.isWhitespace) ? ch : " "
        }
        return String(kept).split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        let mid = s.count / 2
        return s.count % 2 == 0 ? (s[mid - 1] + s[mid]) / 2 : s[mid]
    }

    // MARK: Final version (A5.7)

    private static let finalMarkers = ["final", "signed", "executed", "approved", "v-final", "vfinal"]
    private static let stopWords: Set<String> = [
        "draft", "final", "signed", "executed", "approved", "copy", "version", "the", "and", "for", "with", "rev"
    ]

    /// Significant tokens in a filename (lowercased words ≥4 chars, minus the
    /// draft/final markers themselves), used to pair a draft with its final.
    static func significantTokens(_ filename: String) -> Set<String> {
        let base = (filename as NSString).deletingPathExtension.lowercased()
        let words = base.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        return Set(words.filter { $0.count >= 4 && !stopWords.contains($0) })
    }

    /// A5.7 — flag documents that are marked a "draft" when no "final" (or
    /// signed/executed) counterpart sharing a significant name token is in the
    /// archive. The final may live elsewhere; absence is not proof none exists.
    ///
    /// - Parameter documents: (objectID, filename) for each ingested document.
    public func detectMissingFinalVersion(
        documents: [(objectID: UUID, filename: String)],
        limit: Int = 50
    ) -> [GapNode] {
        // Collect the token sets of every "final"-ish document.
        let finals: [Set<String>] = documents
            .filter { doc in Self.finalMarkers.contains { doc.filename.lowercased().contains($0) } }
            .map { Self.significantTokens($0.filename) }

        var gaps: [GapNode] = []
        var seenDraftKeys = Set<String>()
        for doc in documents {
            let lower = doc.filename.lowercased()
            guard lower.contains("draft") else { continue }
            let tokens = Self.significantTokens(doc.filename)
            guard !tokens.isEmpty else { continue }
            // A final counterpart exists if some final doc shares a token.
            let hasFinal = finals.contains { !$0.isDisjoint(with: tokens) }
            if hasFinal { continue }
            // Dedupe drafts that share the same token signature.
            let key = tokens.sorted().joined(separator: "|")
            guard seenDraftKeys.insert(key).inserted else { continue }
            gaps.append(GapNode(
                kind: .finalVersion,
                description: "Only a draft of \"\(doc.filename)\" is present",
                reason: "this document is marked a draft and no final/signed version sharing its name is in the archive — it matters because the operative version is usually the final one. The final may live elsewhere; absence is not proof none exists.",
                confidence: 0.3,
                evidenceObjectID: doc.objectID
            ))
            if gaps.count >= limit { break }
        }
        return gaps
    }

    // MARK: Expected responses (A5.7)

    /// Explicit request-for-reply phrases. Kept specific to avoid flagging every
    /// message that merely contains a question mark.
    private static let responseRequestPhrases: [String] = [
        "please confirm", "please advise", "please respond", "please reply",
        "let me know", "await your", "awaiting your", "look forward to your reply",
        "look forward to hearing", "can you confirm", "could you confirm",
        "kindly confirm", "kindly revert", "please review and", "your confirmation",
        "waiting for your", "get back to me", "need your approval", "need your sign-off"
    ]

    /// A5.7 — flag messages that explicitly request a reply/confirmation but
    /// have no reply to them in the archive. The reply may exist elsewhere;
    /// absence is not proof it was ignored. Low confidence, reasoned.
    ///
    /// - Parameter messages: per-message (objectID, subject, body, hasReply)
    ///   where `hasReply` is true iff some other message replies to this one.
    public func detectExpectedResponses(
        messages: [(objectID: UUID, subject: String, body: String, hasReply: Bool)],
        limit: Int = 50
    ) -> [GapNode] {
        var gaps: [GapNode] = []
        for m in messages {
            guard !m.hasReply else { continue }
            let lower = m.body.lowercased()
            guard let phrase = Self.responseRequestPhrases.first(where: { lower.contains($0) }) else { continue }
            let subject = m.subject.trimmingCharacters(in: .whitespacesAndNewlines)
            gaps.append(GapNode(
                kind: .expectedResponse,
                description: subject.isEmpty ? "A message requested a reply that isn't in the archive"
                                             : "No reply found to \"\(subject)\"",
                reason: "the message asks for a response (\"\(phrase)\") but no reply to it is in the archive — it matters because whether (and how) the recipient responded can be the crux of a matter. The reply may live outside this archive; absence is not proof it was ignored.",
                confidence: 0.3,
                evidenceObjectID: m.objectID
            ))
            if gaps.count >= limit { break }
        }
        return gaps
    }

    // MARK: Payment proof (A5.7)

    /// A5.7 — flag issued invoices that have no matching payment (same amount +
    /// currency) anywhere in the archive. The payment may live outside the
    /// archive; absence is NOT proof of non-payment. Low confidence, reasoned.
    ///
    /// - Parameters:
    ///   - issued: (amount, currency, objectID) for each invoice-issued event.
    ///   - paid: (amount, currency) for each invoice-paid event.
    public func detectMissingPaymentProof(
        issued: [(amount: Double, currency: String, objectID: UUID)],
        paid: [(amount: Double, currency: String)],
        limit: Int = 50
    ) -> [GapNode] {
        // A payment "covers" an issue when amount matches (within a cent) and
        // currency matches. One paid record can satisfy at most one invoice.
        var remaining = paid
        var gaps: [GapNode] = []
        for invoice in issued {
            if let idx = remaining.firstIndex(where: {
                $0.currency == invoice.currency && abs($0.amount - invoice.amount) < 0.01
            }) {
                remaining.remove(at: idx)   // consumed by this invoice
                continue
            }
            let amount = Self.renderMoney(invoice.amount, invoice.currency)
            gaps.append(GapNode(
                kind: .paymentProof,
                description: "No payment record found for the \(amount) invoice",
                reason: "an invoice for \(amount) was issued but no payment of that amount is in the archive — it matters because the payment (or its absence) is often the point in dispute. The payment may simply live outside this archive; this is not proof of non-payment.",
                confidence: 0.3,
                evidenceObjectID: invoice.objectID
            ))
            if gaps.count >= limit { break }
        }
        return gaps
    }

    private static func renderMoney(_ value: Double, _ currency: String) -> String {
        let n = value == value.rounded() ? String(format: "%.0f", value) : String(format: "%.2f", value)
        return currency.isEmpty ? n : "\(currency) \(n)"
    }

    // MARK: Custody breaks (A5.7)

    /// A5.7 — flag files whose bytes changed since first ingest (a custody hash
    /// mismatch), so an earlier version's evidence may no longer be recoverable.
    /// Neutral framing — a change can be an ordinary edit, not tampering.
    ///
    /// - Parameter mismatches: (detail, fileID) for each hash-mismatch custody
    ///   event; `detail` is the recorded human description (e.g. "content at
    ///   X.pdf changed since last ingest").
    public func detectCustodyBreaks(
        mismatches: [(detail: String?, fileID: UUID)],
        limit: Int = 100
    ) -> [GapNode] {
        var seen = Set<UUID>()
        var gaps: [GapNode] = []
        for m in mismatches where seen.insert(m.fileID).inserted {
            let what = (m.detail?.isEmpty == false) ? m.detail! : "a file's contents changed since it was first ingested"
            gaps.append(GapNode(
                kind: .custodyBreak,
                description: what,
                reason: "the file's contents differ from when it was first seen (custody hash mismatch) — an earlier version's evidence may no longer be recoverable. A change can be an ordinary edit, not tampering; both versions' extracted facts are preserved.",
                confidence: 0.4,
                evidenceObjectID: m.fileID
            ))
            if gaps.count >= limit { break }
        }
        return gaps
    }

    // MARK: Unreadable regions (A5.7)

    private static func readableReason(status: String) -> String {
        switch status {
        case "partial":     return "only part of the document could be parsed"
        case "corrupt":     return "the file appears corrupt"
        case "encrypted":   return "the file is encrypted and couldn't be decoded"
        case "unsupported": return "the format isn't fully supported yet"
        case "failed":      return "parsing failed"
        default:            return "the document couldn't be fully read"
        }
    }

    /// A5.7 — flag sources whose extraction wasn't clean (partial / corrupt /
    /// encrypted / unsupported / failed), so the unreadable region is recorded
    /// as possibly-missing evidence rather than silently dropped. Reflects a
    /// parsing limit, not wrongdoing.
    ///
    /// - Parameter regions: per-source (filename, extraction status, warning count).
    public func detectUnreadableRegions(
        regions: [(filename: String, status: String, warningCount: Int)],
        limit: Int = 100
    ) -> [GapNode] {
        var gaps: [GapNode] = []
        for region in regions {
            let why = Self.readableReason(status: region.status)
            let warnClause = region.warningCount > 0 ? " (\(region.warningCount) parser warning(s))" : ""
            gaps.append(GapNode(
                kind: .unreadableRegion,
                description: "Part of \"\(region.filename)\" could not be read",
                reason: "\(why)\(warnClause) — evidence in the unreadable region may be missing from the ledger. This reflects a parsing limit, not wrongdoing; the source is still tracked and can be re-parsed.",
                confidence: 0.3
            ))
            if gaps.count >= limit { break }
        }
        return gaps
    }

    // MARK: Thread parents

    /// Detect replies/forwards whose original message wasn't ingested.
    public func detectThreadParent(
        replySubjects: [(objectID: UUID, subject: String, hasParent: Bool)]
    ) -> [GapNode] {
        guard let regex = Self.replyPrefixRegex else { return [] }

        var gaps: [GapNode] = []
        for entry in replySubjects {
            guard !entry.hasParent else { continue }
            let subject = entry.subject
            let range = NSRange(subject.startIndex..<subject.endIndex, in: subject)
            guard regex.firstMatch(in: subject, range: range) != nil else { continue }

            let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
            gaps.append(GapNode(
                kind: .threadParent,
                description: "Reply \"\(trimmed)\" has no ingested original",
                reason: "the parent message of this reply isn't in the archive",
                confidence: 0.4,
                evidenceObjectID: entry.objectID
            ))
            if gaps.count >= 50 { break }
        }
        return gaps
    }
}
