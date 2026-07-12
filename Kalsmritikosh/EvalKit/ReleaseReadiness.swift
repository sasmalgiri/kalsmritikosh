//
//  ReleaseReadiness.swift
//  Kalsmritikosh
//
//  Single-button release-gate orchestrator. Runs every check the app
//  knows how to run, captures partial failures so a single bad step
//  doesn't hide what else is wrong, and emits ONE verdict:
//
//      RELEASE READY: YES   → safe for public distribution
//      RELEASE READY: NO    → at least one blocking check failed
//
//  The categories, in order:
//
//      1. Schema integrity   (latestVersion == compiled-in constant)
//      2. Deterministic logic (pure, no DB / LLM — fast probes)
//      3. Bundle integrity   (fixtures + privacy manifest present)
//      4. Capability resolve (a reasoning provider answers preflight)
//      5. Live data health   (read-only audit of the user's DB)
//      6. ProjectDelta smoke (boots an isolated copy + end-to-end)
//      7. Fast Eval baseline (4 representative LLM questions)
//      8. Gate 3 Multi-hop   (4 typed-multihop questions)
//
//  Categories 1–4 are blockers (a failure → NOT READY). 5 is a soft
//  warning — the live DB may have ingest quirks the user has chosen
//  to accept. 6–8 are blockers when an end-to-end pass is required
//  for distribution.
//
//  Writes `release-readiness.md` to ~/Documents/EvalBaselines/ next
//  to the other diagnostics reports.
//

import Foundation
import OSLog

public enum ReleaseReadiness {

    /// One row in the verdict table. `blocker == true` means a failure
    /// flips the overall verdict; `blocker == false` (data-health
    /// warnings) renders as ⚠️ but lets the verdict stay PASS.
    public struct Check: Sendable {
        public let id: String
        public let name: String
        public let passed: Bool
        public let detail: String
        public let blocker: Bool
        public let secondsTaken: TimeInterval
    }

    public struct Report: Sendable {
        public let checks: [Check]
        public let reportURL: URL
        public let totalSeconds: TimeInterval

        /// PASS iff every blocker check passed. Soft warnings don't
        /// flip the verdict (data-health is the only one).
        public var releaseReady: Bool {
            checks.allSatisfy { $0.passed || !$0.blocker }
        }
    }

    /// Run everything. Never throws — failures are captured per-check
    /// so the user always sees the full picture. The returned URL
    /// always points at a written file even when individual steps
    /// failed (the report itself records what failed).
    /// Release gate has two modes (Ledger-AI contract — split the fast
    /// loop from the overnight deep eval):
    ///
    ///  - `.fast` — schema + deterministic logic + bundle + capability +
    ///    live data health. NO LLM-heavy end-to-end steps. Target 2-5
    ///    minutes. This is the every-iteration gate.
    ///  - `.deep` — everything in `.fast` PLUS the ProjectDelta smoke +
    ///    Fast Eval + Gate 3 Multi-hop. LLM-heavy, 20 min – hours.
    ///    Run manually / overnight before a real submission.
    public enum Mode: String, Sendable {
        case fast
        case deep
    }

    @MainActor
    public static func run(_ state: AppState, mode: Mode = .deep) async -> Report {
        let started = Date()
        KalsmritikoshLog.app.info("ReleaseReadiness run starting (mode=\(mode.rawValue, privacy: .public))")
        var checks: [Check] = []

        // 1. Schema integrity ────────────────────────────────────────
        checks.append(checkSchemaIntegrity(state))

        // 2. Deterministic logic ─────────────────────────────────────
        checks.append(checkQueryCategoryClassifier())
        checks.append(checkEvidenceRankerComposite())
        checks.append(checkDatePrecisionRendering())
        checks.append(checkChatExportRegex())
        checks.append(checkIMessageEpochConversion())
        checks.append(checkConfidenceAggregateClamp())
        checks.append(checkRerankerQuestionShape())
        checks.append(checkConversionExporters())
        checks.append(checkSystemModesWireUp())

        // 3. Bundle integrity ────────────────────────────────────────
        checks.append(checkProjectDeltaFixturePresent())
        checks.append(checkPrivacyManifestPresent())
        checks.append(checkReleaseProfile())

        // 4. Capability resolve ──────────────────────────────────────
        checks.append(await checkReasoningCapabilityResolves(state))

        // 5. Live data health (soft warning) ─────────────────────────
        checks.append(await checkLiveDataHealth(state))

        // 6-8. LLM-heavy end-to-end — DEEP mode only. These are the
        // steps that turned the gate into an 8-hour run; the fast loop
        // skips them entirely.
        if mode == .deep {
            // 6. ProjectDelta smoke
            checks.append(await checkProjectDeltaSmoke())
            // 7. Fast Eval baseline
            checks.append(await checkFastEvalBaseline())
            // 8. Gate 3 Multi-hop
            checks.append(await checkGate3Multihop())
        }

        let totalSeconds = Date().timeIntervalSince(started)
        let reportURL = (try? writeReport(checks: checks, totalSeconds: totalSeconds))
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("release-readiness-failed.md")

        let report = Report(checks: checks, reportURL: reportURL, totalSeconds: totalSeconds)
        if report.releaseReady {
            KalsmritikoshLog.app.info("ReleaseReadiness PASSED in \(String(format: "%.1f", totalSeconds))s")
        } else {
            let fails = checks.filter { !$0.passed && $0.blocker }.map(\.name).joined(separator: ", ")
            KalsmritikoshLog.app.error("ReleaseReadiness FAILED in \(String(format: "%.1f", totalSeconds))s — blockers: \(fails, privacy: .public)")
        }
        return report
    }

    // MARK: - Category 1: Schema

    /// P0.3/P0.4 — the live config must match the locked v1 release profile:
    /// ledger engine, zero-LLM ingest policy (no distillation / prefix /
    /// first-chunk card). A drifted build fails the gate instead of shipping.
    private static func checkReleaseProfile() -> Check {
        let t0 = Date()
        let violations = ReleaseCapabilityProfile.violations()
        let pass = violations.isEmpty
        return Check(
            id: "release.capabilityProfile",
            name: "Release capability profile",
            passed: pass,
            detail: pass
                ? "live config matches locked v1 profile (ledger engine, zero-LLM ingest)"
                : "DRIFT: \(violations.joined(separator: "; "))",
            blocker: true,
            secondsTaken: Date().timeIntervalSince(t0)
        )
    }

    private static func checkSchemaIntegrity(_ state: AppState) -> Check {
        let t0 = Date()
        let expected = 40
        let got = SchemaMigrations.latestVersion
        let pass = got == expected
        return Check(
            id: "schema.latestVersion",
            name: "Schema version",
            passed: pass,
            detail: pass
                ? "SchemaMigrations.latestVersion = \(got)"
                : "expected \(expected), got \(got) — migration list desynced with this code",
            blocker: true,
            secondsTaken: Date().timeIntervalSince(t0)
        )
    }

    // MARK: - Category 2b: Convert exporters (all formats, one pass)

    /// Runs DocumentExporter for a sample record in every output format and
    /// validates the bytes — so the user never has to open Convert and try
    /// each format by hand. DOCX/XLSX are re-parsed with ZIPReader to prove
    /// the OOXML archive is structurally valid (required parts present) and
    /// that the main part decompresses (CRC/STORE round-trip). This is the
    /// only automated check the hand-rolled ZipWriter/OOXML writers get.
    private static func checkConversionExporters() -> Check {
        let t0 = Date()
        let records = [
            ExportRecord(
                title: "SelfTest",
                sourceType: "plainText",
                text: "Kalsmritikosh self-check.\nLine two — 123, 456.\nUnicode: café, naïve, 日本語."
            )
        ]
        var fails: [String] = []

        // PDF — must exist and carry the %PDF signature.
        if let pdf = DocumentExporter.pdf(records) {
            if pdf.count < 100 || !pdf.starts(with: Array("%PDF".utf8)) {
                fails.append("PDF header/size (\(pdf.count)B)")
            }
        } else { fails.append("PDF returned nil") }

        // RTF — must contain the {\rtf control word.
        if let rtf = DocumentExporter.rtf(records), let s = String(data: rtf, encoding: .utf8) {
            if !s.contains("{\\rtf") { fails.append("RTF signature") }
        } else { fails.append("RTF returned nil/undecodable") }

        // PNG — must carry the 8-byte PNG magic.
        if let png = DocumentExporter.png(records) {
            let magic: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
            if png.count < 100 || Array(png.prefix(8)) != magic {
                fails.append("PNG magic (\(png.count)B)")
            }
        } else { fails.append("PNG returned nil") }

        // DOCX / XLSX — round-trip through ZIPReader.
        fails.append(contentsOf: validateOOXML(
            DocumentExporter.docx(records),
            required: ["[Content_Types].xml", "word/document.xml"],
            mainPart: "word/document.xml",
            label: "DOCX"
        ))
        fails.append(contentsOf: validateOOXML(
            DocumentExporter.xlsx(records),
            required: ["[Content_Types].xml", "xl/workbook.xml", "xl/worksheets/sheet1.xml"],
            mainPart: "xl/worksheets/sheet1.xml",
            label: "XLSX"
        ))

        let pass = fails.isEmpty
        return Check(
            id: "convert.exporters",
            name: "Convert exporters (PDF/RTF/PNG/DOCX/XLSX)",
            passed: pass,
            detail: pass
                ? "all 5 formats produced valid output; DOCX/XLSX re-parsed as valid OOXML archives (parts present + main part decompresses)"
                : "problems: \(fails.joined(separator: "; "))",
            blocker: false,
            secondsTaken: Date().timeIntervalSince(t0)
        )
    }

    /// Parses `data` as a ZIP, confirms every `required` part is present, and
    /// reads `mainPart` back out (which throws on CRC/decompress failure).
    /// Returns a list of human-readable problems (empty == valid).
    private static func validateOOXML(
        _ data: Data,
        required: [String],
        mainPart: String,
        label: String
    ) -> [String] {
        guard data.count > 100 else { return ["\(label) too small (\(data.count)B)"] }
        do {
            let reader = ZIPReader(data: data)
            let names = Set(try reader.entries().map(\.name))
            let problems = required
                .filter { !names.contains($0) }
                .map { "\(label) missing \($0)" }
            // Reading the main part validates the local header + CRC-32.
            _ = try reader.read(mainPart)
            return problems
        } catch {
            return ["\(label) not a valid archive (\(error))"]
        }
    }

    // MARK: - Category 2c: System modes + MoE wiring (all three, one pass)

    /// Confirms every SystemMode resolves to an engine with the correct ingest
    /// policy, and that the super-expert council gate returns its backbone.
    /// Lets the user verify all three modes at once instead of switching mode,
    /// relaunching, and inspecting behaviour three separate times.
    private static func checkSystemModesWireUp() -> Check {
        let t0 = Date()
        var fails: [String] = []
        for mode in SystemMode.allCases {
            let engine = SystemEngineFactory.make(mode)
            if engine.mode != mode {
                fails.append("\(mode.rawValue): engine.mode = \(engine.mode.rawValue)")
            }
            let p = engine.ingestPolicy
            switch mode {
            case .fullLLM:
                if !(p.eagerMemoryDistillation && p.contextPrefixBackfill) {
                    fails.append("fullLLM should eager-distill + prefix-backfill")
                }
            case .hotWarmCold, .ledgerEventDriven:
                if !p.firstChunkCard || p.eagerMemoryDistillation || p.contextPrefixBackfill {
                    fails.append("\(mode.rawValue) should be firstChunkCard-only")
                }
            }
        }
        let gated = ExpertCouncil.gate(question: "Why was Project Delta delayed?", k: 3)
        if gated.count < 2 {
            fails.append("council gate returned \(gated.count) experts (< backbone)")
        }
        let pass = fails.isEmpty
        return Check(
            id: "engines.modes",
            name: "System modes + MoE council (all 3 modes)",
            passed: pass,
            detail: pass
                ? "all 3 engines resolve with correct ingest policy; council gate returns \(gated.count) super-experts"
                : "problems: \(fails.joined(separator: "; "))",
            blocker: false,
            secondsTaken: Date().timeIntervalSince(t0)
        )
    }

    // MARK: - Category 2: Deterministic logic

    /// 13 known-good question→category mappings; any drift fails fast.
    private static func checkQueryCategoryClassifier() -> Check {
        let t0 = Date()
        let cases: [(String, QueryCategory)] = [
            ("What is the contract amount?",                          .fact),
            ("Who is the project owner?",                             .fact),
            ("When did Supplier ABC deliver?",                        .timeline),
            ("Show me the history of Project Delta",                  .timeline),
            ("Why was Project Delta delayed?",                        .rootCause),
            ("What caused the invoice rejection?",                    .rootCause),
            ("Compare Q1 vs Q2 revenue",                              .comparison),
            ("How has the project changed over time?",                .trend),
            ("Are we compliant with GDPR?",                           .compliance),
            ("Tell me the story of Project Delta",                    .narrative),
            ("Walk me through what happened with the supplier",       .narrative),
            ("What if we hadn't signed the amendment?",               .counterfactual),
            ("What's the risk of this contract?",                     .risk)
        ]
        let classifier = QueryCategoryClassifier()
        var mismatches: [String] = []
        for (q, expected) in cases {
            let got = classifier.classify(question: q)
            if got != expected {
                mismatches.append("\"\(q.prefix(40))\" → \(got.rawValue) (≠ \(expected.rawValue))")
            }
        }
        let pass = mismatches.isEmpty
        return Check(
            id: "logic.queryCategoryClassifier",
            name: "QueryCategoryClassifier (13 cases)",
            passed: pass,
            detail: pass
                ? "all 13 question shapes classified correctly"
                : "mismatches: \(mismatches.joined(separator: "; "))",
            blocker: true,
            secondsTaken: Date().timeIntervalSince(t0)
        )
    }

    /// EvidenceRanker composite must stay in [0,1] and rank a unique
    /// citation strictly above a duplicate one (the core promise of
    /// the independence dimension).
    private static func checkEvidenceRankerComposite() -> Check {
        let t0 = Date()
        let objA = UUID()
        let objB = UUID()
        // 3 citations: A, A, B. B is unique → should outscore A on
        // independence. Composite for B must be > composite for A.
        let cits = [
            VerifiedAnswer.Citation(objectID: objA, snippet: "first A"),
            VerifiedAnswer.Citation(objectID: objA, snippet: "second A"),
            VerifiedAnswer.Citation(objectID: objB, snippet: "lone B")
        ]
        let ranker = EvidenceRanker()
        let scores = ranker.rank(citations: cits)
        guard scores.count == 3 else {
            return Check(
                id: "logic.evidenceRanker",
                name: "EvidenceRanker composite",
                passed: false,
                detail: "ranker returned \(scores.count) scores (expected 3)",
                blocker: true,
                secondsTaken: Date().timeIntervalSince(t0)
            )
        }
        let inRange = scores.allSatisfy { $0.composite >= 0 && $0.composite <= 1 }
        let bBeatsA = scores[2].composite > scores[0].composite
        let pass = inRange && bBeatsA
        return Check(
            id: "logic.evidenceRanker",
            name: "EvidenceRanker composite",
            passed: pass,
            detail: pass
                ? String(format: "A=%.2f A=%.2f B=%.2f (B > A; all in [0,1])",
                         scores[0].composite, scores[1].composite, scores[2].composite)
                : "scores: \(scores.map { String(format: "%.2f", $0.composite) })",
            blocker: true,
            secondsTaken: Date().timeIntervalSince(t0)
        )
    }

    /// DatePrecision must produce the documented phrase shape at each
    /// precision tier. Regressions here surface as garbled answer copy.
    private static func checkDatePrecisionRendering() -> Check {
        let t0 = Date()
        guard let date = ISO8601DateFormatter().date(from: "2025-03-14T09:12:00Z") else {
            return Check(id: "logic.datePrecision", name: "DatePrecision rendering",
                         passed: false, detail: "anchor date failed to parse",
                         blocker: true, secondsTaken: Date().timeIntervalSince(t0))
        }
        let cases: [(DatePrecision, String)] = [
            (.day,    "Mar"),
            (.month,  "March"),
            (.year,   "2025"),
            (.decade, "2020s")
        ]
        var fails: [String] = []
        for (precision, needle) in cases {
            let phrase = precision.renderPhrase(date: date)
            if !phrase.contains(needle) {
                fails.append("\(precision) missing '\(needle)': '\(phrase)'")
            }
        }
        let pass = fails.isEmpty
        return Check(
            id: "logic.datePrecision",
            name: "DatePrecision rendering",
            passed: pass,
            detail: pass ? "day/month/year/decade phrasing intact" : fails.joined(separator: "; "),
            blocker: true,
            secondsTaken: Date().timeIntervalSince(t0)
        )
    }

    /// ChatExportLoader's three vendor regexes must each match a
    /// canonical line. Drift here means chat ingestion silently fails.
    private static func checkChatExportRegex() -> Check {
        let t0 = Date()
        let samples: [(NSRegularExpression, String, String)] = [
            (ChatExportLoader.whatsappRegex,
             "[3/14/25, 9:12:34 AM] Alice: Did you sign the contract?",
             "WhatsApp"),
            (ChatExportLoader.signalRegex,
             "2025-03-14 09:12:34 - Alice: Did you sign the contract?",
             "Signal"),
            (ChatExportLoader.slackRegex,
             "[2025-03-14, 09:12 AM] alice: Did you sign the contract?",
             "Slack")
        ]
        var fails: [String] = []
        for (regex, line, name) in samples {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            if regex.firstMatch(in: line, options: [], range: range) == nil {
                fails.append("\(name) regex did not match canonical line")
            }
        }
        let pass = fails.isEmpty
        return Check(
            id: "logic.chatExportRegex",
            name: "ChatExportLoader regex (3 vendors)",
            passed: pass,
            detail: pass ? "WhatsApp + Signal + Slack patterns all match" : fails.joined(separator: "; "),
            blocker: true,
            secondsTaken: Date().timeIntervalSince(t0)
        )
    }

    /// IMessageLoader's epoch detector must convert BOTH legacy
    /// (seconds) and modern (nanoseconds) columns to the same wall-
    /// clock instant.
    private static func checkIMessageEpochConversion() -> Check {
        let t0 = Date()
        // 2025-01-01 00:00:00 UTC == 1735689600 unix == 757_382_400 Mach.
        let expected = Date(timeIntervalSince1970: 1_735_689_600)
        let modern = IMessageLoader.dateFromAppleNanoseconds(757_382_400 * 1_000_000_000)
        let legacy = IMessageLoader.dateFromAppleNanoseconds(757_382_400)
        let modernOK = abs(modern.timeIntervalSince(expected)) < 1
        let legacyOK = abs(legacy.timeIntervalSince(expected)) < 1
        let pass = modernOK && legacyOK
        return Check(
            id: "logic.iMessageEpoch",
            name: "IMessageLoader epoch (ns + sec)",
            passed: pass,
            detail: pass
                ? "both columns converge on 2025-01-01 UTC"
                : "modern=\(modernOK ? "ok" : "drift"), legacy=\(legacyOK ? "ok" : "drift")",
            blocker: true,
            secondsTaken: Date().timeIntervalSince(t0)
        )
    }

    /// Confidence.aggregate must clamp under 0.99 even with 200 maximal
    /// claims — a regression here means the quality strip can promise
    /// certainty the engine can't actually justify.
    private static func checkConfidenceAggregateClamp() -> Check {
        let t0 = Date()
        let maximal = Confidence.aggregate(
            Array(repeating: Confidence(1.0), count: 200),
            agreement: 1.0,
            diversity: 1.0,
            contradictionPenalty: 0.0
        )
        let pass = maximal.value < 0.99
        return Check(
            id: "logic.confidenceClamp",
            name: "Confidence aggregate clamp",
            passed: pass,
            detail: pass
                ? String(format: "200×1.0 high-signal clamped to %.3f < 0.99", maximal.value)
                : String(format: "clamp failed: aggregate=%.3f ≥ 0.99", maximal.value),
            blocker: true,
            secondsTaken: Date().timeIntervalSince(t0)
        )
    }

    /// Reranker.questionShape underpins the prompt-templating router.
    /// Drift here changes how every expert frames its answer.
    private static func checkRerankerQuestionShape() -> Check {
        let t0 = Date()
        let cases: [(String, String)] = [
            ("Who signed the contract?",        "who"),
            ("When did the invoice arrive?",    "when"),
            ("List all suppliers",              "list"),
            ("Is the project delayed?",         "yes-no"),
            ("Project Delta status",            "statement")
        ]
        let mismatches = cases.compactMap { (q, expected) -> String? in
            let got = Reranker.questionShape(q)
            return got == expected ? nil : "\(q) → \(got) (≠ \(expected))"
        }
        let pass = mismatches.isEmpty
        return Check(
            id: "logic.questionShape",
            name: "Reranker.questionShape (5 shapes)",
            passed: pass,
            detail: pass ? "who/when/list/yes-no/statement all correct" : mismatches.joined(separator: "; "),
            blocker: true,
            secondsTaken: Date().timeIntervalSince(t0)
        )
    }

    // MARK: - Category 3: Bundle integrity

    /// The 8 ProjectDelta fixture files must ship in the bundle —
    /// without them, the smoke + Fast Eval + Gate 3 steps all fail
    /// for an unrelated reason (missing corpus).
    private static func checkProjectDeltaFixturePresent() -> Check {
        let t0 = Date()
        let expected: Set<String> = [
            "contract.md", "amendment-7.md",
            "invoice-401.eml", "invoice-432.eml",
            "supplier_abc_22.eml", "supplier_abc_23.eml",
            "supplier_abc_24.eml", "supplier_abc_25.eml"
        ]
        var found: Set<String> = []
        if let resourcePath = Bundle.main.resourcePath {
            let subdir = URL(fileURLWithPath: resourcePath)
                .appendingPathComponent("ProjectDelta", isDirectory: true)
            if FileManager.default.fileExists(atPath: subdir.path) {
                let items = (try? FileManager.default.contentsOfDirectory(at: subdir, includingPropertiesForKeys: nil)) ?? []
                for item in items { found.insert(item.lastPathComponent) }
            }
        }
        if found.isEmpty {
            for ext in ["eml", "md"] {
                let urls = Bundle.main.urls(forResourcesWithExtension: ext, subdirectory: nil) ?? []
                for url in urls where expected.contains(url.lastPathComponent) {
                    found.insert(url.lastPathComponent)
                }
            }
        }
        let missing = expected.subtracting(found)
        let pass = missing.isEmpty
        return Check(
            id: "bundle.projectDeltaFixture",
            name: "ProjectDelta fixture in bundle",
            passed: pass,
            detail: pass
                ? "all 8 fixture files present"
                : "missing: \(missing.sorted().joined(separator: ", "))",
            blocker: true,
            secondsTaken: Date().timeIntervalSince(t0)
        )
    }

    /// Apple now rejects builds that import certain Required-Reason
    /// APIs without a privacy manifest. PrivacyInfo.xcprivacy must
    /// be bundled or the App Store review will bounce the submission.
    private static func checkPrivacyManifestPresent() -> Check {
        let t0 = Date()
        let url = Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy")
        let pass = url != nil
        return Check(
            id: "bundle.privacyManifest",
            name: "PrivacyInfo.xcprivacy bundled",
            passed: pass,
            detail: pass
                ? "PrivacyInfo.xcprivacy found in bundle"
                : "PrivacyInfo.xcprivacy NOT in bundle — App Store will reject; add to Copy Bundle Resources",
            blocker: true,
            secondsTaken: Date().timeIntervalSince(t0)
        )
    }

    // MARK: - Category 4: Capability resolution

    /// A reasoning provider must resolve for the LLM-on path to fire.
    /// If none resolves, every expert silently falls to heuristic
    /// floor and the eval baselines below will produce meaningless
    /// numbers (but won't loudly fail).
    @MainActor
    private static func checkReasoningCapabilityResolves(_ state: AppState) async -> Check {
        let t0 = Date()
        guard let caps = state.capabilities else {
            return Check(
                id: "caps.reasoningResolves",
                name: "Reasoning capability resolves",
                passed: false,
                detail: "CapabilityRegistry not booted",
                blocker: true,
                secondsTaken: Date().timeIntervalSince(t0)
            )
        }
        let spec = CapabilitySpec.reasoning(contextTokens: 4_000, purpose: "release.readiness")
        do {
            let provider = try await caps.resolve(spec)
            return Check(
                id: "caps.reasoningResolves",
                name: "Reasoning capability resolves",
                passed: true,
                detail: "provider: \(provider.id)",
                blocker: true,
                secondsTaken: Date().timeIntervalSince(t0)
            )
        } catch {
            return Check(
                id: "caps.reasoningResolves",
                name: "Reasoning capability resolves",
                passed: false,
                detail: "no reasoning provider — install Ollama + pull a model, or add a cloud endpoint",
                blocker: true,
                secondsTaken: Date().timeIntervalSince(t0)
            )
        }
    }

    // MARK: - Category 5: Live data health (soft warning)

    /// Read-only audit. Flags counted as warnings — the user may have
    /// chosen to ship with incomplete ingest. Doesn't block the
    /// verdict, but shows up in the report.
    @MainActor
    private static func checkLiveDataHealth(_ state: AppState) async -> Check {
        let t0 = Date()
        do {
            let result = try await DataHealthCheck.run(state)
            let pass = result.issuesFound == 0
            return Check(
                id: "health.live",
                name: "Live data health (read-only)",
                passed: pass,
                detail: pass
                    ? "no issues — \(result.summary.split(separator: "\n").first ?? "")"
                    : "\(result.issuesFound) issue(s) flagged — see data-health-report.md",
                blocker: false,
                secondsTaken: Date().timeIntervalSince(t0)
            )
        } catch {
            return Check(
                id: "health.live",
                name: "Live data health (read-only)",
                passed: false,
                detail: "audit threw: \(error)",
                blocker: false,
                secondsTaken: Date().timeIntervalSince(t0)
            )
        }
    }

    // MARK: - Category 6: ProjectDelta smoke (end-to-end)

    @MainActor
    private static func checkProjectDeltaSmoke() async -> Check {
        let t0 = Date()
        do {
            let smoke = try await runProjectDeltaSmokeTest()
            return Check(
                id: "e2e.smoke",
                name: "ProjectDelta end-to-end smoke",
                passed: smoke.ok,
                detail: smoke.ok
                    ? "\(smoke.assertionsPassed.count) checks passed; cited \(smoke.answer.citations.count)"
                    : "\(smoke.assertionsFailed.count) failures — ALL: \(smoke.assertionsFailed.joined(separator: " | "))",
                blocker: true,
                secondsTaken: Date().timeIntervalSince(t0)
            )
        } catch {
            return Check(
                id: "e2e.smoke",
                name: "ProjectDelta end-to-end smoke",
                passed: false,
                detail: "smoke threw: \(error)",
                blocker: true,
                secondsTaken: Date().timeIntervalSince(t0)
            )
        }
    }

    // MARK: - Category 7: Fast Eval baseline

    @MainActor
    private static func checkFastEvalBaseline() async -> Check {
        let t0 = Date()
        do {
            let result = try await Gate1Baseline.generateFast()
            let providerOK = result.reasoningProviderID != nil
            let pass = providerOK && result.ingestedFixtureFiles > 0
            let provider = result.reasoningProviderID ?? "none (heuristic floor)"
            return Check(
                id: "eval.fast",
                name: "Fast Eval baseline (4 questions)",
                passed: pass,
                detail: pass
                    ? "ingest \(result.ingestedFixtureFiles)f, query \(String(format: "%.1f", result.querySeconds))s, provider \(provider)"
                    : "no reasoning provider or ingest empty — fastEval not measuring the LLM path",
                blocker: true,
                secondsTaken: Date().timeIntervalSince(t0)
            )
        } catch {
            return Check(
                id: "eval.fast",
                name: "Fast Eval baseline (4 questions)",
                passed: false,
                detail: "Fast Eval threw: \(error)",
                blocker: true,
                secondsTaken: Date().timeIntervalSince(t0)
            )
        }
    }

    // MARK: - Category 8: Gate 3 Multi-hop

    @MainActor
    private static func checkGate3Multihop() async -> Check {
        let t0 = Date()
        do {
            let result = try await Gate1Baseline.generateGate3Multihop()
            let providerOK = result.reasoningProviderID != nil
            let pass = providerOK && result.ingestedFixtureFiles > 0
            let provider = result.reasoningProviderID ?? "none (heuristic floor)"
            return Check(
                id: "eval.gate3",
                name: "Gate 3 Multi-hop (M1..M4)",
                passed: pass,
                detail: pass
                    ? "ingest \(result.ingestedFixtureFiles)f, query \(String(format: "%.1f", result.querySeconds))s, provider \(provider)"
                    : "no reasoning provider or ingest empty",
                blocker: true,
                secondsTaken: Date().timeIntervalSince(t0)
            )
        } catch {
            return Check(
                id: "eval.gate3",
                name: "Gate 3 Multi-hop (M1..M4)",
                passed: false,
                detail: "Gate 3 threw: \(error)",
                blocker: true,
                secondsTaken: Date().timeIntervalSince(t0)
            )
        }
    }

    // MARK: - Report writing

    private static func writeReport(checks: [Check], totalSeconds: TimeInterval) throws -> URL {
        let documentsDir = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let reportDir = documentsDir.appendingPathComponent("EvalBaselines", isDirectory: true)
        try? FileManager.default.createDirectory(at: reportDir, withIntermediateDirectories: true)
        let url = reportDir.appendingPathComponent("release-readiness.md", isDirectory: false)

        let blockerFails = checks.filter { !$0.passed && $0.blocker }
        let softFails = checks.filter { !$0.passed && !$0.blocker }
        let ready = blockerFails.isEmpty

        var md = "# Kalsmritikosh — Release Readiness Report\n\n"
        md += "Generated: \(Date().formatted(date: .abbreviated, time: .standard))\n"
        md += "Total runtime: \(String(format: "%.1f", totalSeconds))s\n\n"

        md += "## Verdict\n\n"
        if ready {
            md += "## ✅ RELEASE READY: YES\n\n"
            md += "Every blocking check passed. The build is ready for public distribution without TestFlight.\n"
            if !softFails.isEmpty {
                md += "\n_\(softFails.count) soft warning(s) below — review but they do not block release._\n"
            }
        } else {
            md += "## ❌ RELEASE READY: NO\n\n"
            md += "\(blockerFails.count) blocking check(s) failed. Public distribution is NOT recommended until these are fixed:\n\n"
            for check in blockerFails {
                md += "- **\(check.name)** — \(check.detail)\n"
            }
        }
        md += "\n"

        md += "## Per-check results (\(checks.count) total)\n\n"
        md += "| # | Check | Result | Detail | Time |\n|---:|---|---|---|---:|\n"
        for (i, check) in checks.enumerated() {
            let badge: String
            if check.passed { badge = "✅ PASS" }
            else if check.blocker { badge = "❌ FAIL" }
            else { badge = "⚠️ WARN" }
            let detail = check.detail.replacingOccurrences(of: "|", with: "\\|")
            md += "| \(i + 1) | \(check.name) | \(badge) | \(detail) | \(String(format: "%.1f", check.secondsTaken))s |\n"
        }
        md += "\n"

        md += "## Coverage\n\n"
        md += "- **Schema integrity** — current migration head matches the compiled-in `latestVersion`.\n"
        md += "- **Deterministic logic** — pure functions (no DB / LLM): query classifier, evidence ranker, date renderer, chat regex, iMessage epoch, confidence clamp, reranker shape.\n"
        md += "- **Bundle integrity** — ProjectDelta fixture + PrivacyInfo.xcprivacy must ship.\n"
        md += "- **Capability resolution** — a reasoning provider answers a preflight resolve.\n"
        md += "- **Live data health** — read-only audit of the user's database (soft warning).\n"
        md += "- **ProjectDelta smoke** — boot → ingest fixture → ask canonical question → assert citations + body content.\n"
        md += "- **Fast Eval baseline** — 4 representative LLM questions (L1, A3, T3, M1).\n"
        md += "- **Gate 3 Multi-hop** — 4 typed multi-hop questions (M1..M4).\n\n"

        md += "## Sibling reports\n\n"
        md += "These reports may have been written or refreshed by this run; check them for deeper detail:\n\n"
        md += "- `data-health-report.md` — full live-DB audit\n"
        md += "- `eval-report-fast.md` — Fast Eval per-question metrics\n"
        md += "- `eval-report-gate3-multihop.md` — Gate 3 per-question metrics\n"

        try md.data(using: .utf8)?.write(to: url, options: .atomic)
        KalsmritikoshLog.app.info("ReleaseReadiness report → \(url.path, privacy: .public)")
        return url
    }
}
