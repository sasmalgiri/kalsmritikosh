//
//  DatasetProcessor.swift
//  Kalsmritikosh
//
//  LAB-004 — a safe, deterministic processor library over the EvidenceDataset kernel. Every
//  transform PRESERVES LINEAGE: a derived cell carries the union of the evidence blocks of
//  the inputs it was computed from, and is marked DETERMINISTICALLY_DERIVED so it still
//  drills through to source. No arbitrary code — only these vetted, pure operations.
//
//  Pure functions, Sendable. This is the formula/processor layer the Workbench UI (LAB-005+)
//  and reports draw on; the versioned transformation graph (LAB-003) sequences these.
//

import Foundation

public enum DatasetProcessor {

    /// Keep rows whose cell in `columnIndex` contains `needle` (case-insensitive). Lineage
    /// is unchanged (filtering selects rows, it does not derive new values).
    public nonisolated static func filterRows(_ ds: EvidenceDataset, columnIndex: Int, contains needle: String) -> EvidenceDataset {
        let kept = ds.rows.filter { row in
            guard columnIndex < row.cells.count, let v = row.cells[columnIndex].value else { return false }
            return v.localizedCaseInsensitiveContains(needle)
        }
        return EvidenceDataset(name: ds.name, version: ds.version + 1, columns: ds.columns, rows: kept)
    }

    /// Sum the numeric values of a column into ONE derived cell whose lineage is the union of
    /// every contributing cell's source blocks. Non-numeric cells are ignored (and disclosed
    /// via the count of contributors vs rows by the caller if needed).
    public nonisolated static func sum(_ ds: EvidenceDataset, columnIndex: Int) -> DatasetCell {
        var total = 0.0
        var blocks: [UUID] = []
        var seen = Set<UUID>()
        var contributed = 0
        for row in ds.rows where columnIndex < row.cells.count {
            let cell = row.cells[columnIndex]
            guard let v = cell.value, let n = numeric(v) else { continue }
            total += n
            contributed += 1
            for b in cell.sourceBlockIDs where seen.insert(b).inserted { blocks.append(b) }
        }
        // A derivation from zero evidence is not a fact — mark missing.
        guard contributed > 0 else { return .missing }
        let formatted = total == total.rounded() ? String(Int(total)) : String(total)
        return DatasetCell(value: formatted, sourceBlockIDs: blocks, status: .deterministicallyDerived)
    }

    /// Group rows by the value of `keyColumn` and count rows per group. Each count cell's
    /// lineage is the union of the grouped rows' key-cell blocks.
    public nonisolated static func countByGroup(_ ds: EvidenceDataset, keyColumn: Int) -> [(key: String, count: Int, cell: DatasetCell)] {
        var groups: [String: (Int, [UUID], Set<UUID>)] = [:]
        for row in ds.rows where keyColumn < row.cells.count {
            let cell = row.cells[keyColumn]
            let key = cell.value ?? "(missing)"
            var entry = groups[key] ?? (0, [], Set<UUID>())
            entry.0 += 1
            for b in cell.sourceBlockIDs where entry.2.insert(b).inserted { entry.1.append(b) }
            groups[key] = entry
        }
        return groups.map { (k, v) in
            (k, v.0, DatasetCell(value: String(v.0), sourceBlockIDs: v.1, status: .deterministicallyDerived))
        }.sorted { $0.count > $1.count }
    }

    /// Parse a numeric value from a money/number string ("₹3,800" → 3800, "2.70 lac" → 270000).
    nonisolated static func numeric(_ s: String) -> Double? {
        let lower = s.lowercased()
        let digits = lower.filter { $0.isNumber || $0 == "." }
        guard let base = Double(digits) else { return nil }
        if lower.contains("lac") || lower.contains("lakh") { return base * 100_000 }
        if lower.contains("crore") { return base * 10_000_000 }
        if lower.contains("k") && !lower.contains("lac") { return base * 1_000 }
        return base
    }
}
