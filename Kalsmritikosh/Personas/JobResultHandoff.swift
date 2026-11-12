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
    /// S12 (ADAPT-02) — a row carried to money must state an amount.
    case noAmount

    public var errorDescription: String? {
        switch self {
        case .noSource: return "This row cites no source version, so it cannot be carried into the case as evidence. Link its source first, or add it as your own note."
        case .rowOutOfRange: return "That row no longer exists in the result."
        case .reasonRequired: return "Excluding material from the report needs the reason — put it in the row's note."
        case .noAmount: return "This row states no amount, so it cannot become a money record. Record the amount in the row's Amounts field first."
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
    /// S16 (ARCH-05) — every reference of the row as a typed reference, its availability read from the ledger when the row
    /// was carried: a reference with no source version is `.notRecorded`, one whose version left the case `.outsideScope`,
    /// an erased one `.erased` — said so, never dropped. Filled by `JobResultHandoff.typed(_:caseID:caseFiles:)`.
    public var references: [CaseTypedReference] = []
    public init(row: JobResultRow, index: Int, reviewState: CarriedReviewState, digest: String, origin: String, references: [CaseTypedReference] = []) {
        self.row = row; self.index = index; self.reviewState = reviewState; self.digest = digest; self.origin = origin; self.references = references
    }
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

    /// Validate the row against the LEDGER and carry the LEDGER's row (N5, mandate 2026-11-01): the saved
    /// record is loaded by id — integrity-checked against its digest — and must belong to the same case and
    /// job and be the current revision; the row text, references, decision and the result state all come
    /// from that saved revision. The caller's copy is only the pointer: if its row or state differs from
    /// what was saved, that is an unsaved edit and nothing is carried (save the review first).
    public static func carried(_ record: JobResultRecord, row index: Int, results: JobResultRepository) async throws -> CarriedRow {
        guard let saved = try await results.record(id: record.id),
              saved.caseID == record.caseID, saved.jobID == record.jobID,
              try await results.latest(caseID: saved.caseID, jobID: saved.jobID)?.id == saved.id,
              let digest = try await results.payloadSHA256(id: saved.id) else { throw CaseFileError.staleResultRevision }
        guard saved.content.rows.indices.contains(index) else { throw JobResultHandoffError.rowOutOfRange }
        let row = saved.content.rows[index]
        if !record.content.rows.indices.contains(index) || record.content.rows[index] != row || record.state != saved.state {
            throw JobResultExportError.unsavedEdits
        }
        return CarriedRow(row: row, index: index, reviewState: reviewState(saved, row: row), digest: digest,
                          origin: origin(jobID: saved.jobID, resultID: saved.id, row: index))
    }

    /// S16 (ARCH-05) — the carried row's references as typed references (holder = the row's origin stamp), read in one savepoint.
    public static func typed(_ carried: CarriedRow, caseID: UUID, caseFiles: CaseFileService) async throws -> CarriedRow {
        let refs = carried.row.refs
        let holder = carried.origin
        let typed = try await caseFiles.file.database.withSavepoint("jr_refs_\(UUID().uuidString.prefix(8))") { db -> [CaseTypedReference] in
            try refs.map { r in
                let source = CaseMapSourceRef(sourceVersionID: r.sourceVersionID, objectID: r.objectID, blockID: r.blockID, documentName: nil, quote: r.quote)
                return try CaseTypedReferences.resolve(db, caseID: caseID, holder: holder, source: source, provenance: "job result row (reviewed)",
                                                       scopeFingerprint: nil)
            }
        }
        var out = carried
        out.references = typed.isEmpty
            ? [CaseTypedReference(holder: holder, objectID: nil, sourceVersionID: nil, locator: .init(blockID: nil, note: "the row cites no source"),
                                  availability: .notRecorded, scopeFingerprint: nil, provenance: "job result row (reviewed)")]
            : typed
        return out
    }

    /// S16 (ARCH-09) — run the carry's writes with the row's revision and references re-checked inside each write's savepoint:
    /// a result superseded, a digest changed or a cited version erased / taken out of the case while the carry was in flight
    /// refuses the write (`CaseApplyRecheck.Refused`) and leaves nothing.
    static func applying<T: Sendable>(_ carried: CarriedRow, record: JobResultRecord, _ body: () async throws -> T) async throws -> T {
        let check = CaseApplyRecheck.carriedRowIntact(resultID: record.id, jobID: record.jobID, digest: carried.digest, references: carried.references)
        return try await CaseApplyRecheck.$current.withValue(check) { try await body() }
    }

    /// The row, validated against the ledger, with its typed references (ARCH-05).
    static func carriedTyped(_ record: JobResultRecord, row index: Int, results: JobResultRepository, caseFiles: CaseFileService) async throws -> CarriedRow {
        try await typed(try await carried(record, row: index, results: results), caseID: record.caseID, caseFiles: caseFiles)
    }

    /// Verify EVERY citation of a carried row (N5), not only the first. The recorded support is the primary
    /// citation's when all verify; otherwise the first that does not, naming which citation it is.
    static func verifyAll(_ refs: [StudioEvidenceRef], caseID: UUID, caseFiles: CaseFileService) async -> CaseEvidenceSupport? {
        guard !refs.isEmpty else { return nil }
        var primary: CaseEvidenceSupport?
        for (i, ref) in refs.enumerated() {
            let v = await caseFiles.verify(reference: ref.sourceVersionID?.uuidString ?? "", passage: ref, caseID: caseID)
            if i == 0 { primary = v.support }
            if case .unverified(let why) = v.support {
                return .unverified(refs.count > 1 ? "citation \(i + 1) of \(refs.count): \(why)" : why)
            }
        }
        return primary
    }

    /// Add the row to an allegation: ONE verified link per citation (both sides of a disagreement
    /// travel), each carrying the stance, the review state and the revision digest.
    @discardableResult
    public static func addToAllegation(_ record: JobResultRecord, row index: Int, allegationID: UUID, stance: GridStance,
                                       note: String?, results: JobResultRepository, caseFiles: CaseFileService,
                                       allowDuplicate: Bool = false, actor: String, at date: Date = Date()) async throws -> [UUID] {
        try PaidUse.require("carry a result into the case")
        let carried = try await carriedTyped(record, row: index, results: results, caseFiles: caseFiles)
        guard carried.reviewState != .rejected else { throw CaseFileError.rejectedRowNotEvidence }
        let refs = carried.citations
        guard !refs.isEmpty else { throw JobResultHandoffError.noSource }
        var ids: [UUID] = []
        for ref in refs {
            guard let version = ref.sourceVersionID else { continue }
            let (id, _) = try await applying(carried, record: record) { try await caseFiles.linkEvidence(caseID: record.caseID, allegationID: allegationID, evidenceRef: version.uuidString,
                                                           label: Self.text(of: carried.row), stance: stance, note: note ?? carried.row.note,
                                                           passage: ref, origin: carried.origin, reviewState: carried.reviewState.rawValue,
                                                           originDigest: carried.digest, allowDuplicate: allowDuplicate, actor: actor, at: date) }
            ids.append(id)
        }
        return ids
    }

    /// Add the row to the chronology as an investigator entry, with every citation and its verified
    /// primary passage; a rejected row is refused.
    @discardableResult
    public static func addToChronology(_ record: JobResultRecord, row index: Int, results: JobResultRepository, caseFiles: CaseFileService,
                                       allowDuplicate: Bool = false, actor: String, at date: Date = Date()) async throws -> UUID {
        try PaidUse.require("carry a result into the case")
        let carried = try await carriedTyped(record, row: index, results: results, caseFiles: caseFiles)
        guard carried.reviewState != .rejected else { throw CaseFileError.rejectedRowNotEvidence }
        let refs = carried.citations
        let primary = refs.first
        let support = await verifyAll(refs, caseID: record.caseID, caseFiles: caseFiles)
        return try await applying(carried, record: record) { try await caseFiles.file.addJournal(caseID: record.caseID, kind: .chronology, text: Self.text(of: carried.row), eventDate: Self.date(of: carried.row),
                                                   evidenceRef: primary?.sourceVersionID?.uuidString, quote: primary?.quote, origin: carried.origin,
                                                   citations: refs, support: support, reviewState: carried.reviewState.rawValue,
                                                   originDigest: carried.digest, allowDuplicate: allowDuplicate,
                                                   // TIME-02: a result row's date is a calendar day (yyyy-MM-dd), kept as written.
                                                   datePrecision: .day, dateText: carried.row.date, actor: actor, at: date) }
    }

    /// Select the row for the final report, or record it as excluded with the row's note as the
    /// reason. A rejected row can only be excluded; an undecided row is included as provisional.
    @discardableResult
    public static func addToReport(_ record: JobResultRecord, row index: Int, include: Bool, allegationID: UUID? = nil,
                                   results: JobResultRepository, caseFiles: CaseFileService,
                                   allowDuplicate: Bool = false, actor: String, at date: Date = Date()) async throws -> UUID {
        try PaidUse.require("carry a result into the case")
        let carried = try await carriedTyped(record, row: index, results: results, caseFiles: caseFiles)
        if include, carried.reviewState == .rejected { throw CaseFileError.rejectedRowNotEvidence }
        let reason = carried.row.note?.trimmingCharacters(in: .whitespacesAndNewlines)
        if !include, (reason ?? "").isEmpty { throw JobResultHandoffError.reasonRequired }
        let refs = carried.citations
        let primary = refs.first
        let support = await verifyAll(refs, caseID: record.caseID, caseFiles: caseFiles)
        return try await applying(carried, record: record) { try await caseFiles.file.addReportItem(caseID: record.caseID, allegationID: allegationID, text: Self.text(of: carried.row), quote: primary?.quote,
                                                      evidenceRef: primary?.sourceVersionID?.uuidString, origin: carried.origin,
                                                      included: include, exclusionReason: include ? nil : reason,
                                                      citations: refs, reviewState: carried.reviewState.rawValue, originDigest: carried.digest,
                                                      support: support, allowDuplicate: allowDuplicate, actor: actor, at: date) }
    }
}

// MARK: - S12 (ADAPT-02): money and question destinations, with the same carry rules

extension JobResultHandoff {
    /// Carry the row into the case's money records as an UNCLASSIFIED record — a proposal: it keeps the amount as written,
    /// the row's day, its primary citation and its origin, and enters no figure until a person classifies it. The same row
    /// is carried to money once unless `allowDuplicate` asks for a distinct record.
    @discardableResult
    public static func addToMoney(_ record: JobResultRecord, row index: Int, results: JobResultRepository, caseFiles: CaseFileService,
                                  allowDuplicate: Bool = false, actor: String, at date: Date = Date()) async throws -> UUID {
        try PaidUse.require("carry a result into the case")
        let carried = try await carriedTyped(record, row: index, results: results, caseFiles: caseFiles)
        guard carried.reviewState != .rejected else { throw CaseFileError.rejectedRowNotEvidence }
        guard let amount = JobResultMapAdapter.amountText(carried.row) else { throw JobResultHandoffError.noAmount }
        var input = CaseMoneyRecordInput(kind: .unclassified, amountText: amount)
        if let d = carried.row.date, CaseMoneyLedger.date(String(d.prefix(10))) != nil { input.date = String(d.prefix(10)) } else { input.dateText = carried.row.date }
        input.currency = carried.row.fields?["currency"].flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        input.description = Self.text(of: carried.row)
        if let p = carried.citations.first {
            input.sourceVersionID = p.sourceVersionID; input.blockID = p.blockID; input.quote = p.quote
        }
        let stamp = CaseCarryStamp(origin: carried.origin, originDigest: carried.digest, reviewState: carried.reviewState.rawValue, distinct: allowDuplicate)
        return try await applying(carried, record: record) { try await caseFiles.file.recordMoney(caseID: record.caseID, input, carry: stamp, actor: actor, at: date) }
    }

    /// Carry the row into the case as an OPEN question (distinct from evidence on an existing allegation): the row's own
    /// words, its origin and its review state; it decides nothing. Deduplicated like every carry.
    @discardableResult
    public static func addToQuestion(_ record: JobResultRecord, row index: Int, results: JobResultRepository, caseFiles: CaseFileService,
                                     allowDuplicate: Bool = false, actor: String, at date: Date = Date()) async throws -> UUID {
        try PaidUse.require("carry a result into the case")
        let carried = try await carriedTyped(record, row: index, results: results, caseFiles: caseFiles)
        guard carried.reviewState != .rejected else { throw CaseFileError.rejectedRowNotEvidence }
        let stamp = CaseCarryStamp(origin: carried.origin, originDigest: carried.digest, reviewState: carried.reviewState.rawValue, distinct: allowDuplicate)
        return try await applying(carried, record: record) { try await caseFiles.file.addAllegation(caseID: record.caseID, text: Self.text(of: carried.row), carry: stamp, actor: actor, at: date) }
    }
}

extension Optional where Wrapped: Sendable {
    /// Map an optional through an async transform.
    func asyncMap<T: Sendable>(_ transform: (Wrapped) async -> T) async -> T? {
        guard let self else { return nil }
        return await transform(self)
    }
}
