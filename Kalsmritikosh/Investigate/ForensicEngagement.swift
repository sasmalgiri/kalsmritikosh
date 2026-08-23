//
//  ForensicEngagement.swift
//  Kalsmritikosh
//
//  PERSONA STUDIO #4 (Forensic Accountant) — the tracing schedule + expert
//  report, shaped by FRCP 26(a)(2)(B) and the Daubert discipline from real
//  practice: scope & qualifications → MATERIALS RELIED UPON → METHODOLOGY tied
//  to a recognized standard (the funds-tracing methods: specific identification
//  or an indirect method with justification) → the tracing schedule where every
//  amount drills to a source document → FINDINGS (facts) kept distinct from
//  OPINIONS stated to a reasonable degree of professional certainty →
//  limitations → signature. Courts exclude experts who skip these.
//
//  Pure Codable model + pure hardcopy renderer; persists on-device as JSON.
//

import Foundation

public struct FAMaterial: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var descriptionText: String = ""    // "Bank statements, Acct #4410, Jan–Mar 2026"
    public var source: String = ""             // file / producing party
    public init() {}
}

public struct FATransaction: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var date: String = ""               // yyyy-MM-dd
    public var descriptionText: String = ""
    public var payer: String = ""
    public var payee: String = ""
    public var amount: String = ""             // keep as entered; parsed for the total
    public var account: String = ""
    public var sourceDoc: String = ""          // THE rule: every row ties to a source
    public init() {}

    public var isComplete: Bool {
        !date.trimmed.isEmpty && !descriptionText.trimmed.isEmpty && !amount.trimmed.isEmpty
            && !sourceDoc.trimmed.isEmpty
    }
    /// Numeric value for the schedule total (tolerates $ and commas).
    public var amountValue: Double? {
        Double(amount.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "").trimmed)
    }
}

public struct ForensicEngagement: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date

    // Stage 1 — Engagement.
    public var scope: String = ""              // what the expert was asked to determine
    public var preparedFor: String = ""        // counsel / court
    public var expert: String = ""
    public var qualifications: String = ""     // the 26(a)(2)(B) qualifications summary

    // Stage 2 — Materials relied upon.
    public var materials: [FAMaterial] = []

    // Stage 3 — Methodology (named, from the recognized catalog).
    public var methodID: String = ""           // FundsTracingMethods id
    public var methodJustification: String = "" // esp. WHY an indirect method (direct not possible)

    // Stage 4 — The tracing schedule.
    public var schedule: [FATransaction] = []

    // Stage 5 — Findings vs opinion.
    public var findings: [String] = []         // factual observations
    public var opinion: String = ""            // the professional opinion drawn from them
    public var certaintyDeclared = false       // "to a reasonable degree of professional certainty"
    public var limitations: [String] = []

    public init(title: String, now: Date) {
        self.title = title; self.createdAt = now; self.updatedAt = now
    }

    public var method: FundsTracingMethod? { FundsTracingMethods.methods.first { $0.id == methodID } }

    public enum Stage: Int, CaseIterable, Sendable {
        case engagement, materials, method, schedule, opinion
        public var title: String {
            switch self {
            case .engagement: return "Engagement"
            case .materials: return "Materials"
            case .method: return "Method"
            case .schedule: return "Tracing schedule"
            case .opinion: return "Findings & opinion"
            }
        }
        public var systemImage: String {
            switch self {
            case .engagement: return "briefcase"
            case .materials: return "tray.full"
            case .method: return "function"
            case .schedule: return "tablecells"
            case .opinion: return "checkmark.seal"
            }
        }
    }

    public func isComplete(_ stage: Stage) -> Bool {
        switch stage {
        case .engagement: return !scope.trimmed.isEmpty && !expert.trimmed.isEmpty
        case .materials:  return !materials.isEmpty && materials.allSatisfy { !$0.descriptionText.trimmed.isEmpty }
        case .method:
            guard method != nil else { return false }
            // An INDIRECT method must be justified (direct tracing not possible).
            return method?.family == "Direct" || !methodJustification.trimmed.isEmpty
        case .schedule:   return !schedule.isEmpty && schedule.allSatisfy(\.isComplete)
        case .opinion:    return !findings.isEmpty && !opinion.trimmed.isEmpty && certaintyDeclared
        }
    }
    public var completionFraction: Double {
        Double(Stage.allCases.filter { isComplete($0) }.count) / Double(Stage.allCases.count)
    }

    public var scheduleTotal: Double { schedule.compactMap(\.amountValue).reduce(0, +) }

    /// Worked example — a small misappropriation tracing.
    public static func sample(now: Date) -> ForensicEngagement {
        var f = ForensicEngagement(title: "Acme v. Vendor — funds tracing", now: now)
        f.scope = "Determine whether, and in what amount, payments from Acme's operating account were diverted to vendor-controlled accounts between January and March 2026."
        f.preparedFor = "Counsel for Acme Corp. (plaintiff)"
        f.expert = "F. Accountant, CPA/CFF"
        f.qualifications = "CPA (GA), CFF; 14 years forensic accounting; prior testimony in 6 matters (list attached as Exhibit A)."
        var m1 = FAMaterial(); m1.descriptionText = "Operating account statements, Acct #2210, Jan–Mar 2026"; m1.source = "bank-statements.pdf (produced by Acme)"
        var m2 = FAMaterial(); m2.descriptionText = "Vendor master file and payment register"; m2.source = "ap-register.xlsx"
        var m3 = FAMaterial(); m3.descriptionText = "Incorporation records for Vendor LLC"; m3.source = "sos-filing.pdf"
        f.materials = [m1, m2, m3]
        f.methodID = "direct.specific"
        var t1 = FATransaction(); t1.date = "2026-01-18"; t1.descriptionText = "Wire — 'consulting services'"; t1.payer = "Acme operating #2210"; t1.payee = "Vendor LLC #8834"; t1.amount = "$18,400"; t1.account = "#2210"; t1.sourceDoc = "bank-statements.pdf p.4"
        var t2 = FATransaction(); t2.date = "2026-02-12"; t2.descriptionText = "Wire — duplicate invoice 1042"; t2.payer = "Acme operating #2210"; t2.payee = "Vendor LLC #8834"; t2.amount = "$18,400"; t2.account = "#2210"; t2.sourceDoc = "bank-statements.pdf p.9; ap-register row 214"
        var t3 = FATransaction(); t3.date = "2026-03-05"; t3.descriptionText = "Transfer to principal's personal account"; t3.payer = "Vendor LLC #8834"; t3.payee = "Personal #1101"; t3.amount = "$30,000"; t3.account = "#8834"; t3.sourceDoc = "vendor-statements.pdf p.2"
        f.schedule = [t1, t2, t3]
        f.findings = [
            "Invoice 1042 was paid twice, on 2026-01-18 and 2026-02-12, $18,400 each (schedule rows 1–2).",
            "Vendor LLC's sole member is the respondent (sos-filing.pdf).",
            "$30,000 moved from Vendor LLC to the respondent's personal account within 21 days of the second payment (row 3)."
        ]
        f.opinion = "To a reasonable degree of professional certainty, $18,400 of Acme funds (the duplicate payment of invoice 1042) was diverted through Vendor LLC to the respondent's personal account. The tracing is direct: each movement is identified on the schedule and drills to its source document."
        f.certaintyDeclared = true
        f.limitations = ["Vendor LLC's second account (#9911) was not produced; amounts routed through it, if any, are not captured.",
                         "No opinion is offered on intent; that is for the trier of fact."]
        return f
    }
}

// MARK: - The hardcopy-faithful renderer

public enum FAReportRenderer {

    public static func markdown(_ f: ForensicEngagement, generatedAt: Date) -> String {
        let df = DateFormatter(); df.dateStyle = .long
        var out = LegalNotice.reportDisclaimer + "\n\n"
        out += "# Expert Report of \(f.expert.orDashFA) — \(f.title.trimmed.isEmpty ? "Untitled" : f.title)\n\n"
        out += "**Prepared for:** \(f.preparedFor.orDashFA) · **Date:** \(df.string(from: generatedAt))\n"
        out += "**Prepared pursuant to Fed. R. Civ. P. 26(a)(2)(B).**\n\n---\n\n"

        out += "## 1. Engagement & scope\n\n\(f.scope.trimmed.isEmpty ? "_Not stated._" : f.scope)\n\n"
        out += "## 2. Qualifications\n\n\(f.qualifications.trimmed.isEmpty ? "_Not stated._" : f.qualifications)\n\n"

        out += "## 3. Materials relied upon\n\n"
        if f.materials.isEmpty { out += "_None recorded._\n\n" }
        else {
            for m in f.materials { out += "- \(m.descriptionText)\(m.source.trimmed.isEmpty ? "" : " _(\(m.source))_")\n" }
            out += "\n"
        }

        out += "## 4. Methodology\n\n"
        if let m = f.method {
            out += "**\(m.name)** (\(m.family) method). \(m.detail)\n"
            if !f.methodJustification.trimmed.isEmpty { out += "\n\(f.methodJustification)\n" }
        } else { out += "_Method not yet selected._\n" }
        out += "\n_\(FundsTracingMethods.disciplineNote)_\n\n"

        out += "## 5. Tracing schedule\n\n"
        out += "| # | Date | Description | Payer | Payee | Amount | Account | Source document |\n|---|---|---|---|---|---|---|---|\n"
        for (i, t) in f.schedule.enumerated() {
            out += "| \(i + 1) | \(t.date.orDashFA) | \(t.descriptionText.orDashFA) | \(t.payer.orDashFA) | \(t.payee.orDashFA) | \(t.amount.orDashFA) | \(t.account.orDashFA) | \(t.sourceDoc.orDashFA) |\n"
        }
        out += "\n**Schedule total: $\(String(format: "%.2f", f.scheduleTotal))** — every amount above drills to its source document.\n\n"

        out += "## 6. Findings of fact\n\n"
        for (i, fd) in f.findings.enumerated() { out += "\(i + 1). \(fd)\n" }
        out += "\n"

        out += "## 7. Opinion\n\n"
        out += "_The findings above are factual observations; the opinion below is the expert's professional judgement drawn from them._\n\n"
        out += (f.opinion.trimmed.isEmpty ? "_Not stated._" : f.opinion) + "\n\n"
        if f.certaintyDeclared { out += "This opinion is held **to a reasonable degree of professional certainty**.\n\n" }

        if !f.limitations.isEmpty {
            out += "## 8. Limitations\n\n"
            for l in f.limitations { out += "- \(l)\n" }
            out += "\n"
        }

        out += "---\n\nSigned: **\(f.expert.orDashFA)**\n"
        return out
    }
}

private extension String {
    var orDashFA: String { trimmed.isEmpty ? "—" : self }
}
