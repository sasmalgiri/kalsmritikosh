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
         actionReview, methodReadiness

    /// The jobs each executor serves — only where its result IS the job's intended outcome.
    public static let assignments: [String: JobExecutorKind] = {
        var m: [String: JobExecutorKind] = [:]
        func set(_ k: JobExecutorKind, _ jobs: [String]) { for j in jobs { m[j] = k } }
        set(.chronology, ["inv.linkage", "law.fact-chronology", "hr.incident-timeline", "siu.loss-chronology", "jrn.chronology",
                          "res.chronology", "ind.personal-chronology", "ind.career-education", "gen.family-lines"])
        set(.deadlines, ["law.deadlines"])
        set(.catalogue, ["res.corpus-catalogue", "jrn.source-vault", "siu.prior-claims", "hr.evidence-register", "res.metadata"])
        set(.exhibits, ["law.exhibit-binder"])
        set(.citations, ["res.bibliography", "res.edition", "gen.originals"])
        set(.records, ["ind.document-versions", "ind.property", "ind.insurance", "ind.applications", "ind.document-vault"])
        set(.reminders, ["ind.reminders"])
        set(.reliability, ["inv.source-reliability", "res.source-criticism", "jrn.source-map", "jrn.source-reliability", "ind.doc-reliability",
                           "law.source-desk", "siu.source-vetting", "fa.doc-reliability", "hr.credibility", "gen.source-analysis"])
        set(.issueMatrix, ["law.parties-issues", "law.fact-evidence", "law.document-coding", "law.obligations", "siu.red-flags",
                           "hr.allegations", "gen.evidence-notes"])
        set(.quotes, ["res.transcription", "jrn.quote-book", "jrn.transcript", "hr.statements"])
        set(.interviewPlan, ["jrn.interview-plan", "law.witness-profiles", "law.deposition", "siu.euo-prep", "hr.interview-prep"])
        set(.causation, ["res.alternative", "res.causal", "jrn.causal", "ind.why", "law.causation", "siu.causation", "fa.analysis", "gen.migration"])
        set(.money, ["law.damages", "fa.funds-tracing", "fa.workpapers"])
        set(.disclosure, ["ind.health-scope", "ind.secure-share", "law.redaction", "hr.disclosure-review"])
        set(.dataTable, ["inv.data-lab", "jrn.data-desk"])
        set(.publication, ["jrn.publication", "jrn.publication-package"])
        set(.sameName, ["gen.same-person"])
        set(.actionRegister, ["inv.capa-register", "res.errata", "jrn.correction-history", "jrn.correction-actions", "ind.fix-it",
                              "law.remediation", "siu.recovery-actions", "fa.recovery", "hr.corrective-actions", "gen.to-do"])
        set(.actionReview, ["inv.effectiveness-review", "res.errata-review", "jrn.correction-review", "ind.fix-review", "law.remediation-review",
                            "siu.action-review", "fa.recovery-review", "hr.action-review", "gen.to-do-review"])
        set(.methodReadiness, ["inv.methods", "res.methods", "jrn.methods", "ind.methods", "law.methods", "fa.methods", "gen.methods"])
        return m
    }()

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
