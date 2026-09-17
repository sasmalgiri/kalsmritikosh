//
//  TopicSpineBuilder.swift
//  Kalsmritikosh
//
//  Topic-Ledger U5 (owner rule 2 — deterministic spine) — the "upside-down tree"
//  rollup: turn a subject's LEAF facts + dated events into ONE topic (a
//  MemoryObject) with a structured, ordered narrative. NO model — a pure
//  deterministic assembly, so it runs on any machine (with or without a reasoning
//  model) and is unit-testable. The optional AI pass (U6) only adds connective
//  grammar ON TOP of this spine; it never invents. This is what collapses the
//  790 flat facts into a handful of readable topics.
//

import Foundation

public enum TopicSpineBuilder {

    /// Build a deterministic topic for one subject. `facts` should already be the
    /// subject's canonical (deduped) facts; `events` its dated events. `now`
    /// injected for determinism.
    public nonisolated static func build(
        subjectKind: MemoryObject.SubjectKind = .topic,
        subjectIdentifier: String,
        facts: [GenericFact],
        events: [Event],
        now: Date
    ) -> MemoryObject {
        // Group facts by field (stable order), listing distinct values per field.
        var order: [String] = []
        var byField: [String: [String]] = [:]
        for f in facts.sorted(by: { $0.field != $1.field ? $0.field < $1.field : $0.value < $1.value }) {
            let field = humanize(f.field)
            let value = (f.unit?.isEmpty == false) ? "\(f.value) \(f.unit!)" : f.value
            if byField[field] == nil { order.append(field) }
            if byField[field]?.contains(value) != true { byField[field, default: []].append(value) }
        }
        let factLines = order.map { "• \($0): \(byField[$0]!.joined(separator: "; "))" }

        let df = DateFormatter()
        df.dateFormat = "d MMM yyyy"; df.timeZone = TimeZone(identifier: "UTC")
        df.locale = Locale(identifier: "en_US_POSIX")
        let sortedEvents = events.sorted { $0.date != $1.date ? $0.date < $1.date : $0.title < $1.title }
        let eventLines = sortedEvents.map { "• \(df.string(from: $0.date)) — \($0.title)" }

        var parts: [String] = ["Topic: \(subjectIdentifier)."]
        if !factLines.isEmpty { parts.append("What the sources record:\n" + factLines.joined(separator: "\n")) }
        if !eventLines.isEmpty { parts.append("Timeline:\n" + eventLines.joined(separator: "\n")) }
        let narrative = parts.joined(separator: "\n\n")

        let objectIDs = orderedUnique(sortedEvents.map(\.sourceObjectID))

        return MemoryObject(
            subjectKind: subjectKind,
            subjectIdentifier: subjectIdentifier,
            keyEventIDs: sortedEvents.map(\.id),
            narrative: narrative,
            sourceObjectIDs: objectIDs,
            confidence: .medium,
            createdAt: now,
            updatedAt: now)
    }

    nonisolated static func humanize(_ field: String) -> String {
        guard let first = field.first else { return field }
        return first.uppercased() + field.dropFirst()
    }

    nonisolated static func orderedUnique(_ ids: [UUID]) -> [UUID] {
        var seen = Set<UUID>(); var out: [UUID] = []
        for id in ids where seen.insert(id).inserted { out.append(id) }
        return out
    }
}
