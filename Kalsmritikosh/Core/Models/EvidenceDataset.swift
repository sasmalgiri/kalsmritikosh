//
//  EvidenceDataset.swift
//  Kalsmritikosh
//
//  SUPERSEDED (Stage C, LAB-001): this prototype kernel and its historical in-file "LAB-001..006"
//  labels are superseded by the canonical Workbench dataset model (Kalsmritikosh/Workbench/) — the
//  ONE dataset authority. It is retained ONLY as a temporary compatibility surface for existing code
//  and tests; convert a legacy value into the canonical form via
//  WorkbenchDatasetRepository.convertLegacy(_:). Do not add new persistence or behavior here.
//
//  (historical) LAB-001 — the one evidence kernel for the Workbench/DataLab. An EvidenceDataset is a
//  versioned table derived from the ledger where EVERY cell carries the evidence blocks that
//  back its value. "Every value and visual must drill through to source evidence" (locked
//  contract). A cell with no provenance is not allowed to hold a derived value — it must be
//  explicitly marked missing.
//
//  This is the data contract only (models + invariants). The transformation graph (LAB-003),
//  processors (LAB-004) and UI (LAB-005+) build on it. Pure value types, Sendable, Codable.
//

import Foundation

public struct DatasetColumn: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let name: String
    public let shape: FactSchemaRegistry.ValueShape
    public nonisolated init(id: UUID = UUID(), name: String, shape: FactSchemaRegistry.ValueShape) {
        self.id = id; self.name = name; self.shape = shape
    }
}

/// One cell. A derived value MUST carry >=1 supporting evidence block, or be `.missing`.
public struct DatasetCell: Codable, Sendable, Hashable {
    public let value: String?
    public let sourceBlockIDs: [UUID]
    public let status: EvidenceStatus

    public nonisolated init(value: String?, sourceBlockIDs: [UUID], status: EvidenceStatus) {
        self.value = value
        self.sourceBlockIDs = sourceBlockIDs
        self.status = status
    }

    public static let missing = DatasetCell(value: nil, sourceBlockIDs: [], status: .missingEvidence)

    /// A value-bearing cell is well-formed only if it drills through to evidence
    /// (or is a deterministic derivation / human entry, which record their own basis).
    public var isProvenanced: Bool {
        if value == nil { return status == .missingEvidence }
        switch status {
        case .deterministicallyDerived, .humanCorrected, .humanConfirmed:
            return true                    // derivation/human basis recorded elsewhere
        default:
            return !sourceBlockIDs.isEmpty  // observed/asserted values need a block
        }
    }

    /// Build an evidence-backed cell from a GenericFact (kernel bridge).
    public nonisolated static func from(_ fact: GenericFact) -> DatasetCell {
        DatasetCell(value: fact.value, sourceBlockIDs: fact.sourceBlockIDs,
                    status: LegacyEvidenceStatusAdapter.encode(fact.assessment))
    }
}

public struct DatasetRow: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let cells: [DatasetCell]
    public nonisolated init(id: UUID = UUID(), cells: [DatasetCell]) { self.id = id; self.cells = cells }
}

public struct EvidenceDataset: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let name: String
    public let version: Int
    public let columns: [DatasetColumn]
    public let rows: [DatasetRow]

    public nonisolated init(id: UUID = UUID(), name: String, version: Int = 1,
                            columns: [DatasetColumn], rows: [DatasetRow]) {
        self.id = id; self.name = name; self.version = version
        self.columns = columns; self.rows = rows
    }

    /// Kernel invariants: every row has one cell per column, and every cell is provenanced.
    public var isWellFormed: Bool {
        rows.allSatisfy { $0.cells.count == columns.count && $0.cells.allSatisfy(\.isProvenanced) }
    }

    /// Cells that violate the drill-through rule (a derived value with no evidence).
    public var unprovenancedCells: [(row: Int, column: Int)] {
        var out: [(Int, Int)] = []
        for (r, row) in rows.enumerated() {
            for (c, cell) in row.cells.enumerated() where !cell.isProvenanced { out.append((r, c)) }
        }
        return out
    }
}
