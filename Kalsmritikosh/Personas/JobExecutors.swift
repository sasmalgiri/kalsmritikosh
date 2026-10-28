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
    case chronology

    /// The jobs each executor serves — only where its result IS the job's intended outcome.
    public static let assignments: [String: JobExecutorKind] = [
        "inv.linkage": .chronology, "law.fact-chronology": .chronology, "hr.incident-timeline": .chronology,
        "siu.loss-chronology": .chronology, "jrn.chronology": .chronology, "res.chronology": .chronology,
        "ind.personal-chronology": .chronology,
    ]
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
