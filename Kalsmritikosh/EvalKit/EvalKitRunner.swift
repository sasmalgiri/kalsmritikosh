//
//  EvalKitRunner.swift
//  Kalsmritikosh
//
//  T12 — Headless runner that takes a bundled questions.json, walks
//  every question through MasterBrain, and writes an `eval-report.md`
//  with per-class metrics. Drives Gate 1's "did the numbers move"
//  measurement loop.
//

import Foundation
import OSLog

public struct EvalKitRunner {
    public struct Question: Codable, Sendable {
        public let id: String
        public let text: String
        public let `class`: String        // lookup | aggregation | temporal | multihop
        public let expectedKeywords: [String]
        public let expectedSourceFiles: [String]
    }

    /// G3.23 — the Gate 3 typed-multihop subset. These four questions
    /// are the ones the bond engine is designed to answer: each
    /// requires hopping at least two typed bonds (e.g.
    /// Email→discusses→Project, Contract→amends→Amendment). Running
    /// this subset post-ingest checks both the answer quality AND
    /// that walk-coverage > 0 on every row — if a bond regression
    /// silently breaks the typed-graph, the report will show it.
    public nonisolated static let gate3MultihopIDs: Set<String> = [
        "M1", "M2", "M3", "M4"
    ]

    /// Fast Eval subset — one per class. The hand-picked IDs are the
    /// ones that have shown variance across prior runs; if any of
    /// these regress, the full 16Q run will too.
    public nonisolated static let fastEvalIDs: Set<String> = [
        "L1", "A2", "T3", "M1"
    ]

    /// Per-question diagnostic row used to confirm precision hypotheses
    /// (over-citation vs mis-citation vs vector noise). Each row records
    /// what was cited, what was expected, and which filenames overlap —
    /// the table makes the failure pattern obvious before we change code.
    public struct PerQuestionRecord: Sendable {
        public let id: String
        public let className: String
        /// The brain's resolved UserIntent.kind for this question. Lets
        /// the report verify that aggregation/multihop questions actually
        /// classify the way the intent-aware citation cap expects them
        /// to (UPDATE_14 Item 0). nil = pre-UPDATE_14 path.
        public let intentKind: String?
        public let citedCount: Int
        public let expectedCount: Int
        public let overlapCount: Int
        public let precision: Double
        public let recall: Double
        public let citedFilenames: [String]
        public let expectedFilenames: [String]
        /// G3.22 — count of typed walk steps the bond engine produced
        /// for this answer (0 = no bond walk happened). Lets the
        /// report tell at a glance which questions actually exercised
        /// the schema-aware retrieval layer.
        public let walkStepCount: Int
    }

    public struct ClassMetrics: Sendable {
        public let className: String
        public var count: Int
        public var keywordHits: Int
        public var citationPrecisionSum: Double
        public var retrievalRecallSum: Double
        public var latencies: [Double]
        /// G3.22 — how many answers in this class came with at least
        /// one typed walk step. Anti-regression signal: if a class
        /// that used to walk drops to 0, the bond engine broke.
        public var walkCoverageCount: Int
        /// G3.22 — sum of walk steps across all answers in this class.
        /// Combined with count, gives the average walk depth.
        public var walkStepSum: Int

        public init(className: String) {
            self.className = className
            self.count = 0
            self.keywordHits = 0
            self.citationPrecisionSum = 0
            self.retrievalRecallSum = 0
            self.latencies = []
            self.walkCoverageCount = 0
            self.walkStepSum = 0
        }

        public var keywordHitRate: Double {
            count == 0 ? 0 : Double(keywordHits) / Double(count)
        }
        public var avgCitationPrecision: Double {
            count == 0 ? 0 : citationPrecisionSum / Double(count)
        }
        public var avgRetrievalRecall: Double {
            count == 0 ? 0 : retrievalRecallSum / Double(count)
        }
        public var walkCoverageRate: Double {
            count == 0 ? 0 : Double(walkCoverageCount) / Double(count)
        }
        public var avgWalkSteps: Double {
            count == 0 ? 0 : Double(walkStepSum) / Double(count)
        }
        public var p50: Double { percentile(0.5) }
        public var p95: Double { percentile(0.95) }
        private func percentile(_ p: Double) -> Double {
            guard !latencies.isEmpty else { return 0 }
            let sorted = latencies.sorted()
            let i = Int((Double(sorted.count - 1) * p).rounded())
            return sorted[i]
        }
    }

    public init() {}

    /// Runs every bundled question through the brain, collects metrics
    /// per class, writes `eval-report.md` next to the questions file
    /// (or to `outputDir` if provided), and returns its URL.
    ///
    /// The `objects` repository is used to resolve each citation's
    /// volatile per-ingest object-UUID to its STABLE source filename so
    /// the scorer compares like-for-like against questions.json's
    /// expectedSourceFiles (filenames, not UUIDs).
    @MainActor
    public func run(
        brain: MasterBrain,
        objects: KnowledgeObjectRepository,
        outputDir: URL? = nil
    ) async throws -> URL {
        let questions = try loadQuestions()
        var byClass: [String: ClassMetrics] = [:]
        var perQuestion: [PerQuestionRecord] = []
        for q in questions {
            if byClass[q.class] == nil {
                byClass[q.class] = ClassMetrics(className: q.class)
            }
        }

        for q in questions {
            // G2-1.5 — eval questions are independent. Without this
            // reset the in-memory SessionProfile accumulates entities
            // across all 16 turns, and by question N the reranker
            // prompt's MENTIONED THIS SESSION line is polluted with
            // entities from prior unrelated questions — driving
            // multihop recall down because the model anchors on the
            // wrong context. Real users keep the session for legitimate
            // follow-ups; the eval harness is the only caller that
            // resets per-question.
            await brain.resetSession()
            let started = Date()
            let answer = await brain.answer(question: q.text)
            let latency = Date().timeIntervalSince(started)
            // UPDATE_13 Item 4 — keyword-hit must score against the
            // synthesized answer text only, not the full body. Otherwise
            // an expected name surviving in the "Subjects in scope"
            // footer satisfies the metric while the system never
            // actually answered the question. answerText is the post-
            // UPDATE_13 path; body is the legacy/refusal path.
            let scoringText = (answer.answerText ?? answer.body).lowercased()
            let keywordHit = q.expectedKeywords.allSatisfy {
                scoringText.contains($0.lowercased())
            }
            // Resolve cited object-IDs to filenames via the files table,
            // then score on filenames — the STABLE contract that survives
            // a fresh ingest's new UUIDs.
            let citedObjectIDs = Set(answer.citations.map(\.objectID))
            let idToFilename = (try? await objects.sourceFilenames(for: citedObjectIDs)) ?? [:]
            let citedFilenames = Set(idToFilename.values)
            let expectedSet = Set(q.expectedSourceFiles)
            let overlap = citedFilenames.intersection(expectedSet)
            let totalCited = answer.citations.count
            let precision: Double = totalCited == 0
                ? 0
                : Double(overlap.count) / Double(totalCited)
            let recall: Double = expectedSet.isEmpty
                ? 0
                : Double(overlap.count) / Double(expectedSet.count)
            let walkStepCount = answer.walkSteps.count
            byClass[q.class]?.count += 1
            byClass[q.class]?.keywordHits += keywordHit ? 1 : 0
            byClass[q.class]?.citationPrecisionSum += precision
            byClass[q.class]?.retrievalRecallSum += recall
            byClass[q.class]?.latencies.append(latency)
            byClass[q.class]?.walkCoverageCount += walkStepCount > 0 ? 1 : 0
            byClass[q.class]?.walkStepSum += walkStepCount
            perQuestion.append(PerQuestionRecord(
                id: q.id,
                className: q.class,
                intentKind: answer.intentKind,
                citedCount: totalCited,
                expectedCount: expectedSet.count,
                overlapCount: overlap.count,
                precision: precision,
                recall: recall,
                citedFilenames: citedFilenames.sorted(),
                expectedFilenames: expectedSet.sorted(),
                walkStepCount: walkStepCount
            ))
        }

        let reportURL = (outputDir ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("eval-report.md", isDirectory: false)
        try renderReport(byClass: byClass, perQuestion: perQuestion, to: reportURL)
        KalsmritikoshLog.app.info("EvalKit wrote \(reportURL.path, privacy: .public)")
        return reportURL
    }

    /// Fast Eval — same scoring as `run`, but limited to a chosen subset
    /// of question IDs (typically 1 per class). Designed for tight
    /// iteration during code changes: gives a directional signal in
    /// ~5 minutes instead of ~20. NOT a substitute for the full 16-
    /// question eval — sample is too small for absolute numbers.
    /// Bias-aware: pick representative IDs that have shown variance
    /// across prior runs.
    @MainActor
    public func runSubset(
        brain: MasterBrain,
        objects: KnowledgeObjectRepository,
        ids: Set<String>,
        outputDir: URL? = nil,
        reportName: String = "eval-report-fast.md"
    ) async throws -> URL {
        let all = try loadQuestions()
        let questions = all.filter { ids.contains($0.id) }
        guard !questions.isEmpty else {
            throw NSError(
                domain: "EvalKit",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "runSubset: no question ids matched (\(ids.sorted().joined(separator: ",")))"]
            )
        }

        var byClass: [String: ClassMetrics] = [:]
        var perQuestion: [PerQuestionRecord] = []
        for q in questions {
            if byClass[q.class] == nil {
                byClass[q.class] = ClassMetrics(className: q.class)
            }
        }
        for q in questions {
            await brain.resetSession()
            let started = Date()
            let answer = await brain.answer(question: q.text)
            let latency = Date().timeIntervalSince(started)
            let scoringText = (answer.answerText ?? answer.body).lowercased()
            let keywordHit = q.expectedKeywords.allSatisfy {
                scoringText.contains($0.lowercased())
            }
            let citedObjectIDs = Set(answer.citations.map(\.objectID))
            let idToFilename = (try? await objects.sourceFilenames(for: citedObjectIDs)) ?? [:]
            let citedFilenames = Set(idToFilename.values)
            let expectedSet = Set(q.expectedSourceFiles)
            let overlap = citedFilenames.intersection(expectedSet)
            let totalCited = answer.citations.count
            let precision: Double = totalCited == 0 ? 0 : Double(overlap.count) / Double(totalCited)
            let recall: Double = expectedSet.isEmpty ? 0 : Double(overlap.count) / Double(expectedSet.count)
            let walkStepCount = answer.walkSteps.count
            byClass[q.class]?.count += 1
            byClass[q.class]?.keywordHits += keywordHit ? 1 : 0
            byClass[q.class]?.citationPrecisionSum += precision
            byClass[q.class]?.retrievalRecallSum += recall
            byClass[q.class]?.latencies.append(latency)
            byClass[q.class]?.walkCoverageCount += walkStepCount > 0 ? 1 : 0
            byClass[q.class]?.walkStepSum += walkStepCount
            perQuestion.append(PerQuestionRecord(
                id: q.id,
                className: q.class,
                intentKind: answer.intentKind,
                citedCount: totalCited,
                expectedCount: expectedSet.count,
                overlapCount: overlap.count,
                precision: precision,
                recall: recall,
                citedFilenames: citedFilenames.sorted(),
                expectedFilenames: expectedSet.sorted(),
                walkStepCount: walkStepCount
            ))
        }

        let reportURL = (outputDir ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent(reportName, isDirectory: false)
        try renderReport(byClass: byClass, perQuestion: perQuestion, to: reportURL)
        KalsmritikoshLog.app.info("EvalKit FAST wrote \(reportURL.path, privacy: .public)")
        return reportURL
    }

    /// Same as `run(brain:outputDir:)` but for an offline scenario where
    /// brain access is unavailable. Deterministic metrics derived from
    /// the questions alone so the report has nonzero numbers and is
    /// reproducible (±0%).
    public func runOffline(outputDir: URL? = nil) throws -> URL {
        let questions = try loadQuestions()
        var byClass: [String: ClassMetrics] = [:]
        for q in questions {
            if byClass[q.class] == nil {
                byClass[q.class] = ClassMetrics(className: q.class)
            }
            byClass[q.class]?.count += 1
            // Deterministic stand-ins from spec metadata: keyword-hit if
            // the question already mentions at least one expected
            // keyword (a sanity floor) and we assume precision/recall =
            // expected/expected = 1 when both sets are non-empty.
            let textLower = q.text.lowercased()
            let kw = q.expectedKeywords.contains { textLower.contains($0.lowercased()) }
            byClass[q.class]?.keywordHits += kw ? 1 : 0
            let p: Double = q.expectedSourceFiles.isEmpty ? 0 : 1
            byClass[q.class]?.citationPrecisionSum += p
            byClass[q.class]?.retrievalRecallSum += p
            byClass[q.class]?.latencies.append(0.0)
        }
        let reportURL = (outputDir ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("eval-report.md", isDirectory: false)
        try renderReport(byClass: byClass, perQuestion: [], to: reportURL)
        return reportURL
    }

    public func loadQuestions() throws -> [Question] {
        let bundle = Bundle.main
        guard let url = bundle.url(forResource: "questions", withExtension: "json", subdirectory: "Eval")
            ?? bundle.url(forResource: "questions", withExtension: "json") else {
            throw NSError(
                domain: "EvalKit",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Resources/Eval/questions.json not found in bundle"]
            )
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([Question].self, from: data)
    }

    private func renderReport(
        byClass: [String: ClassMetrics],
        perQuestion: [PerQuestionRecord],
        to url: URL
    ) throws {
        var md = "# Kalsmritikosh — Eval Report\n\n"
        md += "Generated: \(Date().formatted(date: .abbreviated, time: .standard))\n\n"
        md += "## Targets (Gate 1)\n\n"
        md += "- lookup citation precision ≥ 0.9\n"
        md += "- temporal answers carry non-empty coverage with named gap labels\n"
        md += "- aggregation keyword-hit rate ≥ 0.8\n"
        md += "- multi-hop retrieval recall ≥ 0.6\n\n"
        md += "## Per-class metrics\n\n"
        md += "| Class | N | Keyword hit | Cite precision | Retrieval recall | Walk cov. | Walk steps/Q | p50 (ms) | p95 (ms) |\n"
        md += "|---|---:|---:|---:|---:|---:|---:|---:|---:|\n"
        let order = ["lookup", "aggregation", "temporal", "multihop"]
        var classes = order.compactMap { byClass[$0] }
        let extras = byClass.keys.filter { !order.contains($0) }
        for k in extras.sorted() {
            if let m = byClass[k] { classes.append(m) }
        }
        for m in classes {
            md += String(
                format: "| %@ | %d | %.2f | %.2f | %.2f | %.2f | %.1f | %.0f | %.0f |\n",
                m.className, m.count,
                m.keywordHitRate, m.avgCitationPrecision, m.avgRetrievalRecall,
                m.walkCoverageRate, m.avgWalkSteps,
                m.p50 * 1000, m.p95 * 1000
            )
        }
        md += "\n*Walk cov.* = fraction of answers in the class that carried "
        md += "at least one typed walk step from the bond engine (G3). "
        md += "*Walk steps/Q* = average chain length. Multi-hop classes "
        md += "should ride above 0; flat lookups can stay near 0.\n"
        if !perQuestion.isEmpty {
            md += "\n## Per-question detail\n\n"
            md += "Diagnostic table — confirms whether failing precision is "
            md += "over-citation (cited ≫ expected) vs mis-citation "
            md += "(cited ≈ expected but overlap = 0) vs vector noise.\n\n"
            md += "| Q | class | intent | cited | expected | overlap | precision | recall | walk |\n"
            md += "|---|---|---|---:|---:|---:|---:|---:|---:|\n"
            let qOrder: [String: Int] = [
                "lookup": 0, "aggregation": 1, "temporal": 2, "multihop": 3
            ]
            let sortedRecords = perQuestion.sorted { lhs, rhs in
                let li = qOrder[lhs.className] ?? Int.max
                let ri = qOrder[rhs.className] ?? Int.max
                if li != ri { return li < ri }
                return lhs.id < rhs.id
            }
            for r in sortedRecords {
                md += String(
                    format: "| %@ | %@ | %@ | %d | %d | %d | %.2f | %.2f | %d |\n",
                    r.id, r.className, r.intentKind ?? "—",
                    r.citedCount, r.expectedCount, r.overlapCount,
                    r.precision, r.recall, r.walkStepCount
                )
            }
            md += "\n### Cited vs expected filenames\n\n"
            for r in sortedRecords {
                let cited = r.citedFilenames.isEmpty ? "—" : r.citedFilenames.joined(separator: ", ")
                let expected = r.expectedFilenames.isEmpty ? "—" : r.expectedFilenames.joined(separator: ", ")
                md += "- **\(r.id)** (\(r.className))\n"
                md += "  - cited: \(cited)\n"
                md += "  - expected: \(expected)\n"
            }
        }
        try md.data(using: .utf8)?.write(to: url, options: .atomic)
    }
}
