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

    /// F16 — run the CURRENT structural parser over the exact re-verified bytes of a version
    /// (snapshot + identity URL) and return its document; nil = the type has no structural parser.
    public typealias Reparse = @Sendable (_ sourceVersionID: UUID, _ snapshotURL: URL, _ identityURL: URL) async throws -> ParsedDocument?

    public init(database: Database, readiness: SourceReadinessRepository, byteResolver: SourceVersionByteResolver,
                reparse: Reparse? = nil) {
        self.database = database
        self.readiness = readiness
        self.byteResolver = byteResolver
        self.reparse = reparse
    }

    /// The readiness dimensions produced by the structural parser (parser-version dependent).
    public static let parserDimensions: [SourceReadinessDimension] = [.structuralExtraction, .metadataExtraction, .ocr]

    public enum Outcome: Sendable, Equatable {
        case upToDate
        case reprocessed(dimensions: [SourceReadinessDimension])
        /// F16 — the current parser produces a DIFFERENT block set for these bytes. Activating it would
        /// need a versioned derivation (the committed structure is attach-once), so nothing is re-stamped:
        /// the dimensions stay honestly stale at their old producer version.
        case changedOutputNotActivated(dimensions: [SourceReadinessDimension])
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
        let fresh = try await reparse(sourceVersionID, resolved.snapshotURL, resolved.identityURL)?.blocks ?? []
        let committed = try await EvidenceStore(database: database).blocks(forVersion: sourceVersionID)
        guard Self.fingerprint(fresh) == Self.fingerprint(committed) else {
            KalsmritikoshLog.ingestion.info("reprocess \(sourceVersionID.uuidString, privacy: .public): parser \(currentParserVersion, privacy: .public) output differs from committed structure — not re-stamped")
            return .changedOutputNotActivated(dimensions: stale)
        }

        // Capture the existing parser-dimension records so the refresh preserves their exact proof.
        let snapshot = try await readiness.snapshot(sourceVersionID: sourceVersionID)
        let records = stale.compactMap { snapshot.dimension($0) }

        // Leaving `ready` requires an explicit invalidation to `running` (readiness transition rule).
        try await readiness.apply(SourceReadinessUpdatePlan(
            sourceVersionID: sourceVersionID, expectedRevision: snapshot.aggregateRevision,
            updates: records.map { SourceReadinessDimensionUpdate(dimension: $0.dimension, state: .running, action: .invalidate,
                                                                  detail: "parser upgrade to \(currentParserVersion)") },
            producerID: "usf-m3.reprocess", producerVersion: currentParserVersion, occurredAt: now))

        // Re-satisfy each dimension to its prior state with its prior proof, stamped with the new version.
        let mid = try await readiness.snapshot(sourceVersionID: sourceVersionID)
        try await readiness.apply(SourceReadinessUpdatePlan(
            sourceVersionID: sourceVersionID, expectedRevision: mid.aggregateRevision,
            updates: records.map { rec in
                SourceReadinessDimensionUpdate(
                    dimension: rec.dimension, state: rec.state,
                    action: rec.state == .ready ? .satisfy : .partiallySatisfy, applicability: rec.applicability,
                    completedUnits: rec.completedUnits, totalUnits: rec.totalUnits, basis: rec.basis, detail: rec.detail)
            },
            producerID: "usf-m3.reprocess", producerVersion: currentParserVersion, occurredAt: now))

        return .reprocessed(dimensions: stale)
    }

    /// F16 — the content identity of a block set: ordered (kind, text, locator). Ids and timestamps are
    /// excluded (a re-parse mints new ids); anything a citation shows or resolves by is included.
    static func fingerprint(_ blocks: [EvidenceBlock]) -> [String] {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return blocks.sorted { $0.ordinal < $1.ordinal }.map { b in
            let locator = (try? enc.encode(b.locator)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            return "\(b.kind.rawValue)\u{1F}\(b.rawText)\u{1F}\(locator)"
        }
    }
}
