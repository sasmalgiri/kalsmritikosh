//
//  AnswerHarness.swift
//  Kalsmritikosh
//
//  C-1 — the answer side of the validation chain. The Ingestion Report says
//  what arrived; the Golden Thread says one document is reachable; this asks
//  whether the machinery actually ANSWERS, with citations, and — the part that
//  matters more — whether it correctly REFUSES when it should.
//
//  WHY THE QUESTIONS ARE DERIVED FROM THE LEDGER, NOT FIXED IN CODE. A fixed
//  literal question set ("what is the contract value?") cannot work here: the
//  archive is the user's own and unknown to us, so a fixed set would abstain on
//  everything and prove nothing except that abstention works. Worse, it would
//  look like a failing harness on a perfectly healthy archive, which is the
//  kind of false alarm that gets a check switched off.
//
//  So the harness reads the ledger and builds questions it KNOWS have evidence:
//  a real entity's name, a real subject-field pair, a real year. Each one is
//  answerable in principle, so an abstention on any of them is a genuine
//  retrieval or composition failure rather than an honest "I don't know".
//
//  AND THEN THE CONTROL. Questions derived from the ledger can only ever test
//  the happy path — every one has evidence by construction, so passing them all
//  is consistent with a system that answers ANYTHING, including things it has no
//  evidence for. That is the worst possible defect in an evidence-gated product
//  and the derived set cannot detect it. So the harness also asks about
//  something provably absent: a random token that cannot appear in any archive.
//  An ANSWER to that is the most serious result this file can produce, and it is
//  reported above everything else.
//
//  THREE FAILURE CLASSES, kept separate because they mean different things:
//
//    fabrication  — answered the control question. The evidence gate is not
//                   holding. Nothing else in the report matters until this is
//                   fixed.
//    uncited      — answered a real question with ZERO citations. The claim–
//                   evidence contract is violated: the answer may even be
//                   right, but the user cannot check it and we cannot show
//                   where it came from.
//    unreachable  — abstained on a question built from the ledger's own
//                   contents. The evidence exists; retrieval could not find it.
//
//  A harness that reported one number ("7/10 passed") would blend a fabrication
//  into the same figure as a missed retrieval, and those are not comparable.
//
//  Read-only with respect to the ledger. Costs real model calls, so it is
//  bounded and run only on request.
//

import Foundation
import os

public enum AnswerHarness {

    /// One probe and what came back.
    public struct Probe: Sendable {
        public enum Expectation: String, Sendable {
            /// Built from the ledger — evidence exists, so an answer is expected.
            case shouldAnswer
            /// Provably absent — a refusal is the CORRECT outcome.
            case shouldRefuse
        }
        public let question: String
        public let derivedFrom: String
        public let expectation: Expectation
        public let refused: Bool
        public let answerLength: Int
        public let citationCount: Int
        public let confidence: Double
        public let conflicts: Int
        public let llmCalls: Int
        public let seconds: Double
        public let answerSource: String

        /// What this probe PROVES, in the three separated classes.
        public var verdict: String {
            switch expectation {
            case .shouldRefuse:
                return refused ? "correctly refused" : "FABRICATION — answered with no evidence available"
            case .shouldAnswer:
                if refused { return "UNREACHABLE — abstained on its own ledger's content" }
                if citationCount == 0 { return "UNCITED — answered with zero citations" }
                return "answered, \(citationCount) citation(s)"
            }
        }

        public var isFabrication: Bool {
            expectation == .shouldRefuse && !refused
        }
        public var isUncited: Bool {
            expectation == .shouldAnswer && !refused && citationCount == 0
        }
        public var isUnreachable: Bool {
            expectation == .shouldAnswer && refused
        }
        public var isClean: Bool { !isFabrication && !isUncited && !isUnreachable }
    }

    public struct Result: Sendable {
        public let reportURL: URL
        public let probes: [Probe]
        public let skipReason: String?

        public var fabrications: [Probe] { probes.filter(\.isFabrication) }
        public var uncited: [Probe] { probes.filter(\.isUncited) }
        public var unreachable: [Probe] { probes.filter(\.isUnreachable) }

        public var summary: String {
            if let skipReason { return "Not run — \(skipReason)" }
            guard !probes.isEmpty else { return "No probes could be built." }
            var lines: [String] = []
            if !fabrications.isEmpty {
                lines.append("⚠️ \(fabrications.count) FABRICATION(S) — answered without evidence")
            }
            if !uncited.isEmpty { lines.append("⚠️ \(uncited.count) answered with no citations") }
            if !unreachable.isEmpty { lines.append("⚠️ \(unreachable.count) abstained on its own content") }
            if lines.isEmpty {
                lines.append("✓ \(probes.count) probe(s): answers cited, refusals correct")
            }
            let avg = probes.map(\.seconds).reduce(0, +) / Double(probes.count)
            lines.append(String(format: "avg %.1fs · %d LLM call(s) total",
                                avg, probes.map(\.llmCalls).reduce(0, +)))
            return lines.joined(separator: "\n")
        }
    }

    // MARK: - Run

    /// Build probes from the ledger, ask them, and report.
    ///
    /// `maxDerivedProbes` bounds the cost: each probe is a real answer with real
    /// model calls, and an unbounded harness over a large archive would run for
    /// a very long time and teach nothing the first few probes did not.
    @MainActor
    public static func run(_ state: AppState, maxDerivedProbes: Int = 5) async throws -> Result {
        guard let database = state.database else {
            throw NSError(domain: "AnswerHarness", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "AppState is not booted."])
        }
        let brain = state.brain

        // A ledger with nothing in it cannot produce derived probes, and saying
        // "0 failures" about an empty archive would be the emptiest possible
        // pass. Skip explicitly instead.
        let koCount = (try? await database.query(
            "SELECT COUNT(*) FROM knowledge_objects;", []).first?.int(0)) ?? 0
        guard (koCount ?? 0) > 0 else {
            let url = try write("# Answer Harness\n\nNot run: nothing is ingested, so no "
                              + "question could be built from the ledger. This is not a pass.\n")
            return Result(reportURL: url, probes: [],
                          skipReason: "nothing is ingested, so no question could be built")
        }

        var questions: [(q: String, from: String)] = []

        // ── derived probe 1: a real entity, by name ──────────────────────────
        // Ordered by mention count so the subject is one the archive genuinely
        // discusses. A one-mention entity would make a weak probe whose failure
        // says more about thresholds than about the pipeline.
        if let rows = try? await database.query("""
            SELECT e.value, COUNT(m.id) AS n FROM entities e
            JOIN entity_mentions m ON m.entity_id = e.id
            WHERE e.merged_into IS NULL AND LENGTH(e.value) >= 4
            GROUP BY e.id ORDER BY n DESC, e.value ASC LIMIT 2;
            """, []) {
            for r in rows {
                guard let name = r.string(0) else { continue }
                questions.append((q: "What do we know about \(name)?",
                                  from: "entity “\(name)” (\(Int(r.int(1) ?? 0)) mentions)"))
            }
        }

        // ── derived probe 2: a real subject-field pair ───────────────────────
        // The sharpest derived probe: a specific value that IS in the ledger, so
        // the answer can be checked for containing it.
        if let rows = try? await database.query("""
            SELECT subject_label, field, value FROM generic_facts
            WHERE LENGTH(subject_label) >= 4 AND LENGTH(value) >= 2
            ORDER BY COALESCE(source_count, 1) DESC, field ASC LIMIT 2;
            """, []) {
            for r in rows {
                guard let subject = r.string(0), let field = r.string(1) else { continue }
                questions.append((q: "What is the \(field.replacingOccurrences(of: "_", with: " ")) of \(subject)?",
                                  from: "fact \(field)=\(r.string(2) ?? "?") on “\(subject)”"))
            }
        }

        // ── derived probe 3: a real year from the timeline ───────────────────
        if let rows = try? await database.query("""
            SELECT CAST(strftime('%Y', date, 'unixepoch') AS TEXT) AS y, COUNT(*) AS n
            FROM events GROUP BY y ORDER BY n DESC LIMIT 1;
            """, []), let year = rows.first?.string(0) {
            questions.append((q: "What happened in \(year)?",
                              from: "\(Int(rows.first?.int(1) ?? 0)) event(s) dated \(year)"))
        }

        questions = Array(questions.prefix(maxDerivedProbes))

        var probes: [Probe] = []
        // The SAME access context the Ask surface uses. A harness that granted
        // itself wider access than the real UI would pass on evidence the user
        // can never reach, which would make its "answered, cited" verdicts
        // unearned.
        let access = SensitiveAccessContext(scope: .globalOwnerRetrieval())

        for item in questions {
            probes.append(await ask(brain: brain, question: item.q, from: item.from,
                                    expectation: .shouldAnswer, access: access))
        }

        // ── THE CONTROL ─────────────────────────────────────────────────────
        //
        // A token no archive can contain. Deliberately shaped like a plausible
        // reference so the question reads as a real one — asking "what is
        // Zzqx?" would be refused by any sanity check on the INPUT rather than
        // by the evidence gate, and would therefore prove nothing about the
        // gate. The suffix is random per run so a cached answer cannot satisfy
        // it either.
        let absentToken = "Case No. \(Int.random(in: 70_000_000...79_999_999))-ZQX"
        probes.append(await ask(
            brain: brain,
            question: "What was decided in \(absentToken)?",
            from: "a reference generated at random — it CANNOT exist in any archive",
            expectation: .shouldRefuse, access: access))

        // ── Report ──────────────────────────────────────────────────────────
        let result = Result(reportURL: try write(render(probes)), probes: probes, skipReason: nil)
        KalsmritikoshLog.app.info("AnswerHarness: \(probes.count, privacy: .public) probe(s), \(result.fabrications.count, privacy: .public) fabrication(s), \(result.uncited.count, privacy: .public) uncited, \(result.unreachable.count, privacy: .public) unreachable")
        return result
    }

    // MARK: - One probe

    @MainActor
    private static func ask(
        brain: MasterBrain, question: String, from: String,
        expectation: Probe.Expectation, access: SensitiveAccessContext
    ) async -> Probe {
        let started = Date()
        let d = await brain.answerWithDiagnostics(question: question, access: access)
        let a = d.answer
        return Probe(
            question: question,
            derivedFrom: from,
            expectation: expectation,
            refused: a.refused,
            answerLength: (a.answerText ?? a.body).count,
            citationCount: a.citations.count,
            confidence: a.confidence.value,
            conflicts: a.contradictions.count,
            llmCalls: d.llmCalls,
            seconds: Date().timeIntervalSince(started),
            answerSource: String(describing: a.source))
    }

    // MARK: - Rendering

    private static func render(_ probes: [Probe]) -> String {
        var md = "# Answer Harness — does the machinery answer, and does it refuse?\n\n"
        md += "Generated: \(Date().formatted(date: .abbreviated, time: .standard))\n"
        md += "Build `\(BuildIdentity.gitSHA)` · schema v\(SchemaMigrations.latestVersion)\n\n"
        md += "Questions are DERIVED FROM YOUR LEDGER, not fixed in code: a fixed set\n"
        md += "would abstain on every archive it was not written for and prove nothing.\n"
        md += "Each derived question has evidence by construction, so an abstention on\n"
        md += "one is a real retrieval failure rather than an honest \"I don't know\".\n\n"

        let fabrications = probes.filter(\.isFabrication)
        if !fabrications.isEmpty {
            md += "## ⚠️ FABRICATION — the evidence gate is not holding\n\n"
            md += "The control question asks about a reference generated at random, which\n"
            md += "cannot exist in any archive. It was ANSWERED. Nothing else in this\n"
            md += "report matters until this is fixed: an evidence-gated product that\n"
            md += "answers without evidence has lost the property it is built on.\n\n"
            for p in fabrications {
                md += "- “\(p.question)” → \(p.answerLength) characters, \(p.citationCount) citation(s)\n"
            }
            md += "\n"
        } else if probes.contains(where: { $0.expectation == .shouldRefuse }) {
            md += "## ✓ The evidence gate holds\n\n"
            md += "A question about a randomly generated reference was correctly refused.\n"
            md += "This is ONE control, not a proof of universal abstention.\n\n"
        }

        let uncited = probes.filter(\.isUncited)
        if !uncited.isEmpty {
            md += "## ⚠️ Answered with no citations (\(uncited.count))\n\n"
            md += "The claim–evidence contract is that every claim carries the evidence\n"
            md += "supporting it. These answers may even be correct — but the user cannot\n"
            md += "check them and we cannot show where they came from.\n\n"
            for p in uncited { md += "- “\(p.question)”\n" }
            md += "\n"
        }

        let unreachable = probes.filter(\.isUnreachable)
        if !unreachable.isEmpty {
            md += "## ⚠️ Abstained on its own content (\(unreachable.count))\n\n"
            md += "Each of these was built FROM the ledger, so the evidence provably\n"
            md += "exists. Retrieval could not find it — the document is stored and\n"
            md += "unreachable, which from the user's side is the same as absent.\n\n"
            for p in unreachable {
                md += "- “\(p.question)” — built from \(p.derivedFrom)\n"
            }
            md += "\n"
        }

        md += "## Every probe\n\n"
        md += "| question | expected | outcome | cites | conf | conflicts | calls | secs |\n"
        md += "|---|---|---|---:|---:|---:|---:|---:|\n"
        for p in probes {
            md += "| \(p.question) | \(p.expectation == .shouldRefuse ? "refuse" : "answer") "
            md += "| \(p.verdict) | \(p.citationCount) | \(String(format: "%.2f", p.confidence)) "
            md += "| \(p.conflicts) | \(p.llmCalls) | \(String(format: "%.1f", p.seconds)) |\n"
        }
        md += "\n### Where each question came from\n\n"
        for p in probes { md += "- “\(p.question)” ← \(p.derivedFrom)\n" }
        md += "\n"

        md += "## What this does NOT tell you\n\n"
        md += "- **Whether the answers are CORRECT.** It checks that an answer exists, is\n"
        md += "  cited, and that a baseless question is refused. It does not read the\n"
        md += "  answer and compare it against the source.\n"
        md += "- **Whether the answers are COMPLETE.** An answer citing one document when\n"
        md += "  five were relevant passes every check here.\n"
        md += "- **That abstention always works.** One control question proves the gate\n"
        md += "  held once, for one shape of question.\n"
        return md
    }

    private static func write(_ md: String) throws -> URL {
        let documentsDir = try FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let reportDir = documentsDir.appendingPathComponent("EvalBaselines", isDirectory: true)
        try? FileManager.default.createDirectory(at: reportDir, withIntermediateDirectories: true)
        let url = reportDir.appendingPathComponent("answer-harness.md", isDirectory: false)
        try md.data(using: .utf8)?.write(to: url, options: .atomic)
        return url
    }
}
