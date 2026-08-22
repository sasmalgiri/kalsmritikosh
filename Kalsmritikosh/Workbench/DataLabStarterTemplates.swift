//
//  DataLabStarterTemplates.swift
//  Kalsmritikosh
//
//  Ready-made DataLab tables — one per professional persona — so every user
//  starts from the table they'd otherwise build by hand in Excel, instead of a
//  blank grid. Each template is a RECIPE (named columns + optional derived
//  formula columns), applied idempotently through the same field/transform
//  mechanism as the forensic net-worth workpaper (see DataLabView.applyStarter).
//
//  These are column scaffolds with plain-language help and a load-bearing note;
//  the math (totals, counts, sorting, running totals) is done by the existing
//  plain-language Analyses. A column with a `formula` becomes a derived column.
//

import Foundation

public struct DataLabStarterTemplate: Identifiable, Sendable {

    public struct Column: Sendable {
        public let name: String
        public let shape: FactSchemaRegistry.ValueShape
        public let formula: String?
        public let help: String
        public init(_ name: String, _ shape: FactSchemaRegistry.ValueShape, formula: String? = nil, help: String = "") {
            self.name = name; self.shape = shape; self.formula = formula; self.help = help
        }
    }

    public let id: String
    public let profession: String
    public let displayName: String
    public let purpose: String
    public let columns: [Column]
    /// Load-bearing caveat shown under the template.
    public let note: String

    /// Plain input columns (added as fields).
    public var inputColumns: [Column] { columns.filter { $0.formula == nil } }

    /// Derived columns → calculated-column transforms (carry lineage).
    public var transformSpecs: [WorkbenchTransformSpec] {
        columns.compactMap { col in
            col.formula.map {
                WorkbenchTransformSpec.calculatedColumn(newField: col.name, shape: col.shape, formula: $0)
            }
        }
    }

    /// The analyses this profession actually runs on this table — so DataLab
    /// shows those, not the full generic menu. Derived from the profession.
    public var analyses: [WorkbenchAnalysisPresetKind] {
        DataLabStarterTemplates.analysisKinds(forProfession: profession)
    }
}

/// Parses a clipboard block (copied from Excel / Numbers / a CSV) into rows of
/// trimmed cells, so DataLab can paste-fill a table. Tab-separated when any tab
/// is present (the spreadsheet default), otherwise comma-separated. Pure and
/// deterministic so it can be unit-tested without the pasteboard.
public enum DataLabPasteParser {
    public static func parse(_ raw: String) -> [[String]] {
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard !lines.isEmpty else { return [] }
        let separator: Character = raw.contains("\t") ? "\t" : ","
        return lines.map { line in
            line.split(separator: separator, omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
        }
    }
}

public enum DataLabStarterTemplates {

    public static let all: [DataLabStarterTemplate] = [
        // ── Lawyer — privilege log (FRCP 26(b)(5)) ───────────────────────────
        DataLabStarterTemplate(
            id: "law.datalab.privilege-log",
            profession: "Lawyer",
            displayName: "Privilege log",
            purpose: "Log each withheld or redacted document so the privilege claim can be assessed without revealing the protected content.",
            columns: [
                .init("Doc ID", .text, help: "Bates or internal identifier."),
                .init("Date", .date, help: "Date of the document."),
                .init("Author", .text, help: "Who created it."),
                .init("Recipients", .text, help: "To / cc — everyone who received it."),
                .init("Description", .text, help: "Enough to assess the claim, without disclosing the privileged content."),
                .init("Privilege basis", .text, help: "e.g. attorney-client, work product."),
                .init("Withheld or redacted", .text, help: "Whether the document is fully withheld or produced redacted.")
            ],
            note: "FRCP 26(b)(5): describe each item enough to let others test the claim — without revealing what's protected."),

        // ── Investigator — surveillance / activity log ───────────────────────
        DataLabStarterTemplate(
            id: "inv.datalab.surveillance-log",
            profession: "Investigator",
            displayName: "Surveillance / activity log",
            purpose: "A contemporaneous, timestamped log of what was observed — kept separate from what it might mean.",
            columns: [
                .init("Date", .date, help: "Day of the observation."),
                .init("Time", .text, help: "Start / end time."),
                .init("Location", .text, help: "Where it happened."),
                .init("Observed", .text, help: "What you actually saw — facts, not conclusions."),
                .init("Method or source", .text, help: "How it was obtained (must be lawful)."),
                .init("Significance", .text, help: "Your inference — kept separate from the observation.")
            ],
            note: "Record what was observed separately from what you infer; note the lawful method for each entry."),

        // ── SIU — claim red-flag triage ──────────────────────────────────────
        DataLabStarterTemplate(
            id: "siu.datalab.claim-triage",
            profession: "SIU / Insurance",
            displayName: "Claim red-flag triage",
            purpose: "Triage claims by exposure and indicators so effort matches impact.",
            columns: [
                .init("Claim no", .text, help: "Claim number."),
                .init("Insured", .text, help: "Policyholder / claimant."),
                .init("Loss date", .date, help: "Date of loss."),
                .init("Amount", .money, help: "Claimed / reserved amount."),
                .init("Indicators", .text, help: "Red flags observed — each a lead, not proof. \(SIUFraudIndicators.helpSummary)"),
                .init("Priority", .text, help: "Low / Medium / High / Critical."),
                .init("Referred", .boolean, help: "Referred for full investigation?"),
                .init("Notes", .text, help: "Next step / rationale.")
            ],
            note: "Indicators are leads, not proof of fraud — they justify a closer look, not a conclusion."),

        // ── Forensic Accountant — transaction ledger / tracing ───────────────
        DataLabStarterTemplate(
            id: "fa.datalab.transaction-ledger",
            profession: "Forensic Accountant",
            displayName: "Transaction ledger / tracing",
            purpose: "Lay out money movements — payer, payee, amount — each tied to a source document.",
            columns: [
                .init("Date", .date, help: "Transaction date."),
                .init("Description", .text, help: "What the transaction was."),
                .init("Payer", .text, help: "Who paid."),
                .init("Payee", .text, help: "Who received."),
                .init("Amount", .money, help: "Value moved."),
                .init("Account", .text, help: "Which account / statement."),
                .init("Source doc", .text, help: "The bank statement or record this row is tied to.")
            ],
            note: "Tie every row to a source document; name any missing statement or period — a silent gap misleads. \(FundsTracingMethods.helpSummary) \(FundsTracingMethods.disciplineNote)"),

        // ── HR / Compliance — allegation matrix ──────────────────────────────
        DataLabStarterTemplate(
            id: "hr.datalab.allegation-matrix",
            profession: "HR / Compliance",
            displayName: "Allegation matrix",
            purpose: "One row per allegation, mapped to policy, evidence, and finding.",
            columns: [
                .init("Allegation", .text, help: "The specific behaviour alleged — described, not labelled."),
                .init("Complainant", .text, help: "Who raised it."),
                .init("Respondent", .text, help: "Who it concerns."),
                .init("Date", .date, help: "When the conduct occurred."),
                .init("Policy", .text, help: "Which policy / rule it engages."),
                .init("Evidence", .text, help: "Statements, documents, records supporting or contradicting."),
                .init("Finding", .text, help: "Your reasoned conclusion."),
                .init("Substantiated", .boolean, help: "Is the allegation substantiated on the evidence?")
            ],
            note: "Describe behaviour and evidence, not labels — 'raised voice, pointed finger', not 'aggressive'. \(WorkplaceFairnessPrinciples.helpSummary) \(WorkplaceFairnessPrinciples.disciplineNote)"),

        // ── Researcher — systematic-review data extraction ───────────────────
        DataLabStarterTemplate(
            id: "res.datalab.extraction",
            profession: "Researcher",
            displayName: "Data extraction table",
            purpose: "One row per included study — the coding sheet for a systematic review.",
            columns: [
                .init("Study ID", .text, help: "Author-year or record ID."),
                .init("Author", .text, help: "First author."),
                .init("Year", .number, help: "Publication year."),
                .init("Design", .text, help: "RCT, cohort, case-control, etc."),
                .init("Sample size", .number, help: "Total N."),
                .init("Outcome measure", .text, help: "The outcome extracted."),
                .init("Result", .text, help: "Effect size / finding."),
                .init("Risk of bias", .text, help: "Low / some concerns / high.")
            ],
            note: "One row per included study; dual-extract independently where you can, then reconcile."),

        // ── Journalist — claim & source tracker ──────────────────────────────
        DataLabStarterTemplate(
            id: "jrn.datalab.claim-tracker",
            profession: "Journalist",
            displayName: "Claim & source tracker",
            purpose: "Track each claim, where it came from, and whether it's independently verified.",
            columns: [
                .init("Claim", .text, help: "The specific assertion."),
                .init("Source", .text, help: "Who / what it came from."),
                .init("Source type", .text, help: "Document, interview, database, etc."),
                .init("Verified", .boolean, help: "Independently confirmed?"),
                .init("Date checked", .date, help: "When you last verified it."),
                .init("Corroborations", .number, help: "How many independent sources confirm it."),
                .init("Notes", .text, help: "Caveats, denials, open questions.")
            ],
            note: "Presence in a database is not verification — corroborate independently, and note when a source declined."),

        // ── Genealogist — research log (GPS) ─────────────────────────────────
        DataLabStarterTemplate(
            id: "gen.datalab.research-log",
            profession: "Genealogist",
            displayName: "Research log",
            purpose: "Every search you ran and what it returned — including the searches that found nothing.",
            columns: [
                .init("Date", .date, help: "When you searched."),
                .init("Repository", .text, help: "Archive / site / collection."),
                .init("Source searched", .text, help: "The specific record set."),
                .init("Result", .text, help: "What you found — or 'nil'."),
                .init("Found", .boolean, help: "Did it yield anything?"),
                .init("Citation", .text, help: "Drafted source citation."),
                .init("Next step", .text, help: "What this points to next.")
            ],
            note: "Log negative results too — a documented nil search is what builds a reasonably-exhaustive search."),

        // ── Individual — accounts & assets inventory ─────────────────────────
        DataLabStarterTemplate(
            id: "ind.datalab.inventory",
            profession: "Individual",
            displayName: "Accounts & assets inventory",
            purpose: "A single place listing what you have, where it lives, and who can reach it.",
            columns: [
                .init("Item", .text, help: "Account, policy, document, or asset."),
                .init("Type", .text, help: "Bank, insurance, property, subscription, etc."),
                .init("Institution", .text, help: "Provider / holder."),
                .init("Identifier", .text, help: "Account/policy number (store securely)."),
                .init("Value", .money, help: "Approximate value, if relevant."),
                .init("Location", .text, help: "Where the original / access lives."),
                .init("Who can access", .text, help: "The trusted person who can reach it.")
            ],
            note: "The point is findability in an emergency — where each item lives and who can access it."),

        // ── Content Creator — content & disclosure log ───────────────────────
        DataLabStarterTemplate(
            id: "cc.datalab.content-log",
            profession: "Content Creator",
            displayName: "Content & disclosure log",
            purpose: "Plan pieces, track the claims that need checking, and flag required disclosures.",
            columns: [
                .init("Piece", .text, help: "Title / working name."),
                .init("Platform", .text, help: "Where it publishes."),
                .init("Publish date", .date, help: "Planned or actual date."),
                .init("Claim to check", .text, help: "Any factual claim that needs verifying."),
                .init("Source", .text, help: "Backing source for the claim."),
                .init("Verified", .boolean, help: "Checked and current?"),
                .init("Disclosure needed", .boolean, help: "Sponsored / material connection to disclose?"),
                .init("Status", .text, help: "Draft / review / published.")
            ],
            note: "Flag material connections (FTC) and re-check source currency before it goes out.")
    ]

    /// Canonical analysis order (mirrors WorkbenchModePresetCatalog.simplePresets).
    static let allAnalysesOrdered: [WorkbenchAnalysisPresetKind] = [
        .totalByCategory, .countByCategory, .averageByCategory,
        .keepRowsAbove, .keepRowsBelow, .sortLowToHigh, .sortHighToLow,
        .runningTotal, .removeDuplicates
    ]

    /// The analyses a profession genuinely uses on its table — curated so the
    /// Analyses panel shows what's needed, not the full generic list.
    static func analysisKinds(forProfession profession: String) -> [WorkbenchAnalysisPresetKind] {
        switch profession {
        case "Lawyer":
            return [.countByCategory, .sortLowToHigh, .removeDuplicates]
        case "Investigator":
            return [.sortLowToHigh, .countByCategory]
        case "SIU / Insurance":
            return [.countByCategory, .sortHighToLow, .keepRowsAbove]
        case "Forensic Accountant":
            return [.totalByCategory, .runningTotal, .sortHighToLow, .removeDuplicates]
        case "HR / Compliance":
            return [.countByCategory, .sortLowToHigh]
        case "Researcher":
            return [.averageByCategory, .countByCategory, .sortLowToHigh]
        case "Journalist":
            return [.countByCategory, .keepRowsBelow, .sortLowToHigh]
        case "Genealogist":
            return [.countByCategory, .sortLowToHigh]
        case "Individual":
            return [.totalByCategory, .sortHighToLow]
        case "Content Creator":
            return [.countByCategory, .sortLowToHigh]
        default:
            return allAnalysesOrdered
        }
    }

    /// The analyses to surface for a workspace's persona — the union across its
    /// suggested templates, in canonical order. `.general` → the full set.
    public static func analyses(for template: WorkspaceTemplate) -> [WorkbenchAnalysisPresetKind] {
        if template == .general { return allAnalysesOrdered }
        let wanted = Set(suggested(for: template).flatMap { $0.analyses })
        let ordered = allAnalysesOrdered.filter { wanted.contains($0) }
        return ordered.isEmpty ? allAnalysesOrdered : ordered
    }

    /// Templates whose profession best matches a workspace template, so the
    /// most relevant ones can be surfaced first. Falls back to all.
    public static func suggested(for template: WorkspaceTemplate) -> [DataLabStarterTemplate] {
        let professions: [String]
        switch template {
        case .legalMatter:    professions = ["Lawyer"]
        case .investigation:  professions = ["Investigator", "SIU / Insurance", "Forensic Accountant"]
        case .journalism:     professions = ["Journalist"]
        case .researchReview: professions = ["Researcher", "Genealogist"]
        case .personalMatter: professions = ["Individual"]
        case .general:        professions = []
        }
        let match = all.filter { professions.contains($0.profession) }
        return match.isEmpty ? all : match
    }
}
