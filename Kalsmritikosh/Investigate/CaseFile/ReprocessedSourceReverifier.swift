//
//  ReprocessedSourceReverifier.swift
//  Kalsmritikosh
//
//  Smart-map IN-08 (docs/IME_Full_Smart_Map_Implementation_TODO_2026-11-08.md §04): when a reader upgrade
//  re-reads a source version and a NEW derivation becomes its active structure, the case records that cite the
//  version (allegation evidence links, chronology entries, report items) are re-verified against the ledger as
//  it is now — through the one CaseEvidenceVerifier (CaseFileService.reverifyLinks / reverifyCarriedItems).
//
//  One logical effect: verification overwrites each record's stored state (never adds a row, never changes a
//  quote, note, stance or decision), and the outcome is logged once per case per activated reading — a rerun
//  for the same reading finds the log row and adds nothing. Every run terminates with a recorded state in the
//  case log: "sourceReverified" with its counts, or "sourceReverifyFailed" with the reason.
//
//  A passage pinned to a block of the EARLIER reading still verifies (the superseded block is kept for
//  citations, and its words were read from these exact bytes); whether the NEW reading still contains the
//  words is reported separately so the investigator can look again — the record is not silently re-pinned.
//

import Foundation
import os

public nonisolated struct SourceReverificationOutcome: Sendable, Equatable {
    public let caseID: UUID
    public let sourceVersionID: UUID
    /// The active reading (parser run) the records were checked against.
    public let readingID: String
    /// Records of this case citing the version that were checked.
    public let checked: Int
    public let verified: Int
    public let unverified: Int
    /// Records whose stored verification state changed in this run.
    public let changed: Int
    /// Records pinned to a block of an earlier reading of the version.
    public let pinnedToEarlierReading: Int
    /// Of those, records whose quoted words the new reading no longer contains.
    public let notInNewReading: Int
    /// Nil on success; the reason when verification could not be completed.
    public let failure: String?
    /// True when this reading had already been re-verified for this case (nothing was written).
    public let alreadyRecorded: Bool

    /// The case-log detail ("reading <id>: 3 checked · 3 verified · …").
    public var logDetail: String {
        if let failure { return "reading \(readingID): \(failure)" }
        var parts = ["\(checked) checked", "\(verified) verified", "\(unverified) unverified", "\(changed) changed"]
        if pinnedToEarlierReading > 0 {
            parts.append("\(pinnedToEarlierReading) pinned to the earlier reading")
            if notInNewReading > 0 { parts.append("\(notInNewReading) not found in the new reading — review") }
        }
        return "reading \(readingID): " + parts.joined(separator: " · ")
    }
}

public actor ReprocessedSourceReverifier {
    public static let actorName = "Source re-read check"
    public static let doneAction = "sourceReverified"
    public static let failedAction = "sourceReverifyFailed"

    private let database: Database
    private let caseFiles: CaseFileService

    public init(database: Database, caseFiles: CaseFileService) {
        self.database = database
        self.caseFiles = caseFiles
    }

    /// The cases with a live record citing the version (by reference, pinned block or citation).
    public func casesCiting(sourceVersionID svid: UUID) async throws -> [UUID] {
        let v = svid.uuidString.uppercased()
        let rows = try await database.query("""
            SELECT a.case_id FROM case_allegation_evidence e JOIN case_allegations a ON a.id = e.allegation_id
             WHERE e.removed_at IS NULL AND (upper(e.evidence_ref) = ?
                   OR e.block_id IN (SELECT id FROM evidence_blocks WHERE source_version_id = ?))
            UNION
            SELECT case_id FROM case_journal
             WHERE removed_at IS NULL AND (upper(COALESCE(evidence_ref, '')) = ? OR instr(upper(COALESCE(citations_json, '')), ?) > 0)
            UNION
            SELECT case_id FROM case_report_items
             WHERE upper(COALESCE(evidence_ref, '')) = ? OR instr(upper(COALESCE(citations_json, '')), ?) > 0;
            """, [.text(v), .uuid(svid), .text(v), .text(v), .text(v), .text(v)])
        return Array(Set(rows.compactMap { $0.uuid(0) })).sorted { $0.uuidString < $1.uuidString }
    }

    /// Re-verify every case citing `svid` after its new derivation was activated. Never throws: each case ends
    /// with a recorded state (or, when even the log cannot be written, a logged error).
    @discardableResult
    public func reverify(sourceVersionID svid: UUID, at date: Date = Date()) async -> [SourceReverificationOutcome] {
        let reading: String
        let cases: [UUID]
        do {
            reading = try await activeReading(svid)
            cases = try await casesCiting(sourceVersionID: svid)
        } catch {
            KalsmritikoshLog.app.error("IN-08 re-verification for \(svid.uuidString, privacy: .public) could not start: \(error.localizedDescription, privacy: .public)")
            return []
        }
        var out: [SourceReverificationOutcome] = []
        for caseID in cases {
            out.append(await reverify(caseID: caseID, sourceVersionID: svid, reading: reading, at: date))
        }
        return out
    }

    private func reverify(caseID: UUID, sourceVersionID svid: UUID, reading: String, at date: Date) async -> SourceReverificationOutcome {
        func outcome(_ c: Int = 0, _ v: Int = 0, _ u: Int = 0, _ ch: Int = 0, _ p: Int = 0, _ n: Int = 0,
                     failure: String? = nil, already: Bool = false) -> SourceReverificationOutcome {
            SourceReverificationOutcome(caseID: caseID, sourceVersionID: svid, readingID: reading, checked: c, verified: v, unverified: u,
                                        changed: ch, pinnedToEarlierReading: p, notInNewReading: n, failure: failure, alreadyRecorded: already)
        }
        do {
            // Once per case per reading: a rerun after the outcome was recorded adds nothing.
            if try await alreadyRecorded(caseID: caseID, svid: svid, reading: reading) { return outcome(already: true) }
            let before = try await citingRecords(caseID: caseID, svid: svid)
            try await caseFiles.reverifyLinks(caseID: caseID, at: date)
            try await caseFiles.reverifyCarriedItems(caseID: caseID, at: date)
            let after = try await citingRecords(caseID: caseID, svid: svid)

            let priorState = Dictionary(before.map { ($0.id, $0.state) }, uniquingKeysWith: { a, _ in a })
            let verified = after.filter { $0.state == "verified" || $0.state == "exhibit" }.count
            let changed = after.filter { priorState[$0.id] != $0.state }.count
            let pinned = try await pinnedToSupersededBlocks(after)
            let activeText = try await activeNormalizedText(svid)
            let missing = pinned.filter { rec in
                guard let q = rec.quote.map(StudioEvidenceResolver.norm), !q.isEmpty else { return false }
                return !activeText.contains(q)
            }.count
            let result = outcome(after.count, verified, after.count - verified, changed, pinned.count, missing)
            try await caseFiles.file.logAction(caseID: caseID, action: Self.doneAction,
                                               detail: "\(svid.uuidString) " + result.logDetail, actor: Self.actorName, at: date)
            return result
        } catch {
            let why = "re-verification could not complete (\(error.localizedDescription))"
            KalsmritikoshLog.app.error("IN-08 case \(caseID.uuidString, privacy: .public) source \(svid.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            let failed = outcome(failure: why)
            do {
                try await caseFiles.file.logAction(caseID: caseID, action: Self.failedAction,
                                                   detail: "\(svid.uuidString) " + failed.logDetail, actor: Self.actorName, at: date)
            } catch {
                KalsmritikoshLog.app.error("IN-08 failure not recorded for case \(caseID.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
            return failed
        }
    }

    // MARK: - Reads

    /// The parser run of the version's active blocks (the reading the records are checked against).
    private func activeReading(_ svid: UUID) async throws -> String {
        if let run = try await database.query("""
            SELECT pr.id FROM parser_runs pr WHERE pr.source_version_id = ?
               AND EXISTS (SELECT 1 FROM evidence_blocks b WHERE b.superseded_by_run = pr.id)
             ORDER BY pr.started_at DESC LIMIT 1;
            """, [.uuid(svid)]).first?.string(0) {
            return run
        }
        return "initial"
    }

    private func alreadyRecorded(caseID: UUID, svid: UUID, reading: String) async throws -> Bool {
        try await !database.query("""
            SELECT 1 FROM case_actions WHERE case_id = ? AND action = ? AND detail LIKE ? LIMIT 1;
            """, [.uuid(caseID), .text(Self.doneAction), .text("\(svid.uuidString) reading \(reading):%")]).isEmpty
    }

    private nonisolated struct CitingRecord { let id: UUID; let state: String?; let quote: String?; let blockIDs: [UUID] }

    /// This case's live records citing the version, with their stored state, quote and pinned blocks.
    private func citingRecords(caseID: UUID, svid: UUID) async throws -> [CitingRecord] {
        var out: [CitingRecord] = []
        let ref = svid.uuidString.uppercased()
        func cites(_ evidenceRef: String?, _ citations: [StudioEvidenceRef]) -> Bool {
            evidenceRef?.uppercased() == ref || citations.contains { $0.sourceVersionID == svid }
        }
        let blocksOfVersion = Set(try await database.query("SELECT id FROM evidence_blocks WHERE source_version_id = ?;", [.uuid(svid)]).compactMap { $0.uuid(0) })
        for l in try await caseFiles.file.allegationEvidence(caseID: caseID)
        where l.evidenceRef.uppercased() == ref || l.blockID.map(blocksOfVersion.contains) == true {
            out.append(CitingRecord(id: l.id, state: l.verification, quote: l.quote, blockIDs: l.blockID.map { [$0] } ?? []))
        }
        for e in try await caseFiles.file.journal(caseID: caseID) where cites(e.evidenceRef, e.citations) {
            out.append(CitingRecord(id: e.id, state: e.verification, quote: e.citations.first?.quote ?? e.quote,
                                    blockIDs: e.citations.filter { $0.sourceVersionID == svid || $0.sourceVersionID == nil }.compactMap(\.blockID)))
        }
        for i in try await caseFiles.file.reportItems(caseID: caseID) where cites(i.evidenceRef, i.citations) {
            out.append(CitingRecord(id: i.id, state: i.verification, quote: i.citations.first?.quote ?? i.quote,
                                    blockIDs: i.citations.filter { $0.sourceVersionID == svid || $0.sourceVersionID == nil }.compactMap(\.blockID)))
        }
        return out
    }

    /// Records with a pinned block that a later reading superseded.
    private func pinnedToSupersededBlocks(_ records: [CitingRecord]) async throws -> [CitingRecord] {
        let ids = Array(Set(records.flatMap(\.blockIDs)))
        guard !ids.isEmpty else { return [] }
        let superseded = Set(try await database.query(
            "SELECT id FROM evidence_blocks WHERE superseded_by_run IS NOT NULL AND id IN (\(ids.map { _ in "?" }.joined(separator: ",")));",
            ids.map { .uuid($0) }).compactMap { $0.uuid(0) })
        return records.filter { $0.blockIDs.contains(where: superseded.contains) }
    }

    /// The new reading's text, joined in reading order and normalised like a quote.
    private func activeNormalizedText(_ svid: UUID) async throws -> String {
        let blocks = try await EvidenceStore(database: database).blocks(forVersion: svid)
        return StudioEvidenceResolver.norm(blocks.map(\.rawText).joined(separator: " "))
    }
}
