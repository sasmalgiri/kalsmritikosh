//
//  JobResultMapAdapter.swift
//  Kalsmritikosh
//
//  Smart-map S12 (ADAPT-01 / ADAPT-03) — how every retained persona job's result reaches the case map: through the
//  CANONICAL case records the existing hand-off writes (evidence on a question, a chronology entry, a report item, an
//  unclassified money record, an open question), never through a parallel store. One adapter per job kind, so every job
//  in the catalogue resolves to its destinations — or, for the two kinds whose output IS a canonical record already (the
//  case itself, its closure position), to the record it is. Persona labels are presentation only: the same record has
//  the same identity, state and links whatever profession's words name it.
//

import Foundation

public nonisolated enum JobResultDestination: String, Sendable, CaseIterable, Identifiable {
    case allegationEvidence, chronology, report, money, question
    public var id: String { rawValue }
    /// The control that carries a row there (JobResultView ▸ “Add to case…”).
    public var control: String {
        switch self {
        case .allegationEvidence: return "Link to allegation…"
        case .chronology: return "Add to chronology"
        case .report: return "Include in report"
        case .money: return "Add to money records"
        case .question: return "Add as an open question"
        }
    }
    /// Where the carried row appears on the case map.
    public var mapLanding: String {
        switch self {
        case .allegationEvidence: return "a Supports / Challenges / Mentions link from its document to the question"
        case .chronology: return "an Event, Derived from its document"
        case .report: return "a report item, Selected for report under its question"
        case .money: return "a Money item, unclassified (in no figure until a person classifies it)"
        case .question: return "a Question, open"
        }
    }
    /// The canonical table the carry writes (the one ledger).
    public var canonicalTable: String {
        switch self {
        case .allegationEvidence: return "case_allegation_evidence"
        case .chronology: return "case_journal"
        case .report: return "case_report_items"
        case .money: return "case_money_records"
        case .question: return "case_allegations"
        }
    }
}

public nonisolated enum JobResultMapAdapter {
    /// The destinations a job kind's result rows may be carried to. Empty: the job's output is itself a canonical record
    /// (see `canonicalOutput`).
    public static func destinations(for kind: PersonaJobKind) -> [JobResultDestination] {
        switch kind {
        case .caseIntake, .closure: return []
        case .findings: return [.report, .allegationEvidence]
        case .linkage, .dataLab: return [.chronology, .allegationEvidence, .report, .money, .question]
        case .analysis, .contradictionGap, .causalAnalysis: return [.question, .allegationEvidence, .report, .chronology]
        case .capaRegister, .effectivenessReview: return [.report, .question, .allegationEvidence]
        case .ask, .methods, .subjectDossier, .identityResolution, .sourceReliability, .evidenceCustody:
            return [.allegationEvidence, .chronology, .report, .question]
        }
    }

    /// For the kinds without row destinations: the canonical record the job writes directly.
    public static func canonicalOutput(for kind: PersonaJobKind) -> String? {
        switch kind {
        case .caseIntake: return "the case itself and its scope (investigation_cases, investigation_case_sources) — the map's case item and its documents"
        case .closure: return "the case's stage and closure position (case_profiles, case_closure_records) — the map's header and History"
        default: return nil
        }
    }

    /// Every catalogue job with its adapter: (job, destinations, canonical output).
    public static func coverage() -> [(job: PersonaJob, destinations: [JobResultDestination], canonical: String?)] {
        PersonaJobCatalogComposer.allJobs.map { ($0, destinations(for: $0.kind), canonicalOutput(for: $0.kind)) }
    }

    /// The amount a row states, as written: its Amounts / Amount field, else nil (never read out of free prose).
    public static func amountText(_ row: JobResultRow) -> String? {
        for key in ["amount", "amounts"] {
            if let v = row.fields?[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty {
                // Several amounts in one cell ("USD 500; USD 650") are not one money record: the first, as written.
                return v.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) }
            }
        }
        return nil
    }
}

// MARK: - ADAPT-03: persona words for map kinds, through the frozen terminology (presentation only)

public nonisolated enum CaseMapPersonaLabels {
    /// The terminology token a map kind is named by, when there is one.
    public static func token(for kind: CaseMapNodeKind) -> PersonaTerminologyToken? {
        switch kind {
        case .finding: return .claim
        case .question: return .issue
        case .hypothesis: return .hypothesis
        case .evidence: return .evidence
        case .action: return .task
        default: return nil
        }
    }

    /// The label of a map kind for a persona application: the persona's own nonblank word when its terminology defines
    /// one, otherwise the canonical label. Never an identifier; never changes what the record is.
    public static func label(_ kind: CaseMapNodeKind, persona: ApplicationDefinitionID?) -> String {
        guard let persona, let token = token(for: kind), let terminology = terminology(for: persona) else { return kind.label }
        let snapshot = TerminologyDefinitionSnapshot(from: terminology)
        guard let word = try? PersonaTerminologyResolver().label(for: token, in: snapshot, expectedApplicationID: persona,
                                                                  expectedVersion: terminology.version, canonicalFallback: kind.label) else { return kind.label }
        // The map's finding kind also holds report items: the persona's word names the first part only.
        if kind == .finding, word != kind.label { return "\(word) or report item" }
        return word
    }

    /// The registered terminology packs (the same packages the production catalogue composes).
    static let terminologies: [PersonaTerminologyDefinition] = [
        InvestigatorPersonaPackage.terminology, ResearcherPersonaPackage.terminology, JournalistPersonaPackage.terminology,
        IndividualPersonaPackage.terminology, LawyerPersonaPackage.terminology, SIUPersonaPackage.terminology,
        ForensicAccountantPersonaPackage.terminology, CompliancePersonaPackage.terminology, GenealogistPersonaPackage.terminology,
        ContentCreatorPersonaPackage.terminology]

    static func terminology(for persona: ApplicationDefinitionID) -> PersonaTerminologyDefinition? {
        terminologies.first { $0.applicationID == persona }
    }
}
