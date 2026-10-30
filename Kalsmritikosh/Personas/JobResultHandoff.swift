//
//  JobResultHandoff.swift
//  Kalsmritikosh
//
//  Investigator workflow review 2026-10-30, I5 — a reviewed job-result row is carried into the case
//  file WITHOUT retyping: to an allegation (as a passage-level evidence link with stance), to the
//  chronology (as an investigator entry quoting the passage), or into the final report's explicit
//  selection (included, or excluded with the reason). Every carry-over keeps the same source
//  identity (the exact source version, passage and quote) and names the result revision it came
//  from, so the case report and the job result point at one record.
//

import Foundation

public nonisolated enum JobResultHandoffError: Error, Equatable, LocalizedError {
    case noSource
    case sourceNotInCase
    case rowOutOfRange
    case reasonRequired

    public var errorDescription: String? {
        switch self {
        case .noSource: return "This row cites no source version, so it cannot be carried into the case as evidence. Link its source first, or add it as your own note."
        case .sourceNotInCase: return "This row's source is not in the case's scope."
        case .rowOutOfRange: return "That row no longer exists in the result."
        case .reasonRequired: return "Excluding material from the report needs the reason — put it in the row's note."
        }
    }
}

public nonisolated enum JobResultHandoff {
    /// The origin stamp a carried-over record keeps: which job, which result revision, which row.
    public static func origin(jobID: String, resultID: UUID, row: Int) -> String {
        "job:\(jobID):\(resultID.uuidString):row:\(row)"
    }

    /// The row's first reference to an exact source version — the identity the case file links.
    public static func passage(of row: JobResultRow) -> StudioEvidenceRef? {
        row.refs.first { $0.sourceVersionID != nil }
    }

    /// The text carried: the row's title, with its detail when the detail adds something the title
    /// and the quoted passage do not already say (a detail that only repeats the quote is dropped —
    /// the quote travels separately).
    public static func text(of row: JobResultRow) -> String {
        let t = row.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let d = row.detail?.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty, d != t else { return t }
        let bare = d.trimmingCharacters(in: CharacterSet(charactersIn: "“”\"' "))
        if row.refs.contains(where: { ($0.quote ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "“”\"' ")) == bare }) { return t }
        return "\(t) — \(d)"
    }

    /// The row's date as a calendar date (yyyy-MM-dd), when it has one.
    public static func date(of row: JobResultRow) -> Date? {
        guard let s = row.date else { return nil }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current
        return f.date(from: String(s.prefix(10)))
    }

    /// Add the row to an allegation as a passage-level evidence link with the stance the person chose.
    public static func addToAllegation(_ record: JobResultRecord, row index: Int, allegationID: UUID, stance: GridStance,
                                       note: String?, file: CaseFileRepository, actor: String, at date: Date = Date()) async throws {
        guard record.content.rows.indices.contains(index) else { throw JobResultHandoffError.rowOutOfRange }
        let row = record.content.rows[index]
        guard let ref = passage(of: row), let version = ref.sourceVersionID else { throw JobResultHandoffError.noSource }
        try await file.addAllegationEvidence(caseID: record.caseID, allegationID: allegationID, evidenceRef: version.uuidString,
                                             label: text(of: row), stance: stance, note: note ?? row.note, passage: ref,
                                             origin: origin(jobID: record.jobID, resultID: record.id, row: index), actor: actor, at: date)
    }

    /// Add the row to the chronology as an investigator entry quoting its passage. A row without a
    /// date is still added, undated (the report shows "—").
    @discardableResult
    public static func addToChronology(_ record: JobResultRecord, row index: Int, file: CaseFileRepository,
                                       actor: String, at date: Date = Date()) async throws -> UUID {
        guard record.content.rows.indices.contains(index) else { throw JobResultHandoffError.rowOutOfRange }
        let row = record.content.rows[index]
        let ref = passage(of: row)
        return try await file.addJournal(caseID: record.caseID, kind: .chronology, text: text(of: row), eventDate: self.date(of: row),
                                         evidenceRef: ref?.sourceVersionID?.uuidString, quote: ref?.quote,
                                         origin: origin(jobID: record.jobID, resultID: record.id, row: index), actor: actor, at: date)
    }

    /// Select the row for the final report (included), or record it as excluded with the row's note as
    /// the reason. The item keeps the passage and the result revision.
    @discardableResult
    public static func addToReport(_ record: JobResultRecord, row index: Int, include: Bool, allegationID: UUID? = nil,
                                   file: CaseFileRepository, actor: String, at date: Date = Date()) async throws -> UUID {
        guard record.content.rows.indices.contains(index) else { throw JobResultHandoffError.rowOutOfRange }
        let row = record.content.rows[index]
        let ref = passage(of: row)
        let reason = row.note?.trimmingCharacters(in: .whitespacesAndNewlines)
        if !include, (reason ?? "").isEmpty { throw JobResultHandoffError.reasonRequired }
        return try await file.addReportItem(caseID: record.caseID, allegationID: allegationID, text: text(of: row), quote: ref?.quote,
                                            evidenceRef: ref?.sourceVersionID?.uuidString,
                                            origin: origin(jobID: record.jobID, resultID: record.id, row: index),
                                            included: include, exclusionReason: include ? nil : reason, actor: actor, at: date)
    }
}
