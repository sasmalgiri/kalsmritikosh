//
//  SourceReprocessingCoordinator.swift
//  Kalsmritikosh
//
//  USF-M3 / USF-FINAL (USF-010) — integrity-preserving recovery + reprocessing. NOT a "reprocess
//  everything" mechanism: it uses the exact SourceVersion + readiness producer versions to reprocess
//  ONLY what became stale. When the structural parser is upgraded, the parser-DEPENDENT readiness
//  dimensions (structure / metadata / OCR) produced by an OLDER parser version are refreshed to the
//  current version — but FIRST the exact bytes are re-verified (a changed / missing referenced source
//  can never be re-stamped onto the old version). Custody, loader-produced search readiness, and
//  unrelated accepted analytical work are preserved; an up-to-date version reprocesses to nothing.
//

import Foundation
import os

public struct SourceReprocessingCoordinator: Sendable {

    private let database: Database
    private let readiness: SourceReadinessRepository
    private let byteResolver: SourceVersionByteResolver
    private let reparse: Reparse?
    private let reindex: Reindex?

    /// F16 — run the CURRENT structural parser over the exact re-verified bytes of a version
    /// (snapshot + identity URL) and return its document; nil = the type has no structural parser.
    public typealias Reparse = @Sendable (_ sourceVersionID: UUID, _ snapshotURL: URL, _ identityURL: URL) async throws -> ParsedDocument?
    /// F16/F25 — switch the version's search chunks (and retire their vectors) to the active derivation
    /// and advance indexing readiness from measured coverage.
    public typealias Reindex = @Sendable (_ sourceVersionID: UUID) async throws -> Void

    public init(database: Database, readiness: SourceReadinessRepository, byteResolver: SourceVersionByteResolver,
                reparse: Reparse? = nil, reindex: Reindex? = nil) {
        self.database = database
        self.readiness = readiness
        self.byteResolver = byteResolver
        self.reparse = reparse
        self.reindex = reindex
    }

    /// The readiness dimensions produced by the structural parser (parser-version dependent).
    public static let parserDimensions: [SourceReadinessDimension] = [.structuralExtraction, .metadataExtraction, .ocr]

    public enum Outcome: Sendable, Equatable {
        case upToDate
        case reprocessed(dimensions: [SourceReadinessDimension])
        /// F16 — the current parser produced a DIFFERENT block set; it was validated and activated as the
        /// version's structure (the old blocks superseded, kept for citations) and readiness re-stamped.
        case activated(dimensions: [SourceReadinessDimension], supersededBlocks: Int, activatedBlocks: Int)
        /// F16 — the changed output was worse than what it would replace, so nothing was activated or
        /// re-stamped: the dimensions stay honestly stale at their old producer version.
        case changedOutputRejected(dimensions: [SourceReadinessDimension], reason: String)
    }

    /// Parser-dependent, present dimensions whose stored producer version differs from `currentParserVersion`.
    public func staleParserDimensions(sourceVersionID: UUID, currentParserVersion: String) async throws -> [SourceReadinessDimension] {
        let names = Self.parserDimensions.map { "'\($0.rawValue)'" }.joined(separator: ",")
        let rows = try await database.query("""
            SELECT dimension, producer_version, state FROM source_readiness_dimensions
             WHERE source_version_id = ? AND dimension IN (\(names));
            """, [.uuid(sourceVersionID)])
        return rows.compactMap { r -> SourceReadinessDimension? in
            guard let dim = r.string(0).flatMap({ SourceReadinessDimension(rawValue: $0) }) else { return nil }
            let state = r.string(2) ?? ""
            guard state == "ready" || state == "partial" else { return nil }
            return (r.string(1) != currentParserVersion) ? dim : nil
        }.sorted { $0.ordinal < $1.ordinal }
    }

    /// Reprocess the exact source version to `currentParserVersion`. Re-verifies the exact bytes, then
    /// refreshes ONLY the stale parser dimensions' producer version (their committed structure is
    /// unchanged for the same bytes). Custody + search readiness + unrelated work are preserved.
    /// Up-to-date → no-op. Throws `sourceBytesChanged` / `sourceUnavailable` for a changed/missing source.
    @discardableResult
    public func reprocess(sourceVersionID: UUID, currentParserVersion: String, at now: Date) async throws -> Outcome {
        let stale = try await staleParserDimensions(sourceVersionID: sourceVersionID, currentParserVersion: currentParserVersion)
        guard !stale.isEmpty else { return .upToDate }

        // §18/§40 — re-verify the EXACT bytes before touching anything. A changed / missing referenced
        // source throws here, so the old version's readiness is never refreshed onto different bytes.
        let resolved = try await byteResolver.resolve(sourceVersionID: sourceVersionID, at: now)
        defer { try? FileManager.default.removeItem(at: resolved.cleanupDirectory) }

        // F16 — actually RUN the current parser over those bytes. Re-stamping the old proof with the new
        // version is only honest when the new parser yields the SAME block set; if it yields a different
        // one the old structure is not what v-current would produce, so nothing is stamped.
        guard let reparse else {
            throw SourceUpgradeError.missingDependency("no re-parser wired; refusing to re-stamp without running the parser")
        }
        let freshDoc = try await reparse(sourceVersionID, resolved.snapshotURL, resolved.identityURL)
        let store = EvidenceStore(database: database)
        let committed = try await store.blocks(forVersion: sourceVersionID)
        let snapshot = try await readiness.snapshot(sourceVersionID: sourceVersionID)
        let records = stale.compactMap { snapshot.dimension($0) }

        if Self.fingerprint(freshDoc?.blocks ?? []) == Self.fingerprint(committed) {
            // Resume: a derivation was activated but the stamp that follows it never landed — the proof
            // still names the run it replaced. Stamp from the ACTIVE derivation, never the old proof.
            if let active = try await store.activatedDerivationReceipt(forVersion: sourceVersionID),
               records.contains(where: { $0.basis?.kind == .parserRun && $0.basis?.identifier != active.parserRunID.uuidString }) {
                try await stamp(sourceVersionID, snapshot: snapshot, records: records, from: active,
                                version: currentParserVersion, at: now)
                try await reindex?(sourceVersionID)
                return .activated(dimensions: stale, supersededBlocks: 0, activatedBlocks: active.blockCount)
            }
            // Same structure: each dimension keeps its exact prior proof, stamped with the new version.
            try await restamp(sourceVersionID, snapshot: snapshot, to: records.map { rec in
                SourceReadinessDimensionUpdate(
                    dimension: rec.dimension, state: rec.state, action: .reconcile, applicability: rec.applicability,
                    completedUnits: rec.completedUnits, totalUnits: rec.totalUnits, basis: rec.basis, detail: rec.detail)
            }, version: currentParserVersion, at: now)
            return .reprocessed(dimensions: stale)
        }

        // F16 — the output CHANGED. Validate it, activate it as the version's structure in one
        // savepoint (the old blocks are superseded, not deleted), and only THEN re-stamp readiness
        // from the committed receipt. An interruption before the stamp leaves the dimensions stale at
        // the old version (a rerun finds the activated structure and re-stamps); never falsely v2.
        guard let freshDoc else {
            return .changedOutputRejected(dimensions: stale, reason: "the current parser produced no structure for these bytes")
        }
        if let reason = Self.activationRefusal(fresh: freshDoc, committed: committed,
                                               priorStructural: snapshot.dimension(.structuralExtraction)?.state) {
            KalsmritikoshLog.ingestion.info("reprocess \(sourceVersionID.uuidString, privacy: .public): parser \(currentParserVersion, privacy: .public) output refused — \(reason, privacy: .public)")
            return .changedOutputRejected(dimensions: stale, reason: reason)
        }
        let parser = try await store.activeParser(forVersion: sourceVersionID) ?? "reprocess"
        let activation = try await store.activateDerivation(freshDoc, parser: parser, parserVersion: currentParserVersion,
                                                            startedAt: now, endedAt: now)
        if activation.unownedCount > 0 {
            KalsmritikoshLog.ingestion.info("reprocess \(sourceVersionID.uuidString, privacy: .public): \(activation.unownedCount, privacy: .public) activated blocks have no knowable owner")
        }
        try await stamp(sourceVersionID, snapshot: snapshot, records: records, from: activation.receipt,
                        version: currentParserVersion, at: now)
        // The search chunks follow the active derivation. If this is interrupted, indexing stays
        // invalidated (see `stamp`) and reconciliation rebuilds it — the old index never passes as current.
        try await reindex?(sourceVersionID)
        return .activated(dimensions: stale, supersededBlocks: activation.supersededCount,
                          activatedBlocks: activation.activated.count)
    }

    /// Re-stamp the stale dimensions from an activated derivation's committed receipt.
    private func stamp(_ svid: UUID, snapshot: SourceReadinessSnapshot, records: [SourceReadinessDimensionRecord],
                       from receipt: StructuralPersistenceReceipt, version: String, at now: Date) async throws {
        let produced = Dictionary(IngestCoordinator.structuralReadinessUpdates(receipt).map { ($0.dimension, $0) },
                                  uniquingKeysWith: { a, _ in a })
        // The index was built from the replaced derivation: it is not current until it is switched.
        var indexing: [SourceReadinessDimensionUpdate] = []
        if let idx = snapshot.dimension(.indexing), idx.state == .ready || idx.state == .partial {
            indexing = [SourceReadinessDimensionUpdate(dimension: .indexing, state: .running, action: .invalidate,
                                                       detail: "index rebuild pending for the activated parser \(version) derivation")]
        }
        try await restamp(svid, snapshot: snapshot, to: indexing + records.map { rec in
            // A dimension the new structure no longer produces (e.g. no OCR blocks) is not applicable.
            let u = produced[rec.dimension] ?? SourceReadinessDimensionUpdate(
                dimension: rec.dimension, state: .ready, action: .satisfy, applicability: .notApplicable)
            return SourceReadinessDimensionUpdate(
                dimension: u.dimension, state: u.state, action: u.state == rec.state ? .reconcile : u.action,
                applicability: u.applicability, completedUnits: u.completedUnits, totalUnits: u.totalUnits,
                basis: u.basis, detail: "activated parser \(version) derivation")
        }, version: version, at: now)
    }

    /// Re-stamp dimensions in ONE readiness plan (same-state → `reconcile`), so no interruption can
    /// leave a dimension half-way (invalidated to `running` and never re-satisfied).
    private func restamp(_ svid: UUID, snapshot: SourceReadinessSnapshot, to updates: [SourceReadinessDimensionUpdate],
                         version: String, at now: Date) async throws {
        guard !updates.isEmpty else { return }
        try await readiness.apply(SourceReadinessUpdatePlan(
            sourceVersionID: svid, expectedRevision: snapshot.aggregateRevision, updates: updates,
            producerID: "usf-m3.reprocess", producerVersion: version, occurredAt: now))
    }

    /// F16 — why a changed derivation must NOT be activated, or nil when it may. A newer parser's output
    /// is activated only when it is at least as good as what it replaces: a clean status, substantive
    /// blocks where the old structure had them, and no fall from complete to partial.
    static func activationRefusal(fresh: ParsedDocument, committed: [EvidenceBlock],
                                  priorStructural: SourceReadinessDimensionState?) -> String? {
        guard fresh.extractionStatus == .complete || fresh.extractionStatus == .partial else {
            return "the current parser reported \(fresh.extractionStatus.rawValue)"
        }
        let meaningful = fresh.blocks.filter(\.isMeaningful)
        if meaningful.isEmpty, committed.contains(where: \.isMeaningful) {
            return "the new structure has no substantive blocks where the old one did"
        }
        // F04 — a bounded re-parse that no longer covers records the ledger already cites (e.g. rows a
        // resumable ingest committed beyond the whole-file parse's bound) would supersede real evidence.
        let freshRecords = Set(fresh.blocks.compactMap(\.recordIdentity))
        let dropped = Set(committed.compactMap(\.recordIdentity)).subtracting(freshRecords).count
        if dropped > 0 {
            return "the new structure drops \(dropped) record(s) the committed structure cites"
        }
        let complete = fresh.extractionStatus == .complete && !meaningful.isEmpty
            && meaningful.allSatisfy { $0.locator.isResolvable }
        if priorStructural == .ready, !complete {
            return "the new structure is incomplete where the old one was complete"
        }
        return nil
    }

    /// F16 — the content identity of a block set, in order. Every semantically material output field is
    /// included: kind, raw and normalized text, locator, attributes (record keys, table/row, message
    /// index, …), extraction method and confidence, language, and the parent by ORDINAL. Only fields a
    /// re-parse mints afresh are excluded: block/document ids and timestamps.
    static func fingerprint(_ blocks: [EvidenceBlock]) -> [String] {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        func json<T: Encodable>(_ v: T) -> String { (try? enc.encode(v)).flatMap { String(data: $0, encoding: .utf8) } ?? "" }
        let ordinalOf = Dictionary(blocks.map { ($0.id, $0.ordinal) }, uniquingKeysWith: { a, _ in a })
        return blocks.sorted { $0.ordinal < $1.ordinal }.map { b in
            let parent = b.parentBlockID.flatMap { ordinalOf[$0] }.map(String.init) ?? "-"
            return [b.kind.rawValue, b.rawText, b.normalizedText, json(b.locator), json(b.attributes),
                    b.extractionMethod.rawValue, String(b.extractionConfidence), b.language ?? "-", parent]
                .joined(separator: "\u{1F}")
        }
    }
}
