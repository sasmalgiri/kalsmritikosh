//
//  IncidentAnswerComposer.swift
//  Kalsmritikosh
//
//  "When did the accident in <case> happen?" answered by the incident itself: its date first,
//  then what the source says happened, cited to the event.
//
//  FOUND BY THE CASE BENCH, 2026-10-18. Without the on-device AI such questions got a list of
//  ranked passages — usually led by the probable-cause paragraph, because it says "accident" —
//  and the date was somewhere inside (65% of NTSB date answers did not lead with the date).
//  The incident events (IncidentEventExtractor) already hold the date, cited to the sentence
//  that states it.
//
//  Fires only for a "when … happen / occur / take place" question, or "when was/were the
//  accident / injury / collision …", and only on incident events in the retrieval set (which
//  the anchored retriever has already limited to the named case). Deterministic, no model.
//

import Foundation

public enum IncidentAnswerComposer {

    nonisolated static let happenWords = ["happen", "occur", "take place", "took place"]
    nonisolated static let incidentNouns = ["accident", "incident", "crash", "collision", "injury", "injuries",
                                            "explosion", "fire", "death", "fatality", "assault", "theft"]

    public struct Composition: Sendable {
        public let text: String
        public let events: [Event]
    }

    public nonisolated static func asksWhenItHappened(_ question: String) -> Bool {
        let q = question.lowercased().trimmingCharacters(in: .whitespaces)
        guard q.hasPrefix("when ") || q.contains(" when ") || q.hasPrefix("on what date") || q.hasPrefix("what date") else { return false }
        return happenWords.contains { q.contains($0) } || incidentNouns.contains { q.contains($0) }
    }

    /// `facts` — the scoped facts: when the documents state their own labeled date ("Date &
    /// time:", "Event date:"), the incident on that day is the one asked about. A labeled date that
    /// matches no incident means the incidents found are background, so nothing is composed and
    /// the ordinary answer path decides.
    public nonisolated static func compose(question: String, events: [Event], facts: [GenericFact] = []) -> Composition? {
        guard asksWhenItHappened(question) else { return nil }
        let incidents = events.filter { $0.kind == .incidentOccurred }.sorted { $0.date < $1.date }
        guard let first = incidents.first else { return nil }
        var format = Date.FormatStyle(date: .long, time: .omitted).locale(Locale(identifier: "en_US_POSIX"))
        format.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let labeledDays = Set(facts
            .filter { FactSchemaRegistry.expectedShape(of: $0.field) == .date && FactSchemaRegistry.normalizeField($0.field) != "date" }
            .compactMap { IncidentEventExtractor.firstDate(in: $0.value) ?? ISO8601DateFormatter().date(from: $0.value + "T00:00:00Z") }
            .map { $0.formatted(format) })
        if !labeledDays.isEmpty {
            guard let matched = incidents.first(where: { labeledDays.contains($0.date.formatted(format)) }) else { return nil }
            return Composition(text: "\(matched.date.formatted(format)). \(matched.summary ?? matched.title)", events: [matched])
        }
        let days = Array(Set(incidents.map { $0.date.formatted(format) }))
        if days.count == 1 {
            return Composition(text: "\(first.date.formatted(format)). \(first.summary ?? first.title)", events: [first])
        }
        // Several dated incidents: all of them, in order — the reader decides which one is meant.
        let lines = incidents.prefix(3).map { "- \($0.date.formatted(format)): \($0.summary ?? $0.title)" }
        return Composition(text: "The documents date \(incidents.count) incidents:\n" + lines.joined(separator: "\n"),
                           events: Array(incidents.prefix(3)))
    }
}
