//
//  WorkbenchDatasetRepository.swift
//  Kalsmritikosh
//
//  LAB-001 (Stage C) — the ONE authoritative writer/reader for the canonical Workbench dataset model
//  (schema v92). Every mutation is atomic (SAVEPOINT), carries optimistic revision CAS, validates
//  ownership and — for a source binding — drills through to a REAL canonical object (Gate 4), and
//  appends exactly one durable revision-history event. Canonical evidence is READ-ONLY here: a
//  binding references a block/claim/event/… + SourceVersion + locator; the repository never inserts,
//  updates or deletes a canonical row. fetch(_:) reconstructs the full deterministic record for
//  close/reopen (Gate 7). staleBindings(_:) reports bindings whose SourceVersion is no longer current
//  without erasing the durable dataset (Gate 6).
//

import Foundation

public actor WorkbenchDatasetRepository {
    private let database: Database

    public init(database: Database) { self.database = database }

    private nonisolated static let encoder = JSONEncoder()
    private nonisolated static let decoder = JSONDecoder()

    /// The canonical table backing each binding target kind (for drill-through existence validation).
    private nonisolated static func canonicalTable(_ kind: WorkbenchBindingTargetKind) -> String {
        switch kind {
        case .evidenceBlock:   return "evidence_blocks"
        case .claim:           return "claims"
        case .event:           return "events"
        case .entity:          return "entities"
        case .sourceVersion:   return "source_versions"
        case .contradiction:   return "contradictions"
        case .gap:             return "gap_nodes"
        case .knowledgeObject: return "knowledge_objects"
        }
    }

    // MARK: - Create

    /// Open a new dataset (revision 1, `created` event). The workspace must exist.
    @discardableResult
    public func createDataset(workspaceID: UUID, title: String, mode: WorkbenchDatasetMode,
                              actor: String, at date: Date) async throws -> WorkbenchDatasetRecord {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw WorkbenchError.blankTitle }
        try requireActor(actor)
        guard try await rowExists("workspaces", id: workspaceID) else { throw WorkbenchError.workspaceNotFound(workspaceID) }
        let id = UUID()
        let sp = savepoint("wbds_create", id)
        do {
            try await database.exec("SAVEPOINT \(sp);")
            try await database.exec("""
                INSERT INTO workbench_datasets (id, workspace_id, title, mode, revision, created_at, updated_at)
                VALUES (?,?,?,?,?,?,?);
                """, [.uuid(id), .uuid(workspaceID), .text(clean), .text(mode.rawValue), .integer(1), .date(date), .date(date)])
            try await appendEvent(datasetID: id, sequence: 1, revision: 1, action: .created, actor: actor, detail: nil, at: date)
            try await database.exec("RELEASE SAVEPOINT \(sp);")
        } catch { try? await rollback(sp); throw error }
        return try await require(id)
    }

    // MARK: - Structure mutations

    @discardableResult
    public func addField(datasetID: UUID, name: String, valueShape: FactSchemaRegistry.ValueShape,
                         expectedRevision: Int, actor: String, at date: Date) async throws -> WorkbenchDatasetRecord {
        try requireActor(actor)
        let ds = try await requireDataset(datasetID); try requireRevision(ds, expectedRevision)
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw WorkbenchError.blankFieldName }
        let newRev = ds.revision + 1
        let sp = savepoint("wbds_field", UUID())
        do {
            try await database.exec("SAVEPOINT \(sp);")
            let ordinal = try await nextOrdinal("workbench_fields", datasetID)
            try await database.exec("""
                INSERT INTO workbench_fields (id, dataset_id, name, value_shape, ordinal, created_at)
                VALUES (?,?,?,?,?,?);
                """, [.uuid(UUID()), .uuid(datasetID), .text(clean), .text(valueShape.rawValue), .integer(Int64(ordinal)), .date(date)])
            try await bumpRevision(datasetID, to: newRev, at: date)
            try await appendEvent(datasetID: datasetID, sequence: try await nextSequence(datasetID), revision: newRev,
                                  action: .fieldAdded, actor: actor, detail: clean, at: date)
            try await database.exec("RELEASE SAVEPOINT \(sp);")
        } catch { try? await rollback(sp); throw error }
        return try await require(datasetID)
    }

    @discardableResult
    public func addRow(datasetID: UUID, expectedRevision: Int, actor: String, at date: Date) async throws -> WorkbenchDatasetRecord {
        try requireActor(actor)
        let ds = try await requireDataset(datasetID); try requireRevision(ds, expectedRevision)
        let newRev = ds.revision + 1
        let rowID = UUID()
        let sp = savepoint("wbds_row", rowID)
        do {
            try await database.exec("SAVEPOINT \(sp);")
            let ordinal = try await nextOrdinal("workbench_rows", datasetID)
            try await database.exec("INSERT INTO workbench_rows (id, dataset_id, ordinal, created_at) VALUES (?,?,?,?);",
                                    [.uuid(rowID), .uuid(datasetID), .integer(Int64(ordinal)), .date(date)])
            try await bumpRevision(datasetID, to: newRev, at: date)
            try await appendEvent(datasetID: datasetID, sequence: try await nextSequence(datasetID), revision: newRev,
                                  action: .rowAdded, actor: actor, detail: nil, at: date)
            try await database.exec("RELEASE SAVEPOINT \(sp);")
        } catch { try? await rollback(sp); throw error }
        return try await require(datasetID)
    }

    /// Set (upsert) the single cell at (row, field). Replacing a cell drops its old source bindings
    /// (a new value needs its own drill-through). A `sourceValue` cell must later bind evidence to be
    /// well-formed; that is enforced at bind time and by the record's provenance check.
    @discardableResult
    public func setCell(datasetID: UUID, rowID: UUID, fieldID: UUID, kind: WorkbenchCellKind,
                        value: String?, status: EvidenceStatus, expectedRevision: Int,
                        actor: String, at date: Date) async throws -> WorkbenchDatasetRecord {
        try requireActor(actor)
        let ds = try await requireDataset(datasetID); try requireRevision(ds, expectedRevision)
        guard try await ownedRow(rowID, datasetID) else { throw WorkbenchError.rowNotInDataset(rowID) }
        guard try await ownedField(fieldID, datasetID) else { throw WorkbenchError.fieldNotInDataset(fieldID) }
        let newRev = ds.revision + 1
        let sp = savepoint("wbds_cell", UUID())
        do {
            try await database.exec("SAVEPOINT \(sp);")
            try await database.exec("DELETE FROM workbench_cells WHERE row_id = ? AND field_id = ?;", [.uuid(rowID), .uuid(fieldID)])
            try await database.exec("""
                INSERT INTO workbench_cells (id, dataset_id, row_id, field_id, kind, value, status, created_at)
                VALUES (?,?,?,?,?,?,?,?);
                """, [.uuid(UUID()), .uuid(datasetID), .uuid(rowID), .uuid(fieldID), .text(kind.rawValue),
                      value.map { SQLValue.text($0) } ?? .null, .text(status.rawValue), .date(date)])
            try await bumpRevision(datasetID, to: newRev, at: date)
            try await appendEvent(datasetID: datasetID, sequence: try await nextSequence(datasetID), revision: newRev,
                                  action: .cellSet, actor: actor, detail: kind.rawValue, at: date)
            try await database.exec("RELEASE SAVEPOINT \(sp);")
        } catch { try? await rollback(sp); throw error }
        return try await require(datasetID)
    }

    /// Bind a source-derived cell to its exact canonical origin. The target row MUST exist in its
    /// canonical table (Gate 4 drill-through — never a copied-text-only binding); a provided
    /// SourceVersion must exist, and for an evidence-block target must match the block's own version.
    @discardableResult
    public func bindSource(cellID: UUID, targetKind: WorkbenchBindingTargetKind, targetID: String,
                           sourceVersionID: UUID?, locator: SourceLocator?, expectedRevision: Int,
                           actor: String, at date: Date) async throws -> WorkbenchDatasetRecord {
        try requireActor(actor)
        guard let datasetID = try await datasetOfCell(cellID) else { throw WorkbenchError.cellNotFound(cellID) }
        let ds = try await requireDataset(datasetID); try requireRevision(ds, expectedRevision)
        try await validateBindingTarget(kind: targetKind, targetID: targetID, sourceVersionID: sourceVersionID)
        let newRev = ds.revision + 1
        let sp = savepoint("wbds_bind", UUID())
        do {
            try await database.exec("SAVEPOINT \(sp);")
            let ordinal = try await nextBindingOrdinal(cellID)
            let locatorJSON = try locator.map { String(data: try Self.encoder.encode($0), encoding: .utf8) ?? "" }
            try await database.exec("""
                INSERT INTO workbench_source_bindings (id, cell_id, target_kind, target_id, source_version_id, locator_json, ordinal, created_at)
                VALUES (?,?,?,?,?,?,?,?);
                """, [.uuid(UUID()), .uuid(cellID), .text(targetKind.rawValue), .text(targetID),
                      sourceVersionID.map { SQLValue.uuid($0) } ?? .null,
                      locatorJSON.map { SQLValue.text($0) } ?? .null, .integer(Int64(ordinal)), .date(date)])
            try await bumpRevision(datasetID, to: newRev, at: date)
            try await appendEvent(datasetID: datasetID, sequence: try await nextSequence(datasetID), revision: newRev,
                                  action: .sourceBound, actor: actor, detail: targetKind.rawValue, at: date)
            try await database.exec("RELEASE SAVEPOINT \(sp);")
        } catch { try? await rollback(sp); throw error }
        return try await require(datasetID)
    }

    @discardableResult
    public func saveView(datasetID: UUID, name: String, projectionJSON: String,
                         expectedRevision: Int, actor: String, at date: Date) async throws -> WorkbenchDatasetRecord {
        try requireActor(actor)
        let ds = try await requireDataset(datasetID); try requireRevision(ds, expectedRevision)
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw WorkbenchError.blankViewName }
        let newRev = ds.revision + 1
        let sp = savepoint("wbds_view", UUID())
        do {
            try await database.exec("SAVEPOINT \(sp);")
            try await database.exec("""
                INSERT INTO workbench_saved_views (id, dataset_id, name, projection_json, created_at)
                VALUES (?,?,?,?,?);
                """, [.uuid(UUID()), .uuid(datasetID), .text(clean), .text(projectionJSON), .date(date)])
            try await bumpRevision(datasetID, to: newRev, at: date)
            try await appendEvent(datasetID: datasetID, sequence: try await nextSequence(datasetID), revision: newRev,
                                  action: .viewSaved, actor: actor, detail: clean, at: date)
            try await database.exec("RELEASE SAVEPOINT \(sp);")
        } catch { try? await rollback(sp); throw error }
        return try await require(datasetID)
    }

    @discardableResult
    public func rename(datasetID: UUID, title: String, expectedRevision: Int, actor: String, at date: Date) async throws -> WorkbenchDatasetRecord {
        try await headerPatch(datasetID: datasetID, expectedRevision: expectedRevision, actor: actor, at: date,
                              action: .renamed, detail: title) { clean in
            let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { throw WorkbenchError.blankTitle }
            try await self.database.exec("UPDATE workbench_datasets SET title = ? WHERE id = ?;", [.text(t), .uuid(datasetID)])
            _ = clean
        }
    }

    @discardableResult
    public func setMode(datasetID: UUID, mode: WorkbenchDatasetMode, expectedRevision: Int, actor: String, at date: Date) async throws -> WorkbenchDatasetRecord {
        try await headerPatch(datasetID: datasetID, expectedRevision: expectedRevision, actor: actor, at: date,
                              action: .modeChanged, detail: mode.rawValue) { _ in
            try await self.database.exec("UPDATE workbench_datasets SET mode = ? WHERE id = ?;", [.text(mode.rawValue), .uuid(datasetID)])
        }
    }

    public func delete(datasetID: UUID) async throws {
        try await database.exec("DELETE FROM workbench_datasets WHERE id = ?;", [.uuid(datasetID)])
    }

    // MARK: - Legacy conversion support (internal; used by WorkbenchLegacyCompat)

    func evidenceBlockExists(_ id: UUID) async throws -> Bool { try await rowExists("evidence_blocks", id: id) }

    @discardableResult
    func noteConversion(datasetID: UUID, expectedRevision: Int, actor: String, legacyID: UUID, at date: Date) async throws -> WorkbenchDatasetRecord {
        try await headerPatch(datasetID: datasetID, expectedRevision: expectedRevision, actor: actor, at: date,
                              action: .converted, detail: legacyID.uuidString) { _ in /* history-only, no header change */ }
    }

    // MARK: - Reads (deterministic order) + reopen

    public func dataset(id: UUID) async throws -> WorkbenchDataset? {
        (try await database.query("\(Self.datasetColumns) WHERE id = ? LIMIT 1;", [.uuid(id)])).first.flatMap(Self.decodeDataset)
    }

    public func fields(datasetID: UUID) async throws -> [WorkbenchField] {
        (try await database.query("\(Self.fieldColumns) WHERE dataset_id = ? ORDER BY ordinal ASC, id ASC;", [.uuid(datasetID)]))
            .compactMap(Self.decodeField)
    }

    public func rows(datasetID: UUID) async throws -> [WorkbenchRow] {
        (try await database.query("\(Self.rowColumns) WHERE dataset_id = ? ORDER BY ordinal ASC, id ASC;", [.uuid(datasetID)]))
            .compactMap(Self.decodeRow)
    }

    public func cells(datasetID: UUID) async throws -> [WorkbenchCell] {
        (try await database.query("\(Self.cellColumns) WHERE dataset_id = ? ORDER BY created_at ASC, id ASC;", [.uuid(datasetID)]))
            .compactMap(Self.decodeCell)
    }

    public func bindings(datasetID: UUID) async throws -> [WorkbenchSourceBinding] {
        (try await database.query("""
            \(Self.bindingColumns)
            WHERE cell_id IN (SELECT id FROM workbench_cells WHERE dataset_id = ?)
            ORDER BY cell_id ASC, ordinal ASC, id ASC;
            """, [.uuid(datasetID)])).compactMap(Self.decodeBinding)
    }

    public func savedViews(datasetID: UUID) async throws -> [WorkbenchSavedView] {
        (try await database.query("\(Self.viewColumns) WHERE dataset_id = ? ORDER BY created_at ASC, id ASC;", [.uuid(datasetID)]))
            .compactMap(Self.decodeView)
    }

    public func events(datasetID: UUID) async throws -> [WorkbenchDatasetEvent] {
        (try await database.query("\(Self.eventColumns) WHERE dataset_id = ? ORDER BY sequence ASC;", [.uuid(datasetID)]))
            .compactMap(Self.decodeEvent)
    }

    /// The durable reopen anchor: reconstruct the full deterministic record from disk.
    public func fetch(datasetID: UUID) async throws -> WorkbenchDatasetRecord? {
        guard let ds = try await dataset(id: datasetID) else { return nil }
        return WorkbenchDatasetRecord(
            dataset: ds,
            fields: try await fields(datasetID: datasetID),
            rows: try await rows(datasetID: datasetID),
            cells: try await cells(datasetID: datasetID),
            bindings: try await bindings(datasetID: datasetID),
            savedViews: try await savedViews(datasetID: datasetID),
            events: try await events(datasetID: datasetID))
    }

    public func datasetIDs(workspaceID: UUID) async throws -> [UUID] {
        (try await database.query("SELECT id FROM workbench_datasets WHERE workspace_id = ? ORDER BY created_at ASC, id ASC;",
                                  [.uuid(workspaceID)])).compactMap { $0.uuid(0) }
    }

    // MARK: - Gate 6: stale-source detection (never erases the durable dataset)

    /// Bindings whose bound SourceVersion is no longer the current version of its logical source.
    /// The dataset is untouched; the caller decides whether to refresh.
    public func staleBindings(datasetID: UUID) async throws -> [WorkbenchSourceBinding] {
        var stale: [WorkbenchSourceBinding] = []
        for binding in try await bindings(datasetID: datasetID) {
            guard let sv = binding.sourceVersionID else { continue }
            let rows = try await database.query("""
                SELECT cur.id FROM source_versions bound
                JOIN source_versions cur ON cur.logical_source_id = bound.logical_source_id AND cur.is_current = 1
                WHERE bound.id = ? LIMIT 1;
                """, [.uuid(sv)])
            if let current = rows.first?.uuid(0), current != sv { stale.append(binding) }
        }
        return stale
    }

    // MARK: - Gate 5 support: the canonical scope targets a dataset binds (for SensitiveScope propagation)

    /// The distinct canonical SourceVersion / KnowledgeObject targets this dataset references, so a
    /// caller can resolve visibility/export through the SHARED SensitiveScope authority — the
    /// Workbench never forks privacy rules.
    public func boundScopeTargets(datasetID: UUID) async throws -> [SensitiveScopeTarget] {
        var targets: Set<SensitiveScopeTarget> = []
        for b in try await bindings(datasetID: datasetID) {
            switch b.targetKind {
            case .sourceVersion:
                if let id = b.targetUUID { targets.insert(SensitiveScopeTarget(kind: .sourceVersion, id: id)) }
            case .knowledgeObject:
                if let id = b.targetUUID { targets.insert(SensitiveScopeTarget(kind: .knowledgeObject, id: id)) }
            default:
                if let sv = b.sourceVersionID { targets.insert(SensitiveScopeTarget(kind: .sourceVersion, id: sv)) }
            }
        }
        return targets.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    // MARK: - Validation helpers

    private func requireActor(_ actor: String) throws {
        guard !actor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw WorkbenchError.blankActor }
    }

    private func requireDataset(_ id: UUID) async throws -> WorkbenchDataset {
        guard let ds = try await dataset(id: id) else { throw WorkbenchError.datasetNotFound(id) }
        return ds
    }

    private func requireRevision(_ ds: WorkbenchDataset, _ expected: Int) throws {
        guard ds.revision == expected else { throw WorkbenchError.revisionConflict(expected: expected, actual: ds.revision) }
    }

    private func require(_ id: UUID) async throws -> WorkbenchDatasetRecord {
        guard let rec = try await fetch(datasetID: id) else { throw WorkbenchError.datasetNotFound(id) }
        return rec
    }

    private func validateBindingTarget(kind: WorkbenchBindingTargetKind, targetID: String, sourceVersionID: UUID?) async throws {
        guard let uuid = UUID(uuidString: targetID) else {
            throw WorkbenchError.bindingTargetNotFound(kind: kind.rawValue, id: targetID)
        }
        guard try await rowExists(Self.canonicalTable(kind), id: uuid) else {
            throw WorkbenchError.bindingTargetNotFound(kind: kind.rawValue, id: targetID)
        }
        if let sv = sourceVersionID {
            guard try await rowExists("source_versions", id: sv) else {
                throw WorkbenchError.bindingTargetNotFound(kind: "sourceVersion", id: sv.uuidString)
            }
            // An evidence-block binding's SourceVersion must be the block's own version.
            if kind == .evidenceBlock {
                let rows = try await database.query("SELECT source_version_id FROM evidence_blocks WHERE id = ? LIMIT 1;", [.uuid(uuid)])
                if let blockSV = rows.first?.uuid(0), blockSV != sv {
                    throw WorkbenchError.bindingCrossWorkspace(kind: kind.rawValue, id: targetID)
                }
            }
        }
    }

    private func headerPatch(datasetID: UUID, expectedRevision: Int, actor: String, at date: Date,
                             action: WorkbenchDatasetEventAction, detail: String?,
                             _ body: @Sendable (String) async throws -> Void) async throws -> WorkbenchDatasetRecord {
        try requireActor(actor)
        let ds = try await requireDataset(datasetID); try requireRevision(ds, expectedRevision)
        let newRev = ds.revision + 1
        let sp = savepoint("wbds_hdr", datasetID)
        do {
            try await database.exec("SAVEPOINT \(sp);")
            try await body("")
            try await bumpRevision(datasetID, to: newRev, at: date)
            try await appendEvent(datasetID: datasetID, sequence: try await nextSequence(datasetID), revision: newRev,
                                  action: action, actor: actor, detail: detail, at: date)
            try await database.exec("RELEASE SAVEPOINT \(sp);")
        } catch { try? await rollback(sp); throw error }
        return try await require(datasetID)
    }

    // MARK: - Row/sequence helpers

    private func rowExists(_ table: String, id: UUID) async throws -> Bool {
        Int(try await database.query("SELECT COUNT(*) FROM \(table) WHERE id = ?;", [.uuid(id)]).first?.int(0) ?? 0) > 0
    }
    private func ownedRow(_ rowID: UUID, _ datasetID: UUID) async throws -> Bool {
        Int(try await database.query("SELECT COUNT(*) FROM workbench_rows WHERE id = ? AND dataset_id = ?;", [.uuid(rowID), .uuid(datasetID)]).first?.int(0) ?? 0) > 0
    }
    private func ownedField(_ fieldID: UUID, _ datasetID: UUID) async throws -> Bool {
        Int(try await database.query("SELECT COUNT(*) FROM workbench_fields WHERE id = ? AND dataset_id = ?;", [.uuid(fieldID), .uuid(datasetID)]).first?.int(0) ?? 0) > 0
    }
    private func datasetOfCell(_ cellID: UUID) async throws -> UUID? {
        try await database.query("SELECT dataset_id FROM workbench_cells WHERE id = ? LIMIT 1;", [.uuid(cellID)]).first?.uuid(0)
    }
    private func nextOrdinal(_ table: String, _ datasetID: UUID) async throws -> Int {
        Int(try await database.query("SELECT COALESCE(MAX(ordinal), -1) FROM \(table) WHERE dataset_id = ?;", [.uuid(datasetID)]).first?.int(0) ?? -1) + 1
    }
    private func nextBindingOrdinal(_ cellID: UUID) async throws -> Int {
        Int(try await database.query("SELECT COALESCE(MAX(ordinal), -1) FROM workbench_source_bindings WHERE cell_id = ?;", [.uuid(cellID)]).first?.int(0) ?? -1) + 1
    }
    private func nextSequence(_ datasetID: UUID) async throws -> Int {
        Int(try await database.query("SELECT COALESCE(MAX(sequence), 0) FROM workbench_dataset_events WHERE dataset_id = ?;", [.uuid(datasetID)]).first?.int(0) ?? 0) + 1
    }
    private func bumpRevision(_ datasetID: UUID, to revision: Int, at date: Date) async throws {
        try await database.exec("UPDATE workbench_datasets SET revision = ?, updated_at = ? WHERE id = ?;",
                                [.integer(Int64(revision)), .date(date), .uuid(datasetID)])
    }
    private func appendEvent(datasetID: UUID, sequence: Int, revision: Int, action: WorkbenchDatasetEventAction,
                             actor: String, detail: String?, at date: Date) async throws {
        try await database.exec("""
            INSERT INTO workbench_dataset_events (id, dataset_id, sequence, dataset_revision, action, actor, detail, occurred_at)
            VALUES (?,?,?,?,?,?,?,?);
            """, [.uuid(UUID()), .uuid(datasetID), .integer(Int64(sequence)), .integer(Int64(revision)),
                  .text(action.rawValue), .text(actor), detail.map { SQLValue.text($0) } ?? .null, .date(date)])
    }
    private func rollback(_ sp: String) async throws {
        try? await database.exec("ROLLBACK TO SAVEPOINT \(sp);")
        try? await database.exec("RELEASE SAVEPOINT \(sp);")
    }
    private func savepoint(_ prefix: String, _ id: UUID) -> String {
        "\(prefix)_\(id.uuidString.replacingOccurrences(of: "-", with: ""))"
    }

    // MARK: - Columns + decoders

    private nonisolated static let datasetColumns = "SELECT id, workspace_id, title, mode, revision, created_at, updated_at FROM workbench_datasets"
    private nonisolated static func decodeDataset(_ r: SQLRow) -> WorkbenchDataset? {
        guard let id = r.uuid(0), let ws = r.uuid(1), let title = r.string(2),
              let mode = r.string(3).flatMap(WorkbenchDatasetMode.init(rawValue:)),
              let rev = r.int(4).map({ Int($0) }), let c = r.date(5), let u = r.date(6) else { return nil }
        return WorkbenchDataset(id: id, workspaceID: ws, title: title, mode: mode, revision: rev, createdAt: c, updatedAt: u)
    }

    private nonisolated static let fieldColumns = "SELECT id, dataset_id, name, value_shape, ordinal, created_at FROM workbench_fields"
    private nonisolated static func decodeField(_ r: SQLRow) -> WorkbenchField? {
        guard let id = r.uuid(0), let ds = r.uuid(1), let name = r.string(2),
              let shape = r.string(3).flatMap(FactSchemaRegistry.ValueShape.init(rawValue:)),
              let ord = r.int(4).map({ Int($0) }), let c = r.date(5) else { return nil }
        return WorkbenchField(id: id, datasetID: ds, name: name, valueShape: shape, ordinal: ord, createdAt: c)
    }

    private nonisolated static let rowColumns = "SELECT id, dataset_id, ordinal, created_at FROM workbench_rows"
    private nonisolated static func decodeRow(_ r: SQLRow) -> WorkbenchRow? {
        guard let id = r.uuid(0), let ds = r.uuid(1), let ord = r.int(2).map({ Int($0) }), let c = r.date(3) else { return nil }
        return WorkbenchRow(id: id, datasetID: ds, ordinal: ord, createdAt: c)
    }

    private nonisolated static let cellColumns = "SELECT id, dataset_id, row_id, field_id, kind, value, status, created_at FROM workbench_cells"
    private nonisolated static func decodeCell(_ r: SQLRow) -> WorkbenchCell? {
        guard let id = r.uuid(0), let ds = r.uuid(1), let row = r.uuid(2), let field = r.uuid(3),
              let kind = r.string(4).flatMap(WorkbenchCellKind.init(rawValue:)),
              let status = r.string(6).flatMap(EvidenceStatus.init(rawValue:)), let c = r.date(7) else { return nil }
        return WorkbenchCell(id: id, datasetID: ds, rowID: row, fieldID: field, kind: kind, value: r.string(5), status: status, createdAt: c)
    }

    private nonisolated static let bindingColumns = "SELECT id, cell_id, target_kind, target_id, source_version_id, locator_json, ordinal, created_at FROM workbench_source_bindings"
    private nonisolated static func decodeBinding(_ r: SQLRow) -> WorkbenchSourceBinding? {
        guard let id = r.uuid(0), let cell = r.uuid(1),
              let kind = r.string(2).flatMap(WorkbenchBindingTargetKind.init(rawValue:)),
              let target = r.string(3), let ord = r.int(6).map({ Int($0) }), let c = r.date(7) else { return nil }
        let locator = r.string(5).flatMap { try? Self.decoder.decode(SourceLocator.self, from: Data($0.utf8)) }
        return WorkbenchSourceBinding(id: id, cellID: cell, targetKind: kind, targetID: target,
                                      sourceVersionID: r.uuid(4), locator: locator, ordinal: ord, createdAt: c)
    }

    private nonisolated static let viewColumns = "SELECT id, dataset_id, name, projection_json, created_at FROM workbench_saved_views"
    private nonisolated static func decodeView(_ r: SQLRow) -> WorkbenchSavedView? {
        guard let id = r.uuid(0), let ds = r.uuid(1), let name = r.string(2), let proj = r.string(3), let c = r.date(4) else { return nil }
        return WorkbenchSavedView(id: id, datasetID: ds, name: name, projectionJSON: proj, createdAt: c)
    }

    private nonisolated static let eventColumns = "SELECT id, dataset_id, sequence, dataset_revision, action, actor, detail, occurred_at FROM workbench_dataset_events"
    private nonisolated static func decodeEvent(_ r: SQLRow) -> WorkbenchDatasetEvent? {
        guard let id = r.uuid(0), let ds = r.uuid(1), let seq = r.int(2).map({ Int($0) }), let rev = r.int(3).map({ Int($0) }),
              let action = r.string(4).flatMap(WorkbenchDatasetEventAction.init(rawValue:)), let actor = r.string(5), let at = r.date(7) else { return nil }
        return WorkbenchDatasetEvent(id: id, datasetID: ds, sequence: seq, datasetRevision: rev, action: action, actor: actor, detail: r.string(6), occurredAt: at)
    }
}
