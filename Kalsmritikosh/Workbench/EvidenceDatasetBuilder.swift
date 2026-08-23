//
//  EvidenceDatasetBuilder.swift
//  Kalsmritikosh
//
//  Builds a DataLab dataset FROM the ingested ledger, with every populated cell
//  drill-through bound to the exact canonical object it came from — the same
//  sourced-dataset pattern the Investigator's Source Inventory uses
//  (InvestigationDataLabService), generalized to shapes any persona can use.
//
//  This is what makes DataLab more than a spreadsheet: you don't re-key your
//  evidence, and every value proves where it came from (green, drillable),
//  rather than being hand-typed (grey, unsourced).
//
//  Two shapes are available today because the ledger genuinely holds this data:
//    • Timeline        — one row per dated Event, bound to that Event.
//    • People & orgs    — one row per canonical Entity, bound to that Entity.
//  Payments/claims shapes are the next extension (they need per-edge amounts /
//  claim rows the ledger does not yet expose cleanly).
//

import Foundation

public actor EvidenceDatasetBuilder {

    public struct BuildResult: Sendable {
        public let record: WorkbenchDatasetRecord
        public let rowsAdded: Int
        public let boundCells: Int
    }

    public enum Shape: String, Sendable, CaseIterable {
        case timeline
        case peopleAndOrganizations
        case payments
        case communications
        case conflicts
        case missingEvidence
    }

    private let datasets: WorkbenchDatasetRepository
    private let events: EventsRepository
    private let entities: EntitiesRepository
    private let relationships: RelationshipsRepository

    public init(datasets: WorkbenchDatasetRepository, events: EventsRepository,
                entities: EntitiesRepository, relationships: RelationshipsRepository) {
        self.datasets = datasets
        self.events = events
        self.entities = entities
        self.relationships = relationships
    }

    private nonisolated var isoFormatter: ISO8601DateFormatter { ISO8601DateFormatter() }

    // MARK: - Timeline (from dated events)

    /// One row per dated event, newest first, each populated cell bound to that
    /// event (drill-through). `allowedObjectIDs`, when non-nil, restricts to
    /// events whose source object is in that set (workspace scoping); nil = all.
    public func buildTimeline(workspaceID: UUID, title: String,
                              allowedObjectIDs: Set<UUID>?, limit: Int = 500,
                              actor: String, at date: Date) async throws -> BuildResult {
        var all = try await events.recent(limit: max(limit, 1))
        if let allow = allowedObjectIDs {
            all = all.filter { allow.contains($0.sourceObjectID) }
        }
        let picked = Array(all.prefix(limit))

        var rec = try await datasets.createDataset(workspaceID: workspaceID, title: title,
                                                   mode: .advanced, actor: actor, at: date)
        let id = rec.dataset.id
        let fields: [(String, FactSchemaRegistry.ValueShape)] = [
            ("Date", .date), ("Event", .text), ("Details", .text)
        ]
        var fieldID: [String: UUID] = [:]
        for (name, shape) in fields {
            rec = try await datasets.addField(datasetID: id, name: name, valueShape: shape,
                                              expectedRevision: rec.dataset.revision, actor: actor, at: date)
            fieldID[name] = rec.fields.first { $0.name == name }?.id
        }

        var bound = 0
        for event in picked {
            rec = try await datasets.addRow(datasetID: id, expectedRevision: rec.dataset.revision, actor: actor, at: date)
            guard let row = rec.rows.last else { continue }
            let values: [(String, String)] = [
                ("Date", isoFormatter.string(from: event.date)),
                ("Event", event.title),
                ("Details", event.summary ?? "")
            ]
            for (name, value) in values where !value.isEmpty {
                guard let fid = fieldID[name] else { continue }
                rec = try await datasets.setCell(datasetID: id, rowID: row.id, fieldID: fid,
                                                 kind: .sourceValue, value: value, status: .directlyObserved,
                                                 expectedRevision: rec.dataset.revision, actor: actor, at: date)
                guard let cell = rec.cells.first(where: { $0.rowID == row.id && $0.fieldID == fid }) else { continue }
                rec = try await datasets.bindSource(cellID: cell.id, targetKind: .event,
                                                    targetID: event.id.uuidString, sourceVersionID: nil, locator: nil,
                                                    expectedRevision: rec.dataset.revision, actor: actor, at: date)
                bound += 1
            }
        }
        return BuildResult(record: rec, rowsAdded: picked.count, boundCells: bound)
    }

    // MARK: - People & organizations (from entities)

    /// One row per canonical entity of the requested kinds, the Name cell bound
    /// to that entity (drill-through). Entities aren't workspace-scoped through a
    /// simple call, so this draws on the whole ledger (stated in the UI).
    public func buildEntities(workspaceID: UUID, title: String,
                              kinds: [Entity.Kind], limit: Int = 500,
                              actor: String, at date: Date) async throws -> BuildResult {
        var collected: [(id: UUID, name: String, kind: String)] = []
        for kind in kinds {
            let rows = try await entities.list(kind: kind, limit: limit)
            for r in rows { collected.append((r.id, r.value, kind.rawValue)) }
        }
        let picked = Array(collected.prefix(limit))

        var rec = try await datasets.createDataset(workspaceID: workspaceID, title: title,
                                                   mode: .advanced, actor: actor, at: date)
        let id = rec.dataset.id
        for (name, shape) in [("Name", FactSchemaRegistry.ValueShape.text), ("Kind", .text)] {
            rec = try await datasets.addField(datasetID: id, name: name, valueShape: shape,
                                              expectedRevision: rec.dataset.revision, actor: actor, at: date)
        }
        let nameFieldID = rec.fields.first { $0.name == "Name" }?.id
        let kindFieldID = rec.fields.first { $0.name == "Kind" }?.id

        var bound = 0
        for entity in picked {
            rec = try await datasets.addRow(datasetID: id, expectedRevision: rec.dataset.revision, actor: actor, at: date)
            guard let row = rec.rows.last else { continue }
            if let nf = nameFieldID, !entity.name.isEmpty {
                rec = try await datasets.setCell(datasetID: id, rowID: row.id, fieldID: nf,
                                                 kind: .sourceValue, value: entity.name, status: .directlyObserved,
                                                 expectedRevision: rec.dataset.revision, actor: actor, at: date)
                if let cell = rec.cells.first(where: { $0.rowID == row.id && $0.fieldID == nf }) {
                    rec = try await datasets.bindSource(cellID: cell.id, targetKind: .entity,
                                                        targetID: entity.id.uuidString, sourceVersionID: nil, locator: nil,
                                                        expectedRevision: rec.dataset.revision, actor: actor, at: date)
                    bound += 1
                }
            }
            if let kf = kindFieldID {
                rec = try await datasets.setCell(datasetID: id, rowID: row.id, fieldID: kf,
                                                 kind: .userEntered, value: entity.kind, status: .sourceAsserted,
                                                 expectedRevision: rec.dataset.revision, actor: actor, at: date)
            }
        }
        return BuildResult(record: rec, rowsAdded: picked.count, boundCells: bound)
    }

    // MARK: - Relationship tables (payments, communications)

    /// One row per relationship edge of the given kinds, both parties
    /// drill-through bound to their entity, plus corroboration weight and
    /// source-document count as honest summary figures (no invented amount).
    private func buildEdgeTable(kinds: [Relationship.Kind],
                                fromName: String, toName: String, countName: String,
                                workspaceID: UUID, title: String, limit: Int,
                                actor: String, at date: Date) async throws -> BuildResult {
        let edges = try await relationships.fundFlowEdges(kinds: kinds, limit: limit)

        var rec = try await datasets.createDataset(workspaceID: workspaceID, title: title,
                                                   mode: .advanced, actor: actor, at: date)
        let id = rec.dataset.id
        let fields: [(String, FactSchemaRegistry.ValueShape)] = [
            (fromName, .text), (toName, .text), (countName, .number), ("Source documents", .number)
        ]
        var fieldID: [String: UUID] = [:]
        for (name, shape) in fields {
            rec = try await datasets.addField(datasetID: id, name: name, valueShape: shape,
                                              expectedRevision: rec.dataset.revision, actor: actor, at: date)
            fieldID[name] = rec.fields.first { $0.name == name }?.id
        }

        var bound = 0
        for edge in edges {
            rec = try await datasets.addRow(datasetID: id, expectedRevision: rec.dataset.revision, actor: actor, at: date)
            guard let row = rec.rows.last else { continue }

            let parties: [(field: String, label: String, entityID: UUID)] = [
                (fromName, edge.fromLabel, edge.fromID),
                (toName, edge.toLabel, edge.toID)
            ]
            for party in parties {
                guard let fid = fieldID[party.field], !party.label.isEmpty else { continue }
                rec = try await datasets.setCell(datasetID: id, rowID: row.id, fieldID: fid,
                                                 kind: .sourceValue, value: party.label, status: .directlyObserved,
                                                 expectedRevision: rec.dataset.revision, actor: actor, at: date)
                guard let cell = rec.cells.first(where: { $0.rowID == row.id && $0.fieldID == fid }) else { continue }
                rec = try await datasets.bindSource(cellID: cell.id, targetKind: .entity,
                                                    targetID: party.entityID.uuidString, sourceVersionID: nil, locator: nil,
                                                    expectedRevision: rec.dataset.revision, actor: actor, at: date)
                bound += 1
            }
            if let wf = fieldID[countName] {
                rec = try await datasets.setCell(datasetID: id, rowID: row.id, fieldID: wf,
                                                 kind: .userEntered, value: String(edge.weight), status: .sourceAsserted,
                                                 expectedRevision: rec.dataset.revision, actor: actor, at: date)
            }
            if let sf = fieldID["Source documents"] {
                rec = try await datasets.setCell(datasetID: id, rowID: row.id, fieldID: sf,
                                                 kind: .userEntered, value: String(edge.evidenceCount), status: .sourceAsserted,
                                                 expectedRevision: rec.dataset.revision, actor: actor, at: date)
            }
        }
        return BuildResult(record: rec, rowsAdded: edges.count, boundCells: bound)
    }

    /// Payments: payer → payee (Forensic / SIU daily work).
    public func buildPayments(workspaceID: UUID, title: String, limit: Int = 500,
                              actor: String, at date: Date) async throws -> BuildResult {
        try await buildEdgeTable(kinds: [.paid], fromName: "Payer", toName: "Payee",
                                 countName: "Times observed", workspaceID: workspaceID, title: title,
                                 limit: limit, actor: actor, at: date)
    }

    /// Communications: who contacted whom (Investigator / Journalist daily work).
    public func buildCommunications(workspaceID: UUID, title: String, limit: Int = 500,
                                    actor: String, at date: Date) async throws -> BuildResult {
        try await buildEdgeTable(kinds: [.emailed, .sent, .received], fromName: "From", toName: "To",
                                 countName: "Messages", workspaceID: workspaceID, title: title,
                                 limit: limit, actor: actor, at: date)
    }

    // MARK: - Review-desk tables (conflicts, missing evidence)

    /// Conflicts to resolve: one row per detected contradiction, the conflict
    /// cell drill-through bound to the contradiction record.
    public func buildContradictions(contradictions repo: ContradictionsRepository,
                                    workspaceID: UUID, title: String, limit: Int = 500,
                                    actor: String, at date: Date) async throws -> BuildResult {
        let items = await repo.all(limit: limit)
        var rec = try await datasets.createDataset(workspaceID: workspaceID, title: title,
                                                   mode: .advanced, actor: actor, at: date)
        let id = rec.dataset.id
        for (name, shape) in [("Conflict", FactSchemaRegistry.ValueShape.text), ("Claim A", .text),
                              ("Claim B", .text), ("Severity", .text), ("Status", .text)] {
            rec = try await datasets.addField(datasetID: id, name: name, valueShape: shape,
                                              expectedRevision: rec.dataset.revision, actor: actor, at: date)
        }
        func fid(_ n: String) -> UUID? { rec.fields.first { $0.name == n }?.id }
        var bound = 0
        for c in items {
            rec = try await datasets.addRow(datasetID: id, expectedRevision: rec.dataset.revision, actor: actor, at: date)
            guard let row = rec.rows.last else { continue }
            let anchor = c.description.isEmpty ? c.kind.rawValue : c.description
            if let f = fid("Conflict") {
                rec = try await datasets.setCell(datasetID: id, rowID: row.id, fieldID: f,
                                                 kind: .sourceValue, value: anchor, status: .directlyObserved,
                                                 expectedRevision: rec.dataset.revision, actor: actor, at: date)
                if let cell = rec.cells.first(where: { $0.rowID == row.id && $0.fieldID == f }) {
                    rec = try await datasets.bindSource(cellID: cell.id, targetKind: .contradiction,
                                                        targetID: c.id.uuidString, sourceVersionID: nil, locator: nil,
                                                        expectedRevision: rec.dataset.revision, actor: actor, at: date)
                    bound += 1
                }
            }
            for (name, value) in [("Claim A", c.claimA), ("Claim B", c.claimB),
                                  ("Severity", c.severity.rawValue), ("Status", c.status.rawValue)] {
                guard let f = fid(name), !value.isEmpty else { continue }
                rec = try await datasets.setCell(datasetID: id, rowID: row.id, fieldID: f,
                                                 kind: .userEntered, value: value, status: .sourceAsserted,
                                                 expectedRevision: rec.dataset.revision, actor: actor, at: date)
            }
        }
        return BuildResult(record: rec, rowsAdded: items.count, boundCells: bound)
    }

    /// Missing evidence / follow-ups: one row per gap, the gap cell
    /// drill-through bound to the gap record.
    public func buildGaps(gaps repo: GapNodeRepository,
                          workspaceID: UUID, title: String, limit: Int = 500,
                          actor: String, at date: Date) async throws -> BuildResult {
        let items = await repo.all(includeDismissed: false, limit: limit)
        var rec = try await datasets.createDataset(workspaceID: workspaceID, title: title,
                                                   mode: .advanced, actor: actor, at: date)
        let id = rec.dataset.id
        for (name, shape) in [("Gap", FactSchemaRegistry.ValueShape.text), ("Why it matters", .text),
                              ("Near", .text), ("Status", .text)] {
            rec = try await datasets.addField(datasetID: id, name: name, valueShape: shape,
                                              expectedRevision: rec.dataset.revision, actor: actor, at: date)
        }
        func fid(_ n: String) -> UUID? { rec.fields.first { $0.name == n }?.id }
        var bound = 0
        for g in items {
            rec = try await datasets.addRow(datasetID: id, expectedRevision: rec.dataset.revision, actor: actor, at: date)
            guard let row = rec.rows.last else { continue }
            let anchor = g.description.isEmpty ? g.kind.rawValue : g.description
            if let f = fid("Gap") {
                rec = try await datasets.setCell(datasetID: id, rowID: row.id, fieldID: f,
                                                 kind: .sourceValue, value: anchor, status: .directlyObserved,
                                                 expectedRevision: rec.dataset.revision, actor: actor, at: date)
                if let cell = rec.cells.first(where: { $0.rowID == row.id && $0.fieldID == f }) {
                    rec = try await datasets.bindSource(cellID: cell.id, targetKind: .gap,
                                                        targetID: g.id.uuidString, sourceVersionID: nil, locator: nil,
                                                        expectedRevision: rec.dataset.revision, actor: actor, at: date)
                    bound += 1
                }
            }
            for (name, value) in [("Why it matters", g.reason), ("Near", g.nearEntity ?? ""),
                                  ("Status", g.dismissed ? "dismissed" : "open")] {
                guard let f = fid(name), !value.isEmpty else { continue }
                rec = try await datasets.setCell(datasetID: id, rowID: row.id, fieldID: f,
                                                 kind: .userEntered, value: value, status: .sourceAsserted,
                                                 expectedRevision: rec.dataset.revision, actor: actor, at: date)
            }
        }
        return BuildResult(record: rec, rowsAdded: items.count, boundCells: bound)
    }
}
