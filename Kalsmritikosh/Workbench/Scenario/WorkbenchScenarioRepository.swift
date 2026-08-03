//
//  WorkbenchScenarioRepository.swift
//  Kalsmritikosh
//
//  LAB-003 (Stage C) — the ONE authoritative writer/reader for scenario overlays (schema v94). Every
//  mutation is atomic (SAVEPOINT), carries optimistic revision CAS, and appends exactly one durable
//  audit event. The overlay is an append-only OPERATION LOG plus an undo/redo pointer: undo/redo move
//  the pointer, a new operation after an undo ABANDONS (never deletes, never resurrects) the redo
//  branch, and the current scenario state is always REPLAYED from the live operations up to the pointer
//  — so close/reopen restores the exact position and the whole history is provable. Canonical evidence,
//  the source cells and the LAB-002 derivations are READ-ONLY here: the repository never inserts,
//  updates or deletes a canonical row, and promotion only RECORDS a human-reviewed routing to an
//  existing authority (never performs the canonical write itself).
//

import Foundation

public actor WorkbenchScenarioRepository {
    private let database: Database

    public init(database: Database) { self.database = database }

    // MARK: - Create

    /// Open a new scenario over a dataset at its current revision (pointer at origin, `created` event).
    @discardableResult
    public func createScenario(datasetID: UUID, title: String, actor: String, at date: Date) async throws -> WorkbenchScenarioRecord {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw WorkbenchScenarioError.blankTitle }
        try requireActor(actor)
        guard let baseRev = try await datasetRevision(datasetID) else { throw WorkbenchScenarioError.datasetNotFound(datasetID) }
        let id = UUID()
        let sp = savepoint("wbsc_create", id)
        do {
            try await database.exec("SAVEPOINT \(sp);")
            try await database.exec("""
                INSERT INTO workbench_scenarios (id, dataset_id, base_dataset_revision, title, status, current_op_seq, revision, actor, created_at, updated_at)
                VALUES (?,?,?,?,?,?,?,?,?,?);
                """, [.uuid(id), .uuid(datasetID), .integer(Int64(baseRev)), .text(clean), .text(WorkbenchScenarioStatus.active.rawValue),
                      .integer(0), .integer(1), .text(actor), .date(date), .date(date)])
            try await appendEvent(scenarioID: id, revision: 1, action: .created, actor: actor, detail: nil, at: date)
            try await database.exec("RELEASE SAVEPOINT \(sp);")
        } catch { try? await rollback(sp); throw error }
        return try await require(id)
    }

    // MARK: - Apply an overlay operation

    @discardableResult
    public func applyOperation(scenarioID: UUID, kind: WorkbenchScenarioOpKind, rowID: UUID, fieldID: UUID?,
                               afterValue: String?, reason: String?, expectedRevision: Int,
                               actor: String, at date: Date) async throws -> WorkbenchScenarioRecord {
        try requireActor(actor)
        let sc = try await requireActiveScenario(scenarioID); try requireRevision(sc, expectedRevision)
        let targetKind: WorkbenchScenarioTargetKind = (kind == .rowInclusion || kind == .rowExclusion || (kind == .classification && fieldID == nil) || (kind == .annotation && fieldID == nil)) ? .row : .cell
        if targetKind == .cell && fieldID == nil { throw WorkbenchScenarioError.fieldRequiredForCellOp }
        // Ownership: the row (and field, for a cell op) must belong to the scenario's dataset.
        guard try await rowInDataset(rowID, sc.datasetID) else { throw WorkbenchScenarioError.rowNotInDataset(rowID) }
        if targetKind == .cell, let f = fieldID, try await !fieldInDataset(f, sc.datasetID) { throw WorkbenchScenarioError.fieldNotInDataset(f) }
        if kind == .proposedCorrection && (reason?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
            throw WorkbenchScenarioError.blankReason
        }

        // The projected value at the target BEFORE this op (audit / comparison).
        let before: String? = targetKind == .cell ? try await projectedCellValue(sc, rowID: rowID, fieldID: fieldID!) : nil
        let newRev = sc.revision + 1
        let sp = savepoint("wbsc_apply", UUID())
        do {
            try await database.exec("SAVEPOINT \(sp);")
            // A new operation after an undo truncates (abandons) the redo branch — never resurrected.
            try await database.exec("""
                UPDATE workbench_scenario_operations SET status = 'abandoned'
                WHERE scenario_id = ? AND status = 'live' AND sequence > ?;
                """, [.uuid(scenarioID), .integer(Int64(sc.currentOpSeq))])
            let seq = try await maxOpSequence(scenarioID) + 1     // monotone, never reused
            try await database.exec("""
                INSERT INTO workbench_scenario_operations (id, scenario_id, sequence, kind, target_kind, row_id, field_id, before_value, after_value, reason, status, actor, created_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?);
                """, [.uuid(UUID()), .uuid(scenarioID), .integer(Int64(seq)), .text(kind.rawValue), .text(targetKind.rawValue),
                      .uuid(rowID), fieldID.map { SQLValue.uuid($0) } ?? .null,
                      before.map { SQLValue.text($0) } ?? .null, afterValue.map { SQLValue.text($0) } ?? .null,
                      reason.map { SQLValue.text($0) } ?? .null, .text(WorkbenchScenarioOpStatus.live.rawValue), .text(actor), .date(date)])
            try await movePointer(scenarioID, to: seq, revision: newRev, at: date)
            try await appendEvent(scenarioID: scenarioID, revision: newRev, action: .operationApplied, actor: actor, detail: kind.rawValue, at: date)
            try await database.exec("RELEASE SAVEPOINT \(sp);")
        } catch { try? await rollback(sp); throw error }
        return try await require(scenarioID)
    }

    // MARK: - Undo / redo / reset

    @discardableResult
    public func undo(scenarioID: UUID, expectedRevision: Int, actor: String, at date: Date) async throws -> WorkbenchScenarioRecord {
        try requireActor(actor)
        let sc = try await requireActiveScenario(scenarioID); try requireRevision(sc, expectedRevision)
        guard sc.currentOpSeq > 0, try await liveOpExists(scenarioID, atOrBelow: sc.currentOpSeq) else { throw WorkbenchScenarioError.nothingToUndo }
        let newPointer = try await greatestLiveSeq(scenarioID, below: sc.currentOpSeq)   // 0 if none
        try await pointerMutation(scenarioID, to: newPointer, revision: sc.revision + 1, action: .undone, actor: actor, at: date)
        return try await require(scenarioID)
    }

    @discardableResult
    public func redo(scenarioID: UUID, expectedRevision: Int, actor: String, at date: Date) async throws -> WorkbenchScenarioRecord {
        try requireActor(actor)
        let sc = try await requireActiveScenario(scenarioID); try requireRevision(sc, expectedRevision)
        guard let next = try await smallestLiveSeq(scenarioID, above: sc.currentOpSeq) else { throw WorkbenchScenarioError.nothingToRedo }
        try await pointerMutation(scenarioID, to: next, revision: sc.revision + 1, action: .redone, actor: actor, at: date)
        return try await require(scenarioID)
    }

    /// Reset the overlay to the scenario origin (pointer → 0). Non-destructive: the operation log is
    /// preserved (all operations remain, redoable), so reset is itself reversible via redo.
    @discardableResult
    public func reset(scenarioID: UUID, expectedRevision: Int, actor: String, at date: Date) async throws -> WorkbenchScenarioRecord {
        try requireActor(actor)
        let sc = try await requireActiveScenario(scenarioID); try requireRevision(sc, expectedRevision)
        try await pointerMutation(scenarioID, to: 0, revision: sc.revision + 1, action: .reset, actor: actor, at: date)
        return try await require(scenarioID)
    }

    // MARK: - Discard / duplicate

    /// Discard: mark the scenario inactive. The operation log, reviews and events are PRESERVED (the
    /// audit trail of what was proposed and what happened survives). Canonical state is unchanged.
    @discardableResult
    public func discard(scenarioID: UUID, actor: String, at date: Date) async throws -> WorkbenchScenarioRecord {
        try requireActor(actor)
        let sc = try await requireActiveScenario(scenarioID)
        let newRev = sc.revision + 1
        let sp = savepoint("wbsc_discard", scenarioID)
        do {
            try await database.exec("SAVEPOINT \(sp);")
            try await database.exec("UPDATE workbench_scenarios SET status = 'discarded', revision = ?, updated_at = ? WHERE id = ?;",
                                    [.integer(Int64(newRev)), .date(date), .uuid(scenarioID)])
            try await appendEvent(scenarioID: scenarioID, revision: newRev, action: .discarded, actor: actor, detail: nil, at: date)
            try await database.exec("RELEASE SAVEPOINT \(sp);")
        } catch { try? await rollback(sp); throw error }
        return try await require(scenarioID)
    }

    /// Duplicate the scenario's CURRENT applied state into a fresh independent scenario (copying only the
    /// applied live operations, resequenced 1…N with the pointer at N). A `duplicated` event is recorded
    /// on the source; the new scenario opens with a `created` event.
    @discardableResult
    public func duplicate(scenarioID: UUID, newTitle: String, actor: String, at date: Date) async throws -> WorkbenchScenarioRecord {
        try requireActor(actor)
        let clean = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw WorkbenchScenarioError.blankTitle }
        let source = try await require(scenarioID)
        let applied = source.appliedOperations
        let newID = UUID()
        let sp = savepoint("wbsc_dup", newID)
        do {
            try await database.exec("SAVEPOINT \(sp);")
            try await database.exec("""
                INSERT INTO workbench_scenarios (id, dataset_id, base_dataset_revision, title, status, current_op_seq, revision, actor, created_at, updated_at)
                VALUES (?,?,?,?,?,?,?,?,?,?);
                """, [.uuid(newID), .uuid(source.scenario.datasetID), .integer(Int64(source.scenario.baseDatasetRevision)),
                      .text(clean), .text(WorkbenchScenarioStatus.active.rawValue), .integer(Int64(applied.count)),
                      .integer(1), .text(actor), .date(date), .date(date)])
            for (i, op) in applied.enumerated() {
                try await database.exec("""
                    INSERT INTO workbench_scenario_operations (id, scenario_id, sequence, kind, target_kind, row_id, field_id, before_value, after_value, reason, status, actor, created_at)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?);
                    """, [.uuid(UUID()), .uuid(newID), .integer(Int64(i + 1)), .text(op.kind.rawValue), .text(op.targetKind.rawValue),
                          .uuid(op.rowID), op.fieldID.map { SQLValue.uuid($0) } ?? .null,
                          op.beforeValue.map { SQLValue.text($0) } ?? .null, op.afterValue.map { SQLValue.text($0) } ?? .null,
                          op.reason.map { SQLValue.text($0) } ?? .null, .text(WorkbenchScenarioOpStatus.live.rawValue), .text(actor), .date(date)])
            }
            try await appendEvent(scenarioID: newID, revision: 1, action: .created, actor: actor, detail: "duplicatedFrom:\(scenarioID.uuidString)", at: date)
            // Record the duplication on the source (its own revision bump + event).
            let srcRev = source.scenario.revision + 1
            try await database.exec("UPDATE workbench_scenarios SET revision = ?, updated_at = ? WHERE id = ?;",
                                    [.integer(Int64(srcRev)), .date(date), .uuid(scenarioID)])
            try await appendEvent(scenarioID: scenarioID, revision: srcRev, action: .duplicated, actor: actor, detail: newID.uuidString, at: date)
            try await database.exec("RELEASE SAVEPOINT \(sp);")
        } catch { try? await rollback(sp); throw error }
        return try await require(newID)
    }

    // MARK: - Promotion through review (records a human decision; never writes canonical evidence)

    /// Record a human-reviewed promotion of a scenario operation to an EXISTING authority. On acceptance
    /// the caller supplies the reference to the object the destination authority created; on rejection
    /// canonical state is untouched. This never performs the canonical write and never bypasses the
    /// destination's own review rules.
    @discardableResult
    public func promoteThroughReview(scenarioID: UUID, operationID: UUID,
                                     destination: WorkbenchScenarioPromotionDestination,
                                     decision: WorkbenchScenarioReviewDecision, reviewer: String,
                                     reason: String?, resultingReference: String?,
                                     expectedRevision: Int, at date: Date) async throws -> WorkbenchScenarioRecord {
        try requireActor(reviewer)
        let sc = try await requireActiveScenario(scenarioID); try requireRevision(sc, expectedRevision)
        guard let op = try await operation(id: operationID), op.scenarioID == scenarioID else { throw WorkbenchScenarioError.operationNotFound(operationID) }
        guard op.kind != .rowInclusion && op.kind != .rowExclusion else { throw WorkbenchScenarioError.operationNotPromotable(operationID) }
        let newRev = sc.revision + 1
        let sp = savepoint("wbsc_promote", UUID())
        do {
            try await database.exec("SAVEPOINT \(sp);")
            try await database.exec("""
                INSERT INTO workbench_scenario_reviews (id, scenario_id, operation_id, destination, decision, reviewer, reason, resulting_reference, decided_at)
                VALUES (?,?,?,?,?,?,?,?,?);
                """, [.uuid(UUID()), .uuid(scenarioID), .uuid(operationID), .text(destination.rawValue), .text(decision.rawValue),
                      .text(reviewer), reason.map { SQLValue.text($0) } ?? .null,
                      resultingReference.map { SQLValue.text($0) } ?? .null, .date(date)])
            try await database.exec("UPDATE workbench_scenarios SET revision = ?, updated_at = ? WHERE id = ?;",
                                    [.integer(Int64(newRev)), .date(date), .uuid(scenarioID)])
            try await appendEvent(scenarioID: scenarioID, revision: newRev,
                                  action: decision == .accepted ? .promotionAccepted : .promotionRejected,
                                  actor: reviewer, detail: destination.rawValue, at: date)
            try await database.exec("RELEASE SAVEPOINT \(sp);")
        } catch { try? await rollback(sp); throw error }
        return try await require(scenarioID)
    }

    // MARK: - Reads + reopen

    public func scenario(id: UUID) async throws -> WorkbenchScenario? {
        (try await database.query("\(Self.scColumns) WHERE id = ? LIMIT 1;", [.uuid(id)])).first.flatMap(Self.decodeScenario)
    }
    public func operations(scenarioID: UUID) async throws -> [WorkbenchScenarioOperation] {
        (try await database.query("\(Self.opColumns) WHERE scenario_id = ? ORDER BY sequence ASC;", [.uuid(scenarioID)])).compactMap(Self.decodeOp)
    }
    public func reviews(scenarioID: UUID) async throws -> [WorkbenchScenarioReview] {
        (try await database.query("\(Self.revColumns) WHERE scenario_id = ? ORDER BY decided_at ASC, id ASC;", [.uuid(scenarioID)])).compactMap(Self.decodeReview)
    }
    public func events(scenarioID: UUID) async throws -> [WorkbenchScenarioEvent] {
        (try await database.query("\(Self.evColumns) WHERE scenario_id = ? ORDER BY sequence ASC;", [.uuid(scenarioID)])).compactMap(Self.decodeEvent)
    }

    /// The durable reopen anchor: full scenario + all operations (live + abandoned) + reviews + events,
    /// so the exact undo/redo position is recovered after relaunch.
    public func fetch(scenarioID: UUID) async throws -> WorkbenchScenarioRecord? {
        guard let sc = try await scenario(id: scenarioID) else { return nil }
        return WorkbenchScenarioRecord(scenario: sc,
                                       operations: try await operations(scenarioID: scenarioID),
                                       reviews: try await reviews(scenarioID: scenarioID),
                                       events: try await events(scenarioID: scenarioID))
    }

    public func scenarioIDs(datasetID: UUID) async throws -> [UUID] {
        (try await database.query("SELECT id FROM workbench_scenarios WHERE dataset_id = ? ORDER BY created_at ASC, id ASC;", [.uuid(datasetID)])).compactMap { $0.uuid(0) }
    }

    // MARK: - Projection / diff / transform-over-scenario

    /// The deterministic overlay projection at the scenario's current pointer.
    public func projection(scenarioID: UUID) async throws -> WorkbenchScenarioProjection {
        let rec = try await require(scenarioID)
        let base = try await fetchBaseRecord(rec.scenario.datasetID)
        return WorkbenchScenarioProjection.build(base: base, appliedOps: rec.appliedOperations)
    }

    /// The source-vs-scenario value differences at the current pointer.
    public func diff(scenarioID: UUID) async throws -> [WorkbenchScenarioDiffEntry] {
        try await projection(scenarioID: scenarioID).diff()
    }

    /// Run a LAB-002 transform over the SCENARIO projection (not the canonical dataset). Pure: computes
    /// with the ONE existing engine over the projected record and returns the outcome — it persists
    /// nothing and NEVER mutates the canonical LAB-002 derivations.
    public func transformOverScenario(scenarioID: UUID, spec: WorkbenchTransformSpec) async throws -> WorkbenchTransformOutcome {
        let projected = try await projection(scenarioID: scenarioID).projectedRecord()
        return try WorkbenchTransformEngine.compute(spec, over: projected)
    }

    // MARK: - Staleness (never rewrites; surfaces reasons)

    /// Compare the scenario's base against the live dataset. A stale scenario is preserved as created;
    /// its reasons are surfaced for an explicit rebase decision. Never silently rewrites.
    public func staleness(scenarioID: UUID) async throws -> WorkbenchScenarioStaleness {
        let sc = try await requireScenario(scenarioID)
        let current = try await datasetRevision(sc.datasetID) ?? sc.baseDatasetRevision
        let revChanged = current != sc.baseDatasetRevision
        var superseded = 0
        for binding in try await datasetBindings(sc.datasetID) {
            guard let sv = binding.sourceVersionID else { continue }
            let rows = try await database.query("""
                SELECT cur.id FROM source_versions bound
                JOIN source_versions cur ON cur.logical_source_id = bound.logical_source_id AND cur.is_current = 1
                WHERE bound.id = ? LIMIT 1;
                """, [.uuid(sv)])
            if let currentSV = rows.first?.uuid(0), currentSV != sv { superseded += 1 }
        }
        var reasons: [String] = []
        if revChanged { reasons.append("base dataset revision changed (\(sc.baseDatasetRevision) → \(current))") }
        if superseded > 0 { reasons.append("\(superseded) bound source version(s) superseded") }
        return WorkbenchScenarioStaleness(scenarioID: scenarioID, baseDatasetRevision: sc.baseDatasetRevision,
                                          currentDatasetRevision: current, baseRevisionChanged: revChanged,
                                          supersededSourceVersionCount: superseded, reasons: reasons)
    }

    /// The distinct canonical scope targets the scenario's base dataset binds — for SensitiveScope
    /// resolution through the SHARED authority. A scenario never widens visibility beyond its base.
    public func scopeTargets(scenarioID: UUID) async throws -> [SensitiveScopeTarget] {
        let sc = try await requireScenario(scenarioID)
        var targets: Set<SensitiveScopeTarget> = []
        for b in try await datasetBindings(sc.datasetID) {
            switch b.targetKind {
            case .sourceVersion: if let id = b.targetUUID { targets.insert(SensitiveScopeTarget(kind: .sourceVersion, id: id)) }
            case .knowledgeObject: if let id = b.targetUUID { targets.insert(SensitiveScopeTarget(kind: .knowledgeObject, id: id)) }
            default: if let sv = b.sourceVersionID { targets.insert(SensitiveScopeTarget(kind: .sourceVersion, id: sv)) }
            }
        }
        return targets.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    // MARK: - Validation helpers

    private func requireActor(_ actor: String) throws {
        guard !actor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw WorkbenchScenarioError.blankActor }
    }
    private func requireScenario(_ id: UUID) async throws -> WorkbenchScenario {
        guard let sc = try await scenario(id: id) else { throw WorkbenchScenarioError.scenarioNotFound(id) }
        return sc
    }
    private func requireActiveScenario(_ id: UUID) async throws -> WorkbenchScenario {
        let sc = try await requireScenario(id)
        guard sc.status == .active else { throw WorkbenchScenarioError.notActive(id) }
        return sc
    }
    private func requireRevision(_ sc: WorkbenchScenario, _ expected: Int) throws {
        guard sc.revision == expected else { throw WorkbenchScenarioError.revisionConflict(expected: expected, actual: sc.revision) }
    }
    private func require(_ id: UUID) async throws -> WorkbenchScenarioRecord {
        guard let rec = try await fetch(scenarioID: id) else { throw WorkbenchScenarioError.scenarioNotFound(id) }
        return rec
    }
    private func operation(id: UUID) async throws -> WorkbenchScenarioOperation? {
        (try await database.query("\(Self.opColumns) WHERE id = ? LIMIT 1;", [.uuid(id)])).first.flatMap(Self.decodeOp)
    }

    /// The projected value at (row,field) given the scenario's applied operations (for beforeValue capture).
    private func projectedCellValue(_ sc: WorkbenchScenario, rowID: UUID, fieldID: UUID) async throws -> String? {
        let base = try await fetchBaseRecord(sc.datasetID)
        let applied = try await operations(scenarioID: sc.id).filter { $0.status == .live && $0.sequence <= sc.currentOpSeq }
        return WorkbenchScenarioProjection.build(base: base, appliedOps: applied).projectedValue(rowID: rowID, fieldID: fieldID)
    }

    // MARK: - Pointer mutation helpers

    private func pointerMutation(_ scenarioID: UUID, to seq: Int, revision: Int, action: WorkbenchScenarioEventAction, actor: String, at date: Date) async throws {
        let sp = savepoint("wbsc_ptr", UUID())
        do {
            try await database.exec("SAVEPOINT \(sp);")
            try await movePointer(scenarioID, to: seq, revision: revision, at: date)
            try await appendEvent(scenarioID: scenarioID, revision: revision, action: action, actor: actor, detail: nil, at: date)
            try await database.exec("RELEASE SAVEPOINT \(sp);")
        } catch { try? await rollback(sp); throw error }
    }
    private func movePointer(_ scenarioID: UUID, to seq: Int, revision: Int, at date: Date) async throws {
        try await database.exec("UPDATE workbench_scenarios SET current_op_seq = ?, revision = ?, updated_at = ? WHERE id = ?;",
                                [.integer(Int64(seq)), .integer(Int64(revision)), .date(date), .uuid(scenarioID)])
    }

    private func maxOpSequence(_ scenarioID: UUID) async throws -> Int {
        Int(try await database.query("SELECT COALESCE(MAX(sequence), 0) FROM workbench_scenario_operations WHERE scenario_id = ?;", [.uuid(scenarioID)]).first?.int(0) ?? 0)
    }
    private func liveOpExists(_ scenarioID: UUID, atOrBelow seq: Int) async throws -> Bool {
        Int(try await database.query("SELECT COUNT(*) FROM workbench_scenario_operations WHERE scenario_id = ? AND status = 'live' AND sequence <= ?;", [.uuid(scenarioID), .integer(Int64(seq))]).first?.int(0) ?? 0) > 0
    }
    private func greatestLiveSeq(_ scenarioID: UUID, below seq: Int) async throws -> Int {
        Int(try await database.query("SELECT COALESCE(MAX(sequence), 0) FROM workbench_scenario_operations WHERE scenario_id = ? AND status = 'live' AND sequence < ?;", [.uuid(scenarioID), .integer(Int64(seq))]).first?.int(0) ?? 0)
    }
    private func smallestLiveSeq(_ scenarioID: UUID, above seq: Int) async throws -> Int? {
        let rows = try await database.query("SELECT MIN(sequence) FROM workbench_scenario_operations WHERE scenario_id = ? AND status = 'live' AND sequence > ?;", [.uuid(scenarioID), .integer(Int64(seq))])
        guard let v = rows.first?.int(0) else { return nil }
        return Int(v)
    }
    private func nextEventSequence(_ scenarioID: UUID) async throws -> Int {
        Int(try await database.query("SELECT COALESCE(MAX(sequence), 0) FROM workbench_scenario_events WHERE scenario_id = ?;", [.uuid(scenarioID)]).first?.int(0) ?? 0) + 1
    }
    private func appendEvent(scenarioID: UUID, revision: Int, action: WorkbenchScenarioEventAction, actor: String, detail: String?, at date: Date) async throws {
        let seq = try await nextEventSequence(scenarioID)
        try await database.exec("""
            INSERT INTO workbench_scenario_events (id, scenario_id, sequence, scenario_revision, action, actor, detail, occurred_at)
            VALUES (?,?,?,?,?,?,?,?);
            """, [.uuid(UUID()), .uuid(scenarioID), .integer(Int64(seq)), .integer(Int64(revision)),
                  .text(action.rawValue), .text(actor), detail.map { SQLValue.text($0) } ?? .null, .date(date)])
    }
    private func rollback(_ sp: String) async throws {
        try? await database.exec("ROLLBACK TO SAVEPOINT \(sp);")
        try? await database.exec("RELEASE SAVEPOINT \(sp);")
    }
    private func savepoint(_ prefix: String, _ id: UUID) -> String { "\(prefix)_\(id.uuidString.replacingOccurrences(of: "-", with: ""))" }

    // MARK: - Dataset ownership + base-record reads (canonical evidence read-only)

    private func datasetRevision(_ datasetID: UUID) async throws -> Int? {
        (try await database.query("SELECT revision FROM workbench_datasets WHERE id = ? LIMIT 1;", [.uuid(datasetID)]).first?.int(0)).map { Int($0) }
    }
    private func rowInDataset(_ rowID: UUID, _ datasetID: UUID) async throws -> Bool {
        Int(try await database.query("SELECT COUNT(*) FROM workbench_rows WHERE id = ? AND dataset_id = ?;", [.uuid(rowID), .uuid(datasetID)]).first?.int(0) ?? 0) > 0
    }
    private func fieldInDataset(_ fieldID: UUID, _ datasetID: UUID) async throws -> Bool {
        Int(try await database.query("SELECT COUNT(*) FROM workbench_fields WHERE id = ? AND dataset_id = ?;", [.uuid(fieldID), .uuid(datasetID)]).first?.int(0) ?? 0) > 0
    }
    private func datasetBindings(_ datasetID: UUID) async throws -> [WorkbenchSourceBinding] {
        (try await database.query("""
            SELECT id, cell_id, target_kind, target_id, source_version_id, locator_json, ordinal, created_at
            FROM workbench_source_bindings
            WHERE cell_id IN (SELECT id FROM workbench_cells WHERE dataset_id = ?)
            ORDER BY cell_id ASC, ordinal ASC, id ASC;
            """, [.uuid(datasetID)])).compactMap(Self.decodeBinding)
    }

    /// Reconstruct the base dataset record (dataset/fields/rows/cells/bindings) directly — a
    /// self-contained read path so the scenario layer never mutates a canonical row.
    private func fetchBaseRecord(_ datasetID: UUID) async throws -> WorkbenchDatasetRecord {
        guard let ds = (try await database.query(
            "SELECT id, workspace_id, title, mode, revision, created_at, updated_at FROM workbench_datasets WHERE id = ? LIMIT 1;",
            [.uuid(datasetID)])).first.flatMap(Self.decodeDataset) else { throw WorkbenchScenarioError.datasetNotFound(datasetID) }
        let fields = (try await database.query(
            "SELECT id, dataset_id, name, value_shape, ordinal, created_at FROM workbench_fields WHERE dataset_id = ? ORDER BY ordinal ASC, id ASC;",
            [.uuid(datasetID)])).compactMap(Self.decodeField)
        let rows = (try await database.query(
            "SELECT id, dataset_id, ordinal, created_at FROM workbench_rows WHERE dataset_id = ? ORDER BY ordinal ASC, id ASC;",
            [.uuid(datasetID)])).compactMap(Self.decodeRow)
        let cells = (try await database.query(
            "SELECT id, dataset_id, row_id, field_id, kind, value, status, created_at FROM workbench_cells WHERE dataset_id = ? ORDER BY created_at ASC, id ASC;",
            [.uuid(datasetID)])).compactMap(Self.decodeCell)
        let bindings = try await datasetBindings(datasetID)
        return WorkbenchDatasetRecord(dataset: ds, fields: fields, rows: rows, cells: cells, bindings: bindings, savedViews: [], events: [])
    }

    // MARK: - Columns + decoders

    private nonisolated static let scColumns = "SELECT id, dataset_id, base_dataset_revision, title, status, current_op_seq, revision, actor, created_at, updated_at FROM workbench_scenarios"
    private nonisolated static func decodeScenario(_ r: SQLRow) -> WorkbenchScenario? {
        guard let id = r.uuid(0), let ds = r.uuid(1), let baseRev = r.int(2).map({ Int($0) }), let title = r.string(3),
              let status = r.string(4).flatMap(WorkbenchScenarioStatus.init(rawValue:)), let ptr = r.int(5).map({ Int($0) }),
              let rev = r.int(6).map({ Int($0) }), let actor = r.string(7), let c = r.date(8), let u = r.date(9) else { return nil }
        return WorkbenchScenario(id: id, datasetID: ds, baseDatasetRevision: baseRev, title: title, status: status,
                                 currentOpSeq: ptr, revision: rev, actor: actor, createdAt: c, updatedAt: u)
    }

    private nonisolated static let opColumns = "SELECT id, scenario_id, sequence, kind, target_kind, row_id, field_id, before_value, after_value, reason, status, actor, created_at FROM workbench_scenario_operations"
    private nonisolated static func decodeOp(_ r: SQLRow) -> WorkbenchScenarioOperation? {
        guard let id = r.uuid(0), let sid = r.uuid(1), let seq = r.int(2).map({ Int($0) }),
              let kind = r.string(3).flatMap(WorkbenchScenarioOpKind.init(rawValue:)),
              let tk = r.string(4).flatMap(WorkbenchScenarioTargetKind.init(rawValue:)), let row = r.uuid(5),
              let status = r.string(10).flatMap(WorkbenchScenarioOpStatus.init(rawValue:)), let actor = r.string(11), let c = r.date(12) else { return nil }
        return WorkbenchScenarioOperation(id: id, scenarioID: sid, sequence: seq, kind: kind, targetKind: tk,
                                          rowID: row, fieldID: r.uuid(6), beforeValue: r.string(7), afterValue: r.string(8),
                                          reason: r.string(9), status: status, actor: actor, createdAt: c)
    }

    private nonisolated static let revColumns = "SELECT id, scenario_id, operation_id, destination, decision, reviewer, reason, resulting_reference, decided_at FROM workbench_scenario_reviews"
    private nonisolated static func decodeReview(_ r: SQLRow) -> WorkbenchScenarioReview? {
        guard let id = r.uuid(0), let sid = r.uuid(1), let op = r.uuid(2),
              let dest = r.string(3).flatMap(WorkbenchScenarioPromotionDestination.init(rawValue:)),
              let dec = r.string(4).flatMap(WorkbenchScenarioReviewDecision.init(rawValue:)), let reviewer = r.string(5), let at = r.date(8) else { return nil }
        return WorkbenchScenarioReview(id: id, scenarioID: sid, operationID: op, destination: dest, decision: dec,
                                       reviewer: reviewer, reason: r.string(6), resultingReference: r.string(7), decidedAt: at)
    }

    private nonisolated static let evColumns = "SELECT id, scenario_id, sequence, scenario_revision, action, actor, detail, occurred_at FROM workbench_scenario_events"
    private nonisolated static func decodeEvent(_ r: SQLRow) -> WorkbenchScenarioEvent? {
        guard let id = r.uuid(0), let sid = r.uuid(1), let seq = r.int(2).map({ Int($0) }), let rev = r.int(3).map({ Int($0) }),
              let action = r.string(4).flatMap(WorkbenchScenarioEventAction.init(rawValue:)), let actor = r.string(5), let at = r.date(7) else { return nil }
        return WorkbenchScenarioEvent(id: id, scenarioID: sid, sequence: seq, scenarioRevision: rev, action: action, actor: actor, detail: r.string(6), occurredAt: at)
    }

    // Base dataset-record decoders (mirror LAB-001/002; local to this self-contained read path).
    private nonisolated static func decodeDataset(_ r: SQLRow) -> WorkbenchDataset? {
        guard let id = r.uuid(0), let ws = r.uuid(1), let title = r.string(2),
              let mode = r.string(3).flatMap(WorkbenchDatasetMode.init(rawValue:)),
              let rev = r.int(4).map({ Int($0) }), let c = r.date(5), let u = r.date(6) else { return nil }
        return WorkbenchDataset(id: id, workspaceID: ws, title: title, mode: mode, revision: rev, createdAt: c, updatedAt: u)
    }
    private nonisolated static func decodeField(_ r: SQLRow) -> WorkbenchField? {
        guard let id = r.uuid(0), let ds = r.uuid(1), let name = r.string(2),
              let shape = r.string(3).flatMap(FactSchemaRegistry.ValueShape.init(rawValue:)),
              let ord = r.int(4).map({ Int($0) }), let c = r.date(5) else { return nil }
        return WorkbenchField(id: id, datasetID: ds, name: name, valueShape: shape, ordinal: ord, createdAt: c)
    }
    private nonisolated static func decodeRow(_ r: SQLRow) -> WorkbenchRow? {
        guard let id = r.uuid(0), let ds = r.uuid(1), let ord = r.int(2).map({ Int($0) }), let c = r.date(3) else { return nil }
        return WorkbenchRow(id: id, datasetID: ds, ordinal: ord, createdAt: c)
    }
    private nonisolated static func decodeCell(_ r: SQLRow) -> WorkbenchCell? {
        guard let id = r.uuid(0), let ds = r.uuid(1), let row = r.uuid(2), let field = r.uuid(3),
              let kind = r.string(4).flatMap(WorkbenchCellKind.init(rawValue:)),
              let status = r.string(6).flatMap(EvidenceStatus.init(rawValue:)), let c = r.date(7) else { return nil }
        return WorkbenchCell(id: id, datasetID: ds, rowID: row, fieldID: field, kind: kind, value: r.string(5), status: status, createdAt: c)
    }
    private nonisolated static func decodeBinding(_ r: SQLRow) -> WorkbenchSourceBinding? {
        guard let id = r.uuid(0), let cell = r.uuid(1),
              let kind = r.string(2).flatMap(WorkbenchBindingTargetKind.init(rawValue:)),
              let target = r.string(3), let ord = r.int(6).map({ Int($0) }), let c = r.date(7) else { return nil }
        return WorkbenchSourceBinding(id: id, cellID: cell, targetKind: kind, targetID: target,
                                      sourceVersionID: r.uuid(4), locator: nil, ordinal: ord, createdAt: c)
    }
}
