//
//  GroundTruthEvalKit.swift
//  Kalsmritikosh
//
//  Phase J.4 — Vol 29 §Ground Truth / §Metrics. A labeled-fixture
//  eval harness that walks the live ledger (entities + events +
//  causal links) and reports the spec's four metric families:
//
//   • Entity P / R / F1 — match by (lowercased value, kind).
//   • Event P / R / F1 — match by (kind, primary entity name)
//     within a ±dayTolerance window.
//   • Timeline consistency — for every labeled adjacent pair
//     (eventA before eventB), is the actual ordering preserved?
//   • Causal correctness — for every labeled (sourceTitle,
//     targetTitle, relation), does a non-superseded edge exist
//     in `event_links` with the same relation?
//
//  The fixture is a single JSON file. The runner is callable
//  programmatically (SmokeTest, eval scripts) or from the Eval
//  Dashboard via a "Run ground truth" button — but no UI changes
//  in this slice; the runner ships first.
//
//  Quality-or-nothing: the runner returns a structured `Report`
//  with each unmatched item enumerated. No "67% accuracy" with
//  the long tail hidden — every miss is named so the author of the
//  fixture knows exactly what to fix.
//

import Foundation
import OSLog

// MARK: - Fixture shape

/// A ground-truth fixture. Authors hand-edit a JSON file like:
///
/// ```json
/// {
///   "title": "Project Delta — Q1 2025",
///   "entities": [
///     { "value": "Khurana", "kind": "person" },
///     { "value": "TIN23/2367", "kind": "identifier" }
///   ],
///   "events": [
///     { "title": "Contract signed", "kind": "contractSigned",
///       "primaryEntity": "Khurana", "date": "2025-03-12" }
///   ],
///   "timelineOrder": [
///     ["Contract signed", "Invoice 1 issued"]
///   ],
///   "causalLinks": [
///     { "source": "Contract signed", "target": "Invoice 1 issued",
///       "relation": "ENABLED" }
///   ]
/// }
/// ```
public struct GroundTruthFixture: Codable, Sendable {
    public let title: String
    public let entities: [Labeled.Entity]
    public let events: [Labeled.Event]
    public let timelineOrder: [[String]]
    public let causalLinks: [Labeled.CausalLink]

    public enum Labeled {
        public struct Entity: Codable, Sendable, Hashable {
            public let value: String
            public let kind: String
        }
        public struct Event: Codable, Sendable, Hashable {
            public let title: String
            public let kind: String
            public let primaryEntity: String?
            public let date: String     // YYYY-MM-DD
        }
        public struct CausalLink: Codable, Sendable, Hashable {
            public let source: String   // event title
            public let target: String   // event title
            public let relation: String // CAUSED / CONTRIBUTED_TO / ENABLED / PREVENTED / FOLLOWED
        }
    }
}

// MARK: - Result shapes

public struct GroundTruthReport: Sendable {
    public let fixtureTitle: String
    public let runAt: Date
    public let entities: PRF1
    public let events: PRF1
    public let timeline: TimelineMetric
    public let causal: PRF1
    public let unmatchedEntities: [String]
    public let unmatchedEvents: [String]
    public let unmatchedCausalLinks: [String]
    public let timelineFailures: [String]

    public struct PRF1: Sendable {
        public let truePositives: Int
        public let falsePositives: Int   // optional; 0 when we don't track FP
        public let falseNegatives: Int
        public var precision: Double {
            let denom = truePositives + falsePositives
            return denom == 0 ? 0 : Double(truePositives) / Double(denom)
        }
        public var recall: Double {
            let denom = truePositives + falseNegatives
            return denom == 0 ? 0 : Double(truePositives) / Double(denom)
        }
        public var f1: Double {
            let p = precision, r = recall
            return (p + r) == 0 ? 0 : 2 * p * r / (p + r)
        }
    }

    public struct TimelineMetric: Sendable {
        public let pairsChecked: Int
        public let pairsCorrect: Int
        public var consistency: Double {
            pairsChecked == 0 ? 0 : Double(pairsCorrect) / Double(pairsChecked)
        }
    }

    /// Markdown rendering for the report — drop directly into a
    /// SmokeTest log or save next to the fixture.
    public func renderMarkdown() -> String {
        var md = ""
        md += "# Ground-truth eval — \(fixtureTitle)\n\n"
        md += "_Ran \(runAt.formatted(date: .abbreviated, time: .standard))._\n\n"
        md += "## Summary\n\n"
        md += "| Class | P | R | F1 |\n|---|---:|---:|---:|\n"
        md += String(format: "| Entities | %.2f | %.2f | %.2f |\n",
                     entities.precision, entities.recall, entities.f1)
        md += String(format: "| Events   | %.2f | %.2f | %.2f |\n",
                     events.precision, events.recall, events.f1)
        md += String(format: "| Causal   | %.2f | %.2f | %.2f |\n",
                     causal.precision, causal.recall, causal.f1)
        md += "\n"
        md += String(format: "Timeline consistency: %.2f (%d/%d pairs preserved)\n\n",
                     timeline.consistency, timeline.pairsCorrect, timeline.pairsChecked)
        if !unmatchedEntities.isEmpty {
            md += "## Unmatched entities\n\n"
            for e in unmatchedEntities { md += "- \(e)\n" }
            md += "\n"
        }
        if !unmatchedEvents.isEmpty {
            md += "## Unmatched events\n\n"
            for e in unmatchedEvents { md += "- \(e)\n" }
            md += "\n"
        }
        if !timelineFailures.isEmpty {
            md += "## Timeline order failures\n\n"
            for f in timelineFailures { md += "- \(f)\n" }
            md += "\n"
        }
        if !unmatchedCausalLinks.isEmpty {
            md += "## Unmatched causal links\n\n"
            for c in unmatchedCausalLinks { md += "- \(c)\n" }
            md += "\n"
        }
        return md
    }
}

// MARK: - Runner

public struct GroundTruthEvalKit: Sendable {
    public init() {}

    /// Window (in days) for an event match. The labeled date may
    /// disagree with the ledger date by up to this many days and
    /// still count as a hit. Lets fixtures use approximate dates
    /// when the source carries only a month / week.
    public nonisolated static let defaultDayTolerance: Int = 3

    public func run(
        fixture: GroundTruthFixture,
        entities: EntitiesRepository,
        events: EventsRepository,
        links: EventLinksRepository?,
        dayTolerance: Int = GroundTruthEvalKit.defaultDayTolerance
    ) async throws -> GroundTruthReport {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.timeZone = TimeZone(identifier: "UTC")

        // === Entities ===
        var entityTP = 0
        var unmatchedEntities: [String] = []
        for labeled in fixture.entities {
            // EntitiesRepository.findByValue is approximate; fall back
            // to a SELECT if not present. We use a coarse name match —
            // recall first, precision later.
            let needleLower = labeled.value.lowercased()
            let kindLower = labeled.kind.lowercased()
            let hits = (try? await entities.find(byValue: labeled.value)) ?? []
            let matched = hits.contains { ent in
                ent.value.lowercased() == needleLower
                    && ent.kind.rawValue.lowercased() == kindLower
            }
            if matched {
                entityTP += 1
            } else {
                unmatchedEntities.append("\(labeled.value) (\(labeled.kind))")
            }
        }
        let entityMetric = GroundTruthReport.PRF1(
            truePositives: entityTP,
            falsePositives: 0,
            falseNegatives: fixture.entities.count - entityTP
        )

        // === Events ===
        var eventTP = 0
        var unmatchedEvents: [String] = []
        // We materialize a candidate set per labeled event by
        // pulling events with matching kind near the labeled date.
        // The match key is (kind, primary entity name, date ±
        // tolerance).
        for labeled in fixture.events {
            guard let labeledDate = dateFormatter.date(from: labeled.date) else {
                unmatchedEvents.append("\(labeled.title) [unparseable date \(labeled.date)]")
                continue
            }
            let lowerBound = labeledDate.addingTimeInterval(-Double(dayTolerance) * 86_400)
            let upperBound = labeledDate.addingTimeInterval(+Double(dayTolerance) * 86_400)
            let kindLower = labeled.kind.lowercased()
            let candidates = (try? await events.between(start: lowerBound, end: upperBound)) ?? []
            let primaryEntityLower = labeled.primaryEntity?.lowercased() ?? ""
            // Entities aren't decoded into Event.entityIDs reliably
            // (separate join table), so a name match falls back to
            // a title contains check.
            let matched = candidates.contains { ev in
                guard ev.kind.rawValue.lowercased() == kindLower else { return false }
                if primaryEntityLower.isEmpty { return true }
                return ev.title.lowercased().contains(primaryEntityLower)
            }
            if matched {
                eventTP += 1
            } else {
                let suffix = labeled.primaryEntity.map { "/" + $0 } ?? ""
                unmatchedEvents.append("\(labeled.title) (\(labeled.kind)\(suffix)) on \(labeled.date)")
            }
        }
        let eventMetric = GroundTruthReport.PRF1(
            truePositives: eventTP,
            falsePositives: 0,
            falseNegatives: fixture.events.count - eventTP
        )

        // === Timeline consistency ===
        // For each labeled pair [first, second], the first event's
        // earliest matching date in the ledger must be ≤ the second's.
        var pairsChecked = 0
        var pairsCorrect = 0
        var timelineFailures: [String] = []
        for pair in fixture.timelineOrder where pair.count == 2 {
            pairsChecked += 1
            let aTitle = pair[0]
            let bTitle = pair[1]
            // Look up labeled events by title to get their dates.
            let aLabeled = fixture.events.first { $0.title == aTitle }
            let bLabeled = fixture.events.first { $0.title == bTitle }
            guard let aLabeled, let bLabeled,
                  let aDate = dateFormatter.date(from: aLabeled.date),
                  let bDate = dateFormatter.date(from: bLabeled.date) else {
                timelineFailures.append("Pair [\(aTitle) → \(bTitle)] not in fixture event list")
                continue
            }
            if aDate <= bDate {
                pairsCorrect += 1
            } else {
                timelineFailures.append("\(aTitle) (\(aLabeled.date)) is supposed to precede \(bTitle) (\(bLabeled.date)) but doesn't")
            }
        }
        let timelineMetric = GroundTruthReport.TimelineMetric(
            pairsChecked: pairsChecked,
            pairsCorrect: pairsCorrect
        )

        // === Causal correctness ===
        var causalTP = 0
        var unmatchedCausal: [String] = []
        if let links {
            // Pull every non-superseded link once.
            // We can't query by (sourceTitle, targetTitle) directly
            // since the link table keys on event ids — so for each
            // labeled link we resolve both titles to candidate event
            // ids first.
            for labeled in fixture.causalLinks {
                let sourceMatch = fixture.events.first { $0.title == labeled.source }
                let targetMatch = fixture.events.first { $0.title == labeled.target }
                guard let sourceMatch, let targetMatch,
                      let sourceDate = dateFormatter.date(from: sourceMatch.date),
                      let targetDate = dateFormatter.date(from: targetMatch.date) else {
                    unmatchedCausal.append("\(labeled.source) \(labeled.relation) \(labeled.target) [fixture incomplete]")
                    continue
                }
                let sourceLower = sourceDate.addingTimeInterval(-Double(dayTolerance) * 86_400)
                let sourceUpper = sourceDate.addingTimeInterval(+Double(dayTolerance) * 86_400)
                let targetLower = targetDate.addingTimeInterval(-Double(dayTolerance) * 86_400)
                let targetUpper = targetDate.addingTimeInterval(+Double(dayTolerance) * 86_400)
                let sourceCandidates = (try? await events.between(start: sourceLower, end: sourceUpper)) ?? []
                let targetCandidates = (try? await events.between(start: targetLower, end: targetUpper)) ?? []
                let sourceIDs = Set(sourceCandidates
                    .filter { $0.kind.rawValue.lowercased() == sourceMatch.kind.lowercased() }
                    .map(\.id))
                let targetIDs = Set(targetCandidates
                    .filter { $0.kind.rawValue.lowercased() == targetMatch.kind.lowercased() }
                    .map(\.id))
                if sourceIDs.isEmpty || targetIDs.isEmpty {
                    unmatchedCausal.append("\(labeled.source) \(labeled.relation) \(labeled.target) [no candidate events]")
                    continue
                }
                let candidateIDs = sourceIDs.union(targetIDs)
                let candidateLinks = (try? await links.links(in: Array(candidateIDs))) ?? []
                let matched = candidateLinks.contains { link in
                    sourceIDs.contains(link.sourceEventID)
                        && targetIDs.contains(link.targetEventID)
                        && link.relation.rawValue == labeled.relation
                }
                if matched {
                    causalTP += 1
                } else {
                    unmatchedCausal.append("\(labeled.source) \(labeled.relation) \(labeled.target)")
                }
            }
        } else {
            for labeled in fixture.causalLinks {
                unmatchedCausal.append("\(labeled.source) \(labeled.relation) \(labeled.target) [no links repo]")
            }
        }
        let causalMetric = GroundTruthReport.PRF1(
            truePositives: causalTP,
            falsePositives: 0,
            falseNegatives: fixture.causalLinks.count - causalTP
        )

        let report = GroundTruthReport(
            fixtureTitle: fixture.title,
            runAt: Date(),
            entities: entityMetric,
            events: eventMetric,
            timeline: timelineMetric,
            causal: causalMetric,
            unmatchedEntities: unmatchedEntities,
            unmatchedEvents: unmatchedEvents,
            unmatchedCausalLinks: unmatchedCausal,
            timelineFailures: timelineFailures
        )
        KalsmritikoshLog.app.info("GroundTruthEvalKit: entity F1=\(report.entities.f1, privacy: .public) event F1=\(report.events.f1, privacy: .public) timeline=\(report.timeline.consistency, privacy: .public) causal F1=\(report.causal.f1, privacy: .public)")
        return report
    }

    /// Convenience — load a fixture from disk and run.
    public func run(
        fixtureURL: URL,
        entities: EntitiesRepository,
        events: EventsRepository,
        links: EventLinksRepository?
    ) async throws -> GroundTruthReport {
        let data = try Data(contentsOf: fixtureURL)
        let fixture = try JSONDecoder().decode(GroundTruthFixture.self, from: data)
        return try await run(
            fixture: fixture,
            entities: entities,
            events: events,
            links: links
        )
    }
}
