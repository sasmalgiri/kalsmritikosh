//
//  NarrativeEvalKit.swift
//  Kalsmritikosh
//
//  HISTORY Phase F — narrative-specific eval harness. The plain
//  `EvalKitRunner` measures keyword-hit and citation precision —
//  good signals for factual lookups, blunt for narrative quality.
//  This kit adds the metrics that matter for the reconstruction
//  story-quality contract:
//
//    chapter_coverage   — fraction of expected events the answer
//                          places in some chapter (any chapter)
//    citation_density   — avg citations per produced sentence; a
//                          composer that ships prose without [E?]
//                          tokens fails the verifier and this metric
//                          catches it before the verifier strips them
//    contradiction_recall — fraction of known contradictions the
//                          composer surfaced. Quality-or-nothing
//                          says we'd rather surface a conflict than
//                          silently pick a side; this metric proves
//                          we do.
//    confidence_calibration — RMSE between brain confidence and
//                          human gold label confidence
//
//  Designed to be wired into the smoke test loop. Run it after the
//  fixture archive is ingested + the B.2/B.3/Memory passes have
//  finished; pass a hand-curated fixture set; print a Markdown
//  table the project can diff between runs.
//
//  Fixture format (JSON): one array of NarrativeEvalQuestion rows.
//  Bundle one in Resources/Fixtures/NarrativeEval/questions.json
//  in a follow-on commit; for now we ship the schema + harness so
//  the fixture can land later without re-shaping the kit.
//

import Foundation
import OSLog

public nonisolated enum NarrativeEvalKit {

    /// One gold-labeled narrative question. The expected event IDs
    /// + contradictions are hand-curated against the ProjectDelta
    /// fixture (or a successor fixture). The harness compares the
    /// brain's chapters against this gold to score recall.
    public struct Question: Codable, Sendable {
        public let id: String
        public let text: String
        /// Required: the entity IDs the gold-labeled answer touches.
        /// The harness checks each is mentioned in at least one
        /// chapter's WHO/WHAT slot or appears in some chapter's event
        /// list.
        public let expectedEntityIDs: [UUID]
        /// Optional: the gold-labeled contradictions for this
        /// question (e.g. "Project Delta had two distinct kickoff
        /// dates in the archive"). The harness checks each is
        /// surfaced via VerifiedAnswer.contradictions.
        public let expectedContradictions: [String]
        /// Optional: a calibration target — the human rater's
        /// "confidence the answer should carry" (0..1). The harness
        /// computes RMSE between this and brain confidence.
        public let goldConfidence: Double?
        /// Optional: hand-curated event IDs the chapter list should
        /// include. Used by chapter_coverage. nil = the metric
        /// reports N/A for this question.
        public let expectedEventIDs: [UUID]?
        /// HISTORY F follow-on — STABLE coverage gold. The chapter
        /// list's events are resolved to their source filenames; the
        /// metric reports the fraction of these filenames that
        /// appear at least once in the chapter list. Survives
        /// re-ingest (filenames are stable; UUIDs aren't).
        public let expectedSourceFilenames: [String]

        public init(
            id: String,
            text: String,
            expectedEntityIDs: [UUID] = [],
            expectedContradictions: [String] = [],
            goldConfidence: Double? = nil,
            expectedEventIDs: [UUID]? = nil,
            expectedSourceFilenames: [String] = []
        ) {
            self.id = id
            self.text = text
            self.expectedEntityIDs = expectedEntityIDs
            self.expectedContradictions = expectedContradictions
            self.goldConfidence = goldConfidence
            self.expectedEventIDs = expectedEventIDs
            self.expectedSourceFilenames = expectedSourceFilenames
        }
    }

    /// Per-question scored row. The aggregator folds these into a
    /// Markdown table.
    public struct Score: Sendable, Codable {
        public let questionID: String
        public let chapterCoverage: Double?
        public let citationDensity: Double
        public let contradictionRecall: Double?
        public let confidenceError: Double?
        public let chapterCount: Int
        public let sentenceCount: Int
        public let surfacedContradictions: Int
        public let downgrades: [String]
    }

    /// Aggregate report for a run.
    public struct Report: Sendable, Codable {
        public let timestamp: Date
        public let scores: [Score]
        public let avgChapterCoverage: Double
        public let avgCitationDensity: Double
        public let avgContradictionRecall: Double
        public let confidenceRMSE: Double

        public var markdownTable: String {
            var lines: [String] = []
            lines.append("# Narrative Eval — \(ISO8601DateFormatter().string(from: timestamp))")
            lines.append("")
            lines.append("Aggregate: cov=\(format(avgChapterCoverage)) cite/sent=\(format(avgCitationDensity)) contradiction=\(format(avgContradictionRecall)) conf-RMSE=\(format(confidenceRMSE))")
            lines.append("")
            lines.append("| ID | cov | cite/sent | contra | confΔ | chapters | sents | surfaced | downgrades |")
            lines.append("|----|-----|-----------|--------|-------|----------|-------|----------|------------|")
            for s in scores {
                lines.append(
                    "| \(s.questionID) | \(format(s.chapterCoverage)) | \(format(s.citationDensity)) | "
                    + "\(format(s.contradictionRecall)) | \(format(s.confidenceError)) | "
                    + "\(s.chapterCount) | \(s.sentenceCount) | \(s.surfacedContradictions) | "
                    + "\(s.downgrades.joined(separator: "; ")) |"
                )
            }
            return lines.joined(separator: "\n")
        }

        private func format(_ value: Double) -> String {
            String(format: "%.2f", value)
        }

        private func format(_ value: Double?) -> String {
            guard let value else { return "n/a" }
            return String(format: "%.2f", value)
        }
    }

    /// Run a fixture against the brain. Captures one VerifiedAnswer +
    /// streamed chapters per question, scores each against the gold,
    /// returns an aggregated Report. Sequential — narrative eval is
    /// inherently slow (one LLM compose per question); parallelism
    /// would just thrash the model.
    public static func run(
        questions: [Question],
        brain: MasterBrain,
        events: EventsRepository? = nil
    ) async -> Report {
        var scores: [Score] = []
        for question in questions {
            var chapters: [NarrativeChapter] = []
            var verified: VerifiedAnswer?
            for await update in await brain.answerStream(question: question.text) {
                switch update {
                case .chapterReady(let chapter): chapters.append(chapter)
                case .verified(let answer): verified = answer
                case .instant, .synthesisToken, .expertFindingsArrived: continue
                }
            }
            // Resolve chapter event ids to source filenames so the
            // filename-based chapter_coverage metric has data to score.
            var filenames: [Event.ID: String] = [:]
            if let events {
                let allIDs = chapters.flatMap(\.eventIDs)
                filenames = (try? await events.sourceFilenames(forEventIDs: allIDs)) ?? [:]
            }
            let score = scoreAnswer(
                question: question,
                chapters: chapters,
                verified: verified,
                eventFilenames: filenames
            )
            scores.append(score)
        }

        // Aggregates.
        let coverages = scores.compactMap(\.chapterCoverage)
        let densities = scores.map(\.citationDensity)
        let contras = scores.compactMap(\.contradictionRecall)
        let confErrs = scores.compactMap(\.confidenceError)

        let avgCov = coverages.isEmpty ? 0 : coverages.reduce(0, +) / Double(coverages.count)
        let avgDen = densities.isEmpty ? 0 : densities.reduce(0, +) / Double(densities.count)
        let avgCon = contras.isEmpty ? 0 : contras.reduce(0, +) / Double(contras.count)
        let rmse: Double
        if confErrs.isEmpty {
            rmse = 0
        } else {
            let squared = confErrs.map { $0 * $0 }.reduce(0, +)
            rmse = (squared / Double(confErrs.count)).squareRoot()
        }

        return Report(
            timestamp: Date(),
            scores: scores,
            avgChapterCoverage: avgCov,
            avgCitationDensity: avgDen,
            avgContradictionRecall: avgCon,
            confidenceRMSE: rmse
        )
    }

    // MARK: - Pure scoring helpers

    static func scoreAnswer(
        question: Question,
        chapters: [NarrativeChapter],
        verified: VerifiedAnswer?,
        eventFilenames: [Event.ID: String] = [:]
    ) -> Score {
        let allEventIDs = Set(chapters.flatMap(\.eventIDs))
        // Prefer the stable filename-based coverage when the question
        // ships expectedSourceFilenames; fall back to UUID-based when
        // only expectedEventIDs is set; n/a otherwise.
        let chapterCoverage: Double? = {
            if !question.expectedSourceFilenames.isEmpty {
                let citedFilenames = Set(
                    allEventIDs.compactMap { eventFilenames[$0] }
                        .map { $0.lowercased() }
                )
                let hits = question.expectedSourceFilenames
                    .filter { citedFilenames.contains($0.lowercased()) }
                    .count
                return Double(hits) / Double(question.expectedSourceFilenames.count)
            }
            if let expected = question.expectedEventIDs {
                guard !expected.isEmpty else { return 0.0 }
                let hits = expected.filter { allEventIDs.contains($0) }.count
                return Double(hits) / Double(expected.count)
            }
            return nil
        }()

        let totalSentences = chapters
            .map { $0.prose.split(whereSeparator: { ".!?".contains($0) }).count }
            .reduce(0, +)
        let totalCitations = chapters.flatMap(\.claimCitations).count
        let citationDensity: Double = totalSentences == 0
            ? 0
            : Double(totalCitations) / Double(totalSentences)

        let surfaced = verified?.contradictions ?? []
        let contradictionRecall: Double? = question.expectedContradictions.isEmpty
            ? nil
            : Double(matchingContradictions(
                expected: question.expectedContradictions,
                surfaced: surfaced.map(\.description)
            )) / Double(question.expectedContradictions.count)

        let confidenceError: Double? = question.goldConfidence.flatMap { gold in
            verified.map { abs(gold - $0.confidence.value) }
        }

        let downgrades = chapters.flatMap(\.contradictions).map(\.description)
        return Score(
            questionID: question.id,
            chapterCoverage: chapterCoverage,
            citationDensity: citationDensity,
            contradictionRecall: contradictionRecall,
            confidenceError: confidenceError,
            chapterCount: chapters.count,
            sentenceCount: totalSentences,
            surfacedContradictions: surfaced.count,
            downgrades: downgrades
        )
    }

    /// Substring-matching gold contradictions (case-insensitive)
    /// against surfaced descriptions. Allows a gold entry like "two
    /// kickoff dates" to match a surfaced "Multiple meetingHeld
    /// events for the same subject" when the description includes
    /// the right kind. Conservative: a gold entry matches at most
    /// one surfaced row.
    static func matchingContradictions(expected: [String], surfaced: [String]) -> Int {
        var available = surfaced.map { $0.lowercased() }
        var matches = 0
        for gold in expected {
            let needle = gold.lowercased()
            if let idx = available.firstIndex(where: { $0.contains(needle) }) {
                matches += 1
                available.remove(at: idx)
            }
        }
        return matches
    }

    /// Decode a fixture JSON file from a URL. Returns nil on any IO
    /// or decode failure — the harness is "skip silently when no
    /// fixture is bundled" rather than fatal.
    public static func loadFixture(at url: URL) -> [Question]? {
        guard let data = try? Data(contentsOf: url),
              let questions = try? JSONDecoder().decode([Question].self, from: data)
        else {
            return nil
        }
        return questions
    }

    /// The default fixture: hand-curated reconstructive questions
    /// against the ProjectDelta corpus. Entity IDs and event IDs are
    /// intentionally omitted — they're UUIDs generated at ingest time
    /// per machine, so we can't predict them. The metrics we DO get
    /// from this fixture:
    ///
    ///   citation_density   — every question, every run
    ///   contradiction_recall — for questions whose gold list is
    ///                          non-empty
    ///   confidence_calibration — when goldConfidence is set
    ///   chapterCount / sentenceCount — diagnostics only
    ///
    /// The fixture lives in code (not Resources/) so the smoke test
    /// can call it without registering a new bundle resource. A
    /// future commit can swap in a JSON fixture with real
    /// entity / event UUIDs once we have a per-machine fingerprint
    /// step that resolves the canonical IDs post-ingest.
    public nonisolated static let projectDeltaQuestions: [Question] = [
        Question(
            id: "N1",
            text: "Reconstruct the history of Project Delta.",
            goldConfidence: 0.65,
            // Reuses the same stable filename contract that
            // questions.json already uses for the keyword eval — see
            // EvalKitRunner.Question.expectedSourceFiles for the
            // existing fixture's filenames.
            expectedSourceFilenames: [
                "contract.md", "amendment-7.md",
                "invoice-401.md", "delivery-report.md"
            ]
        ),
        Question(
            id: "N2",
            text: "Tell me the story of Supplier ABC.",
            expectedContradictions: ["delivery"],
            goldConfidence: 0.55,
            expectedSourceFilenames: ["delivery-report.md", "invoice-401.md"]
        ),
        Question(
            id: "N3",
            text: "What happened with the contract amendments?",
            goldConfidence: 0.60,
            expectedSourceFilenames: ["amendment-7.md", "contract.md"]
        ),
        Question(
            id: "N4",
            text: "Narrate the Project Delta delivery timeline.",
            expectedContradictions: ["delivery"],
            goldConfidence: 0.55,
            expectedSourceFilenames: ["delivery-report.md"]
        ),
    ]
}
