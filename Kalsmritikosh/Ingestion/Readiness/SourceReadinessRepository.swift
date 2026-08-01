//
//  SourceReadinessRepository.swift
//  Kalsmritikosh
//
//  USF-002 — the ONE ordinary writer of source readiness. Every mutation is a single atomic
//  plan: existence + optimistic CAS + validation + dimension writes + one aggregate revision
//  bump + contiguous events + snapshot reconstruction, all in one SAVEPOINT. A failure writes
//  nothing. Callers move individual dimensions; the overall completion state is DERIVED
//  (SourceReadinessEvaluator) and can never be caller-declared. Readiness is keyed by the exact
//  SourceVersion; aliases resolve through the canonical version and never get their own aggregate.
//

import Foundation

public struct SourceReadinessRepository: Sendable {

    private let database: Database
    public init(database: Database) { self.database = database }

    // MARK: - Bootstrap

    /// Create the aggregate + ten dimensions + ten initialize events for a new source version.
    @discardableResult
    public func bootstrap(sourceVersionID: UUID, detectedType: SourceType,
                          preservationStatus: SourcePreservationStatus, at now: Date) async throws -> SourceReadinessSnapshot {
        let records = SourceReadinessBootstrap.initialDimensions(
            sourceVersionID: sourceVersionID, detectedType: detectedType, preservationStatus: preservationStatus, at: now)
        let id = sourceVersionID
        return try await database.withSavepoint("srr_bootstrap_\(id.uuidString.prefix(8))") { db in
            try Self.initialize(db, sourceVersionID: id, records: records, now: now)
            let rebuilt = try Self.dimensionRecords(db, sourceVersionID: id)
            return SourceReadinessEvaluator.evaluate(sourceVersionID: id, aggregateRevision: 1, dimensions: rebuilt, updatedAt: now)
        }
    }

    /// In-savepoint bootstrap used by the intake transaction so a new source version never exists
    /// without its ten readiness rows. Must run inside an existing SAVEPOINT.
    static func initialize(_ db: isolated Database, sourceVersionID: UUID,
                           records: [SourceReadinessDimensionRecord], now: Date) throws {
        guard try db.query("SELECT 1 FROM source_versions WHERE id = ?;", [.uuid(sourceVersionID)]).first != nil else {
            throw SourceReadinessError.sourceVersionNotFound(sourceVersionID)
        }
        guard try db.query("SELECT 1 FROM source_readiness_aggregates WHERE source_version_id = ?;", [.uuid(sourceVersionID)]).first == nil else {
            throw SourceReadinessError.alreadyInitialized(sourceVersionID)
        }
        guard Set(records.map(\.dimension)).count == SourceReadinessDimension.allCases.count else {
            throw SourceReadinessError.incompleteDimensionSet(sourceVersionID)
        }
        try db.exec("""
            INSERT INTO source_readiness_aggregates (source_version_id, revision, event_sequence, created_at, updated_at)
            VALUES (?,?,?,?,?);
            """, [.uuid(sourceVersionID), .integer(1), .integer(Int64(records.count)), .date(now), .date(now)])
        for r in records.sorted(by: { $0.dimension.ordinal < $1.dimension.ordinal }) {
            try insertDimension(db, r)
            try insertEvent(db, sourceVersionID: sourceVersionID, sequence: r.dimension.ordinal, aggregateRevision: 1,
                            dimension: r.dimension, action: .initialize, fromState: nil, record: r, occurredAt: now)
        }
    }

    // MARK: - Apply a plan (the only ordinary mutation)

    @discardableResult
    public func apply(_ plan: SourceReadinessUpdatePlan) async throws -> SourceReadinessSnapshot {
        guard !plan.producerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SourceReadinessError.blankProducerID }
        guard !plan.producerVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SourceReadinessError.blankProducerVersion }
        // No duplicate dimensions in a single plan.
        var seen = Set<SourceReadinessDimension>()
        for u in plan.updates {
            guard seen.insert(u.dimension).inserted else { throw SourceReadinessError.duplicateDimensionUpdate(u.dimension) }
        }
        let p = plan
        return try await database.withSavepoint("srr_apply_\(p.sourceVersionID.uuidString.prefix(8))") { db in
            guard try db.query("SELECT 1 FROM source_versions WHERE id = ?;", [.uuid(p.sourceVersionID)]).first != nil else {
                throw SourceReadinessError.sourceVersionNotFound(p.sourceVersionID)
            }
            guard let agg = try Self.aggregateRow(db, sourceVersionID: p.sourceVersionID) else {
                throw SourceReadinessError.aggregateNotFound(p.sourceVersionID)
            }
            guard agg.revision == p.expectedRevision else {
                throw SourceReadinessError.revisionConflict(expected: p.expectedRevision, actual: agg.revision)
            }
            let current = try Self.dimensionRecords(db, sourceVersionID: p.sourceVersionID)
            guard current.count == SourceReadinessDimension.allCases.count else {
                throw SourceReadinessError.incompleteDimensionSet(p.sourceVersionID)
            }
            var currentByDim: [SourceReadinessDimension: SourceReadinessDimensionRecord] = [:]
            for r in current { currentByDim[r.dimension] = r }

            // Validate every update up front (fail-closed before any write).
            for u in p.updates {
                guard let cur = currentByDim[u.dimension] else { throw SourceReadinessError.dimensionMissing(u.dimension) }
                try Self.validateShape(u)
                try Self.validateTransition(from: cur.state, update: u)
                if let basis = u.basis { try Self.validateBasis(db, basis: basis, sourceVersionID: p.sourceVersionID) }
            }

            let newAggRevision = agg.revision + 1
            var sequence = agg.eventSequence
            for u in p.updates {
                let cur = currentByDim[u.dimension]!
                let record = SourceReadinessDimensionRecord(
                    sourceVersionID: p.sourceVersionID, dimension: u.dimension, state: u.state,
                    applicability: u.applicability, condition: u.condition, completedUnits: u.completedUnits,
                    totalUnits: u.totalUnits, producerID: p.producerID, producerVersion: p.producerVersion,
                    basis: u.basis, detail: u.detail, revision: cur.revision + 1, updatedAt: p.occurredAt)
                try Self.updateDimension(db, record)
                try Self.insertEvent(db, sourceVersionID: p.sourceVersionID, sequence: sequence,
                                     aggregateRevision: newAggRevision, dimension: u.dimension, action: u.action,
                                     fromState: cur.state, record: record, occurredAt: p.occurredAt)
                sequence += 1
            }
            try db.exec("UPDATE source_readiness_aggregates SET revision = ?, event_sequence = ?, updated_at = ? WHERE source_version_id = ?;",
                        [.integer(Int64(newAggRevision)), .integer(Int64(sequence)), .date(p.occurredAt), .uuid(p.sourceVersionID)])

            let rebuilt = try Self.dimensionRecords(db, sourceVersionID: p.sourceVersionID)
            guard rebuilt.count == SourceReadinessDimension.allCases.count else {
                throw SourceReadinessError.snapshotReconstructionFailed(p.sourceVersionID)
            }
            return SourceReadinessEvaluator.evaluate(sourceVersionID: p.sourceVersionID, aggregateRevision: newAggRevision,
                                                     dimensions: rebuilt, updatedAt: p.occurredAt)
        }
    }

    // MARK: - Read

    /// The deterministic snapshot for a source version.
    public func snapshot(sourceVersionID: UUID) async throws -> SourceReadinessSnapshot {
        let id = sourceVersionID
        return try await database.withSavepoint("srr_read_\(id.uuidString.prefix(8))") { db in
            guard let agg = try Self.aggregateRow(db, sourceVersionID: id) else {
                throw SourceReadinessError.aggregateNotFound(id)
            }
            let records = try Self.dimensionRecords(db, sourceVersionID: id)
            guard records.count == SourceReadinessDimension.allCases.count else {
                throw SourceReadinessError.incompleteDimensionSet(id)
            }
            return SourceReadinessEvaluator.evaluate(sourceVersionID: id, aggregateRevision: agg.revision,
                                                     dimensions: records, updatedAt: agg.updatedAt)
        }
    }

    // MARK: - Validation (§9.3 + shape mirrors the v85 CHECKs)

    private static func validateShape(_ u: SourceReadinessDimensionUpdate) throws {
        if u.action == .initialize { throw SourceReadinessError.invalidAction(.initialize) }
        if u.applicability == .notApplicable {
            guard u.state == .ready, u.condition == nil, u.completedUnits == nil, u.totalUnits == nil else {
                throw SourceReadinessError.invalidApplicability(u.dimension)
            }
        }
        if u.state == .unsupported, u.applicability == .notApplicable { throw SourceReadinessError.invalidApplicability(u.dimension) }
        if u.state == .blocked, u.condition == nil { throw SourceReadinessError.blockingConditionRequired(u.dimension) }
        if u.state != .blocked, u.condition != nil { throw SourceReadinessError.unexpectedBlockingCondition(u.dimension) }
        if (u.completedUnits == nil) != (u.totalUnits == nil) { throw SourceReadinessError.invalidCoverageUnits(u.dimension) }
        if let c = u.completedUnits, let t = u.totalUnits {
            guard c >= 0, t >= 0, c <= t else { throw SourceReadinessError.invalidCoverageUnits(u.dimension) }
        }
        if u.state == .ready, let t = u.totalUnits, t > 0, u.completedUnits != t {
            throw SourceReadinessError.invalidCoverageUnits(u.dimension)
        }
    }

    private static func naturalAction(for state: SourceReadinessDimensionState) -> SourceReadinessAction? {
        switch state {
        case .running: return .begin
        case .ready: return .satisfy
        case .partial: return .partiallySatisfy
        case .blocked: return .block
        case .unsupported: return .markUnsupported
        case .failed: return .fail
        case .notStarted: return nil
        }
    }

    private static func validateTransition(from: SourceReadinessDimensionState, update u: SourceReadinessDimensionUpdate) throws {
        let to = u.state
        func bad() -> SourceReadinessError { .invalidTransition(dimension: u.dimension, from: from, to: to) }

        // Same-state refresh: reconcile, or the state's natural re-assertion.
        if to == from {
            guard u.action == .reconcile || u.action == naturalAction(for: to) else { throw SourceReadinessError.invalidAction(u.action) }
            return
        }
        // Leaving a terminal-ish state (ready/unsupported/failed) requires an explicit invalidation to running.
        if from == .ready || from == .unsupported || from == .failed {
            guard to == .running else { throw bad() }
            guard u.action == .invalidate else { throw SourceReadinessError.invalidAction(u.action) }
            guard !(u.detail ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw bad() }
            return
        }
        // Ordinary forward transitions.
        let allowed: Set<SourceReadinessDimensionState>
        switch from {
        case .notStarted: allowed = [.running, .ready, .partial, .blocked, .unsupported, .failed]
        case .running:    allowed = [.ready, .partial, .blocked, .unsupported, .failed]
        case .partial:    allowed = [.running, .ready, .blocked, .unsupported, .failed]
        case .blocked:    allowed = [.running, .ready, .partial, .unsupported, .failed]
        case .ready, .unsupported, .failed: allowed = []   // handled above
        }
        guard allowed.contains(to) else { throw bad() }
        guard u.action == naturalAction(for: to) else { throw SourceReadinessError.invalidAction(u.action) }
    }

    private static func validateBasis(_ db: isolated Database, basis: SourceReadinessBasis, sourceVersionID: UUID) throws {
        switch basis.kind {
        case .sourceVersion:
            guard basis.identifier == sourceVersionID.uuidString else { throw SourceReadinessError.basisOwnershipMismatch(basis) }
        case .sourceDocument:
            guard try db.query("SELECT 1 FROM source_documents WHERE id = ?;", [.text(basis.identifier)]).first != nil else {
                throw SourceReadinessError.basisNotFound(basis)
            }
            guard try db.query("SELECT 1 FROM source_versions WHERE id = ? AND document_id = ?;",
                               [.uuid(sourceVersionID), .text(basis.identifier)]).first != nil else {
                throw SourceReadinessError.basisOwnershipMismatch(basis)
            }
        case .documentProfile:
            guard try db.query("SELECT 1 FROM document_profiles WHERE source_version_id = ?;", [.uuid(sourceVersionID)]).first != nil else {
                throw SourceReadinessError.basisNotFound(basis)
            }
            guard basis.identifier == sourceVersionID.uuidString else { throw SourceReadinessError.basisOwnershipMismatch(basis) }
        case .evidenceBlock:
            guard try db.query("SELECT 1 FROM evidence_blocks WHERE id = ?;", [.text(basis.identifier)]).first != nil else {
                throw SourceReadinessError.basisNotFound(basis)
            }
            guard try db.query("SELECT 1 FROM evidence_blocks WHERE id = ? AND source_version_id = ?;",
                               [.text(basis.identifier), .uuid(sourceVersionID)]).first != nil else {
                throw SourceReadinessError.basisOwnershipMismatch(basis)
            }
        case .parserRun:
            guard try db.query("SELECT 1 FROM parser_runs WHERE id = ?;", [.text(basis.identifier)]).first != nil else {
                throw SourceReadinessError.basisNotFound(basis)
            }
            guard try db.query("SELECT 1 FROM parser_runs WHERE id = ? AND source_version_id = ?;",
                               [.text(basis.identifier), .uuid(sourceVersionID)]).first != nil else {
                throw SourceReadinessError.basisOwnershipMismatch(basis)
            }
        case .ftsIndex, .vectorIndex, .custody:
            break   // soft references — no canonical row to own; ownership is the version by construction.
        }
    }

    // MARK: - SQL helpers

    struct AggregateRow { let revision: Int; let eventSequence: Int; let updatedAt: Date }

    static func aggregateRow(_ db: isolated Database, sourceVersionID: UUID) throws -> AggregateRow? {
        guard let r = try db.query("SELECT revision, event_sequence, updated_at FROM source_readiness_aggregates WHERE source_version_id = ?;",
                                   [.uuid(sourceVersionID)]).first,
              let rev = r.int(0), let seq = r.int(1) else { return nil }
        return AggregateRow(revision: Int(rev), eventSequence: Int(seq), updatedAt: r.date(2) ?? Date(timeIntervalSince1970: 0))
    }

    static func dimensionRecords(_ db: isolated Database, sourceVersionID: UUID) throws -> [SourceReadinessDimensionRecord] {
        let rows = try db.query("""
            SELECT dimension, state, applicability, condition, completed_units, total_units, producer_id,
                   producer_version, basis_kind, basis_identifier, detail, revision, updated_at
              FROM source_readiness_dimensions WHERE source_version_id = ?;
            """, [.uuid(sourceVersionID)])
        var out: [SourceReadinessDimensionRecord] = []
        for r in rows {
            guard let dim = (r.string(0)).flatMap(SourceReadinessDimension.init(rawValue:)),
                  let state = (r.string(1)).flatMap(SourceReadinessDimensionState.init(rawValue:)),
                  let appl = (r.string(2)).flatMap(SourceReadinessApplicability.init(rawValue:)),
                  let rev = r.int(11) else {
                throw SourceReadinessError.snapshotReconstructionFailed(sourceVersionID)
            }
            let condition = r.string(3).flatMap(SourceReadinessCondition.init(rawValue:))
            let basis: SourceReadinessBasis? = {
                guard let k = r.string(8).flatMap(SourceReadinessBasisKind.init(rawValue:)), let id = r.string(9) else { return nil }
                return SourceReadinessBasis(kind: k, identifier: id)
            }()
            out.append(SourceReadinessDimensionRecord(
                sourceVersionID: sourceVersionID, dimension: dim, state: state, applicability: appl, condition: condition,
                completedUnits: r.int(4).map(Int.init), totalUnits: r.int(5).map(Int.init),
                producerID: r.string(6) ?? "", producerVersion: r.string(7) ?? "", basis: basis,
                detail: r.string(10), revision: Int(rev), updatedAt: r.date(12) ?? Date(timeIntervalSince1970: 0)))
        }
        return out.sorted { $0.dimension.ordinal < $1.dimension.ordinal }
    }

    private static func insertDimension(_ db: isolated Database, _ r: SourceReadinessDimensionRecord) throws {
        try db.exec("""
            INSERT INTO source_readiness_dimensions
                (source_version_id, dimension, state, applicability, condition, completed_units, total_units,
                 producer_id, producer_version, basis_kind, basis_identifier, detail, revision, updated_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?);
            """, bindDimension(r))
    }

    private static func updateDimension(_ db: isolated Database, _ r: SourceReadinessDimensionRecord) throws {
        try db.exec("""
            UPDATE source_readiness_dimensions SET state = ?, applicability = ?, condition = ?, completed_units = ?,
                   total_units = ?, producer_id = ?, producer_version = ?, basis_kind = ?, basis_identifier = ?,
                   detail = ?, revision = ?, updated_at = ? WHERE source_version_id = ? AND dimension = ?;
            """, [.text(r.state.rawValue), .text(r.applicability.rawValue), r.condition.map { SQLValue.text($0.rawValue) } ?? .null,
                  r.completedUnits.map { SQLValue.integer(Int64($0)) } ?? .null, r.totalUnits.map { SQLValue.integer(Int64($0)) } ?? .null,
                  .text(r.producerID), .text(r.producerVersion), r.basis.map { SQLValue.text($0.kind.rawValue) } ?? .null,
                  r.basis.map { SQLValue.text($0.identifier) } ?? .null, r.detail.map(SQLValue.text) ?? .null,
                  .integer(Int64(r.revision)), .date(r.updatedAt), .uuid(r.sourceVersionID), .text(r.dimension.rawValue)])
    }

    private static func bindDimension(_ r: SourceReadinessDimensionRecord) -> [SQLValue] {
        [.uuid(r.sourceVersionID), .text(r.dimension.rawValue), .text(r.state.rawValue), .text(r.applicability.rawValue),
         r.condition.map { SQLValue.text($0.rawValue) } ?? .null,
         r.completedUnits.map { SQLValue.integer(Int64($0)) } ?? .null, r.totalUnits.map { SQLValue.integer(Int64($0)) } ?? .null,
         .text(r.producerID), .text(r.producerVersion), r.basis.map { SQLValue.text($0.kind.rawValue) } ?? .null,
         r.basis.map { SQLValue.text($0.identifier) } ?? .null, r.detail.map(SQLValue.text) ?? .null,
         .integer(Int64(r.revision)), .date(r.updatedAt)]
    }

    private static func insertEvent(_ db: isolated Database, sourceVersionID: UUID, sequence: Int, aggregateRevision: Int,
                                    dimension: SourceReadinessDimension, action: SourceReadinessAction,
                                    fromState: SourceReadinessDimensionState?, record r: SourceReadinessDimensionRecord,
                                    occurredAt: Date) throws {
        try db.exec("""
            INSERT INTO source_readiness_events
                (id, source_version_id, sequence, aggregate_revision, dimension, action, from_state, to_state,
                 applicability, condition, completed_units, total_units, producer_id, producer_version,
                 basis_kind, basis_identifier, detail, occurred_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(UUID()), .uuid(sourceVersionID), .integer(Int64(sequence)), .integer(Int64(aggregateRevision)),
                  .text(dimension.rawValue), .text(action.rawValue), fromState.map { SQLValue.text($0.rawValue) } ?? .null,
                  .text(r.state.rawValue), .text(r.applicability.rawValue), r.condition.map { SQLValue.text($0.rawValue) } ?? .null,
                  r.completedUnits.map { SQLValue.integer(Int64($0)) } ?? .null, r.totalUnits.map { SQLValue.integer(Int64($0)) } ?? .null,
                  .text(r.producerID), .text(r.producerVersion), r.basis.map { SQLValue.text($0.kind.rawValue) } ?? .null,
                  r.basis.map { SQLValue.text($0.identifier) } ?? .null, r.detail.map(SQLValue.text) ?? .null, .date(occurredAt)])
    }
}
