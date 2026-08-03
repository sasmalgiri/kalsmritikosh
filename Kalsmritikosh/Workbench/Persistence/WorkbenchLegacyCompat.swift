//
//  WorkbenchLegacyCompat.swift
//  Kalsmritikosh
//
//  LAB-001 (Stage C) — the TEMPORARY compatibility surface that supersedes the isolated
//  EvidenceDataset prototype. It has NO independent authority: it only READS a legacy EvidenceDataset
//  value and CONVERTS it into the canonical Workbench* tables through WorkbenchDatasetRepository.
//  There is no legacy validation, transformation or lineage here — the canonical repository is the
//  single source of truth. The old in-file "LAB-001..006" prototype labels are superseded by the
//  Stage-5 LAB numbering; this conversion is how any legacy-shaped data becomes canonical.
//

import Foundation

/// Pure, deterministic mapping from the legacy per-cell EvidenceStatus to the canonical Workbench
/// cell provenance kind. No I/O — unit-testable in isolation.
public nonisolated enum WorkbenchLegacyConversion {
    public nonisolated static func cellKind(for status: EvidenceStatus) -> WorkbenchCellKind {
        switch status {
        case .directlyObserved, .sourceAsserted, .contradicted, .unsupported, .missingEvidence:
            return .sourceValue                 // observed / asserted / source-linked (weak stays source-linked)
        case .deterministicallyDerived:
            return .deterministicCalculation
        case .inferred:
            return .modelProposal
        case .humanCorrected:
            return .userCorrected
        case .humanConfirmed, .humanRejected:
            return .reviewed                    // a recorded human decision
        }
    }
}

extension WorkbenchDatasetRepository {

    /// Convert a legacy EvidenceDataset into a NEW canonical Workbench dataset, delegating every write
    /// to the canonical repository. Columns → fields, rows → rows, cells → cells (kind mapped from the
    /// legacy status), and each source block id → a canonical evidence-block binding (drill-through
    /// preserved). Emits a `converted` event. The legacy value is not mutated; the canonical dataset
    /// becomes the authority.
    @discardableResult
    public func convertLegacy(_ legacy: EvidenceDataset, workspaceID: UUID, actor: String,
                              at date: Date) async throws -> WorkbenchDatasetRecord {
        var rec = try await createDataset(workspaceID: workspaceID, title: legacy.name, mode: .advanced, actor: actor, at: date)
        let datasetID = rec.dataset.id

        // Fields, in column order.
        var fieldIDByColumn: [Int: UUID] = [:]
        for (i, column) in legacy.columns.enumerated() {
            rec = try await addField(datasetID: datasetID, name: column.name, valueShape: column.shape,
                                     expectedRevision: rec.dataset.revision, actor: actor, at: date)
            fieldIDByColumn[i] = rec.fields.sorted { $0.ordinal < $1.ordinal }[i].id
        }

        // Rows + cells + bindings.
        for legacyRow in legacy.rows {
            rec = try await addRow(datasetID: datasetID, expectedRevision: rec.dataset.revision, actor: actor, at: date)
            let rowID = rec.rows.sorted { $0.ordinal < $1.ordinal }.last!.id
            for (c, cell) in legacyRow.cells.enumerated() {
                guard let fieldID = fieldIDByColumn[c] else { continue }
                let kind = WorkbenchLegacyConversion.cellKind(for: cell.status)
                rec = try await setCell(datasetID: datasetID, rowID: rowID, fieldID: fieldID, kind: kind,
                                        value: cell.value, status: cell.status,
                                        expectedRevision: rec.dataset.revision, actor: actor, at: date)
                let cellID = rec.cells.first { $0.rowID == rowID && $0.fieldID == fieldID }!.id
                if cell.value != nil {
                    for (bi, blockID) in cell.sourceBlockIDs.enumerated() {
                        // Only bind blocks that resolve — a binding must drill through to real evidence.
                        if try await evidenceBlockExists(blockID) {
                            rec = try await bindSource(cellID: cellID, targetKind: .evidenceBlock, targetID: blockID.uuidString,
                                                       sourceVersionID: nil, locator: nil,
                                                       expectedRevision: rec.dataset.revision, actor: actor, at: date)
                        }
                        _ = bi
                    }
                }
            }
        }

        // Record the conversion in the durable history.
        rec = try await noteConversion(datasetID: datasetID, expectedRevision: rec.dataset.revision,
                                       actor: actor, legacyID: legacy.id, at: date)
        return rec
    }
}
