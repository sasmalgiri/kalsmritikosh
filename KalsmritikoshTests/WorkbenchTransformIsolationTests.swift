//
//  WorkbenchTransformIsolationTests.swift
//  KalsmritikoshTests
//
//  F28 — transforms applied CONCURRENTLY on one shared Database must stay isolated: a transform
//  that fails inside its savepoint rolls back only its own rows, never a neighbour's, and every
//  successful transform lands whole. The revision is compared-and-swapped inside the transaction.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("F28 — Workbench transforms are isolated transactions")
struct WorkbenchTransformIsolationTests {

    private let t0 = Date(timeIntervalSinceReferenceDate: 0)

    /// A dataset with one numeric field and three rows; returns (id, revision).
    private func seedDataset(_ datasets: WorkbenchDatasetRepository, workspace: UUID) async throws -> (UUID, Int) {
        var rec = try await datasets.createDataset(workspaceID: workspace, title: "D", mode: .advanced, actor: "u", at: t0)
        let id = rec.dataset.id
        rec = try await datasets.addField(datasetID: id, name: "amount", valueShape: .number,
                                          expectedRevision: rec.dataset.revision, actor: "u", at: t0)
        let field = rec.fields.first { $0.name == "amount" }!.id
        for v in ["1", "2", "3"] {
            rec = try await datasets.addRow(datasetID: id, expectedRevision: rec.dataset.revision, actor: "u", at: t0)
            let row = rec.rows.max { $0.ordinal < $1.ordinal }!.id
            rec = try await datasets.setCell(datasetID: id, rowID: row, fieldID: field, kind: .sourceValue, value: v,
                                             status: .directlyObserved, expectedRevision: rec.dataset.revision, actor: "u", at: t0)
        }
        return (id, rec.dataset.revision)
    }

    @Test("Concurrent good and failing transforms: every good one lands whole, no failure leaves a row")
    func concurrentTransformsStayIsolated() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let ws = UUID()
        try await db.exec("INSERT INTO workspaces (id, title, created_at, updated_at) VALUES (?,?,?,?);",
                          [.uuid(ws), .text("W"), .real(0), .real(0)])
        let datasets = WorkbenchDatasetRepository(database: db)
        let transforms = WorkbenchTransformRepository(database: db)
        var targets: [(id: UUID, rev: Int, good: Bool)] = []
        for i in 0..<16 {
            let (id, rev) = try await seedDataset(datasets, workspace: ws)
            targets.append((id, rev, i % 2 == 0))
        }

        // A blank new-field name is rejected INSIDE the savepoint (after writes could have begun).
        let outcomes = await withTaskGroup(of: (UUID, Bool, Bool).self) { group in
            for t in targets {
                group.addTask {
                    let spec = WorkbenchTransformSpec.calculatedColumn(
                        newField: t.good ? "doubled" : "   ", shape: .number, formula: "[amount] * 2")
                    let ok = (try? await transforms.applyTransform(datasetID: t.id, spec: spec,
                                                                   expectedRevision: t.rev, actor: "u", at: self.t0)) != nil
                    return (t.id, t.good, ok)
                }
            }
            var all: [(UUID, Bool, Bool)] = []
            for await r in group { all.append(r) }
            return all
        }

        for (id, good, ok) in outcomes {
            #expect(ok == good, "dataset \(id): good=\(good) but ok=\(ok)")
            let rec = try #require(try await datasets.fetch(datasetID: id))
            let target = targets.first { $0.id == id }!
            let derived = rec.fields.first { $0.name == "doubled" }
            if good {
                #expect(rec.dataset.revision == target.rev + 1)
                let cells = rec.cells.filter { $0.fieldID == derived?.id }
                #expect(Set(cells.compactMap(\.value)) == ["2", "4", "6"], "a successful transform lost rows")
                #expect(try await transforms.transformations(datasetID: id).count == 1)
            } else {
                #expect(rec.dataset.revision == target.rev)          // nothing bumped
                #expect(rec.fields.count == 1)                        // no field left behind
                #expect(try await transforms.transformations(datasetID: id).isEmpty)
            }
        }
    }

    @Test("A stale expected revision fails closed inside the transaction and writes nothing")
    func staleRevisionInsideTransaction() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let ws = UUID()
        try await db.exec("INSERT INTO workspaces (id, title, created_at, updated_at) VALUES (?,?,?,?);",
                          [.uuid(ws), .text("W"), .real(0), .real(0)])
        let datasets = WorkbenchDatasetRepository(database: db)
        let transforms = WorkbenchTransformRepository(database: db)
        let (id, rev) = try await seedDataset(datasets, workspace: ws)
        let spec = WorkbenchTransformSpec.calculatedColumn(newField: "d", shape: .number, formula: "[amount] + 1")
        _ = try await transforms.applyTransform(datasetID: id, spec: spec, expectedRevision: rev, actor: "u", at: t0)
        await #expect(throws: WorkbenchError.self) {
            _ = try await transforms.applyTransform(datasetID: id, spec: spec, expectedRevision: rev, actor: "u", at: self.t0)
        }
        #expect(try await transforms.transformations(datasetID: id).count == 1)
    }
}
