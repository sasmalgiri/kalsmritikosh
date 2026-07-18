//
//  PatentLegalEventExtractor.swift
//  Kalsmritikosh
//
//  The "story spine" for legal/patent matters. The generic extractor turns
//  emails into emailReceived events but never records the milestones that ARE
//  the story — filed, examined, objection/hearing, petition, granted. Without
//  those as dated events, the timeline and narrative have nothing to sequence,
//  so a question like "how did the patent get granted?" can't be answered even
//  though the documents (certificate, hearing notice, petitions, intimation)
//  are all ingested.
//
//  This is a deterministic pass over document text: it recognizes milestone
//  phrases, binds each to the nearest date, and emits a high-trust, dated Event
//  (kind .other, milestone recorded in attributes + title). No model.
//

import Foundation

public enum PatentLegalEventExtractor {

    /// A milestone rule. `triggers` prove the milestone is present in the doc;
    /// `dateAnchors` are phrases a date reliably FOLLOWS (label:value form), so
    /// the date is bound precisely rather than by fragile proximity.
    private struct Rule {
        let key: String
        let title: String
        let triggers: [String]
        let dateAnchors: [String]
        var allowNearestFallback = false
    }

    // Ordered most-specific first. Deterministic, from Indian Patent Office
    // document boilerplate (+ general patent terms). Dates come from the anchor,
    // never generic proximity — a wrong date on a legal timeline is worse than none.
    private static let rules: [Rule] = [
        Rule(key: "granted", title: "Patent granted",
             triggers: ["hereby granted", "granted and recorded", "patent has been granted", "date of grant"],
             dateAnchors: ["date of grant :", "date of grant:", "date of grant",
                           "recorded in the register of patents on the", "recorded in the register of patents on",
                           "recorded on the"]),
        Rule(key: "intimation", title: "Intimation of grant issued",
             triggers: ["intimation of the grant", "intimation of grant", "intimation regarding the grant"],
             dateAnchors: ["dated the", "dated"], allowNearestFallback: false),
        Rule(key: "hearing", title: "Hearing held",
             triggers: ["hearing held on", "hearing was held", "hearing dated", "during the hearing"],
             dateAnchors: ["hearing held on", "hearing was held on", "hearing dated", "the hearing on"]),
        Rule(key: "hearing_notice", title: "Hearing notice issued",
             triggers: ["hearing notice", "notice of hearing", "video conferencing on"],
             dateAnchors: ["date of dispatch:", "date of dispatch",
                           "hearing notice of the controller dated", "video conferencing on"]),
        Rule(key: "objection", title: "Objection raised",
             triggers: ["outstanding objection", "objection(s) are still", "not satisfactory u/s", "formal requirement"],
             dateAnchors: ["hearing notice of the controller dated"], allowNearestFallback: true),
        Rule(key: "fer", title: "Examination report (FER) issued",
             triggers: ["first examination report", "response to fer"],
             dateAnchors: ["dated"], allowNearestFallback: true),
        Rule(key: "filed", title: "Patent application filed",
             triggers: ["date of filing", "filed at your office on", "application for patent under no"],
             dateAnchors: ["date of filing :", "date of filing:", "date of filing",
                           "filed at your office on", "was filed at your office on"]),
        Rule(key: "exam_request", title: "Request for examination",
             triggers: ["request for examination"],
             dateAnchors: ["date of request for examination"])
    ]

    /// Extract milestone events. Each milestone's date is bound from its anchor
    /// phrase (the date that follows it); milestones with no anchored date are
    /// dropped (no undated / mis-dated milestones), unless the rule explicitly
    /// allows a lower-confidence nearest-date fallback. Deterministic + capped.
    public static func extract(
        text: String,
        sourceObjectID: KnowledgeObject.ID,
        entityIDs: [Entity.ID] = [],
        limit: Int = 12
    ) -> [Event] {
        guard text.count >= 20 else { return [] }
        let ns = text as NSString
        let lower = text.lowercased()
        let dates = dateMatches(in: text)
        guard !dates.isEmpty else { return [] }

        var out: [Event] = []
        var seen = Set<String>()
        for rule in rules {
            guard firstLocation(of: rule.triggers, in: lower) != nil else { continue }

            var boundDate: Date?
            var dateConf = 0.9
            // Anchored binding: first anchor present → first date within a short
            // window AFTER it.
            for anchor in rule.dateAnchors {
                guard let r = lower.range(of: anchor) else { continue }
                let anchorEnd = lower.distance(from: lower.startIndex, to: r.upperBound)
                if let d = firstDate(dates, afterLoc: anchorEnd, window: 45) { boundDate = d; break }
            }
            if boundDate == nil, rule.allowNearestFallback,
               let markerLoc = firstLocation(of: rule.triggers, in: lower),
               let (d, _) = nearestDate(dates, to: markerLoc) {
                boundDate = d; dateConf = 0.5
            }
            guard let date = boundDate else { continue }

            let key = "\(rule.key)|\(Self.dayKey(date))"
            guard seen.insert(key).inserted else { continue }
            let tier: QualityTier = dateConf >= 0.8 ? .t1 : .t2
            var attrs: [String: AnyCodable] = ["milestone": AnyCodable(.string(rule.key))]
            if let loc = firstLocation(of: rule.triggers, in: lower) {
                let s = max(0, loc - 10)
                let snippet = ns.substring(with: NSRange(location: s, length: min(120, ns.length - s)))
                    .replacingOccurrences(of: "\n", with: " ")
                attrs["evidencePhrase"] = AnyCodable(.string(snippet))
            }
            out.append(Event(
                kind: .other,
                date: date,
                title: rule.title,
                summary: (attrs["evidencePhrase"]?.value).flatMap { if case .string(let s) = $0 { return s } else { return nil } },
                entityIDs: entityIDs,
                sourceObjectID: sourceObjectID,
                confidence: .high,
                dateConfidence: dateConf,
                attributes: attrs,
                qualityTier: tier,
                datePrecision: .day,
                status: .observed
            ))
            if out.count >= limit { break }
        }
        return out
    }

    /// First date whose location falls within [afterLoc, afterLoc+window].
    private static func firstDate(_ dates: [(date: Date, loc: Int)], afterLoc: Int, window: Int) -> Date? {
        dates.filter { $0.loc >= afterLoc && $0.loc <= afterLoc + window }
            .min { $0.loc < $1.loc }?.date
    }

    // MARK: - Helpers

    private static func firstLocation(of triggers: [String], in lowerText: String) -> Int? {
        var best: Int?
        for t in triggers {
            if let r = lowerText.range(of: t) {
                let loc = lowerText.distance(from: lowerText.startIndex, to: r.lowerBound)
                if best == nil || loc < best! { best = loc }
            }
        }
        return best
    }

    private static func nearestDate(_ dates: [(date: Date, loc: Int)], to markerLoc: Int) -> (Date, Int)? {
        guard !dates.isEmpty else { return nil }
        let best = dates.min { abs($0.loc - markerLoc) < abs($1.loc - markerLoc) }!
        return (best.date, best.loc)
    }

    private static func dayKey(_ d: Date) -> String {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: d)
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }

    private static let months: [String: Int] = [
        "jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
        "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12
    ]

    /// Find dates in the text with their character location. Handles
    /// dd/mm/yyyy (day-first, as Indian patent documents use), yyyy-mm-dd, and
    /// "d Month yyyy" / "d Mon yyyy". Returns [(date, location)].
    static func dateMatches(in text: String) -> [(date: Date, loc: Int)] {
        var out: [(Date, Int)] = []
        let ns = text as NSString
        func add(_ y: Int, _ m: Int, _ d: Int, _ loc: Int) {
            guard (1900...2100).contains(y), (1...12).contains(m), (1...31).contains(d) else { return }
            var c = DateComponents(); c.year = y; c.month = m; c.day = d
            if let date = Calendar(identifier: .gregorian).date(from: c) { out.append((date, loc)) }
        }
        // dd/mm/yyyy  (also dd-mm-yyyy)
        if let rx = try? NSRegularExpression(pattern: #"\b(\d{1,2})[/\-.](\d{1,2})[/\-.](\d{4})\b"#) {
            for m in rx.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let d = Int(ns.substring(with: m.range(at: 1))) ?? 0
                let mo = Int(ns.substring(with: m.range(at: 2))) ?? 0
                let y = Int(ns.substring(with: m.range(at: 3))) ?? 0
                add(y, mo, d, m.range.location)      // day-first
            }
        }
        // yyyy-mm-dd
        if let rx = try? NSRegularExpression(pattern: #"\b(\d{4})[/\-.](\d{1,2})[/\-.](\d{1,2})\b"#) {
            for m in rx.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let y = Int(ns.substring(with: m.range(at: 1))) ?? 0
                let mo = Int(ns.substring(with: m.range(at: 2))) ?? 0
                let d = Int(ns.substring(with: m.range(at: 3))) ?? 0
                add(y, mo, d, m.range.location)
            }
        }
        // d Month yyyy  /  d Mon yyyy
        if let rx = try? NSRegularExpression(
            pattern: #"\b(\d{1,2})(?:st|nd|rd|th)?\s+([A-Za-z]{3,9})\.?\s+(\d{4})\b"#, options: [.caseInsensitive]) {
            for m in rx.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let d = Int(ns.substring(with: m.range(at: 1))) ?? 0
                let monName = ns.substring(with: m.range(at: 2)).lowercased()
                let y = Int(ns.substring(with: m.range(at: 3))) ?? 0
                if let mo = months[String(monName.prefix(3))] { add(y, mo, d, m.range.location) }
            }
        }
        return out
    }
}
