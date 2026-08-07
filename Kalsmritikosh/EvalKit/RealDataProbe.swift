//
//  RealDataProbe.swift
//  Kalsmritikosh
//
//  The fixture evals (Gate1Baseline / ReleaseReadiness) boot an ISOLATED temp
//  DB and ask about the bundled ProjectDelta sample so they can score citation
//  precision/recall against gold labels. They never touch the user's real
//  archive.
//
//  This probe is the complement: it runs a handful of questions against the
//  LIVE AppState (the user's actual ingested ledger, READ-ONLY) and reports,
//  per question — wall-clock latency, LLM-call count (via the provider-boundary
//  LLMCallCounters), citation count, and WHICH of the user's real files were
//  cited. It proves the adaptive minimum-LLM budget on real data.
//
//  It deliberately does NOT score correctness: the user's documents have no
//  gold answers, so "was the answer right" is an eyeball check on the Ask tab,
//  not a number here. What it measures is cost + grounding on real data.
//
//  Questions come from (in priority order):
//    1. A user-authored `EvalBaselines/real-questions.txt` (one per line), or
//    2. Auto-generated from the archive's top real entities + a couple of
//       archive-wide questions.
//

import Foundation
import OSLog

public enum RealDataProbe {

    public struct QuestionResult: Sendable {
        public let question: String
        public let latencySeconds: Double
        public let llmCalls: Int
        public let callLimit: Int
        public let queryClass: String
        public let purposes: [String]
        public let citationCount: Int
        public let citedFiles: [String]
        public let confidence: Double
        public let answerState: String
        public let path: String
        public let refused: Bool
        /// True when the request spent MORE calls than its class ceiling —
        /// a hard-budget violation that must never happen.
        public var overBudget: Bool { llmCalls > callLimit }
    }

    public struct Result: Sendable {
        public let reportURL: URL?
        public let results: [QuestionResult]
        public let totalSeconds: Double
        public let totalCalls: Int
        public var questionCount: Int { results.count }
        public var avgCallsPerQuestion: Double {
            results.isEmpty ? 0 : Double(totalCalls) / Double(results.count)
        }
        public var avgLatencySeconds: Double {
            results.isEmpty ? 0 : results.map(\.latencySeconds).reduce(0, +) / Double(results.count)
        }
    }

    /// Run the probe against the live archive. READ-ONLY: it only asks
    /// questions; it never ingests, distills, or writes to the ledger.
    @MainActor
    public static func run(_ appState: AppState, maxQuestions: Int = 6) async -> Result {
        let start = Date()
        let brain = appState.brain
        let questions = await buildQuestions(appState: appState, limit: maxQuestions)

        var results: [QuestionResult] = []
        var totalCalls = 0

        for q in questions {
            // Independent questions — don't let turn N inherit turn N-1's
            // session entities (mirrors the eval harness contract).
            await brain.resetSession()

            // Request-scoped diagnostics: calls attributed to THIS question's
            // request ID (immune to background generation), plus its class
            // ceiling and the actual purposes spent (§14).
            let t0 = Date()
            let diag = await brain.answerWithDiagnostics(question: q, access: SensitiveAccessContext(scope: .globalOwnerRetrieval()))
            let elapsed = Date().timeIntervalSince(t0)
            let answer = diag.answer
            let calls = diag.llmCalls
            totalCalls += calls

            // Resolve each citation's KnowledgeObject back to the real source
            // filename so the user can see grounding points at their own files.
            var files: [String] = []
            if let objects = appState.objects {
                var seen = Set<String>()
                for c in answer.citations {
                    if let url = try? await objects.fetchSourceURL(id: c.objectID) {
                        let name = url.lastPathComponent
                        if seen.insert(name).inserted { files.append(name) }
                    }
                }
            }

            results.append(QuestionResult(
                question: q,
                latencySeconds: elapsed,
                llmCalls: calls,
                callLimit: diag.callLimit,
                queryClass: diag.queryClass,
                purposes: diag.purposes,
                citationCount: answer.citations.count,
                citedFiles: files,
                confidence: answer.confidence.value,
                answerState: String(describing: answer.answerState),
                path: answer.reasoningTrace?.pathTaken ?? "—",
                refused: answer.refused
            ))

            KalsmritikoshLog.app.info("RealDataProbe: \"\(q, privacy: .public)\" → \(calls, privacy: .public) LLM call(s), \(String(format: "%.1f", elapsed), privacy: .public)s, \(answer.citations.count, privacy: .public) citation(s)")
        }

        let total = Date().timeIntervalSince(start)
        let url = try? writeReport(results: results, totalSeconds: total, totalCalls: totalCalls)
        return Result(reportURL: url, results: results, totalSeconds: total, totalCalls: totalCalls)
    }

    // MARK: - Question construction

    private static func buildQuestions(appState: AppState, limit: Int) async -> [String] {
        // 1. A user-authored question list wins outright.
        if let userQs = loadUserQuestions(), !userQs.isEmpty {
            return Array(userQs.prefix(limit))
        }

        // 2. Auto-generate from the archive's top real entities.
        var qs: [String] = []
        if let entities = await appState.entities {
            let projects = (try? await entities.list(kind: .project, limit: 4))?.map(\.value) ?? []
            let orgs = (try? await entities.list(kind: .organization, limit: 4))?.map(\.value) ?? []
            let people = (try? await entities.list(kind: .person, limit: 4))?.map(\.value) ?? []
            for p in projects.prefix(2) { qs.append("What do the documents say about \(p)?") }
            for o in orgs.prefix(2) { qs.append("What is \(o)'s role across these documents?") }
            for pe in people.prefix(2) { qs.append("What do the records show about \(pe)?") }
        }
        // Always include a couple of archive-wide questions so the probe still
        // has something to ask on a sparsely-typed ledger.
        qs.append("What are the most important events in this archive?")
        qs.append("Are there any contradictions across the documents?")

        var seen = Set<String>()
        var out: [String] = []
        for q in qs where seen.insert(q).inserted { out.append(q) }
        return Array(out.prefix(limit))
    }

    /// Optional user override: `EvalBaselines/real-questions.txt`, one question
    /// per line. Lines that are empty or start with `#` are ignored.
    private static func loadUserQuestions() -> [String]? {
        guard let dir = try? FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ) else { return nil }
        let url = dir.appendingPathComponent("EvalBaselines/real-questions.txt")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let lines = text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        return lines.isEmpty ? nil : lines
    }

    // MARK: - Report

    private static func writeReport(
        results: [QuestionResult],
        totalSeconds: Double,
        totalCalls: Int
    ) throws -> URL {
        let documentsDir = try FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let reportDir = documentsDir.appendingPathComponent("EvalBaselines", isDirectory: true)
        try FileManager.default.createDirectory(at: reportDir, withIntermediateDirectories: true)
        let url = reportDir.appendingPathComponent("real-data-probe.md")

        let avgCalls = results.isEmpty ? 0 : Double(totalCalls) / Double(results.count)
        let avgLatency = results.isEmpty ? 0 : results.map(\.latencySeconds).reduce(0, +) / Double(results.count)

        var md = """
        # Kalsmritikosh — Real-Data Probe

        Runs questions against YOUR live archive (read-only) — not the ProjectDelta \
        fixture. Measures cost + grounding on real data; it does NOT score \
        correctness (no gold answers exist for your documents — eyeball those on \
        the Ask tab).

        - Questions: \(results.count)
        - Total LLM calls: \(totalCalls)  (avg \(String(format: "%.1f", avgCalls)) / question)
        - Avg latency: \(String(format: "%.1f", avgLatency))s / question
        - Total runtime: \(String(format: "%.1f", totalSeconds))s

        Budget target (adaptive minimum-LLM): ordinary question 1 call, moderate 2, \
        complex ≤3, investigation ≤5.

        ## Per-question

        | # | Class | Calls/Limit | Latency | Cites | Conf | State | Question |
        |---:|---|---:|---:|---:|---:|---|---|

        """
        for (i, r) in results.enumerated() {
            let confPct = String(format: "%.2f", r.confidence)
            let q = r.question.replacingOccurrences(of: "|", with: "\\|")
            let budget = "\(r.llmCalls)/\(r.callLimit)\(r.overBudget ? " ⚠️OVER" : "")"
            md += "| \(i + 1) | \(r.queryClass) | \(budget) | \(String(format: "%.1f", r.latencySeconds))s | \(r.citationCount) | \(confPct) | \(r.answerState) | \(q) |\n"
        }

        let violations = results.filter(\.overBudget).count
        md += "\n**Hard-budget check:** \(violations == 0 ? "✅ every question stayed within its class ceiling" : "⚠️ \(violations) question(s) EXCEEDED their ceiling — investigate")\n"

        md += "\n## LLM purposes per question\n\n"
        for (i, r) in results.enumerated() {
            let p = r.purposes.isEmpty ? "_(0 calls)_" : r.purposes.joined(separator: ", ")
            md += "- **Q\(i + 1)** (\(r.queryClass)) — \(p)\n"
        }

        md += "\n## Cited files (grounding points in your archive)\n\n"
        for (i, r) in results.enumerated() {
            let files = r.citedFiles.isEmpty
                ? (r.refused ? "_(refused — no grounding)_" : "_(no resolvable source files)_")
                : r.citedFiles.joined(separator: ", ")
            md += "- **Q\(i + 1)** — \(files)\n"
        }

        try md.data(using: .utf8)?.write(to: url, options: .atomic)
        return url
    }
}
