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
    // Final brief §3.4 (optional so schedules saved earlier still open).
    public var kind: FAKind?                   // nil: saved before classification existed
    public var currency: String?               // ISO code; nil/empty: read from the amount's symbol
    public var reference: String?              // cheque/UTR/wire reference — part of the transaction's identity
    /// The case passage this row was prefilled from (source version + block/object + amount): a second
    /// prefill never re-adds it, and never skips a different passage that has the same amount.
    public var sourceKey: String?
    /// Set by the accountant when two rows look alike but are separate transactions.
    public var confirmedDistinct: Bool?
    public init() {}

    public var isComplete: Bool {
        !date.trimmed.isEmpty && !descriptionText.trimmed.isEmpty && !amount.trimmed.isEmpty
            && !sourceDoc.trimmed.isEmpty
    }
    /// The exact amount (sign kept), or nil when unreadable.
    public var amountDecimal: Decimal? { FAMoney.value(of: amount) }
    /// The row's currency: stated, else read from the amount ("₹1,000" → INR); "" when neither says.
    public var effectiveCurrency: String {
        let c = (currency ?? "").trimmed.uppercased()
        return c.isEmpty ? FAMoney.currency(of: amount) : c
    }
    /// The same transaction filed in two documents has the same identity; two payments differ in
    /// date, account, parties or reference.
    func identity(kind: FAKind) -> String {
        let n = { (s: String) in s.lowercased().components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ") }
        return [kind.rawValue, n(date), amountDecimal.map { "\($0.magnitude)" } ?? n(amount), effectiveCurrency, n(account), n(payer), n(payee), n(reference ?? "")].joined(separator: "|")
    }
}

public struct ForensicEngagement: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var history: [StudioAuditEntry]?
    /// A2 — where each filled field came from (case evidence or investigator entry).
    public var provenance: StudioProvenance?

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
    /// Stated opening/closing balances per account and period (final brief §3.4).
    public var reconciliations: [FAReconciliation]?
    /// What the last prefill could not bring in (a capped candidate list is said, not implied complete).
    public var prefillNote: String?

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
        // Every row sourced AND classified: an amount mention is not yet a movement of money.
        case .schedule:   return !schedule.isEmpty && schedule.allSatisfy { $0.isComplete && kind(of: $0) != .unclassified }
        case .opinion:    return !findings.isEmpty && !opinion.trimmed.isEmpty && certaintyDeclared
        }
    }
    public var completionFraction: Double {
        Double(Stage.allCases.filter { isComplete($0) }.count) / Double(Stage.allCases.count)
    }

    /// A row's kind. A row saved before classification existed counts as the payment it was entered
    /// as — unless the case prefilled its amount, in which case it is still only a candidate.
    public func kind(of t: FATransaction) -> FAKind {
        if let k = t.kind { return k }
        if let p = provenance?["schedule.\(t.id.uuidString).amount"], !p.investigatorEntry, !p.evidence.isEmpty { return .unclassified }
        return .payment
    }

    /// Gross, returned and net per currency; what is left out, and why.
    public var summary: FAScheduleSummary {
        var s = FAScheduleSummary()
        var seen: [String: UUID] = [:]
        for t in schedule {
            let k = kind(of: t)
            if k == .unclassified { s.unclassified.append(t.id); continue }
            if !k.isMovement { s.notMovements.append(t.id); continue }
            guard let v = t.amountDecimal else { s.unreadable.append(t.id); continue }
            let key = t.identity(kind: k)
            if t.confirmedDistinct != true, let first = seen[key] { s.duplicateCopies.append((t.id, first)); continue }
            seen[key] = seen[key] ?? t.id
            var tot = s.byCurrency[t.effectiveCurrency] ?? .init()
            let m = v.magnitude
            if k.isOutflow { tot.gross += m } else if k.isReturn { tot.returned += m } else if k == .receipt { tot.receipts += m }
            s.byCurrency[t.effectiveCurrency] = tot
        }
        return s
    }

    /// Each reconciliation: opening + money in − money out for that account in its period, against
    /// the stated closing balance. Duplicate copies, candidates and non-movements are excluded.
    public func reconcile() -> [FAReconciliationResult] {
        let excluded = Set(summary.duplicateCopies.map(\.row))
        return (reconciliations ?? []).map { r in
            guard let opening = FAMoney.value(of: r.opening) else {
                return FAReconciliationResult(id: r.id, expectedClosing: nil, stated: FAMoney.value(of: r.closing))
            }
            var bal = opening
            let acct = r.account.trimmed.lowercased()
            for t in schedule where !excluded.contains(t.id) && t.date >= r.periodStart && t.date <= r.periodEnd {
                let k = kind(of: t)
                guard k.isMovement, let v = t.amountDecimal?.magnitude else { continue }
                let from = t.account.trimmed.lowercased() == acct || t.payer.lowercased().contains(acct)
                let to = t.payee.lowercased().contains(acct)
                if k == .receipt || k.isReturn { if from || to { bal += v } }
                else if from { bal -= v } else if to { bal += v }
            }
            return FAReconciliationResult(id: r.id, expectedClosing: bal, stated: FAMoney.value(of: r.closing))
        }
    }

    /// Gaps between one account's reconciled periods ("2026-02-01 – 2026-02-28"), so a missing
    /// statement is visible rather than silently absent.
    public var missingPeriods: [String] {
        var out: [String] = []
        let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX"); df.dateFormat = "yyyy-MM-dd"
        let cal = Calendar(identifier: .gregorian)
        let byAccount = Dictionary(grouping: reconciliations ?? [], by: { $0.account.trimmed.lowercased() })
        for (account, periods) in byAccount.sorted(by: { $0.key < $1.key }) {
            let sorted = periods.sorted { $0.periodStart < $1.periodStart }
            for (a, b) in zip(sorted, sorted.dropFirst()) {
                guard let end = df.date(from: a.periodEnd), let start = df.date(from: b.periodStart),
                      let next = cal.date(byAdding: .day, value: 1, to: end), next < start,
                      let last = cal.date(byAdding: .day, value: -1, to: start) else { continue }
                out.append("\(account.isEmpty ? "account not stated" : account): \(df.string(from: next)) – \(df.string(from: last))")
            }
        }
        return out
    }

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
        t1.kind = .payment; t2.kind = .payment; t3.kind = .payment
        t1.currency = "USD"; t2.currency = "USD"; t3.currency = "USD"
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
        StudioAudit.record(&f.history, "Worked example created", at: now)
        return f
    }
}

// MARK: - The hardcopy-faithful renderer

public enum FAReportRenderer {

    /// Totals per currency (gross / returned / net), what is excluded and why, the reconciliations
    /// and any missing periods (final brief §3.4).
    static func totals(_ f: ForensicEngagement) -> String {
        let s = f.summary
        var out = "\n"
        if s.byCurrency.isEmpty { out += "**No classified movements yet** — the schedule has no total.\n" }
        for (cur, t) in s.byCurrency.sorted(by: { $0.key < $1.key }) {
            out += "**Schedule total (\(FAMoney.label(cur))):** gross movements \(FAMoney.format(t.gross)); returned (refunds, reversals) \(FAMoney.format(t.returned)); **net \(FAMoney.format(t.net))**"
            if t.receipts != 0 { out += "; receipts into the account \(FAMoney.format(t.receipts))" }
            out += ".\n"
        }
        if s.byCurrency.count > 1 { out += "_Currencies are totalled separately; no conversion is applied._\n" }
        let row = { (id: UUID) in (f.schedule.firstIndex { $0.id == id }).map { "row \($0 + 1)" } ?? "a row" }
        if !s.unclassified.isEmpty { out += "\n_Not in the totals — amount mentions not yet classified as movements: \(s.unclassified.map(row).joined(separator: ", "))._\n" }
        if !s.notMovements.isEmpty { out += "_Not in the totals — invoices, claims, reserves, balances or quotations: \(s.notMovements.map(row).joined(separator: ", "))._\n" }
        if !s.duplicateCopies.isEmpty { out += "_Counted once — the same transaction in another document: \(s.duplicateCopies.map { "\(row($0.row)) (= \(row($0.of)))" }.joined(separator: ", "))._\n" }
        if !s.unreadable.isEmpty { out += "_Not in the totals — amount unreadable: \(s.unreadable.map(row).joined(separator: ", "))._\n" }
        out += "\nEvery amount above drills to its source document.\n"
        let results = f.reconcile()
        if !results.isEmpty {
            out += "\n### Reconciliation\n\n| Account | Period | Opening | Expected closing | Stated closing | Difference | Statement |\n|---|---|---|---|---|---|---|\n"
            for (r, res) in zip(f.reconciliations ?? [], results) {
                let e = res.expectedClosing.map(FAMoney.format) ?? "—", st = res.stated.map(FAMoney.format) ?? "—"
                let d = res.difference.map { $0 == 0 ? "reconciles" : "**\(FAMoney.format($0)) unexplained**" } ?? "—"
                out += "| \(r.account.orDashFA) | \(r.periodStart.orDashFA) – \(r.periodEnd.orDashFA) | \(r.opening.orDashFA) | \(e) | \(st) | \(d) | \(r.sourceDoc.orDashFA) |\n"
            }
            out += "\n_An unexplained difference is a gap in the schedule or the statements — not, by itself, a loss or an irregularity._\n"
        }
        let gaps = f.missingPeriods
        if !gaps.isEmpty { out += "\n**Periods with no statement:** \(gaps.joined(separator: "; ")).\n" }
        if let note = f.prefillNote, !note.isEmpty { out += "\n_\(note)_\n" }
        return out + "\n"
    }

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
        out += Self.totals(f)

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
        out += StudioExportGate.provenanceAppendix(f.gateValues, provenance: f.provenance)
        out += StudioAudit.appendix(f.history)
        return out
    }
}

private extension String {
    var orDashFA: String { trimmed.isEmpty ? "—" : self }
}
