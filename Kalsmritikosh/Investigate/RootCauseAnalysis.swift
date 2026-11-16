//
//  RootCauseAnalysis.swift
//  Kalsmritikosh
//
//  The data behind the Reasoning Studio — a start-to-finish root-cause
//  investigation built from three classic techniques: brainstorming, the
//  5 Whys, and an Ishikawa (fishbone) cause-and-effect diagram, ending in a
//  written conclusion and an approval/sign-off block ready to submit.
//
//  Everything here is a plain Codable value so a whole analysis serialises to
//  JSON and lives on-device (no schema migration, nothing uploaded). The report
//  renderer is pure text so it's unit-testable and reused for copy / export /
//  print (Save as PDF).
//

import Foundation

// MARK: - Pieces

/// One idea from the brainstorm — a possible cause, optionally sorted into a
/// fishbone category and optionally "parked" (kept but set aside).
public struct RCAIdea: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var text: String
    public var category: String?     // matches a RCAFishboneCategory.name when sorted
    public var parked: Bool = false
    /// Case plan 2026-11-16 (REASON-13): exact passages the idea rests on, and an explicitly stated assumption.
    public var citations: [StudioEvidenceRef] = []
    public var assumption: String = ""
    public init(text: String, category: String? = nil, parked: Bool = false) {
        self.text = text; self.category = category; self.parked = parked
    }

    private enum CodingKeys: String, CodingKey { case id, text, category, parked, citations, assumption }
    // Records saved before citations and assumptions decode unchanged (their text stays the investigator's own).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try c.decode(String.self, forKey: .text)
        category = try c.decodeIfPresent(String.self, forKey: .category)
        parked = try c.decodeIfPresent(Bool.self, forKey: .parked) ?? false
        citations = try c.decodeIfPresent([StudioEvidenceRef].self, forKey: .citations) ?? []
        assumption = try c.decodeIfPresent(String.self, forKey: .assumption) ?? ""
    }
}

/// One rung of the 5 Whys ladder: a "why?" and the answer that becomes the next
/// question. `evidence` notes what in the ledger supports the answer.
public struct RCAWhyStep: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var question: String      // "Why did the shipment miss the deadline?"
    public var answer: String        // becomes the basis of the next question
    public var evidence: String = "" // the investigator's own note of where it came from (not a checked citation)
    /// Case plan 2026-11-16 (REASON-13): exact passages that support the answer, and an explicitly stated assumption.
    public var citations: [StudioEvidenceRef] = []
    public var assumption: String = ""
    public init(question: String, answer: String = "", evidence: String = "") {
        self.question = question; self.answer = answer; self.evidence = evidence
    }

    private enum CodingKeys: String, CodingKey { case id, question, answer, evidence, citations, assumption }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        question = try c.decode(String.self, forKey: .question)
        answer = try c.decodeIfPresent(String.self, forKey: .answer) ?? ""
        evidence = try c.decodeIfPresent(String.self, forKey: .evidence) ?? ""
        citations = try c.decodeIfPresent([StudioEvidenceRef].self, forKey: .citations) ?? []
        assumption = try c.decodeIfPresent(String.self, forKey: .assumption) ?? ""
    }
}

public struct RCAFishboneCause: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var text: String
    public var likely: Bool = false  // flagged by the investigator as a probable contributor (a mark, not a finding)
    /// Case plan 2026-11-16 (REASON-13): exact passages the cause rests on, and an explicitly stated assumption.
    public var citations: [StudioEvidenceRef] = []
    public var assumption: String = ""
    public init(text: String, likely: Bool = false) { self.text = text; self.likely = likely }

    private enum CodingKeys: String, CodingKey { case id, text, likely, citations, assumption }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try c.decode(String.self, forKey: .text)
        likely = try c.decodeIfPresent(Bool.self, forKey: .likely) ?? false
        citations = try c.decodeIfPresent([StudioEvidenceRef].self, forKey: .citations) ?? []
        assumption = try c.decodeIfPresent(String.self, forKey: .assumption) ?? ""
    }
}

public struct RCAFishboneCategory: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var name: String
    public var causes: [RCAFishboneCause] = []
    public init(name: String, causes: [RCAFishboneCause] = []) { self.name = name; self.causes = causes }
}

/// Which cause a corrective action addresses (8D: actions tie to causes).
public enum RCACauseTarget: String, Codable, Sendable, CaseIterable, Equatable {
    case rootCause, escapeCause, contributing, general
    public var label: String {
        switch self {
        case .rootCause: return "root cause"
        case .escapeCause: return "escape cause (detection)"
        case .contributing: return "contributing factor"
        case .general: return "general"
        }
    }
}

/// A corrective/preventive action linked to the cause it addresses.
public struct RCARecommendation: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID = UUID()
    public var text: String
    public var addresses: RCACauseTarget = .rootCause
    public init(text: String, addresses: RCACauseTarget = .rootCause) {
        self.text = text; self.addresses = addresses
    }
}

/// What the conclusion records (case plan 2026-11-16, REPORT-11): a stated root cause, or an honest "inconclusive on
/// the available evidence" — a complete conclusion that names no established cause.
public enum RCAConclusionOutcome: String, Codable, Sendable, CaseIterable {
    case rootCauseStated, inconclusive
    public var label: String {
        switch self {
        case .rootCauseStated: return "Root cause stated"
        case .inconclusive: return "Inconclusive on the available evidence"
        }
    }
}

public struct RCAConclusion: Codable, Hashable, Sendable {
    public var outcome: RCAConclusionOutcome = .rootCauseStated
    /// The exact passages the conclusion itself rests on (beside those cited by the Why steps and causes).
    public var citations: [StudioEvidenceRef] = []
    public var rootCause: String = ""
    /// 8D "escape" cause — why existing checks didn't catch this sooner.
    public var escapeRootCause: String = ""
    public var contributingFactors: [String] = []
    /// Actions, each tied to the cause it addresses (8D cause→action linkage).
    public var recommendations: [RCARecommendation] = []
    public var summary: String = ""
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case outcome, citations, rootCause, escapeRootCause, contributingFactors, recommendations, summary
    }
    // Tolerant decode: `escapeRootCause` may be absent (older data), and
    // `recommendations` may be legacy `[String]` — both handled gracefully.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        outcome = (try? c.decodeIfPresent(RCAConclusionOutcome.self, forKey: .outcome)) ?? .rootCauseStated
        citations = try c.decodeIfPresent([StudioEvidenceRef].self, forKey: .citations) ?? []
        rootCause = try c.decodeIfPresent(String.self, forKey: .rootCause) ?? ""
        escapeRootCause = try c.decodeIfPresent(String.self, forKey: .escapeRootCause) ?? ""
        contributingFactors = try c.decodeIfPresent([String].self, forKey: .contributingFactors) ?? []
        if let structured = ((try? c.decodeIfPresent([RCARecommendation].self, forKey: .recommendations)) ?? nil) {
            recommendations = structured
        } else if let legacy = ((try? c.decodeIfPresent([String].self, forKey: .recommendations)) ?? nil) {
            recommendations = legacy.map { RCARecommendation(text: $0) }
        } else {
            recommendations = []
        }
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
    }
}

public enum RCAApprovalStatus: String, Codable, Sendable, CaseIterable {
    case draft, pendingApproval, approved, returned
    public var label: String {
        switch self {
        case .draft: return "Draft"
        case .pendingApproval: return "Pending approval"
        case .approved: return "Approved"
        case .returned: return "Returned for revision"
        }
    }
}

/// The sign-off block — who prepared it, who it goes to, and the decision.
public struct RCAApproval: Codable, Hashable, Sendable {
    public var preparedBy: String = ""
    public var submittedTo: String = ""       // the higher authority / recipient
    public var status: RCAApprovalStatus = .draft
    public var approver: String = ""
    public var decisionNote: String = ""
    public var submittedAt: Date?
    public var decidedAt: Date?
    public init() {}
}

// MARK: - The whole analysis

public struct RootCauseAnalysis: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var title: String                  // case / matter name
    public var problemStatement: String = ""  // the effect / incident under investigation
    public var createdAt: Date
    public var updatedAt: Date
    public var history: [StudioAuditEntry]?

    public var brainstorm: [RCAIdea] = []
    public var fiveWhys: [RCAWhyStep] = []
    public var fishbone: [RCAFishboneCategory]
    public var conclusion: RCAConclusion = RCAConclusion()
    public var approval: RCAApproval = RCAApproval()

    /// The six classic Ishikawa arms, adapted for investigations.
    public static let defaultCategories = [
        "People", "Process", "Policy & Management",
        "Equipment & Tools", "Information & Evidence", "Environment"
    ]

    public init(title: String, now: Date) {
        self.id = UUID()
        self.title = title
        self.createdAt = now
        self.updatedAt = now
        self.fishbone = Self.defaultCategories.map { RCAFishboneCategory(name: $0) }
    }

    // MARK: Progress (drives the stepper's completion ticks)

    public enum Stage: Int, CaseIterable, Sendable {
        case frame, brainstorm, fiveWhys, fishbone, conclude, report
        public var title: String {
            switch self {
            case .frame: return "Frame"
            case .brainstorm: return "Brainstorm"
            case .fiveWhys: return "5 Whys"
            case .fishbone: return "Fishbone"
            case .conclude: return "Conclude"
            case .report: return "Report"
            }
        }
        public var systemImage: String {
            switch self {
            case .frame: return "scope"
            case .brainstorm: return "lightbulb"
            case .fiveWhys: return "arrow.down.right.circle"
            case .fishbone: return "fish"
            case .conclude: return "checkmark.seal"
            case .report: return "doc.richtext"
            }
        }
    }

    public func isComplete(_ stage: Stage) -> Bool {
        switch stage {
        case .frame:      return !problemStatement.trimmed.isEmpty
        case .brainstorm: return brainstorm.contains { !$0.text.trimmed.isEmpty }
        case .fiveWhys:   return fiveWhys.filter { !$0.answer.trimmed.isEmpty }.count >= 3
        case .fishbone:   return fishbone.contains { !$0.causes.isEmpty }
        // An honest "inconclusive" is a complete conclusion: it needs no root cause.
        case .conclude:   return conclusion.outcome == .inconclusive || !conclusion.rootCause.trimmed.isEmpty
        case .report:     return approval.status == .approved
        }
    }

    /// 0…1 across the first five working stages (report is the finisher).
    public var completionFraction: Double {
        let working: [Stage] = [.frame, .brainstorm, .fiveWhys, .fishbone, .conclude]
        let done = working.filter { isComplete($0) }.count
        return Double(done) / Double(working.count)
    }

    // MARK: Evidence state (case plan 2026-11-16, REPORT-11) — kept apart from the sign-off state

    /// What the analysis's steps actually rest on: cited passages, stated assumptions, or only the investigator's notes.
    public struct EvidenceState: Equatable, Sendable {
        public var answeredWhys = 0, citedWhys = 0, assumedWhys = 0
        public var probableCauses = 0, citedCauses = 0, assumedCauses = 0
        public var conclusionCitations = 0
        /// Whether anything in the analysis cites a passage.
        public var anyCited: Bool { citedWhys + citedCauses + conclusionCitations > 0 }
    }

    public var evidenceState: EvidenceState {
        var e = EvidenceState()
        for w in fiveWhys where !w.answer.trimmed.isEmpty {
            e.answeredWhys += 1
            if !Self.quoted(w.citations).isEmpty { e.citedWhys += 1 } else if !w.assumption.trimmed.isEmpty { e.assumedWhys += 1 }
        }
        for c in fishbone.flatMap(\.causes) where c.likely {
            e.probableCauses += 1
            if !Self.quoted(c.citations).isEmpty { e.citedCauses += 1 } else if !c.assumption.trimmed.isEmpty { e.assumedCauses += 1 }
        }
        e.conclusionCitations = Self.quoted(conclusion.citations).count
        return e
    }

    /// The citations that quote a passage: only those can be checked against a source, so only those count as evidence.
    public static func quoted(_ refs: [StudioEvidenceRef]) -> [StudioEvidenceRef] {
        refs.filter { !($0.quote ?? "").trimmed.isEmpty }
    }

    /// Every citation as a gate value (its quote) with its provenance, keyed by where it sits — what the export and
    /// approval re-check resolves against the case (each quote must still be in its cited source, in the case).
    public var citationGate: (values: [String: String], provenance: StudioProvenance) {
        var values: [String: String] = [:], provenance: StudioProvenance = [:]
        func add(_ path: String, _ refs: [StudioEvidenceRef]) {
            for (i, ref) in Self.quoted(refs).enumerated() {
                let key = "\(path).citation\(i)"
                values[key] = ref.quote ?? ""
                provenance[key] = StudioFieldProvenance(evidence: [ref])
            }
        }
        for idea in brainstorm { add("brainstorm.\(idea.id.uuidString)", idea.citations) }
        for w in fiveWhys { add("fiveWhys.\(w.id.uuidString)", w.citations) }
        for c in fishbone.flatMap(\.causes) { add("fishbone.\(c.id.uuidString)", c.citations) }
        add("conclusion", conclusion.citations)
        return (values, provenance)
    }

    /// A fully-worked example so users can click straight through the whole flow
    /// (an SIU-style claim inconsistency). Everything here is illustrative.
    public static func sample(now: Date) -> RootCauseAnalysis {
        var r = RootCauseAnalysis(title: "Claim CL-2291 — inconsistent injury date", now: now)
        r.problemStatement = "The claimant's stated date of injury differs across three documents in file CL-2291 (intake form, recorded statement, and treating-physician note), which affects coverage and reserve."
        r.brainstorm = [
            RCAIdea(text: "Adjuster transcription error at intake", category: "People"),
            RCAIdea(text: "No verification step against the medical record", category: "Process"),
            RCAIdea(text: "Claimant recollection changed over time"),
            RCAIdea(text: "Two separate incidents conflated"),
            RCAIdea(text: "Legacy intake form has no date-cross-check", category: "Equipment & Tools"),
            RCAIdea(text: "Possible misrepresentation", parked: true)
        ]
        r.fiveWhys = [
            RCAWhyStep(question: "Why is the injury date inconsistent across documents?",
                       answer: "The intake form date was never checked against the medical record.",
                       evidence: "intake-form.pdf · p.1"),
            RCAWhyStep(question: "Why was it never checked against the medical record?",
                       answer: "There is no verification step in the claim-intake workflow.",
                       evidence: "SIU-SOP §4"),
            RCAWhyStep(question: "Why is there no verification step?",
                       answer: "The legacy intake form predates the cross-check requirement and was never updated.")
        ]
        if let i = r.fishbone.firstIndex(where: { $0.name == "Process" }) {
            r.fishbone[i].causes = [RCAFishboneCause(text: "No date cross-check at intake", likely: true),
                                    RCAFishboneCause(text: "Manual re-keying of the date")]
        }
        if let i = r.fishbone.firstIndex(where: { $0.name == "Information & Evidence" }) {
            r.fishbone[i].causes = [RCAFishboneCause(text: "Conflicting medical records", likely: true)]
        }
        if let i = r.fishbone.firstIndex(where: { $0.name == "Equipment & Tools" }) {
            r.fishbone[i].causes = [RCAFishboneCause(text: "Legacy intake form without validation")]
        }
        r.conclusion.rootCause = "The claim-intake workflow has no step that reconciles the stated injury date against the medical record, so a transcription discrepancy went undetected."
        r.conclusion.escapeRootCause = "No verification/QA check on the intake form meant the discrepancy was never flagged before the file advanced."
        r.conclusion.contributingFactors = ["Legacy intake form without date validation", "Manual re-keying"]
        r.conclusion.recommendations = [
            RCARecommendation(text: "Add a mandatory date-reconciliation step at intake, cross-checking the medical record.", addresses: .rootCause),
            RCARecommendation(text: "Add a QA/verification check so intake discrepancies are flagged before the file advances.", addresses: .escapeCause),
            RCARecommendation(text: "Retire the legacy intake form; add field validation.", addresses: .contributing),
            RCARecommendation(text: "Re-interview the claimant to resolve the specific date.", addresses: .general)
        ]
        r.conclusion.summary = "The inconsistency is best explained by a process gap at intake rather than misrepresentation on the current evidence. Recommend a verification step and a targeted re-interview before any coverage decision."
        r.approval.preparedBy = "SIU Investigator"
        r.approval.submittedTo = "SIU Manager"
        StudioAudit.record(&r.history, "Worked example created", at: now)
        return r
    }
}

extension String {
    nonisolated var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

// MARK: - Report renderer (pure — copy / export / print all use this)

public enum RCAReportRenderer {

    public static func markdown(_ rca: RootCauseAnalysis, generatedAt: Date) -> String {
        let df = DateFormatter(); df.dateStyle = .long; df.timeStyle = .short
        func date(_ d: Date?) -> String { d.map { df.string(from: $0) } ?? "—" }
        var out = LegalNotice.reportDisclaimer + "\n\n"
        out += "# Root-Cause Analysis — \(rca.title.trimmed.isEmpty ? "Untitled" : rca.title)\n\n"

        // Sign-off header
        out += "**Status:** \(rca.approval.status.label)\n"
        out += "**Prepared by:** \(rca.approval.preparedBy.orDash)\n"
        out += "**Submitted to:** \(rca.approval.submittedTo.orDash)\n"
        if rca.approval.status != .draft { out += "**Submitted:** \(date(rca.approval.submittedAt))\n" }
        if rca.approval.status == .approved || rca.approval.status == .returned {
            out += "**Decision by:** \(rca.approval.approver.orDash) — \(date(rca.approval.decidedAt))\n"
            if !rca.approval.decisionNote.trimmed.isEmpty { out += "**Decision note:** \(rca.approval.decisionNote)\n" }
        }
        out += "**Report generated:** \(df.string(from: generatedAt))\n\n---\n\n"

        // Problem
        out += "## 1. Problem under investigation\n\n"
        out += (rca.problemStatement.trimmed.isEmpty ? "_Not stated._" : rca.problemStatement) + "\n\n"
        out += "**Method:** Structured root-cause analysis — brainstorming, the 5 Whys, and an Ishikawa (fishbone) cause-and-effect diagram.\n\n"
        // Case plan 2026-11-16 (REPORT-11): what the steps rest on and who signed off, stated separately and from the
        // record — never a fixed claim that causes were traced to evidence or that a person confirmed the root cause.
        out += "**Evidence:** " + evidenceLine(rca.evidenceState) + "\n\n"
        out += "**Review:** " + reviewLine(rca.approval, date: date) + "\n\n"

        // Brainstorm
        out += "## 2. Brainstorm — possible causes considered\n\n"
        let live = rca.brainstorm.filter { !$0.text.trimmed.isEmpty && !$0.parked }
        if live.isEmpty { out += "_No ideas recorded._\n\n" }
        else {
            for idea in live {
                let tag = idea.category.map { " _( \($0) )_" } ?? ""
                out += "- \(idea.text)\(tag)\n"
            }
            out += "\n"
            let parked = rca.brainstorm.filter { !$0.text.trimmed.isEmpty && $0.parked }
            if !parked.isEmpty {
                out += "_Parked (considered, set aside):_ " + parked.map(\.text).joined(separator: "; ") + "\n\n"
            }
        }

        // 5 Whys
        out += "## 3. 5 Whys — chain to the root\n\n"
        let whys = rca.fiveWhys.filter { !$0.answer.trimmed.isEmpty }
        if whys.isEmpty { out += "_Not completed._\n\n" }
        else {
            for (i, step) in whys.enumerated() {
                out += "\(i + 1). **\(step.question.trimmed.isEmpty ? "Why?" : step.question)**\n"
                out += "   → \(step.answer)\n"
                out += support(citations: step.citations, assumption: step.assumption, indent: "   ")
                if !step.evidence.trimmed.isEmpty { out += "   _Investigator's note on the source (as entered, not checked): \(step.evidence)_\n" }
            }
            out += "\n"
        }

        // Fishbone
        out += "## 4. Cause-and-effect (fishbone)\n\n"
        let filled = rca.fishbone.filter { !$0.causes.isEmpty }
        if filled.isEmpty { out += "_No causes organised._\n\n" }
        else {
            for cat in filled {
                out += "**\(cat.name)**\n"
                for c in cat.causes {
                    out += "- \(c.likely ? "⭐️ " : "")\(c.text)\(c.likely ? " _(marked probable by the investigator)_" : "")\n"
                    out += support(citations: c.citations, assumption: c.assumption, indent: "  ")
                }
                out += "\n"
            }
        }

        // Conclusion — the analyst's opinion, distinct from the observed steps above.
        out += "## 5. Conclusion (analyst's opinion)\n\n"
        out += "_Sections 2–4 record the observed evidence and analysis; the conclusion below is the investigator's professional judgement drawn from them._\n\n"
        if rca.conclusion.outcome == .inconclusive {
            out += "**Outcome:** Inconclusive on the available evidence — no root cause is established.\n\n"
            if !rca.conclusion.rootCause.trimmed.isEmpty {
                out += "**Leading candidate (not established):** \(rca.conclusion.rootCause)\n\n"
            }
        } else {
            out += "**Root cause:** " + (rca.conclusion.rootCause.trimmed.isEmpty ? "_Not stated._" : rca.conclusion.rootCause) + "\n\n"
        }
        out += "**Basis:** " + basisLine(rca) + "\n"
        out += support(citations: rca.conclusion.citations, assumption: "", indent: "")
        out += "\n"
        if !rca.conclusion.escapeRootCause.trimmed.isEmpty {
            out += "**Why it wasn't caught sooner (escape cause):** \(rca.conclusion.escapeRootCause)\n\n"
        }
        if !rca.conclusion.contributingFactors.isEmpty {
            out += "**Contributing factors:**\n"
            for f in rca.conclusion.contributingFactors where !f.trimmed.isEmpty { out += "- \(f)\n" }
            out += "\n"
        }
        let recs = rca.conclusion.recommendations.filter { !$0.text.trimmed.isEmpty }
        if !recs.isEmpty {
            out += "**Recommendations (each tied to the cause it addresses):**\n"
            for (i, r) in recs.enumerated() { out += "\(i + 1). \(r.text) — _addresses the \(r.addresses.label)_\n" }
            out += "\n"
        }
        if !rca.conclusion.summary.trimmed.isEmpty {
            out += "**Summary:**\n\n\(rca.conclusion.summary)\n\n"
        }

        // Sign-off
        out += "---\n\n"
        out += "Prepared by **\(rca.approval.preparedBy.orDash)**"
        if !rca.approval.submittedTo.trimmed.isEmpty { out += " · Submitted to **\(rca.approval.submittedTo)**" }
        out += "\n\nApproval: **\(rca.approval.status.label)**"
        if rca.approval.status == .approved { out += " — signed **\(rca.approval.approver.orDash)**, \(date(rca.approval.decidedAt))" }
        out += "\n"
        out += StudioAudit.appendix(rca.history)
        return out
    }

    /// The cited passages and stated assumption under a step, one line each ("" when it has neither).
    static func support(citations: [StudioEvidenceRef], assumption: String, indent: String) -> String {
        var out = ""
        for ref in RootCauseAnalysis.quoted(citations) {
            out += "\(indent)_Source: \u{201C}\(ref.quote ?? "")\u{201D}\(ref.sourceVersionID.map { " (version \($0.uuidString.prefix(8)))" } ?? "")_\n"
        }
        if !assumption.trimmed.isEmpty { out += "\(indent)_Assumption (stated, not evidenced): \(assumption)_\n" }
        return out
    }

    /// What the analysis's steps rest on, counted from the record.
    static func evidenceLine(_ e: RootCauseAnalysis.EvidenceState) -> String {
        func part(_ cited: Int, _ assumed: Int, of total: Int, _ noun: String) -> String {
            let notes = total - cited - assumed
            return "\(cited) of \(total) \(noun) cite a source passage, \(assumed) rest on a stated assumption, \(notes) on the investigator's notes only"
        }
        var parts: [String] = []
        if e.answeredWhys > 0 { parts.append(part(e.citedWhys, e.assumedWhys, of: e.answeredWhys, "answered Why steps")) }
        if e.probableCauses > 0 { parts.append(part(e.citedCauses, e.assumedCauses, of: e.probableCauses, "causes marked probable")) }
        if e.conclusionCitations > 0 { parts.append("the conclusion cites \(e.conclusionCitations) passage(s)") }
        guard !parts.isEmpty else { return "nothing is recorded yet." }
        let head = parts.joined(separator: "; ") + "."
        return e.anyCited ? head : head + " No step cites a source: this analysis rests on the investigator's notes and judgement."
    }

    /// Who signed off, kept apart from the evidence: approval records a reviewer's decision on this report; it does not
    /// by itself establish the cause.
    static func reviewLine(_ a: RCAApproval, date: (Date?) -> String) -> String {
        switch a.status {
        case .approved:
            let selfApproved = !a.approver.trimmed.isEmpty && a.approver.trimmed == a.preparedBy.trimmed
            return "approved by \(a.approver.orDash) on \(date(a.decidedAt))\(selfApproved ? " (self-approved: the preparer approved their own report)" : ""). Approval records the reviewer's decision on this report; it does not by itself establish the cause."
        case .pendingApproval:
            return "submitted for approval, not yet decided. Nothing here has been confirmed by a reviewer."
        case .returned:
            return "returned for revision by \(a.approver.orDash). Nothing here has been confirmed by a reviewer."
        case .draft:
            return "draft, not reviewed. Nothing here has been confirmed by a reviewer."
        }
    }

    /// What the conclusion rests on, from the record (its own citations, then the cited steps and causes).
    static func basisLine(_ rca: RootCauseAnalysis) -> String {
        let e = rca.evidenceState
        var parts: [String] = []
        if e.conclusionCitations > 0 { parts.append("\(e.conclusionCitations) passage(s) cited by the conclusion (below)") }
        if e.citedWhys > 0 { parts.append("\(e.citedWhys) cited Why step(s)") }
        if e.citedCauses > 0 { parts.append("\(e.citedCauses) cited probable cause(s)") }
        guard !parts.isEmpty else {
            return "no source is cited — the conclusion rests on the investigator's notes and judgement."
        }
        return parts.joined(separator: ", ") + "."
    }
}

private extension String {
    var orDash: String { trimmed.isEmpty ? "—" : self }
}
