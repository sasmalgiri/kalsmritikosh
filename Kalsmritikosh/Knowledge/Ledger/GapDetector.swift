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
