//
//  WorkbenchDataset.swift
//  Kalsmritikosh
//
//  LAB-001 (Stage C) — the ONE canonical Workbench / DataLab dataset model. A WorkbenchDataset is a
//  working table DERIVED from the read-only evidence ledger; it references canonical evidence, never
//  copies it into a second truth store. Every cell declares its KIND so a derived, entered or
//  proposed value is never mistaken for a direct source observation, and every source-derived cell
//  drills through a WorkbenchSourceBinding to its EXACT canonical origin (block/claim/event/… +
//  SourceVersion + locator). These are the persisted value shapes mirroring the v92 tables; writes
//  go through WorkbenchDatasetRepository. This supersedes the earlier EvidenceDataset prototype — no
//  second dataset authority, no second evidence/epistemic-status vocabulary (status reuses the
//  canonical EvidenceStatus; shapes reuse FactSchemaRegistry.ValueShape).
//
//  Truth boundaries this model preserves:
//    Workbench row  ≠ evidence
//    Workbench cell ≠ confirmed Claim
//    derived value  ≠ directly observed value
//    user-entered   ≠ source evidence
//    scenario value ≠ canonical value
//

import Foundation

/// Two presentations over one truth ledger — never two truth systems (LAB-006).
public nonisolated enum WorkbenchDatasetMode: String, Codable, Sendable, CaseIterable {
    case simple
    case advanced
}

/// The provenance class of a cell's value. `sourceValue` MUST bind evidence; the others record their
/// own basis (a deterministic calculation its transformation, a human/model entry its authorship).
public nonisolated enum WorkbenchCellKind: String, Codable, Sendable, CaseIterable {
    case sourceValue
    case deterministicCalculation
    case userEntered
    case userCorrected
    case modelProposal
    case reviewed

    /// Only a source value is required to drill through to a canonical evidence binding.
    public nonisolated var requiresSourceBinding: Bool { self == .sourceValue }
}

/// The canonical authority a source binding points at. No "copied text" target exists — a binding
/// always names a real canonical object identity.
public nonisolated enum WorkbenchBindingTargetKind: String, Codable, Sendable, CaseIterable {
    case evidenceBlock
    case claim
    case event
    case entity
    case sourceVersion
    case contradiction
    case gap
    case knowledgeObject
}

/// Append-only revision-history vocabulary for a dataset.
public nonisolated enum WorkbenchDatasetEventAction: String, Codable, Sendable, CaseIterable {
    case created
    case fieldAdded
    case rowAdded
    case cellSet
    case sourceBound
    case viewSaved
    case renamed
    case modeChanged
    case converted            // a legacy EvidenceDataset was converted into this canonical form
}

/// A typed column. Shape reuses the canonical FactSchemaRegistry.ValueShape — no new value vocabulary.
public nonisolated struct WorkbenchField: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let datasetID: UUID
    public let name: String
    public let valueShape: FactSchemaRegistry.ValueShape
    public let ordinal: Int
    public let createdAt: Date

    public nonisolated init(id: UUID, datasetID: UUID, name: String,
                            valueShape: FactSchemaRegistry.ValueShape, ordinal: Int, createdAt: Date) {
        self.id = id; self.datasetID = datasetID; self.name = name
        self.valueShape = valueShape; self.ordinal = ordinal; self.createdAt = createdAt
    }
}

/// A row with STABLE identity: the id survives edits/reopens so cells, scenarios and lineage stay
/// attached across revisions.
public nonisolated struct WorkbenchRow: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let datasetID: UUID
    public let ordinal: Int
    public let createdAt: Date

    public nonisolated init(id: UUID, datasetID: UUID, ordinal: Int, createdAt: Date) {
        self.id = id; self.datasetID = datasetID; self.ordinal = ordinal; self.createdAt = createdAt
    }
}

/// The drill-through record: ties a source-derived cell to its exact canonical origin + locator.
public nonisolated struct WorkbenchSourceBinding: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let cellID: UUID
    public let targetKind: WorkbenchBindingTargetKind
    public let targetID: String
    public let sourceVersionID: UUID?
    public let locator: SourceLocator?
    public let ordinal: Int
    public let createdAt: Date

    public nonisolated init(id: UUID, cellID: UUID, targetKind: WorkbenchBindingTargetKind, targetID: String,
                            sourceVersionID: UUID?, locator: SourceLocator?, ordinal: Int, createdAt: Date) {
        self.id = id; self.cellID = cellID; self.targetKind = targetKind; self.targetID = targetID
        self.sourceVersionID = sourceVersionID; self.locator = locator; self.ordinal = ordinal; self.createdAt = createdAt
    }

    /// The referenced id parsed as a UUID, when the target kind uses UUID identity.
    public nonisolated var targetUUID: UUID? { UUID(uuidString: targetID) }
}

/// One cell (row × field). A nil value is a missing cell (binds no evidence). `status` reuses the
/// canonical EvidenceStatus; `kind` is the Workbench provenance class.
public nonisolated struct WorkbenchCell: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let datasetID: UUID
    public let rowID: UUID
    public let fieldID: UUID
    public let kind: WorkbenchCellKind
    public let value: String?
    public let status: EvidenceStatus
    public let createdAt: Date

    public nonisolated init(id: UUID, datasetID: UUID, rowID: UUID, fieldID: UUID, kind: WorkbenchCellKind,
                            value: String?, status: EvidenceStatus, createdAt: Date) {
        self.id = id; self.datasetID = datasetID; self.rowID = rowID; self.fieldID = fieldID
        self.kind = kind; self.value = value; self.status = status; self.createdAt = createdAt
    }

    /// A value-bearing source cell is well-formed only if it drills through to >=1 canonical binding;
    /// a missing cell (nil value) binds nothing; other kinds record their basis elsewhere.
    public nonisolated func isWellFormed(bindingCount: Int) -> Bool {
        if value == nil { return true }
        return kind.requiresSourceBinding ? bindingCount > 0 : true
    }
}

/// A saved projection/filter over a dataset.
public nonisolated struct WorkbenchSavedView: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let datasetID: UUID
    public let name: String
    public let projectionJSON: String
    public let createdAt: Date

    public nonisolated init(id: UUID, datasetID: UUID, name: String, projectionJSON: String, createdAt: Date) {
        self.id = id; self.datasetID = datasetID; self.name = name
        self.projectionJSON = projectionJSON; self.createdAt = createdAt
    }
}

/// One durable revision-history entry.
public nonisolated struct WorkbenchDatasetEvent: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let datasetID: UUID
    public let sequence: Int
    public let datasetRevision: Int
    public let action: WorkbenchDatasetEventAction
    public let actor: String
    public let detail: String?
    public let occurredAt: Date

    public nonisolated init(id: UUID, datasetID: UUID, sequence: Int, datasetRevision: Int,
                            action: WorkbenchDatasetEventAction, actor: String, detail: String?, occurredAt: Date) {
        self.id = id; self.datasetID = datasetID; self.sequence = sequence; self.datasetRevision = datasetRevision
        self.action = action; self.actor = actor; self.detail = detail; self.occurredAt = occurredAt
    }
}

/// The dataset header, mirroring `workbench_datasets`.
public nonisolated struct WorkbenchDataset: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let workspaceID: UUID
    public let title: String
    public let mode: WorkbenchDatasetMode
    public let revision: Int
    public let createdAt: Date
    public let updatedAt: Date

    public nonisolated init(id: UUID, workspaceID: UUID, title: String, mode: WorkbenchDatasetMode,
                            revision: Int, createdAt: Date, updatedAt: Date) {
        self.id = id; self.workspaceID = workspaceID; self.title = title; self.mode = mode
        self.revision = revision; self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

/// The full durable dataset as reconstructed from disk — the close/reopen + resume anchor. Ordering
/// is deterministic (fields/rows by ordinal, cells by (row ordinal, field ordinal), events by
/// sequence) so a reopen recovers identical structure.
public nonisolated struct WorkbenchDatasetRecord: Sendable, Equatable {
    public let dataset: WorkbenchDataset
    public let fields: [WorkbenchField]
    public let rows: [WorkbenchRow]
    public let cells: [WorkbenchCell]
    public let bindings: [WorkbenchSourceBinding]
    public let savedViews: [WorkbenchSavedView]
    public let events: [WorkbenchDatasetEvent]

    public nonisolated init(dataset: WorkbenchDataset, fields: [WorkbenchField], rows: [WorkbenchRow],
                            cells: [WorkbenchCell], bindings: [WorkbenchSourceBinding],
                            savedViews: [WorkbenchSavedView], events: [WorkbenchDatasetEvent]) {
        self.dataset = dataset; self.fields = fields; self.rows = rows; self.cells = cells
        self.bindings = bindings; self.savedViews = savedViews; self.events = events
    }

    /// Bindings for a given cell, in ordinal order.
    public nonisolated func bindings(forCell cellID: UUID) -> [WorkbenchSourceBinding] {
        bindings.filter { $0.cellID == cellID }.sorted { $0.ordinal < $1.ordinal }
    }

    /// True when every source cell drills through to a canonical binding (the LAB drill-through rule).
    public nonisolated var isFullyProvenanced: Bool {
        cells.allSatisfy { $0.isWellFormed(bindingCount: bindings(forCell: $0.id).count) }
    }
}

/// Errors from the Workbench dataset layer. Fail-closed: an invalid binding, cross-workspace
/// reference or stale revision is rejected, never silently coerced.
public nonisolated enum WorkbenchError: Error, Sendable, Equatable {
    case blankTitle
    case blankActor
    case workspaceNotFound(UUID)
    case datasetNotFound(UUID)
    case fieldNotFound(UUID)
    case rowNotFound(UUID)
    case cellNotFound(UUID)
    case fieldNotInDataset(UUID)
    case rowNotInDataset(UUID)
    case revisionConflict(expected: Int, actual: Int)
    case sourceValueRequiresBinding(cell: UUID)
    case bindingTargetNotFound(kind: String, id: String)
    case bindingCrossWorkspace(kind: String, id: String)
    case duplicateCell(row: UUID, field: UUID)
    case blankFieldName
    case blankViewName
}
