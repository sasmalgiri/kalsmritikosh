//
//  IncidentEventExtractor.swift
//  Kalsmritikosh
//
//  The incident itself as a dated event — the first line of every investigation's chronology.
//
//  FOUND BY THE CASE BENCH, 2026-10-18. Across NTSB accident reports, OSHA accident
//  investigations and court decisions, ingest produced ZERO events per document: the marker
//  table only knows business milestones (contract signed, invoice paid, meeting held), so
//  "On January 1, 2008, about 1430 Pacific standard time, a Piper PA 28-180 … collided in
//  flight" left a date entity and no event. With no event the timeline is empty, and "What
//  happened in OSHA investigation 200072106?" answered "No history found".
//
//  A sentence that reports harm or damage (an accident, collision, explosion, fire, fall,
//  injury or death) and carries a FULL written date — in the sentence itself, or in the
//  sentence just before or after it — becomes one `incidentOccurred` event
//  on that date. A sentence without a full date yields nothing: a year alone or a bare
//  weekday is not a date an investigator can put on a chronology, and the file's own date is
//  never substituted.
//
//  Deterministic, offline. At most `maximumPerDocument` incidents, one per distinct day,
//  earliest first.
//

import Foundation

public enum IncidentEventExtractor {

    /// Words that report harm or damage. Matched on word starts, lower-cased.
    nonisolated static let markers: [String] = [
        "accident", "crash", "collided", "collision", "explosion", "exploded", "explode",
        "caught fire", "a fire", "the fire", "fire broke", "injur", "killed", "died", "death of", "fatal", "struck by",
        "fell ", "fall from", "derail", "overturn", "spill", "leaked",
        "nosed over", "ditched", "engulfed", "electrocut", "amputat", "burned", "drowned",
        "assault", "robbery", "stolen", "theft",
        // Case bench 2026-10-20 (OSHA): workplace narratives report harm as "got his hand caught
        // into the press", "was crushed", "was hospitalized", "found unresponsive".
        "caught in", "caught between", "caught into", "crush", "pinned", "fractur", "lacerat",
        "hospitaliz", "unresponsive", "overcome by",
    ]

    nonisolated static let maximumPerDocument = 3

    nonisolated static let monthNumbers: [String: Int] = [
        "january": 1, "february": 2, "march": 3, "april": 4, "may": 5, "june": 6, "july": 7,
        "august": 8, "september": 9, "october": 10, "november": 11, "december": 12,
        "jan": 1, "feb": 2, "mar": 3, "apr": 4, "jun": 6, "jul": 7, "aug": 8, "sep": 9,
        "sept": 9, "oct": 10, "nov": 11, "dec": 12,
    ]

    /// "January 1, 2008", "Jan. 1, 2008", "1 January 2008", "2008-01-01", "1/1/2008" (US order).
    nonisolated static let datePattern = try? NSRegularExpression(pattern:
        #"\b(?:(jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|sept?(?:ember)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\.?\s+(\d{1,2}),?\s+(\d{4})|(\d{1,2})\s+(january|february|march|april|may|june|july|august|september|october|november|december)\s+(\d{4})|(\d{4})-(\d{2})-(\d{2})|(\d{1,2})/(\d{1,2})/(\d{4}))\b"#,
        options: [.caseInsensitive])

    public nonisolated static func extract(text: String, sourceObjectID: UUID, entityIDs: [UUID]) -> [Event] {
        let sentences = splitSentences(text)
        var byDay: [Date: Event] = [:]
        // The date of the last narrative opener ("At 3:15 p.m. on August 19, 2017, an employee …")
        // and how many sentences ago it was. A narrative tells its incident over the next few
        // sentences without repeating the date — the OSHA case bench had the harm three sentences
        // after the opener for 27% of summaries ("… lost his balance … amputating the fingertip").
        var opener: (date: Date, at: Int)?
        for (i, sentence) in sentences.enumerated() {
            let lower = sentence.lowercased()
            let ownDate = firstDate(in: sentence)
            if let ownDate {
                opener = isNarrativeOpener(sentence) ? (ownDate, i) : nil
            }
            guard markers.contains(where: { containsWordStart($0, in: Self.withoutAttributiveAccident(lower)) }) else { continue }
            // The date is often a neighbour, not a part, of the harm sentence: a narrative opens
            // "At 2:00 p.m. on December 3, 2004, Employee #1 was …" and the explosion follows; a
            // form puts "Event date: December 3, 2003" on the line after the event title. So the
            // sentence's own date first, then the one before, then the one after, then the
            // opener of the narrative it belongs to (no other date in between).
            // A sentence that moves the story in time takes no borrowed date.
            var date = ownDate
            let shifted = timeShiftWords.contains(where: { containsWordStart($0, in: lower) })
            if date == nil, !shifted, i > 0, lendsDate(sentences[i - 1]) { date = firstDate(in: sentences[i - 1]) }
            if date == nil, !shifted, i + 1 < sentences.count, lendsDate(sentences[i + 1]) { date = firstDate(in: sentences[i + 1]) }
            if date == nil, !shifted, let opener, i - opener.at <= Self.openerReach { date = opener.date }
            guard let day = date, byDay[day] == nil else { continue }
            byDay[day] = Event(
                kind: .incidentOccurred,
                date: day,
                title: title(from: sentence),
                summary: String(sentence.prefix(400)),
                entityIDs: Array(entityIDs.prefix(12)),
                sourceObjectID: sourceObjectID,
                confidence: .medium,
                dateConfidence: 0.8,
                qualityTier: .t2,
                datePrecision: .day,
                status: .asserted)
        }
        return byDay.values.sorted { $0.date < $1.date }.prefix(maximumPerDocument).map { $0 }
    }

    // MARK: - Pieces

    /// Reports use "accident" as an adjective — "the accident airplane's engine was installed on
    /// January 5, 2004", "the accident pilot held …" — about background, not the incident
    /// (case bench: those dates were taken for the accident's). Such uses are removed before the
    /// markers are tested; "the accident occurred …" still counts.
    nonisolated static let attributiveAccident = try? NSRegularExpression(pattern:
        #"\baccident (?:airplane|aircraft|helicopter|pilot|flight|engine|site|vehicle|car|truck|vessel|scene|investigat\w*|report\w*|history|records?)\b"#)

    nonisolated static func withoutAttributiveAccident(_ lower: String) -> String {
        guard let re = attributiveAccident else { return lower }
        return re.stringByReplacingMatches(in: lower, range: NSRange(location: 0, length: (lower as NSString).length), withTemplate: "")
    }

    /// Words that date a PROCEDURAL step, not the incident: a neighbour sentence carrying one
    /// ("The complaint was filed on May 1, 1990.") never lends its date.
    nonisolated static let proceduralWords: [String] = [
        // Not "entered" or "received": "entered a sand hopper", "received burns" are the incident.
        "filed", "decided", "argued", "served", "docketed", "submitted", "dated",
        "signed", "issued", "hearing", "appeal",
    ]

    /// May a neighbouring sentence lend its date? Only a narrative opener ("On …", "At 2:00 p.m.
    /// on …") or a short form line ("Event date: December 3, 2003"), and never a procedural one.
    nonisolated static func lendsDate(_ sentence: String) -> Bool {
        let s = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = s.lowercased()
        guard !proceduralWords.contains(where: { containsWordStart($0, in: lower) }) else { return false }
        return lower.hasPrefix("on ") || lower.hasPrefix("at ") || s.count <= 80
    }

    /// How many sentences after a narrative opener its date still applies.
    nonisolated static let openerReach = 4

    /// A sentence that moves the story in time ("Two weeks later he was hospitalized") is not on
    /// the opener's day.
    nonisolated static let timeShiftWords: [String] = [
        // Not "days"/"weeks": "was hospitalized for three days" is the incident.
        "later", "subsequent", "afterward", "the following", "the next", "next day", "previous",
        "earlier", "prior", "ago",
    ]

    /// A sentence that opens a narrative with its date: "On August 19, 2017, …", "At 3:15 p.m. on
    /// August 19, 2017, …" — never a procedural one.
    nonisolated static func isNarrativeOpener(_ sentence: String) -> Bool {
        let lower = sentence.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !proceduralWords.contains(where: { containsWordStart($0, in: lower) }) else { return false }
        return lower.hasPrefix("on ") || lower.hasPrefix("at ")
    }

    nonisolated static func splitSentences(_ text: String) -> [String] {
        var out: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: [.bySentences, .localized]) { s, _, _, _ in
            if let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(s) }
        }
        return out
    }

    nonisolated static func containsWordStart(_ marker: String, in lower: String) -> Bool {
        var search = lower.startIndex
        while let r = lower.range(of: marker, range: search..<lower.endIndex) {
            if r.lowerBound == lower.startIndex || !lower[lower.index(before: r.lowerBound)].isLetter { return true }
            search = r.upperBound
        }
        return false
    }

    /// The first full date in `s`, at midnight UTC; nil when there is none or it is impossible.
    nonisolated static func firstDate(in s: String) -> Date? {
        guard let re = datePattern else { return nil }
        let ns = s as NSString
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            func group(_ i: Int) -> String? {
                let r = m.range(at: i)
                return r.location == NSNotFound ? nil : ns.substring(with: r)
            }
            var y: Int?, mo: Int?, d: Int?
            if let mon = group(1) { mo = monthNumbers[mon.lowercased()]; d = Int(group(2) ?? ""); y = Int(group(3) ?? "") }
            else if let mon = group(5) { d = Int(group(4) ?? ""); mo = monthNumbers[mon.lowercased()]; y = Int(group(6) ?? "") }
            else if group(7) != nil { y = Int(group(7) ?? ""); mo = Int(group(8) ?? ""); d = Int(group(9) ?? "") }
            else { mo = Int(group(10) ?? ""); d = Int(group(11) ?? ""); y = Int(group(12) ?? "") }
            guard let year = y, let month = mo, let day = d, (1800...2200).contains(year),
                  (1...12).contains(month), (1...31).contains(day) else { continue }
            var c = DateComponents()
            c.year = year; c.month = month; c.day = day
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "UTC") ?? .gmt
            // Rejects 31 February and the like: a date the calendar cannot build is not a date.
            guard let date = cal.date(from: c), cal.component(.day, from: date) == day else { continue }
            return date
        }
        return nil
    }

    nonisolated static func title(from sentence: String) -> String {
        let flat = sentence.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        guard flat.count > 120 else { return flat }
        let cut = flat.prefix(120)
        if let space = cut.lastIndex(of: " ") { return String(cut[..<space]) + "…" }
        return String(cut) + "…"
    }
}
