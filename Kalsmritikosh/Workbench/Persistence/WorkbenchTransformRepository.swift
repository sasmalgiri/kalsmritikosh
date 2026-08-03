//
//  WorkbenchTransformRepository.swift
//  Kalsmritikosh
//
//  LAB-002 (Stage C) — the ONE authoritative writer/reader for safe transformations (schema v93). It
//  computes an outcome with the pure WorkbenchTransformEngine, then persists it atomically: a
//  calculated / running-total column becomes new `deterministicCalculation` cells (never overwriting a
//  source cell), a filter / sort / deduplicate becomes a recorded projection, and an aggregate becomes
//  grouped derived values — each derived value pinned to its formula/transformation, its EXACT input
//  cell IDs, the engine version, and its output, so it is reproducible and auditable. Canonical
//  evidence is READ-ONLY here (the engine only reads the dataset's own cells; nothing outside the
//  workbench_* tables is touched). An `unsupported` outcome is REFUSED, never silently no-op'd.
//

import Foundation

public actor WorkbenchTransformRepository {
    private let database: Database

    public init(database: Database) { self.database = database }

    private nonisolated static let encoder = JSONEncoder()
    private nonisolated static let decoder = JSONDecoder()

    // MARK: - Apply (atomic)

    /// Compute and durably persist a transformation over a dataset. One SAVEPOINT covers the new field
    /// (for a column), the derived cells, the transformation row, its derivation + input-lineage rows,
    /// the dataset revision bump and the `transformed` event. Fails closed: an unsupported kind, a
    /// mis-specified formula or a stale revision aborts the whole unit with nothing written.
    @discardableResult
    public func applyTransform(datasetID: UUID, spec: WorkbenchTransformSpec, expectedRevision: Int,
                               actor: String, at date: Date) async throws -> WorkbenchTransformationRecord {
        guard !actor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw WorkbenchError.blankActor }
        guard let record = try await fetchRecord(datasetID) else { throw WorkbenchError.datasetNotFound(datasetID) }
        guard record.dataset.revision == expectedRevision else {
            throw WorkbenchError.revisionConflict(expected: expectedRevision, actual: record.dataset.revision)
        }

        let outcome = try WorkbenchTransformEngine.compute(spec, over: record)
        if case .unsupported(let kind, _) = outcome { throw WorkbenchTransformError.notMaterializable(kind) }

        let specJSON = try Self.encodeSpec(spec)
        let transformationID = UUID()
        let newRev = record.dataset.revision + 1
        let sp = savepoint("wbtx", transformationID)

        var derivations: [WorkbenchDerivation] = []
        var inputs: [WorkbenchDerivationInput] = []
        var targetFieldID: UUID?
        var resultJSON: String?

        do {
            try await database.exec("SAVEPOINT \(sp);")
            let sequence = try await nextTransformSequence(datasetID)

            switch outcome {
            case .column(let col):
                targetFieldID = try await insertField(datasetID: datasetID, name: col.newFieldName,
                                                       shape: col.shape, at: date)
                try await insertTransformation(id: transformationID, datasetID: datasetID, sequence: sequence,
                                               kind: spec.kind, formulaText: spec.formulaText, specJSON: specJSON,
                                               targetFieldID: targetFieldID, resultJSON: nil, actor: actor, at: date)
                for dv in col.perRow {
                    guard let rowID = dv.rowID else { continue }
                    let cellID = try await insertDerivedCell(datasetID: datasetID, rowID: rowID,
                                                             fieldID: targetFieldID!, value: dv.value.storedString, at: date)
                    let (der, ins) = try await insertDerivation(transformationID: transformationID, datasetID: datasetID,
                                                               outputCellID: cellID, resultKey: nil,
                                                               outputValue: dv.value.storedString, inputCellIDs: dv.inputCellIDs, at: date)
                    derivations.append(der); inputs.append(contentsOf: ins)
                }

            case .projection(let proj):
                resultJSON = try Self.encodeRowIDs(proj.orderedRowIDs)
                try await insertTransformation(id: transformationID, datasetID: datasetID, sequence: sequence,
                                               kind: spec.kind, formulaText: spec.formulaText, specJSON: specJSON,
                                               targetFieldID: nil, resultJSON: resultJSON, actor: actor, at: date)

            case .aggregate(let agg):
                resultJSON = try Self.encodeAggregate(agg)
                try await insertTransformation(id: transformationID, datasetID: datasetID, sequence: sequence,
                                               kind: spec.kind, formulaText: nil, specJSON: specJSON,
                                               targetFieldID: nil, resultJSON: resultJSON, actor: actor, at: date)
                for dv in agg.groups {
                    let (der, ins) = try await insertDerivation(transformationID: transformationID, datasetID: datasetID,
                                                               outputCellID: nil, resultKey: dv.resultKey,
                                                               outputValue: dv.value.storedString, inputCellIDs: dv.inputCellIDs, at: date)
                    derivations.append(der); inputs.append(contentsOf: ins)
                }

            case .unsupported:
                throw WorkbenchTransformError.notMaterializable(spec.kind)
            }

            try await bumpRevision(datasetID, to: newRev, at: date)
            try await appendTransformedEvent(datasetID: datasetID, revision: newRev, actor: actor,
                                             detail: spec.kind.rawValue, at: date)
            try await database.exec("RELEASE SAVEPOINT \(sp);")
        } catch {
            try? await database.exec("ROLLBACK TO SAVEPOINT \(sp);")
            try? await database.exec("RELEASE SAVEPOINT \(sp);")
            throw error
        }

        let transformation = WorkbenchTransformation(
            id: transformationID, datasetID: datasetID, sequence: try await maxSequence(datasetID),
            kind: spec.kind, formulaText: (spec.kind == .aggregate ? nil : spec.formulaText),
            engineVersion: WorkbenchTransformEngine.engineVersion, specJSON: specJSON,
            targetFieldID: targetFieldID, resultJSON: resultJSON, actor: actor, createdAt: date)
        return WorkbenchTransformationRecord(transformation: transformation, derivations: derivations, inputs: inputs)
    }

    // MARK: - Reads

    public func transformations(datasetID: UUID) async throws -> [WorkbenchTransformation] {
        (try await database.query("\(Self.txColumns) WHERE dataset_id = ? ORDER BY sequence ASC;", [.uuid(datasetID)]))
            .compactMap(Self.decodeTransformation)
    }

    public func transformation(id: UUID) async throws -> WorkbenchTransformation? {
        (try await database.query("\(Self.txColumns) WHERE id = ? LIMIT 1;", [.uuid(id)])).first.flatMap(Self.decodeTransformation)
    }

    public func derivations(transformationID: UUID) async throws -> [WorkbenchDerivation] {
        (try await database.query("\(Self.derColumns) WHERE transformation_id = ? ORDER BY created_at ASC, id ASC;", [.uuid(transformationID)]))
            .compactMap(Self.decodeDerivation)
    }

    public func inputs(derivationID: UUID) async throws -> [WorkbenchDerivationInput] {
        (try await database.query("""
            SELECT id, derivation_id, input_cell_id, ordinal FROM workbench_derivation_inputs
            WHERE derivation_id = ? ORDER BY ordinal ASC;
            """, [.uuid(derivationID)])).compactMap(Self.decodeInput)
    }

    /// The full durable record of an applied transformation (reproduction / audit anchor).
    public func record(transformationID: UUID) async throws -> WorkbenchTransformationRecord? {
        guard let tx = try await transformation(id: transformationID) else { return nil }
        let ders = try await derivations(transformationID: transformationID)
        var allInputs: [WorkbenchDerivationInput] = []
        for d in ders { allInputs.append(contentsOf: try await inputs(derivationID: d.id)) }
        return WorkbenchTransformationRecord(transformation: tx, derivations: ders, inputs: allInputs)
    }

    /// Decode a stored transformation's spec back into a typed WorkbenchTransformSpec.
    public nonisolated func decodeSpec(_ transformation: WorkbenchTransformation) throws -> WorkbenchTransformSpec {
        try Self.decoder.decode(WorkbenchTransformSpec.self, from: Data(transformation.specJSON.utf8))
    }

    /// Re-run a stored transformation's spec against the CURRENT dataset state and return the recomputed
    /// outcome — the basis for an audit "does this still reproduce?" check. Pure recomputation; writes nothing.
    public func recompute(transformationID: UUID) async throws -> WorkbenchTransformOutcome? {
        guard let tx = try await transformation(id: transformationID),
              let rec = try await fetchRecord(tx.datasetID) else { return nil }
        let spec = try decodeSpec(tx)
        return try WorkbenchTransformEngine.compute(spec, over: rec)
    }

    // MARK: - Inserts (inside the caller's SAVEPOINT)

    private func insertField(datasetID: UUID, name: String, shape: FactSchemaRegistry.ValueShape, at date: Date) async throws -> UUID {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw WorkbenchTransformError.emptyFieldName }
        let id = UUID()
        let ordinal = try await nextOrdinal("workbench_fields", datasetID)
        try await database.exec("""
            INSERT INTO workbench_fields (id, dataset_id, name, value_shape, ordinal, created_at)
            VALUES (?,?,?,?,?,?);
            """, [.uuid(id), .uuid(datasetID), .text(clean), .text(shape.rawValue), .integer(Int64(ordinal)), .date(date)])
        return id
    }

    private func insertDerivedCell(datasetID: UUID, rowID: UUID, fieldID: UUID, value: String?, at date: Date) async throws -> UUID {
        let id = UUID()
        // A brand-new column has no prior cell at (row, field); insert a deterministicCalculation cell.
        try await database.exec("""
            INSERT INTO workbench_cells (id, dataset_id, row_id, field_id, kind, value, status, created_at)
            VALUES (?,?,?,?,?,?,?,?);
            """, [.uuid(id), .uuid(datasetID), .uuid(rowID), .uuid(fieldID),
                  .text(WorkbenchCellKind.deterministicCalculation.rawValue),
                  value.map { SQLValue.text($0) } ?? .null,
                  .text(EvidenceStatus.deterministicallyDerived.rawValue), .date(date)])
        return id
    }

    private func insertTransformation(id: UUID, datasetID: UUID, sequence: Int, kind: WorkbenchTransformKind,
                                     formulaText: String?, specJSON: String, targetFieldID: UUID?,
                                     resultJSON: String?, actor: String, at date: Date) async throws {
        try await database.exec("""
            INSERT INTO workbench_transformations
              (id, dataset_id, sequence, kind, formula_text, engine_version, spec_json, target_field_id, result_json, actor, created_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(id), .uuid(datasetID), .integer(Int64(sequence)), .text(kind.rawValue),
                  formulaText.map { SQLValue.text($0) } ?? .null, .text(WorkbenchTransformEngine.engineVersion),
                  .text(specJSON), targetFieldID.map { SQLValue.uuid($0) } ?? .null,
                  resultJSON.map { SQLValue.text($0) } ?? .null, .text(actor), .date(date)])
    }

    private func insertDerivation(transformationID: UUID, datasetID: UUID, outputCellID: UUID?, resultKey: String?,
                                 outputValue: String?, inputCellIDs: [UUID], at date: Date) async throws
                                 -> (WorkbenchDerivation, [WorkbenchDerivationInput]) {
        let id = UUID()
        try await database.exec("""
            INSERT INTO workbench_derivations (id, transformation_id, dataset_id, output_cell_id, result_key, output_value, created_at)
            VALUES (?,?,?,?,?,?,?);
            """, [.uuid(id), .uuid(transformationID), .uuid(datasetID),
                  outputCellID.map { SQLValue.uuid($0) } ?? .null,
                  resultKey.map { SQLValue.text($0) } ?? .null,
                  outputValue.map { SQLValue.text($0) } ?? .null, .date(date)])
        var ins: [WorkbenchDerivationInput] = []
        for (i, cellID) in inputCellIDs.enumerated() {
            let inputID = UUID()
            try await database.exec("""
                INSERT INTO workbench_derivation_inputs (id, derivation_id, input_cell_id, ordinal)
                VALUES (?,?,?,?);
                """, [.uuid(inputID), .uuid(id), .uuid(cellID), .integer(Int64(i))])
            ins.append(WorkbenchDerivationInput(id: inputID, derivationID: id, inputCellID: cellID, ordinal: i))
        }
        let der = WorkbenchDerivation(id: id, transformationID: transformationID, datasetID: datasetID,
                                      outputCellID: outputCellID, resultKey: resultKey, outputValue: outputValue, createdAt: date)
        return (der, ins)
    }

    private func bumpRevision(_ datasetID: UUID, to revision: Int, at date: Date) async throws {
        try await database.exec("UPDATE workbench_datasets SET revision = ?, updated_at = ? WHERE id = ?;",
                                [.integer(Int64(revision)), .date(date), .uuid(datasetID)])
    }

    private func appendTransformedEvent(datasetID: UUID, revision: Int, actor: String, detail: String, at date: Date) async throws {
        let seq = Int(try await database.query("SELECT COALESCE(MAX(sequence), 0) FROM workbench_dataset_events WHERE dataset_id = ?;", [.uuid(datasetID)]).first?.int(0) ?? 0) + 1
        try await database.exec("""
            INSERT INTO workbench_dataset_events (id, dataset_id, sequence, dataset_revision, action, actor, detail, occurred_at)
            VALUES (?,?,?,?,?,?,?,?);
            """, [.uuid(UUID()), .uuid(datasetID), .integer(Int64(seq)), .integer(Int64(revision)),
                  .text(WorkbenchDatasetEventAction.transformed.rawValue), .text(actor), .text(detail), .date(date)])
    }

    // MARK: - Helpers

    private func nextTransformSequence(_ datasetID: UUID) async throws -> Int {
        Int(try await database.query("SELECT COALESCE(MAX(sequence), 0) FROM workbench_transformations WHERE dataset_id = ?;", [.uuid(datasetID)]).first?.int(0) ?? 0) + 1
    }
    private func maxSequence(_ datasetID: UUID) async throws -> Int {
        Int(try await database.query("SELECT COALESCE(MAX(sequence), 0) FROM workbench_transformations WHERE dataset_id = ?;", [.uuid(datasetID)]).first?.int(0) ?? 0)
    }
    private func nextOrdinal(_ table: String, _ datasetID: UUID) async throws -> Int {
        Int(try await database.query("SELECT COALESCE(MAX(ordinal), -1) FROM \(table) WHERE dataset_id = ?;", [.uuid(datasetID)]).first?.int(0) ?? -1) + 1
    }
    private func savepoint(_ prefix: String, _ id: UUID) -> String {
        "\(prefix)_\(id.uuidString.replacingOccurrences(of: "-", with: ""))"
    }

    /// Reconstruct the current dataset record directly (independent of WorkbenchDatasetRepository so the
    /// transform layer has a single self-contained read path). Deterministic ordering mirrors LAB-001.
    private func fetchRecord(_ datasetID: UUID) async throws -> WorkbenchDatasetRecord? {
        guard let ds = (try await database.query(
            "SELECT id, workspace_id, title, mode, revision, created_at, updated_at FROM workbench_datasets WHERE id = ? LIMIT 1;",
            [.uuid(datasetID)])).first.flatMap(Self.decodeDataset) else { return nil }
        let fields = (try await database.query(
            "SELECT id, dataset_id, name, value_shape, ordinal, created_at FROM workbench_fields WHERE dataset_id = ? ORDER BY ordinal ASC, id ASC;",
            [.uuid(datasetID)])).compactMap(Self.decodeField)
        let rows = (try await database.query(
            "SELECT id, dataset_id, ordinal, created_at FROM workbench_rows WHERE dataset_id = ? ORDER BY ordinal ASC, id ASC;",
            [.uuid(datasetID)])).compactMap(Self.decodeRow)
        let cells = (try await database.query(
            "SELECT id, dataset_id, row_id, field_id, kind, value, status, created_at FROM workbench_cells WHERE dataset_id = ? ORDER BY created_at ASC, id ASC;",
            [.uuid(datasetID)])).compactMap(Self.decodeCell)
        return WorkbenchDatasetRecord(dataset: ds, fields: fields, rows: rows, cells: cells,
                                      bindings: [], savedViews: [], events: [])
    }

    // MARK: - Codable result payloads

    private nonisolated struct RowIDList: Codable { let orderedRowIDs: [String] }
    private nonisolated struct AggregateGroupPayload: Codable { let key: String?; let value: String? }
    private nonisolated struct AggregatePayload: Codable { let function: String; let groups: [AggregateGroupPayload] }

    private nonisolated static func encodeSpec(_ spec: WorkbenchTransformSpec) throws -> String {
        String(data: try encoder.encode(spec), encoding: .utf8) ?? "{}"
    }
    private nonisolated static func encodeRowIDs(_ ids: [UUID]) throws -> String {
        String(data: try encoder.encode(RowIDList(orderedRowIDs: ids.map(\.uuidString))), encoding: .utf8) ?? "{}"
    }
    private nonisolated static func encodeAggregate(_ agg: WorkbenchAggregateResult) throws -> String {
        let payload = AggregatePayload(function: agg.function.rawValue,
                                       groups: agg.groups.map { AggregateGroupPayload(key: $0.resultKey, value: $0.value.storedString) })
        return String(data: try encoder.encode(payload), encoding: .utf8) ?? "{}"
    }

    // MARK: - Columns + decoders

    private nonisolated static let txColumns = "SELECT id, dataset_id, sequence, kind, formula_text, engine_version, spec_json, target_field_id, result_json, actor, created_at FROM workbench_transformations"
    private nonisolated static func decodeTransformation(_ r: SQLRow) -> WorkbenchTransformation? {
        guard let id = r.uuid(0), let ds = r.uuid(1), let seq = r.int(2).map({ Int($0) }),
              let kind = r.string(3).flatMap(WorkbenchTransformKind.init(rawValue:)),
              let engine = r.string(5), let spec = r.string(6), let actor = r.string(9), let c = r.date(10) else { return nil }
        return WorkbenchTransformation(id: id, datasetID: ds, sequence: seq, kind: kind, formulaText: r.string(4),
                                       engineVersion: engine, specJSON: spec, targetFieldID: r.uuid(7),
                                       resultJSON: r.string(8), actor: actor, createdAt: c)
    }

    private nonisolated static let derColumns = "SELECT id, transformation_id, dataset_id, output_cell_id, result_key, output_value, created_at FROM workbench_derivations"
    private nonisolated static func decodeDerivation(_ r: SQLRow) -> WorkbenchDerivation? {
        guard let id = r.uuid(0), let tx = r.uuid(1), let ds = r.uuid(2), let c = r.date(6) else { return nil }
        return WorkbenchDerivation(id: id, transformationID: tx, datasetID: ds, outputCellID: r.uuid(3),
                                   resultKey: r.string(4), outputValue: r.string(5), createdAt: c)
    }

    private nonisolated static func decodeInput(_ r: SQLRow) -> WorkbenchDerivationInput? {
        guard let id = r.uuid(0), let der = r.uuid(1), let cell = r.uuid(2), let ord = r.int(3).map({ Int($0) }) else { return nil }
        return WorkbenchDerivationInput(id: id, derivationID: der, inputCellID: cell, ordinal: ord)
    }

    // Dataset-record decoders (mirror LAB-001's, kept local to this self-contained read path).
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
}
