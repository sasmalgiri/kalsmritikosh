//
//  SIUReferral.swift
//  Kalsmritikosh
//
//  PERSONA STUDIO #3 (SIU / insurance fraud) — the referral / investigation
//  report a Special Investigations Unit actually produces, per the regulatory
//  pattern (NAIC Model #901; state SIU regs): claim identification → the
//  referral basis stated against OBJECTIVE criteria (red flags are indicators,
//  never proof) → loss chronology → investigation conducted → statement
//  discrepancies → findings of fact → disposition. The real disciplines are
//  enforced: an examiner wants to see what triggered the referral, what the
//  investigator did, what they found, and what action followed — "closing a
//  case as unsubstantiated is fine when the file shows the work"; external
//  referral only at the reasonable-suspicion threshold, reported in good faith.
//
//  Pure Codable model + pure hardcopy renderer; persists on-device as JSON.
//

import Foundation

public struct SIURedFlag: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    /// A category id from SIUFraudIndicators (recognized taxonomy), or empty for custom.
    public var indicatorID: String = ""
    public var note: String = ""              // the case-specific observation
    public init(indicatorID: String = "", note: String = "") {
        self.indicatorID = indicatorID; self.note = note
    }
    public var indicatorTitle: String {
        SIUFraudIndicators.categories.first { $0.id == indicatorID }?.title ?? "Custom indicator"
    }
    public var indicatorGroup: String {
        SIUFraudIndicators.categories.first { $0.id == indicatorID }?.group ?? "Other"
    }
}

public struct SIUChronologyEvent: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var date: String = ""              // yyyy-MM-dd
    public var event: String = ""
    public var source: String = ""            // the document/statement it comes from
    public init() {}
}

public struct SIUStep: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var date: String = ""
    public var action: String = ""            // recorded statement / EUO / scene / records / ISO ClaimSearch
    public var result: String = ""
    public init() {}
}

public struct SIUDiscrepancy: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var accountA: String = ""          // one account, verbatim in substance
    public var accountB: String = ""          // the conflicting account — both preserved
    public var materiality: String = ""       // why it matters to coverage
    public init() {}
}

public nonisolated enum SIUDisposition: String, Codable, Sendable, CaseIterable, Equatable {
    case returnToClaims, referDOI, referNICB, referLawEnforcement
    public var label: String {
        switch self {
        case .returnToClaims: return "Return to claims — suspicion not substantiated"
        case .referDOI: return "Refer to the DOI fraud bureau"
        case .referNICB: return "Refer to NICB"
        case .referLawEnforcement: return "Refer to law enforcement"
        }
    }
    /// External referrals demand the reasonable-suspicion threshold; returning
    /// to claims does not (the file just has to show the work).
    public var isExternalReferral: Bool { self != .returnToClaims }
}

public struct SIUReferral: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var history: [StudioAuditEntry]?

    // Stage 1 — Claim identification.
    public var claimNumber: String = ""
    public var insured: String = ""
    public var policyNumber: String = ""
    public var lossDate: String = ""
    public var lossType: String = ""          // auto / property / WC / liability …
    public var claimedAmount: String = ""
    public var investigator: String = ""

    // Stage 2 — Referral basis (objective criteria).
    public var redFlags: [SIURedFlag] = []
    public var criteriaNote: String = ""      // which WRITTEN criteria the flags met

    // Stage 3 — Chronology & investigation.
    public var chronology: [SIUChronologyEvent] = []
    public var steps: [SIUStep] = []

    // Stage 4 — Discrepancies + findings of fact.
    public var discrepancies: [SIUDiscrepancy] = []
    public var findingsOfFact: String = ""

    // Stage 5 — Disposition.
    public var disposition: SIUDisposition?
    public var dispositionRationale: String = ""
    public var goodFaithConfirmed = false     // statutory good-faith reporting
    public var indicatorsNotProofAcknowledged = false

    public init(title: String, now: Date) {
        self.title = title; self.createdAt = now; self.updatedAt = now
    }

    public enum Stage: Int, CaseIterable, Sendable {
        case claim, redFlags, investigation, discrepancies, disposition
        public var title: String {
            switch self {
            case .claim: return "Claim"
            case .redFlags: return "Red flags"
            case .investigation: return "Investigation"
            case .discrepancies: return "Discrepancies"
            case .disposition: return "Disposition"
            }
        }
        public var systemImage: String {
            switch self {
            case .claim: return "doc.text"
            case .redFlags: return "flag"
            case .investigation: return "magnifyingglass"
            case .discrepancies: return "arrow.left.arrow.right"
            case .disposition: return "checkmark.seal"
            }
        }
    }

    public func isComplete(_ stage: Stage) -> Bool {
        switch stage {
        case .claim:         return !claimNumber.trimmed.isEmpty && !insured.trimmed.isEmpty && !lossDate.trimmed.isEmpty
        case .redFlags:      return !redFlags.isEmpty && !criteriaNote.trimmed.isEmpty
        case .investigation: return !chronology.isEmpty && !steps.isEmpty
        case .discrepancies: return !findingsOfFact.trimmed.isEmpty
        case .disposition:
            guard let d = disposition, !dispositionRationale.trimmed.isEmpty,
                  indicatorsNotProofAcknowledged else { return false }
            // External referrals additionally require the good-faith confirmation.
            return d.isExternalReferral ? goodFaithConfirmed : true
        }
    }
    public var completionFraction: Double {
        Double(Stage.allCases.filter { isComplete($0) }.count) / Double(Stage.allCases.count)
    }

    /// The worked example — the same CL-2291 claim used across the app's samples.
    public static func sample(now: Date) -> SIUReferral {
        var s = SIUReferral(title: "CL-2291 — suspected date misrepresentation", now: now)
        s.claimNumber = "CL-2291"; s.insured = "R. Claimant"; s.policyNumber = "HP-88-4410"
        s.lossDate = "2026-03-03 (disputed)"; s.lossType = "Disability — injury"; s.claimedAmount = "$46,500"
        s.investigator = "S. Iu (SIU)"
        s.redFlags = [
            SIURedFlag(indicatorID: "incident.inconsistent", note: "Injury date differs across intake form, recorded statement, and physician note."),
            SIURedFlag(indicatorID: "timing.inception", note: "Loss reported 11 days after policy inception."),
            SIURedFlag(indicatorID: "docs.altered", note: "Two versions of the 12 Feb receipt in the file.")
        ]
        s.criteriaNote = "Meets written referral criteria §2(b): two or more recognized indicators including a documentation anomaly."
        var c1 = SIUChronologyEvent(); c1.date = "2026-02-20"; c1.event = "Policy incepts"; c1.source = "policy-schedule.pdf"
        var c2 = SIUChronologyEvent(); c2.date = "2026-03-03"; c2.event = "Injury date per intake form"; c2.source = "intake-form.pdf"
        var c3 = SIUChronologyEvent(); c3.date = "2026-03-10"; c3.event = "Injury date per physician note"; c3.source = "med-record.pdf"
        var c4 = SIUChronologyEvent(); c4.date = "2026-03-14"; c4.event = "First notice of loss"; c4.source = "FNOL record"
        s.chronology = [c1, c2, c3, c4]
        var st1 = SIUStep(); st1.date = "2026-04-08"; st1.action = "Recorded statement — finance analyst"; st1.result = "Consistent with card statements."
        var st2 = SIUStep(); st2.date = "2026-04-10"; st2.action = "Recorded statement — claimant"; st2.result = "Volunteered the date discrepancy unprompted."
        var st3 = SIUStep(); st3.date = "2026-04-12"; st3.action = "ISO ClaimSearch"; st3.result = "No prior similar claims."
        s.steps = [st1, st2, st3]
        var d1 = SIUDiscrepancy()
        d1.accountA = "Intake form: injury 2026-03-03"
        d1.accountB = "Physician note: injury 2026-03-10"
        d1.materiality = "Coverage turns on whether the injury preceded a policy exclusion window."
        s.discrepancies = [d1]
        s.findingsOfFact = "The date discrepancy is documented across three sources. The claimant's unprompted disclosure, the absence of prior claims, and the intake process gap (no reconciliation step) are more consistent with a transcription error than misrepresentation. The altered-receipt indicator could not be substantiated."
        s.disposition = .returnToClaims
        s.dispositionRationale = "Suspicion not substantiated on the developed facts; recommend claims resolve the date via a targeted re-interview and medical-record reconciliation. The file shows the work performed."
        s.indicatorsNotProofAcknowledged = true
        StudioAudit.record(&s.history, "Worked example created", at: now)
        return s
    }
}

// MARK: - The hardcopy-faithful renderer

public enum SIUReportRenderer {

    public static func markdown(_ s: SIUReferral, generatedAt: Date) -> String {
        let df = DateFormatter(); df.dateStyle = .long
        var out = LegalNotice.reportDisclaimer + "\n\n"
        out += "# SIU Investigation Report — \(s.title.trimmed.isEmpty ? "Untitled" : s.title)\n\n"
        out += "_\(JurisdictionNotice.studio(instrument: "NAIC Model #901 and NICB indicators (US)"))_\n\n"

        // Claim identification block.
        out += "| Claim no. | Insured | Policy | Loss date | Loss type | Claimed amount |\n|---|---|---|---|---|---|\n"
        out += "| \(s.claimNumber.orDashSIU) | \(s.insured.orDashSIU) | \(s.policyNumber.orDashSIU) | \(s.lossDate.orDashSIU) | \(s.lossType.orDashSIU) | \(s.claimedAmount.orDashSIU) |\n\n"
        out += "**Investigator:** \(s.investigator.orDashSIU) · **Report date:** \(df.string(from: generatedAt))\n\n---\n\n"

        // 1. Referral basis — objective criteria; indicators never proof.
        out += "## 1. Referral basis (objective criteria)\n\n"
        if s.redFlags.isEmpty { out += "_None recorded._\n\n" }
        else {
            for f in s.redFlags {
                out += "- **\(f.indicatorTitle)** _(\(f.indicatorGroup))_ — \(f.note)\n"
            }
            out += "\n\(s.criteriaNote.trimmed.isEmpty ? "" : s.criteriaNote + "\n")\n"
        }
        out += "_\(SIUFraudIndicators.disciplineNote)_\n\n"

        // 2. Loss chronology.
        out += "## 2. Loss chronology\n\n| Date | Event | Source |\n|---|---|---|\n"
        for c in s.chronology { out += "| \(c.date.orDashSIU) | \(c.event.orDashSIU) | \(c.source.orDashSIU) |\n" }
        out += "\n"

        // 3. Investigation conducted.
        out += "## 3. Investigation conducted\n\n| Date | Action | Result |\n|---|---|---|\n"
        for t in s.steps { out += "| \(t.date.orDashSIU) | \(t.action.orDashSIU) | \(t.result.orDashSIU) |\n" }
        out += "\n"

        // 4. Statement / document discrepancies — both sides preserved.
        out += "## 4. Discrepancies (both accounts preserved)\n\n"
        if s.discrepancies.isEmpty { out += "_None identified._\n\n" }
        else {
            for d in s.discrepancies {
                out += "- **A:** \(d.accountA)\n  **B:** \(d.accountB)\n  _Materiality:_ \(d.materiality.orDashSIU)\n"
            }
            out += "\n"
        }

        // 5. Findings of fact.
        out += "## 5. Findings of fact\n\n\(s.findingsOfFact.trimmed.isEmpty ? "_Not stated._" : s.findingsOfFact)\n\n"

        // 6. Disposition.
        out += "## 6. Disposition\n\n"
        out += "**\(s.disposition?.label ?? "Not yet decided")**\n\n"
        if !s.dispositionRationale.trimmed.isEmpty { out += "\(s.dispositionRationale)\n\n" }
        if s.disposition?.isExternalReferral == true {
            out += "_This referral is made in good faith under the applicable insurance-fraud reporting statute._\n\n"
        }
        out += "---\n\nPrepared by **\(s.investigator.orDashSIU)**. The file documents what triggered the referral, what was done, what was found, and the action that followed.\n"
        out += StudioAudit.appendix(s.history)
        return out
    }
}

private extension String {
    var orDashSIU: String { trimmed.isEmpty ? "—" : self }
}
