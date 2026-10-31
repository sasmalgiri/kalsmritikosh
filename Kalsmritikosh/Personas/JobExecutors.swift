//
//  JobExecutors.swift
//  Kalsmritikosh
//
//  Final completion instructions §3 — shared executors that produce a job's intended result, with
//  job-specific configuration. Each one is deterministic over the case's own evidence (read under the
//  job's access context) and returns a typed result the job service persists.
//

import Foundation

/// Which shared executor produces a job's result (jobs without one keep their kind's routing).
public nonisolated enum JobExecutorKind: String, Sendable {
    case chronology, deadlines, catalogue, exhibits, citations, records, reminders, reliability, issueMatrix,
         quotes, interviewPlan, causation, money, disclosure, dataTable, publication, sameName, actionRegister,
         actionReview, methodReadiness, dataAnalysis, redactionValidation,
         // Release-block directive 2026-10-29 item 1 — the deliverables of the sixteen reopened jobs.
         partiesIssues, periodChronology, careerChronology, documentCoding, statementComparison, witnessProfile,
         sourcedQuestions, workpaperTrace, sourceFamilies, sourceVault, transcriptionLineage, alternativeAccounts,
         annotatedEdition, lineage, configurableAnalysis

    /// The jobs each executor serves — only where its result IS the job's intended outcome.
    public static let assignments: [String: JobExecutorKind] = {
        var m: [String: JobExecutorKind] = [:]
        func set(_ k: JobExecutorKind, _ jobs: [String]) { for j in jobs { m[j] = k } }
        set(.chronology, ["inv.linkage", "law.fact-chronology", "hr.incident-timeline", "siu.loss-chronology", "jrn.chronology",
                          "ind.personal-chronology"])
        set(.periodChronology, ["res.chronology"])
        set(.careerChronology, ["ind.career-education"])
        set(.lineage, ["gen.family-lines"])
        set(.deadlines, ["law.deadlines"])
        set(.catalogue, ["res.corpus-catalogue", "siu.prior-claims", "hr.evidence-register", "res.metadata"])
        set(.documentCoding, ["law.document-coding"])
        set(.sourceVault, ["jrn.source-vault"])
        set(.exhibits, ["law.exhibit-binder"])
        set(.citations, ["res.bibliography", "gen.originals"])
        set(.annotatedEdition, ["res.edition"])
        set(.records, ["ind.document-versions", "ind.property", "ind.insurance", "ind.applications", "ind.document-vault"])
        set(.reminders, ["ind.reminders"])
        set(.reliability, ["inv.source-reliability", "res.source-criticism", "jrn.source-reliability", "ind.doc-reliability",
                           "law.source-desk", "siu.source-vetting", "fa.doc-reliability", "hr.credibility", "gen.source-analysis"])
        set(.sourceFamilies, ["jrn.source-map"])
        set(.issueMatrix, ["law.fact-evidence", "law.obligations", "siu.red-flags", "hr.allegations", "gen.evidence-notes"])
        set(.partiesIssues, ["law.parties-issues"])
        set(.quotes, ["jrn.quote-book", "jrn.transcript"])
        set(.statementComparison, ["hr.statements"])
        set(.transcriptionLineage, ["res.transcription"])
        set(.interviewPlan, ["jrn.interview-plan", "hr.interview-prep"])
        set(.witnessProfile, ["law.witness-profiles"])
        set(.sourcedQuestions, ["law.deposition", "siu.euo-prep"])
        set(.causation, ["res.causal", "jrn.causal", "ind.why", "law.causation", "siu.causation", "fa.analysis", "gen.migration"])
        set(.alternativeAccounts, ["res.alternative"])
        set(.money, ["law.damages", "fa.funds-tracing"])
        set(.workpaperTrace, ["fa.workpapers"])
        set(.disclosure, ["ind.health-scope", "ind.secure-share", "hr.disclosure-review"])
        set(.redactionValidation, ["law.redaction"])
        set(.dataAnalysis, ["jrn.data-desk"])
        set(.configurableAnalysis, ["inv.data-lab"])
        set(.publication, ["jrn.publication", "jrn.publication-package"])
        set(.sameName, ["gen.same-person"])
        set(.actionRegister, ["inv.capa-register", "res.errata", "jrn.correction-history", "jrn.correction-actions", "ind.fix-it",
                              "law.remediation", "siu.recovery-actions", "fa.recovery", "hr.corrective-actions", "gen.to-do"])
        set(.actionReview, ["inv.effectiveness-review", "res.errata-review", "jrn.correction-review", "ind.fix-review", "law.remediation-review",
                            "siu.action-review", "fa.recovery-review", "hr.action-review", "gen.to-do-review"])
        set(.methodReadiness, ["inv.methods", "res.methods", "jrn.methods", "ind.methods", "law.methods", "fa.methods", "gen.methods"])
        return m
    }()

    /// Audit A2 — the jobs whose executor result, once the person reviews it (decisions, notes,
    /// corrections, completion), IS the contract's required result. Every other assigned job only
    /// PREPARES material for its contract (status `.preparation`) until its full result is built.
    public static let contractMet: Set<String> = {
        // Contract met: the 16 whose reviewed rows are the result; every job whose contract columns are
        // recorded through fields (`JobFields.specs`); and the two computed results.
        let direct: Set<String> = [
            "law.fact-chronology", "hr.incident-timeline", "jrn.chronology", "ind.personal-chronology", "ind.career-education",
            "siu.loss-chronology", "res.corpus-catalogue", "hr.evidence-register", "ind.reminders", "jrn.source-reliability",
            "ind.doc-reliability", "law.source-desk", "siu.source-vetting", "fa.doc-reliability", "gen.evidence-notes", "jrn.quote-book",
        ]
        let computed: Set<String> = ["inv.data-lab", "jrn.data-desk", "law.redaction"]
        return direct.union(computed).union(Set(JobFields.specs.keys)).intersection(Set(assignments.keys))
            .subtracting(reopened.keys)
    }()

    /// B3 (completion instructions 2026-10-29) — jobs whose fields and draft rows exist but whose
    /// contract acceptance scenario the result does not yet meet: reopened as preparation, with why.
    /// Empty since the release-block directive of 2026-10-29 (item 1): each of the sixteen jobs B3 had
    /// reopened now has its own executor (`JobDeliverableExecutors.swift`) and acceptance scenario.
    /// A job whose result falls short of its contract again goes back here, with the reason.
    public static let reopened: [String: String] = [:]

    /// The action register an effectiveness review reads (same persona).
    public static let reviewedRegister: [String: String] = [
        "inv.effectiveness-review": "inv.capa-register", "res.errata-review": "res.errata", "jrn.correction-review": "jrn.correction-actions",
        "ind.fix-review": "ind.fix-it", "law.remediation-review": "law.remediation", "siu.action-review": "siu.recovery-actions",
        "fa.recovery-review": "fa.recovery", "hr.action-review": "hr.corrective-actions", "gen.to-do-review": "gen.to-do",
    ]

    /// The executor's result for evidence-only kinds (the review and method kinds need more than the
    /// evidence and are run by the job service).
    public static func run(_ kind: JobExecutorKind, _ e: JobEvidence) -> JobRun? {
        switch kind {
        case .chronology: return ChronologyExecutor.run(e.facts)
        case .deadlines: return DeadlineExecutor.run(e)
        case .catalogue: return InventoryExecutor.run(e, style: .catalogue)
        case .exhibits: return InventoryExecutor.run(e, style: .exhibit)
        case .citations: return InventoryExecutor.run(e, style: .citation)
        case .records: return InventoryExecutor.run(e, style: .records)
        case .reminders: return InventoryExecutor.reminders(e)
        case .reliability: return ReliabilityExecutor.run(e)
        case .issueMatrix: return IssueMatrixExecutor.run(e)
        case .quotes: return StatementExecutor.quotes(e)
        case .interviewPlan: return StatementExecutor.interviewPlan(e)
        case .causation: return CausationExecutor.run(e)
        case .money: return MoneyExecutor.run(e)
        case .disclosure: return DisclosureExecutor.run(e)
        case .dataTable: return DataTableExecutor.run(e)
        case .publication: return PublicationExecutor.run(e)
        case .sameName: return IdentityCandidateExecutor.run(e)
        case .actionRegister: return ActionExecutor.register(e)
        case .dataAnalysis: return DataAnalysisExecutor.run(e)
        case .redactionValidation: return RedactionValidationExecutor.run(e)
        case .partiesIssues: return PartiesIssuesExecutor.run(e)
        case .periodChronology: return PeriodChronologyExecutor.run(e)
        case .careerChronology: return CareerExecutor.run(e)
        case .documentCoding: return DocumentCodingExecutor.run(e)
        case .statementComparison: return StatementComparisonExecutor.run(e)
        case .witnessProfile: return WitnessProfileExecutor.run(e)
        case .sourcedQuestions: return SourcedQuestionsExecutor.run(e)
        case .workpaperTrace: return WorkpaperExecutor.run(e)
        case .sourceFamilies: return SourceFamilyExecutor.run(e)
        case .sourceVault: return SourceVaultExecutor.run(e)
        case .transcriptionLineage: return TranscriptionExecutor.run(e)
        case .alternativeAccounts: return AlternativeAccountsExecutor.run(e)
        case .annotatedEdition: return AnnotatedEditionExecutor.run(e)
        case .lineage: return LineageExecutor.run(e)
        // The person's saved query is applied by the job service (`PersonaJobService.runExecutor`).
        case .configurableAnalysis: return ConfigurableAnalysisExecutor.run(e)
        case .actionReview, .methodReadiness: return nil
        }
    }
}

public nonisolated enum ChronologyExecutor {

    /// A sourced chronology of the case: events in date order, each with its references and the
    /// people its title names. The same event on different days in different documents is shown on
    /// every day, flagged "disputed date" — never averaged or merged. A calendar date a document
    /// states where no event was recognised is a row too, titled by its own sentence and flagged
    /// "date stated in text" (the reader decides what happened). Documents that date nothing are a
    /// stated limitation.
    public static func run(_ facts: StudioCaseFacts) -> (state: JobResultState, content: JobResultContent) {
        guard !facts.events.isEmpty || !facts.statedDates.isEmpty else {
            return (.blocked, JobResultContent(rows: [], limitations: ["The case's documents give no dated event or calendar date, so there is no chronology to build."],
                                               nextActions: ["Add or include documents that date the events, or record dated events by hand."]))
        }
        let iso = DateFormatter(); iso.locale = Locale(identifier: "en_US_POSIX"); iso.dateFormat = "yyyy-MM-dd"; iso.timeZone = .current
        func key(_ title: String) -> String {
            title.lowercased().replacingOccurrences(of: #"[^a-z0-9 ]"#, with: " ", options: .regularExpression)
                .split(separator: " ").joined(separator: " ")
        }
        // The days each event title is given on, and by which documents.
        var days: [String: Set<String>] = [:]
        for e in facts.events { days[key(e.title), default: []].insert(iso.string(from: e.date)) }
        let names = facts.named.map(\.value).filter { $0.count >= 3 }
        var rows: [JobResultRow] = []
        var seen = Set<String>()
        for e in facts.events.sorted(by: { $0.date == $1.date ? $0.title < $1.title : $0.date < $1.date }) {
            let day = iso.string(from: e.date)
            guard seen.insert(key(e.title) + "|" + day).inserted else { continue }
            var flags: [String] = []
            if (days[key(e.title)]?.count ?? 0) > 1 { flags.append("disputed date") }
            if e.refs.isEmpty { flags.append("no source") }
            let linked = names.filter { e.title.range(of: $0, options: .caseInsensitive) != nil }
            rows.append(JobResultRow(title: e.title, detail: linked.isEmpty ? nil : "Names: " + linked.joined(separator: ", "),
                                     date: day, flags: flags, refs: e.refs))
        }
        // Dates a document states on a day it has no recognised event for.
        let eventDays = Set(facts.events.flatMap { e in e.refs.compactMap(\.objectID).map { "\($0)|" + iso.string(from: e.date) } })
        for d in facts.statedDates {
            let day = iso.string(from: d.date)
            guard !d.refs.compactMap(\.objectID).contains(where: { eventDays.contains("\($0)|" + day) }),
                  seen.insert("stated|" + key(d.title) + "|" + day).inserted else { continue }
            let linked = names.filter { d.title.range(of: $0, options: .caseInsensitive) != nil }
            rows.append(JobResultRow(title: d.title, detail: linked.isEmpty ? nil : "Names: " + linked.joined(separator: ", "),
                                     date: day, flags: ["date stated in text"], refs: d.refs))
        }
        rows.sort { $0.date == $1.date ? $0.title < $1.title : ($0.date ?? "") < ($1.date ?? "") }
        var limitations: [String] = []
        let cited = Set((facts.events + facts.statedDates).flatMap(\.refs).compactMap(\.objectID))
        let silent = facts.documents.filter { !cited.contains($0.objectID) }
        if !silent.isEmpty {
            limitations.append("\(silent.count) document(s) give no dated event or calendar date and are not in the chronology: " + silent.prefix(5).map(\.name).joined(separator: ", ") + (silent.count > 5 ? " …" : ""))
        }
        var next: [String] = []
        let disputed = rows.filter { $0.flags.contains("disputed date") }.count
        if disputed > 0 { next.append("Resolve or keep open \(disputed) event(s) whose documents give different dates.") }
        if rows.contains(where: { $0.flags.contains("no source") }) { next.append("Attach a source to every event without one.") }
        let stated = rows.filter { $0.flags.contains("date stated in text") }.count
        if stated > 0 { next.append("Read the \(stated) sentence(s) that only state a date and record what happened on that day.") }
        next.append("Review the chronology; it is a draft until you accept it.")
        return (.draft, JobResultContent(rows: rows, limitations: limitations, nextActions: next))
    }
}
