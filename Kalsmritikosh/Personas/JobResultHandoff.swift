//
//  JobResultHandoff.swift
//  Kalsmritikosh
//
//  Investigator workflow review 2026-10-30, I5, closed by the App Store completion instructions §3 —
//  a reviewed job-result row is carried into the case file WITHOUT retyping and WITHOUT losing
//  anything: EVERY citation the row carries (version, object, block, quote), the saved result
//  revision it came from (validated against the ledger and identified by its payload digest, never
//  by a caller-supplied string), and the row's REVIEW STATE (accepted, completed, undecided,
//  rejected). A rejected row cannot become evidence or a finding; an undecided row enters as
//  provisional and is printed so. Each passage is verified through the case's one evidence verifier
//  (§2) as it is linked. Carrying the same row twice to the same target is refused unless intended.
//

import Foundation

public nonisolated enum JobResultHandoffError: Error, Equatable, LocalizedError {
    case noSource
    case rowOutOfRange
    case reasonRequired

    public var errorDescription: String? {
        switch self {
        case .noSource: return "This row cites no source version, so it cannot be carried into the case as evidence. Link its source first, or add it as your own note."
        case .rowOutOfRange: return "That row no longer exists in the result."
        case .reasonRequired: return "Excluding material from the report needs the reason — put it in the row's note."
        }
    }
}

/// A row as carried: validated against the saved current revision.
public nonisolated struct CarriedRow: Sendable {
    public let row: JobResultRow
    public let index: Int
    public let reviewState: CarriedReviewState
    /// SHA-256 of the saved result revision's payload (what `job_results.payload_sha256` holds).
    public let digest: String
    public let origin: String
    /// Every citation that names a source version.
    public var citations: [StudioEvidenceRef] { row.refs.filter { $0.sourceVersionID != nil } }
}

public nonisolated enum JobResultHandoff {
    /// The origin stamp a carried-over record keeps: which job, which result revision, which row.
    public static func origin(jobID: String, resultID: UUID, row: Int) -> String {
        "job:\(jobID):\(resultID.uuidString):row:\(row)"
    }

    /// The result id inside an origin stamp, when it is one.
    public static func resultID(in origin: String) -> UUID? {
        let parts = origin.split(separator: ":")
        guard parts.count >= 3, parts[0] == "job" else { return nil }
        return UUID(uuidString: String(parts[2]))
    }
    public static func jobID(in origin: String) -> String? {
        let parts = origin.split(separator: ":")
        guard parts.count >= 3, parts[0] == "job" else { return nil }
        return String(parts[1])
    }

    /// The row's first reference to an exact source version (the primary citation).
    public static func passage(of row: JobResultRow) -> StudioEvidenceRef? {
        row.refs.first { $0.sourceVersionID != nil }
    }

    /// The text carried: the row's title, with its detail when the detail adds something the title
    /// and the quoted passage do not already say.
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

    /// The row's review state in its saved revision.
    public static func reviewState(_ record: JobResultRecord, row: JobResultRow) -> CarriedReviewState {
        if record.state == .completed { return row.decision == .rejected ? .rejected : .completed }
        switch row.decision {
        case .accepted?: return .accepted
        case .rejected?: return .rejected
        case nil: return .undecided
        }
    }

    /// Validate the row against the LEDGER: the record must be the case's saved current revision for
    /// its job (not an unsaved working copy, not a superseded one), and its digest is read from the
    /// ledger, not supplied by the caller.
    public static func carried(_ record: JobResultRecord, row index: Int, results: JobResultRepository) async throws -> CarriedRow {
        guard record.content.rows.indices.contains(index) else { throw JobResultHandoffError.rowOutOfRange }
        guard try await results.latest(caseID: record.caseID, jobID: record.jobID)?.id == record.id,
              let digest = try await results.payloadSHA256(id: record.id) else { throw CaseFileError.staleResultRevision }
        let row = record.content.rows[index]
        return CarriedRow(row: row, index: index, reviewState: reviewState(record, row: row), digest: digest,
                          origin: origin(jobID: record.jobID, resultID: record.id, row: index))
    }

    /// Add the row to an allegation: ONE verified link per citation (both sides of a disagreement
    /// travel), each carrying the stance, the review state and the revision digest.
    @discardableResult
    public static func addToAllegation(_ record: JobResultRecord, row index: Int, allegationID: UUID, stance: GridStance,
                                       note: String?, results: JobResultRepository, caseFiles: CaseFileService,
                                       allowDuplicate: Bool = false, actor: String, at date: Date = Date()) async throws -> [UUID] {
        let carried = try await carried(record, row: index, results: results)
        guard carried.reviewState != .rejected else { throw CaseFileError.rejectedRowNotEvidence }
        let refs = carried.citations
        guard !refs.isEmpty else { throw JobResultHandoffError.noSource }
        var ids: [UUID] = []
        for ref in refs {
            guard let version = ref.sourceVersionID else { continue }
            let (id, _) = try await caseFiles.linkEvidence(caseID: record.caseID, allegationID: allegationID, evidenceRef: version.uuidString,
                                                           label: Self.text(of: carried.row), stance: stance, note: note ?? carried.row.note,
                                                           passage: ref, origin: carried.origin, reviewState: carried.reviewState.rawValue,
                                                           originDigest: carried.digest, allowDuplicate: allowDuplicate, actor: actor, at: date)
            ids.append(id)
        }
        return ids
    }

    /// Add the row to the chronology as an investigator entry, with every citation and its verified
    /// primary passage; a rejected row is refused.
    @discardableResult
    public static func addToChronology(_ record: JobResultRecord, row index: Int, results: JobResultRepository, caseFiles: CaseFileService,
                                       allowDuplicate: Bool = false, actor: String, at date: Date = Date()) async throws -> UUID {
        let carried = try await carried(record, row: index, results: results)
        guard carried.reviewState != .rejected else { throw CaseFileError.rejectedRowNotEvidence }
        let refs = carried.citations
        let primary = refs.first
        let support = await primary.asyncMap { ref -> CaseEvidenceVerification in
            await caseFiles.verify(reference: ref.sourceVersionID?.uuidString ?? "", passage: ref, caseID: record.caseID)
        }
        return try await caseFiles.file.addJournal(caseID: record.caseID, kind: .chronology, text: Self.text(of: carried.row), eventDate: Self.date(of: carried.row),
                                                   evidenceRef: primary?.sourceVersionID?.uuidString, quote: primary?.quote, origin: carried.origin,
                                                   citations: refs, support: support?.support, reviewState: carried.reviewState.rawValue,
                                                   originDigest: carried.digest, allowDuplicate: allowDuplicate, actor: actor, at: date)
    }

    /// Select the row for the final report, or record it as excluded with the row's note as the
    /// reason. A rejected row can only be excluded; an undecided row is included as provisional.
    @discardableResult
    public static func addToReport(_ record: JobResultRecord, row index: Int, include: Bool, allegationID: UUID? = nil,
                                   results: JobResultRepository, caseFiles: CaseFileService,
                                   allowDuplicate: Bool = false, actor: String, at date: Date = Date()) async throws -> UUID {
        let carried = try await carried(record, row: index, results: results)
        if include, carried.reviewState == .rejected { throw CaseFileError.rejectedRowNotEvidence }
        let reason = carried.row.note?.trimmingCharacters(in: .whitespacesAndNewlines)
        if !include, (reason ?? "").isEmpty { throw JobResultHandoffError.reasonRequired }
        let refs = carried.citations
        let primary = refs.first
        let support = await primary.asyncMap { ref -> CaseEvidenceVerification in
            await caseFiles.verify(reference: ref.sourceVersionID?.uuidString ?? "", passage: ref, caseID: record.caseID)
        }
        return try await caseFiles.file.addReportItem(caseID: record.caseID, allegationID: allegationID, text: Self.text(of: carried.row), quote: primary?.quote,
                                                      evidenceRef: primary?.sourceVersionID?.uuidString, origin: carried.origin,
                                                      included: include, exclusionReason: include ? nil : reason,
                                                      citations: refs, reviewState: carried.reviewState.rawValue, originDigest: carried.digest,
                                                      support: support?.support, allowDuplicate: allowDuplicate, actor: actor, at: date)
    }
}

extension Optional where Wrapped: Sendable {
    /// Map an optional through an async transform.
    func asyncMap<T: Sendable>(_ transform: (Wrapped) async -> T) async -> T? {
        guard let self else { return nil }
        return await transform(self)
    }
}
