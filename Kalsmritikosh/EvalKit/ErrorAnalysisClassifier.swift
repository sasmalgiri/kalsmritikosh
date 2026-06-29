//
//  ErrorAnalysisClassifier.swift
//  Kalsmritikosh
//
//  Phase J.12 — Vol 29 §Error Analysis. Tags eval failures into a
//  short, mutually-exclusive category list so the operator can see
//  the failure-mode distribution at a glance rather than reading
//  every unmatched item in the report:
//
//      missedEntity            — labeled entity not present in
//                                the entities table at all.
//      incorrectMerge          — labeled entity present but
//                                with the wrong kind (suggests an
//                                entity-linker over-merge).
//      timelineError           — labeled event pair ordering
//                                disagrees with the ledger.
//      causalError             — labeled causal link missing or
//                                stamped with the wrong relation.
//      unsupportedConclusion   — answer body contains a claim
//                                whose cited evidence didn't
//                                resolve in the retrieval set.
//      provenanceGap           — labeled event exists but the
//                                evidence trail back to its source
//                                KO is broken (no chunks, no
//                                source object).
//
//  Input is the GroundTruthReport plus optional ProvenanceTracer
//  hits per labeled event — the classifier emits a histogram +
//  per-item categorized list.
//

import Foundation

public struct ErrorAnalysisReport: Sendable {
    public let histogram: [String: Int]   // category rawValue → count
    public let items: [Item]
    public let runAt: Date

    public struct Item: Sendable {
        public let category: Category
        public let summary: String
    }

    public enum Category: String, Codable, Sendable, CaseIterable {
        case missedEntity            = "missed_entity"
        case incorrectMerge          = "incorrect_merge"
        case timelineError           = "timeline_error"
        case causalError             = "causal_error"
        case unsupportedConclusion   = "unsupported_conclusion"
        case provenanceGap           = "provenance_gap"

        public var humanLabel: String {
            switch self {
            case .missedEntity:          return "Missed entity"
            case .incorrectMerge:        return "Incorrect merge"
            case .timelineError:         return "Timeline error"
            case .causalError:           return "Causal error"
            case .unsupportedConclusion: return "Unsupported conclusion"
            case .provenanceGap:         return "Provenance gap"
            }
        }
    }

    public func renderMarkdown() -> String {
        var md = ""
        md += "# Error analysis\n\n"
        md += "_Ran \(runAt.formatted(date: .abbreviated, time: .standard))._\n\n"
        md += "## Histogram\n\n"
        md += "| Category | Count |\n|---|---:|\n"
        for category in Category.allCases {
            let count = histogram[category.rawValue] ?? 0
            if count > 0 {
                md += "| \(category.humanLabel) | \(count) |\n"
            }
        }
        if items.isEmpty {
            md += "\n_All checks passed._\n"
            return md
        }
        md += "\n## Failures\n\n"
        for category in Category.allCases {
            let bucket = items.filter { $0.category == category }
            if bucket.isEmpty { continue }
            md += "### \(category.humanLabel) (\(bucket.count))\n\n"
            for item in bucket {
                md += "- \(item.summary)\n"
            }
            md += "\n"
        }
        return md
    }
}

public struct ErrorAnalysisClassifier: Sendable {
    public init() {}

    /// Classify every unmatched item from a GroundTruthReport into
    /// one of the six failure modes. Operates on the report's
    /// already-enumerated lists — no DB calls needed.
    public func classify(report: GroundTruthReport) -> ErrorAnalysisReport {
        var items: [ErrorAnalysisReport.Item] = []
        var histogram: [String: Int] = [:]

        for entity in report.unmatchedEntities {
            // Heuristic: when the value contains a "(<kind>)" suffix
            // the unmatched probably indicates either missing
            // entirely (most common) OR a kind mismatch. Without
            // probing the DB we default to missedEntity; the
            // operator can re-run with deeper checks.
            items.append(
                ErrorAnalysisReport.Item(
                    category: .missedEntity,
                    summary: "Entity not in ledger: \(entity)"
                )
            )
            histogram[ErrorAnalysisReport.Category.missedEntity.rawValue, default: 0] += 1
        }
        for event in report.unmatchedEvents {
            if event.contains("[unparseable date") {
                items.append(
                    ErrorAnalysisReport.Item(
                        category: .provenanceGap,
                        summary: "Fixture has malformed date: \(event)"
                    )
                )
                histogram[ErrorAnalysisReport.Category.provenanceGap.rawValue, default: 0] += 1
            } else {
                items.append(
                    ErrorAnalysisReport.Item(
                        category: .missedEntity,
                        summary: "Event not in ledger: \(event)"
                    )
                )
                histogram[ErrorAnalysisReport.Category.missedEntity.rawValue, default: 0] += 1
            }
        }
        for failure in report.timelineFailures {
            items.append(
                ErrorAnalysisReport.Item(
                    category: .timelineError,
                    summary: failure
                )
            )
            histogram[ErrorAnalysisReport.Category.timelineError.rawValue, default: 0] += 1
        }
        for link in report.unmatchedCausalLinks {
            if link.contains("[no candidate events]") || link.contains("[fixture incomplete]") {
                items.append(
                    ErrorAnalysisReport.Item(
                        category: .provenanceGap,
                        summary: link
                    )
                )
                histogram[ErrorAnalysisReport.Category.provenanceGap.rawValue, default: 0] += 1
            } else {
                items.append(
                    ErrorAnalysisReport.Item(
                        category: .causalError,
                        summary: link
                    )
                )
                histogram[ErrorAnalysisReport.Category.causalError.rawValue, default: 0] += 1
            }
        }
        return ErrorAnalysisReport(histogram: histogram, items: items, runAt: Date())
    }

    /// Convenience — classify a single VerifiedAnswer's quality
    /// report. Surfaces `unsupportedConclusion` when the
    /// ConfidenceReport recorded dropped LLM claims. Used by the
    /// SmokeTest tab so per-question failures get categorized
    /// alongside fixture failures.
    public func classify(verifiedAnswer: VerifiedAnswer) -> ErrorAnalysisReport {
        var items: [ErrorAnalysisReport.Item] = []
        var histogram: [String: Int] = [:]
        if let report = verifiedAnswer.report, report.droppedUnverifiable > 0 {
            for _ in 0..<report.droppedUnverifiable {
                items.append(
                    ErrorAnalysisReport.Item(
                        category: .unsupportedConclusion,
                        summary: "LLM claim dropped — cited evidence didn't resolve."
                    )
                )
            }
            histogram[ErrorAnalysisReport.Category.unsupportedConclusion.rawValue] = report.droppedUnverifiable
        }
        if verifiedAnswer.citations.isEmpty && !verifiedAnswer.refused {
            items.append(
                ErrorAnalysisReport.Item(
                    category: .provenanceGap,
                    summary: "Answer has no citations — no evidence trail."
                )
            )
            histogram[ErrorAnalysisReport.Category.provenanceGap.rawValue, default: 0] += 1
        }
        for contradiction in verifiedAnswer.contradictions {
            items.append(
                ErrorAnalysisReport.Item(
                    category: .causalError,
                    summary: contradiction.description
                )
            )
            histogram[ErrorAnalysisReport.Category.causalError.rawValue, default: 0] += 1
        }
        return ErrorAnalysisReport(histogram: histogram, items: items, runAt: Date())
    }
}
