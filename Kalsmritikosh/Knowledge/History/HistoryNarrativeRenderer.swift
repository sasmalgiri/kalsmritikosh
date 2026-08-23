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

public struct RenderedChapter: Sendable, Codable, Hashable {
    public let ordinal: Int
    public let title: String
    public let prose: String
    public let itemIDs: [UUID]
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
            let sentences = plan.itemIDs.compactMap { itemsByID[$0] }.map(Self.sentence(for:))
            return RenderedChapter(ordinal: plan.ordinal, title: plan.title,
                                   prose: sentences.joined(separator: " "), itemIDs: plan.itemIDs)
        }

        let gapsNote: String? = outline.gaps.isEmpty ? nil
            : "Open questions (\(outline.gaps.count)): " + outline.gaps.prefix(3).map(\.description).joined(separator: " ")

        return HistoryNarrative(subjectName: name, summary: summary, chapters: chapters, gapsNote: gapsNote)
    }

    // MARK: - Deterministic sentence + date phrasing (precision-honest)

    static func sentence(for item: HistoryItem) -> String {
        if let phrase = datePhrase(item.start) {
            return "\(phrase): \(item.title)."
        }
        return "\(item.title) (date not established)."
    }

    static func datePhrase(_ t: TemporalValue?) -> String? {
        guard let t, let d = t.start else { return nil }
        let y = calendar.component(.year, from: d)
        switch t.precision {
        case .unknown:                 return nil
        case .decade:                  return "In the \(y / 10 * 10)s"
        case .year:                    return "In \(y)"
        case .quarter, .month:         return "In \(months[calendar.component(.month, from: d)]) \(y)"
        case .day, .minute, .instant:
            let m = calendar.component(.month, from: d), day = calendar.component(.day, from: d)
            return String(format: "On %04d-%02d-%02d", y, m, day)
        }
    }

    static func year(_ d: Date) -> String { String(calendar.component(.year, from: d)) }
}
