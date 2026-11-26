//
//  HistoryNarrativeRenderer.swift
//  Kalsmritikosh
//
//  HIST-052 (Universal History program, Phase 8). Level-2 rendering: deterministic
//  rule-based prose over the reconstructed outline — NOT the LLM, NOT generic RAG.
//  This is the guaranteed fallback so a structured history never drops directly to
//  a chat answer (release gate: no RAG output is labelled Historical). Optional LLM
//  prose (Level 3) may only REPHRASE these chapters; it plugs in at the app layer.
//  Every rendered sentence maps to a history item; date phrasing honours precision
//  (a year is never widened to a day). Deterministic + LLM-free.
//

import Foundation

/// P4-U3 (H-4) — the placed unit. Every span of rendered prose names the
/// item(s) it stands on: the gist span carries the whole chapter's items,
/// each sentence span carries exactly its one item. Citations therefore
/// survive any later rephrasing — the spans are the truth contract.
public struct RenderedSpan: Sendable, Codable, Hashable {
    public let text: String
    public let itemIDs: [UUID]
}

public struct RenderedChapter: Sendable, Codable, Hashable {
    public let ordinal: Int
    public let title: String
    public let prose: String
    public let itemIDs: [UUID]
    /// P4-U3 (H-4) — summarize-then-place: the chapter's deterministic gist,
    /// computed BEFORE any prose work and placed at the chapter head. Optional
    /// for compatibility with pre-P4 rendered payloads.
    public let gist: String?
    /// The placed units (gist span first, then one span per sentence).
    public let spans: [RenderedSpan]?

    public nonisolated init(ordinal: Int, title: String, prose: String, itemIDs: [UUID],
                            gist: String? = nil, spans: [RenderedSpan]? = nil) {
        self.ordinal = ordinal; self.title = title; self.prose = prose
        self.itemIDs = itemIDs; self.gist = gist; self.spans = spans
    }
}

public struct HistoryNarrative: Sendable, Codable, Hashable {
    public let subjectName: String
    public let summary: String
    public let chapters: [RenderedChapter]
    public let gapsNote: String?
}

public nonisolated struct HistoryNarrativeRenderer: Sendable {
    private static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }()
    private static let months = ["", "January", "February", "March", "April", "May", "June",
                                 "July", "August", "September", "October", "November", "December"]

    public init() {}

    public func render(outline: HistoryOutline) -> HistoryNarrative {
        let name = outline.subject.displayName
        let cov = outline.coverage

        var summaryParts = ["History of \(name).",
                            "\(cov.datedItems) dated and \(cov.undatedItems) undated item(s) across \(outline.chapters.count) period(s)."]
        if let e = cov.earliest, let l = cov.latest {
            summaryParts.append("Evidence spans \(Self.year(e))–\(Self.year(l)).")
        }
        let summary = summaryParts.joined(separator: " ")

        let itemsByID = Dictionary(uniqueKeysWithValues: outline.items.map { ($0.id, $0) })
        let chapters = outline.chapters.map { plan -> RenderedChapter in
            let items = plan.itemIDs.compactMap { itemsByID[$0] }
            let sentences = items.map(Self.sentence(for:))
            // P4-U3 (H-4) — summarize FIRST (deterministic gist from the truth
            // content alone), then PLACE: the gist span carries the whole
            // chapter, each sentence span its one item.
            let gist = Self.gist(for: items, chapterTitle: plan.title)
            let spans = [RenderedSpan(text: gist, itemIDs: plan.itemIDs)]
                + zip(sentences, items).map { RenderedSpan(text: $0, itemIDs: [$1.id]) }
            return RenderedChapter(ordinal: plan.ordinal, title: plan.title,
                                   prose: sentences.joined(separator: " "), itemIDs: plan.itemIDs,
                                   gist: gist, spans: spans)
        }

        let gapsNote: String? = outline.gaps.isEmpty ? nil
            : "Open questions (\(outline.gaps.count)): " + outline.gaps.prefix(3).map(\.description).joined(separator: " ")

        return HistoryNarrative(subjectName: name, summary: summary, chapters: chapters, gapsNote: gapsNote)
    }

    // MARK: - Deterministic gist (H-4: summarize BEFORE placing)

    /// The chapter's gist from its truth content alone — counts and
    /// precision-honest dates, nothing invented. Special chapters get plain
    /// statements of what they hold.
    static func gist(for items: [HistoryItem], chapterTitle: String) -> String {
        let n = items.count
        if chapterTitle == HistoryOutlineBuilder.unplacedChapterTitle {
            return "\(n) item(s) awaiting placement review."
        }
        if chapterTitle == HistoryOutlineBuilder.reviewedOutChapterTitle {
            return "\(n) item(s) excluded by your review."
        }
        let phrases = items.compactMap { datePhrase($0.start) }
        guard let first = phrases.first, let last = phrases.last else {
            return "\(n) item(s) without an established date."
        }
        if n == 1 || first == last {
            return "\(n) recorded item(s) — \(lowercasedLead(first))."
        }
        return "\(n) recorded items, from \(lowercasedLead(first)) to \(lowercasedLead(last))."
    }

    /// "On 2004-01-01" → "on 2004-01-01" (mid-sentence placement).
    private static func lowercasedLead(_ phrase: String) -> String {
        guard let head = phrase.first else { return phrase }
        return head.lowercased() + phrase.dropFirst()
    }

    // MARK: - Deterministic sentence + date phrasing (precision-honest)

    static func sentence(for item: HistoryItem) -> String {
        // P4-U4 (SR-6/SR-5) — the review loop speaks in the prose: rejected
        // items are excluded from the story yet named here, and a correction
        // carries its badge.
        if item.reviewStatus == .rejected {
            return "\(item.title) (excluded by review)."
        }
        let badge = item.reviewStatus == .corrected ? " (user-corrected)" : ""
        if let phrase = datePhrase(item.start) {
            return "\(phrase): \(item.title)\(badge)."
        }
        return "\(item.title) (date not established)\(badge)."
    }

    /// `hostTimeZone` — the Mac's time zone (injectable for tests). P4 (real-case evaluation
    /// 2026-11-03, D6): a day-precision date is a calendar day stored at midnight UTC; a ledger written
    /// before that fix holds some at the host's LOCAL midnight (the proceeding extractor built them in
    /// the local calendar), which read back in UTC as the day before on any Mac east of Greenwich
    /// ("2023-06-21" for June 22 on IST). Such a value — exactly local midnight, not UTC midnight — is
    /// the local calendar day it was built from.
    static func datePhrase(_ t: TemporalValue?, hostTimeZone: TimeZone = .current) -> String? {
        guard let t, let d = t.start else { return nil }
        let cal = calendar(forDayValue: d, precision: t.precision, hostTimeZone: hostTimeZone)
        let y = cal.component(.year, from: d)
        switch t.precision {
        case .unknown:                 return nil
        case .decade:                  return "In the \(y / 10 * 10)s"
        case .year:                    return "In \(y)"
        case .quarter, .month:         return "In \(months[cal.component(.month, from: d)]) \(y)"
        case .day, .minute, .instant:
            let m = cal.component(.month, from: d), day = cal.component(.day, from: d)
            return String(format: "On %04d-%02d-%02d", y, m, day)
        }
    }

    /// UTC, except for a day-or-coarser value at the host's local midnight that is not UTC midnight.
    static func calendar(forDayValue d: Date, precision: DatePrecision, hostTimeZone: TimeZone) -> Calendar {
        guard [.day, .month, .quarter, .year, .decade].contains(precision),
              hostTimeZone.secondsFromGMT(for: d) != 0 else { return calendar }
        let utc = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: d)
        guard utc.hour != 0 || utc.minute != 0 || utc.second != 0 else { return calendar }
        var local = Calendar(identifier: .gregorian); local.timeZone = hostTimeZone
        let parts = local.dateComponents([.hour, .minute, .second, .nanosecond], from: d)
        guard parts.hour == 0, parts.minute == 0, parts.second == 0, (parts.nanosecond ?? 0) == 0 else { return calendar }
        return local
    }

    static func year(_ d: Date) -> String { String(calendar.component(.year, from: d)) }
}
