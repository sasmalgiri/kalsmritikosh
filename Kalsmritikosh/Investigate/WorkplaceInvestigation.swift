//
//  WorkplaceInvestigation.swift
//  Kalsmritikosh
//
//  PERSONA STUDIO #1 (exemplar) — the Workplace / HR investigation, built to
//  produce the EXACT deliverable real workplace investigators produce, through
//  the same real-life steps. The report format mirrors the recognized structure
//  (HR Acuity / Synergy Workplace Investigations / ADR):
//    Executive summary → Mandate → Allegations (framed as questions) →
//    Methodology → Evidence → Credibility assessment → Findings per allegation
//    (Substantiated / Partially / Unsubstantiated / Inconclusive, with
//    "because X, supported by Y") → Recommendations (ONLY if authorised) →
//    Procedural fairness → Sign-off.
//
//  Pure Codable model + pure text renderer (testable); persists on-device as
//  JSON. The studio UI walks the real-life stages in order.
//

import Foundation

// MARK: - Pieces

public nonisolated enum WIPartyRole: String, Codable, Sendable, CaseIterable {
    case complainant, respondent, witness
    public var label: String { rawValue.capitalized }
}

public struct WIParty: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var name: String
    public var role: WIPartyRole = .witness
    public init(name: String, role: WIPartyRole = .witness) { self.name = name; self.role = role }
}

/// One allegation, framed as an answerable question (the real-life discipline),
/// carrying its policy, the respondent's response, and the classified finding
/// with plain "because X, supported by Y" reasoning.
public struct WIAllegation: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var question: String          // "Did X use the company card for personal purchases?"
    public var policy: String = ""       // the policy/rule it engages
    public var respondentResponse: String = ""
    public var finding: FindingClassification?
    public var reasoning: String = ""    // "because X, supported by Y"
    public init(question: String) { self.question = question }
}

/// One item of evidence considered (a document, record, or interview).
public struct WIEvidence: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var descriptionText: String
    public var source: String = ""       // file / interview of whom / record
    public var date: String = ""         // yyyy-MM-dd, optional
    public init(descriptionText: String, source: String = "", date: String = "") {
        self.descriptionText = descriptionText; self.source = source; self.date = date
    }
}

/// A credibility assessment for a person, on the recognized factors
/// (plausibility, corroboration, consistency, motive to fabricate, demeanor).
public struct WICredibility: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var person: String
    public var assessment: String        // the reasoned view
    public init(person: String, assessment: String = "") { self.person = person; self.assessment = assessment }
}

public struct WIRecommendation: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var text: String
    public init(text: String) { self.text = text }
}

// MARK: - The whole investigation

public struct WorkplaceInvestigation: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date

    // Stage 1 — Mandate (terms of reference).
    public var mandate: String = ""                     // who commissioned it, to determine what
    public var investigator: String = ""
    public var recommendationsAuthorised: Bool = false  // real rule: recommend ONLY if authorised

    // Stage 2 — Parties & allegations.
    public var parties: [WIParty] = []
    public var allegations: [WIAllegation] = []

    // Stage 3 — Evidence & interviews.
    public var evidence: [WIEvidence] = []
    public var methodologyNote: String = ""             // what was reviewed, who was interviewed, in what order

    // Stage 4 — Credibility.
    public var credibility: [WICredibility] = []

    // Stage 5 — Recommendations (only if authorised) + fairness confirmations.
    public var recommendations: [WIRecommendation] = []
    public var noticeGiven = false                      // respondent told the allegations
    public var opportunityToRespond = false             // and given a fair chance to answer

    // Sign-off.
    public var submittedTo: String = ""

    public init(title: String, now: Date) {
        self.title = title; self.createdAt = now; self.updatedAt = now
    }

    // MARK: Stages (the real-life order)

    public enum Stage: Int, CaseIterable, Sendable {
        case mandate, allegations, evidence, credibility, findings, report
        public var title: String {
            switch self {
            case .mandate: return "Mandate"
            case .allegations: return "Allegations"
            case .evidence: return "Evidence"
            case .credibility: return "Credibility"
            case .findings: return "Findings"
            case .report: return "Report"
            }
        }
        public var systemImage: String {
            switch self {
            case .mandate: return "doc.badge.gearshape"
            case .allegations: return "questionmark.bubble"
            case .evidence: return "tray.full"
            case .credibility: return "person.crop.circle.badge.questionmark"
            case .findings: return "scalemass"
            case .report: return "doc.richtext"
            }
        }
    }

    public func isComplete(_ stage: Stage) -> Bool {
        switch stage {
        case .mandate:     return !mandate.trimmed.isEmpty && !investigator.trimmed.isEmpty
        case .allegations: return allegations.contains { !$0.question.trimmed.isEmpty }
        case .evidence:    return !evidence.isEmpty
        case .credibility: return !credibility.isEmpty
        case .findings:    return !allegations.isEmpty && allegations.allSatisfy { $0.finding != nil }
        case .report:      return noticeGiven && opportunityToRespond
        }
    }

    public var completionFraction: Double {
        let stages = Stage.allCases
        return Double(stages.filter { isComplete($0) }.count) / Double(stages.count)
    }

    /// A fully-worked example so the studio can be clicked through end to end.
    public static func sample(now: Date) -> WorkplaceInvestigation {
        var w = WorkplaceInvestigation(title: "Complaint 2026-014 — expense-card misuse", now: now)
        w.mandate = "Commissioned by HR Director to determine whether the respondent used the corporate card for personal purchases between January and March 2026, contrary to the Expenses Policy."
        w.investigator = "A. Investigator (HR)"
        w.recommendationsAuthorised = true
        w.parties = [WIParty(name: "P. Complainant", role: .complainant),
                     WIParty(name: "R. Respondent", role: .respondent),
                     WIParty(name: "W. Finance Analyst", role: .witness)]
        var a1 = WIAllegation(question: "Did the respondent use the corporate card for personal purchases in Q1 2026?")
        a1.policy = "Expenses Policy §4.2 (personal use prohibited)"
        a1.respondentResponse = "Respondent states the three flagged transactions were client entertainment."
        a1.finding = .substantiated
        a1.reasoning = "Substantiated because the three transactions occurred on leave days with no client meetings in the calendar, supported by card statements (Jan–Mar), the leave record, and the calendar export."
        var a2 = WIAllegation(question: "Did the respondent falsify a receipt for the 12 Feb transaction?")
        a2.policy = "Code of Conduct §2 (honesty)"
        a2.respondentResponse = "Respondent denies alteration; says the vendor reissued the receipt."
        a2.finding = .inconclusive
        a2.reasoning = "Inconclusive because the vendor could not confirm or deny reissue and the two receipt versions are equally plausible; credible but conflicting accounts with no corroboration."
        w.allegations = [a1, a2]
        w.evidence = [
            WIEvidence(descriptionText: "Corporate card statements, Jan–Mar 2026", source: "card-statements.pdf", date: "2026-04-02"),
            WIEvidence(descriptionText: "Leave record for the respondent", source: "leave-record.xlsx", date: "2026-04-02"),
            WIEvidence(descriptionText: "Interview — respondent", source: "R. Respondent", date: "2026-04-10"),
            WIEvidence(descriptionText: "Interview — finance analyst", source: "W. Finance Analyst", date: "2026-04-08")
        ]
        w.methodologyNote = "Reviewed card statements, leave records, and calendars; interviewed the complainant, the finance analyst, and lastly the respondent with the allegations put to them in full; balance-of-probabilities standard applied."
        w.credibility = [
            WICredibility(person: "R. Respondent", assessment: "Account was internally consistent but conflicted with the leave record and calendar on the three flagged dates; no corroboration offered."),
            WICredibility(person: "W. Finance Analyst", assessment: "Consistent, corroborated by the statements, no apparent motive to fabricate.")
        ]
        w.recommendations = [WIRecommendation(text: "Refer the substantiated finding to the disciplinary process (outside this mandate)."),
                             WIRecommendation(text: "Require receipts to be system-generated for card transactions above the threshold.")]
        w.noticeGiven = true
        w.opportunityToRespond = true
        w.submittedTo = "HR Director"
        return w
    }
}

// MARK: - The hardcopy-faithful report renderer

public enum WIReportRenderer {

    public static func markdown(_ w: WorkplaceInvestigation, generatedAt: Date) -> String {
        let df = DateFormatter(); df.dateStyle = .long
        var out = LegalNotice.reportDisclaimer + "\n\n"
        out += "# Workplace Investigation Report — \(w.title.trimmed.isEmpty ? "Untitled" : w.title)\n\n"
        out += "**Investigator:** \(w.investigator.orDashWI) · **Report date:** \(df.string(from: generatedAt))\n"
        out += "**Standard of proof:** Balance of probabilities.\n\n---\n\n"

        // 1. Executive summary — written for a reader with one minute.
        out += "## 1. Executive summary\n\n"
        let counts = Dictionary(grouping: w.allegations.compactMap(\.finding), by: { $0 })
        let summaryBits = FindingClassification.allCases.compactMap { cls -> String? in
            guard let n = counts[cls]?.count, n > 0 else { return nil }
            return "\(n) \(cls.label.lowercased())"
        }
        out += "\(w.allegations.count) allegation(s) were investigated"
        out += summaryBits.isEmpty ? ".\n\n" : ": \(summaryBits.joined(separator: ", ")).\n\n"

        // 2. Mandate.
        out += "## 2. Mandate / terms of reference\n\n\(w.mandate.trimmed.isEmpty ? "_Not stated._" : w.mandate)\n\n"

        // 3. Parties.
        if !w.parties.isEmpty {
            out += "## 3. Parties\n\n"
            for p in w.parties { out += "- **\(p.role.label):** \(p.name)\n" }
            out += "\n"
        }

        // 4. Allegations, framed as questions.
        out += "## 4. Allegations\n\n"
        for (i, a) in w.allegations.enumerated() {
            out += "**A\(i + 1).** \(a.question)\n"
            if !a.policy.trimmed.isEmpty { out += "   _Policy engaged: \(a.policy)_\n" }
        }
        out += "\n"

        // 5. Methodology.
        out += "## 5. Methodology\n\n\(w.methodologyNote.trimmed.isEmpty ? "_Not stated._" : w.methodologyNote)\n\n"

        // 6. Evidence considered.
        out += "## 6. Evidence considered\n\n"
        if w.evidence.isEmpty { out += "_None recorded._\n\n" }
        else {
            for e in w.evidence {
                var line = "- \(e.descriptionText)"
                if !e.source.trimmed.isEmpty { line += " _(\(e.source)\(e.date.trimmed.isEmpty ? "" : ", \(e.date)"))_" }
                out += line + "\n"
            }
            out += "\n"
        }

        // 7. Credibility assessment.
        if !w.credibility.isEmpty {
            out += "## 7. Credibility assessment\n\n"
            for c in w.credibility { out += "- **\(c.person):** \(c.assessment)\n" }
            out += "\n"
        }

        // 8. Findings — per allegation, classified, "because X, supported by Y".
        out += "## 8. Findings (balance of probabilities)\n\n"
        for (i, a) in w.allegations.enumerated() {
            out += "**A\(i + 1). \(a.question)**\n"
            if !a.respondentResponse.trimmed.isEmpty { out += "_Respondent's response:_ \(a.respondentResponse)\n" }
            out += "**Finding: \(a.finding?.label ?? "Not yet classified")**\n"
            if !a.reasoning.trimmed.isEmpty { out += "\(a.reasoning)\n" }
            out += "\n"
        }
        out += "_\(FindingClassifications.disciplineNote)_\n\n"

        // 9. Recommendations — ONLY when the mandate authorises them.
        if w.recommendationsAuthorised, !w.recommendations.isEmpty {
            out += "## 9. Recommendations\n\n"
            for (i, r) in w.recommendations.enumerated() { out += "\(i + 1). \(r.text)\n" }
            out += "\n"
        } else if !w.recommendations.isEmpty {
            out += "## 9. Recommendations\n\n_Recommendations were prepared but are omitted: the mandate does not authorise them._\n\n"
        }

        // 10. Procedural fairness confirmations.
        out += "## 10. Procedural fairness\n\n"
        out += "- Notice of the allegations given to the respondent: **\(w.noticeGiven ? "Yes" : "No")**\n"
        out += "- Fair opportunity to respond before findings: **\(w.opportunityToRespond ? "Yes" : "No")**\n\n"

        // Sign-off.
        out += "---\n\nPrepared by **\(w.investigator.orDashWI)**"
        if !w.submittedTo.trimmed.isEmpty { out += " · Submitted to **\(w.submittedTo)**" }
        out += "\n"
        return out
    }
}

private extension String {
    var orDashWI: String { trimmed.isEmpty ? "—" : self }
}
