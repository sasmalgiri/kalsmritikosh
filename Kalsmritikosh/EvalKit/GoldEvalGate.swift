//
//  GoldEvalGate.swift
//  Kalsmritikosh
//
//  A0.8 / P6.1 — the regression guard around the 60-question gold set.
//
//  The problem it solves: EvalKitRunner produces per-class numbers, but a
//  human reading "cite precision 0.71" can't tell whether that's a regression
//  or just how the system has always scored. Before we start rewriting the
//  retrieval path (evidence-first authority, RRF, independent vector channel),
//  we need a tripwire that says PASS/FAIL against a recorded baseline — so any
//  change that quietly drops recall on the gold set is caught immediately.
//
//  Design: snapshot-regression, NOT hand-picked thresholds.
//    • First run with no baseline on disk → the current metrics ARE the
//      baseline; we persist them and PASS ("baseline established").
//    • Every later run → compare each per-class metric to the baseline; FAIL
//      if any drops by more than `tolerance` (default 0.05). Improvements are
//      reported but never fail.
//
//  This means the gate is green today (whatever the system currently scores)
//  and only turns red when a code change makes retrieval measurably worse —
//  exactly what a regression guard should do. Tighten by re-baselining after a
//  proven improvement (delete the baseline file, or call `establish`).
//

import Foundation

/// One class's three headline metrics, in [0, 1].
public struct GoldEvalClassScore: Codable, Sendable, Hashable {
    public let keywordHitRate: Double
    public let citationPrecision: Double
    public let retrievalRecall: Double

    public init(keywordHitRate: Double, citationPrecision: Double, retrievalRecall: Double) {
        self.keywordHitRate = keywordHitRate
        self.citationPrecision = citationPrecision
        self.retrievalRecall = retrievalRecall
    }
}

/// The persisted baseline: per-class scores plus a little provenance.
public struct GoldEvalBaseline: Codable, Sendable {
    public var version: Int
    public var establishedAt: Date
    public var questionCount: Int
    public var byClass: [String: GoldEvalClassScore]

    public init(version: Int = 1, establishedAt: Date, questionCount: Int, byClass: [String: GoldEvalClassScore]) {
        self.version = version
        self.establishedAt = establishedAt
        self.questionCount = questionCount
        self.byClass = byClass
    }
}

public enum GoldEvalGate {

    /// A per-class metric may drop by at most this much vs the baseline before
    /// the run counts as a regression. Absorbs LLM sampling jitter; a real
    /// retrieval regression moves numbers far more than this.
    public static let defaultTolerance: Double = 0.05

    public struct Verdict: Sendable {
        public let passed: Bool
        public let establishedNewBaseline: Bool
        /// Human-readable regression lines, e.g.
        /// "multihop.retrievalRecall 0.62 → 0.41 (−0.21, tol 0.05)".
        public let regressions: [String]
        /// Improvements worth celebrating (never fail the gate).
        public let improvements: [String]
        public let currentByClass: [String: GoldEvalClassScore]
        public let baselineByClass: [String: GoldEvalClassScore]

        public func renderMarkdown() -> String {
            var md = "## Gold-eval regression gate\n\n"
            if establishedNewBaseline {
                md += "**Status:** ⓘ BASELINE ESTABLISHED — no prior baseline on disk; "
                md += "the current run was recorded as the reference. Re-run to compare.\n\n"
            } else {
                md += passed
                    ? "**Status:** ✓ PASS — no class regressed beyond tolerance.\n\n"
                    : "**Status:** ✗ FAIL — a class regressed beyond tolerance.\n\n"
            }
            if !regressions.isEmpty {
                md += "### Regressions\n\n"
                for r in regressions { md += "- ✗ \(r)\n" }
                md += "\n"
            }
            if !improvements.isEmpty {
                md += "### Improvements\n\n"
                for i in improvements { md += "- ▲ \(i)\n" }
                md += "\n"
            }
            md += "### Current vs baseline\n\n"
            md += "| class | metric | baseline | current | Δ |\n|---|---|---:|---:|---:|\n"
            for cls in currentByClass.keys.sorted() {
                guard let cur = currentByClass[cls] else { continue }
                let base = baselineByClass[cls]
                func row(_ name: String, _ b: Double?, _ c: Double) -> String {
                    let bStr = b.map { String(format: "%.2f", $0) } ?? "—"
                    let dStr = b.map { String(format: "%+.2f", c - $0) } ?? "—"
                    return "| \(cls) | \(name) | \(bStr) | \(String(format: "%.2f", c)) | \(dStr) |\n"
                }
                md += row("keywordHit", base?.keywordHitRate, cur.keywordHitRate)
                md += row("citePrecision", base?.citationPrecision, cur.citationPrecision)
                md += row("retrievalRecall", base?.retrievalRecall, cur.retrievalRecall)
            }
            return md
        }
    }

    /// Project an EvalKitRunner metric map into the gate's compact score map.
    public static func scores(
        from byClass: [String: EvalKitRunner.ClassMetrics]
    ) -> [String: GoldEvalClassScore] {
        var out: [String: GoldEvalClassScore] = [:]
        for (name, m) in byClass {
            out[name] = GoldEvalClassScore(
                keywordHitRate: m.keywordHitRate,
                citationPrecision: m.avgCitationPrecision,
                retrievalRecall: m.avgRetrievalRecall
            )
        }
        return out
    }

    /// Compare current scores to an optional baseline. Pure — unit-testable
    /// with no filesystem. When `baseline` is nil, the verdict marks a fresh
    /// baseline (caller decides whether to persist it).
    public static func evaluate(
        current: [String: GoldEvalClassScore],
        baseline: GoldEvalBaseline?,
        tolerance: Double = defaultTolerance
    ) -> Verdict {
        guard let baseline else {
            return Verdict(
                passed: true,
                establishedNewBaseline: true,
                regressions: [],
                improvements: [],
                currentByClass: current,
                baselineByClass: [:]
            )
        }
        var regressions: [String] = []
        var improvements: [String] = []
        for cls in current.keys.sorted() {
            guard let cur = current[cls], let base = baseline.byClass[cls] else { continue }
            let checks: [(String, Double, Double)] = [
                ("keywordHit", base.keywordHitRate, cur.keywordHitRate),
                ("citePrecision", base.citationPrecision, cur.citationPrecision),
                ("retrievalRecall", base.retrievalRecall, cur.retrievalRecall)
            ]
            for (name, b, c) in checks {
                let delta = c - b
                if delta < -tolerance {
                    regressions.append(String(
                        format: "%@.%@ %.2f → %.2f (%.2f, tol %.2f)",
                        cls, name, b, c, delta, tolerance
                    ))
                } else if delta > tolerance {
                    improvements.append(String(
                        format: "%@.%@ %.2f → %.2f (+%.2f)",
                        cls, name, b, c, delta
                    ))
                }
            }
        }
        return Verdict(
            passed: regressions.isEmpty,
            establishedNewBaseline: false,
            regressions: regressions,
            improvements: improvements,
            currentByClass: current,
            baselineByClass: baseline.byClass
        )
    }

    // MARK: - Persistence

    /// Standard on-disk name for the baseline snapshot.
    public static let baselineFileName = "eval-baseline.json"

    public static func loadBaseline(from url: URL) -> GoldEvalBaseline? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.iso8601.decode(GoldEvalBaseline.self, from: data)
    }

    @discardableResult
    public static func saveBaseline(_ baseline: GoldEvalBaseline, to url: URL) -> Bool {
        guard let data = try? JSONEncoder.iso8601Pretty.encode(baseline) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

private extension JSONEncoder {
    static var iso8601Pretty: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}
