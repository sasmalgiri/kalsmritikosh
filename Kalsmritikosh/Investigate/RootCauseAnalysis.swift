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
    public init(text: String, category: String? = nil, parked: Bool = false) {
        self.text = text; self.category = category; self.parked = parked
    }
}

/// One rung of the 5 Whys ladder: a "why?" and the answer that becomes the next
/// question. `evidence` notes what in the ledger supports the answer.
public struct RCAWhyStep: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var question: String      // "Why did the shipment miss the deadline?"
    public var answer: String        // becomes the basis of the next question
    public var evidence: String = "" // optional pointer to a source / doc number
    public init(question: String, answer: String = "", evidence: String = "") {
        self.question = question; self.answer = answer; self.evidence = evidence
    }
}

public struct RCAFishboneCause: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var text: String
    public var likely: Bool = false  // flagged as a probable contributor
    public init(text: String, likely: Bool = false) { self.text = text; self.likely = likely }
}

public struct RCAFishboneCategory: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var name: String
    public var causes: [RCAFishboneCause] = []
    public init(name: String, causes: [RCAFishboneCause] = []) { self.name = name; self.causes = causes }
}

public struct RCAConclusion: Codable, Hashable, Sendable {
    public var rootCause: String = ""
    /// 8D "escape" cause — why existing checks didn't catch this sooner.
    public var escapeRootCause: String = ""
    public var contributingFactors: [String] = []
    public var recommendations: [String] = []
    public var summary: String = ""
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case rootCause, escapeRootCause, contributingFactors, recommendations, summary
    }
    // Tolerant decode so analyses saved before `escapeRootCause` existed still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rootCause = try c.decodeIfPresent(String.self, forKey: .rootCause) ?? ""
        escapeRootCause = try c.decodeIfPresent(String.self, forKey: .escapeRootCause) ?? ""
        contributingFactors = try c.decodeIfPresent([String].self, forKey: .contributingFactors) ?? []
        recommendations = try c.decodeIfPresent([String].self, forKey: .recommendations) ?? []
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
        case .conclude:   return !conclusion.rootCause.trimmed.isEmpty
        case .report:     return approval.status == .approved
        }
    }

    /// 0…1 across the first five working stages (report is the finisher).
    public var completionFraction: Double {
        let working: [Stage] = [.frame, .brainstorm, .fiveWhys, .fishbone, .conclude]
        let done = working.filter { isComplete($0) }.count
        return Double(done) / Double(working.count)
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
            "Add a mandatory date-reconciliation step at intake, cross-checking the medical record.",
            "Retire the legacy intake form; add field validation.",
            "Re-interview the claimant to resolve the specific date."
        ]
        r.conclusion.summary = "The inconsistency is best explained by a process gap at intake rather than misrepresentation on the current evidence. Recommend a verification step and a targeted re-interview before any coverage decision."
        r.approval.preparedBy = "SIU Investigator"
        r.approval.submittedTo = "SIU Manager"
        return r
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
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
        out += "**Method:** Structured root-cause analysis — brainstorming, the 5 Whys, and an Ishikawa (fishbone) cause-and-effect diagram; causes traced to evidence and the root cause confirmed by a human.\n\n"

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
                if !step.evidence.trimmed.isEmpty { out += "   _Evidence: \(step.evidence)_\n" }
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
                    out += "- \(c.likely ? "⭐️ " : "")\(c.text)\(c.likely ? " _(probable)_" : "")\n"
                }
                out += "\n"
            }
        }

        // Conclusion — the analyst's opinion, distinct from the observed steps above.
        out += "## 5. Conclusion (analyst's opinion)\n\n"
        out += "_Sections 2–4 record the observed evidence and analysis; the conclusion below is the investigator's professional judgement drawn from them._\n\n"
        out += "**Root cause:** " + (rca.conclusion.rootCause.trimmed.isEmpty ? "_Not stated._" : rca.conclusion.rootCause) + "\n\n"
        if !rca.conclusion.escapeRootCause.trimmed.isEmpty {
            out += "**Why it wasn't caught sooner (escape cause):** \(rca.conclusion.escapeRootCause)\n\n"
        }
        if !rca.conclusion.contributingFactors.isEmpty {
            out += "**Contributing factors:**\n"
            for f in rca.conclusion.contributingFactors where !f.trimmed.isEmpty { out += "- \(f)\n" }
            out += "\n"
        }
        if !rca.conclusion.recommendations.isEmpty {
            out += "**Recommendations:**\n"
            for (i, r) in rca.conclusion.recommendations.enumerated() where !r.trimmed.isEmpty { out += "\(i + 1). \(r)\n" }
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
        return out
    }
}

private extension String {
    var orDash: String { trimmed.isEmpty ? "—" : self }
}
