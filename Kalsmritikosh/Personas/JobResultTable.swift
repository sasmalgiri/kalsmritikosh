//
//  JobResultTable.swift
//  Kalsmritikosh
//
//  Investigator workflow review 2026-10-30, I8 — the pure rules behind the compact result review:
//  which rows a filter shows, which rows carry the contract's fields (the data-lab query belongs to
//  its Analysis row alone, not to every table row), and where a bulk decision is semantically safe
//  (clerical rows that restate source values — never a professional conclusion).
//

import Foundation

public nonisolated enum JobResultTable {
    /// Rows large enough to review as a table rather than as cards.
    public static let compactThreshold = 12

    /// Whether the result opens in the compact table: the data lab always, others past the threshold.
    public static func prefersTable(jobID: String, rowCount: Int) -> Bool {
        jobID == "inv.data-lab" || jobID == "jrn.data-desk" || rowCount > compactThreshold
    }

    /// The indices of the rows a review filter shows, in order: a text filter over title, detail,
    /// flags and field values; "unresolved only" keeps rows with no decision.
    public static func visible(rows: [JobResultRow], text: String, unresolvedOnly: Bool) -> [Int] {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return rows.indices.filter { i in
            let r = rows[i]
            if unresolvedOnly, r.decision != nil { return false }
            guard !q.isEmpty else { return true }
            if r.title.lowercased().contains(q) || (r.detail ?? "").lowercased().contains(q) { return true }
            if r.flags.contains(where: { $0.lowercased().contains(q) }) { return true }
            return (r.fields ?? [:]).values.contains { $0.lowercased().contains(q) }
        }
    }

    /// Whether the contract's typed fields apply to this row. The data lab's three query fields
    /// describe the analysis, so only its Analysis row carries them; every other job's fields apply
    /// to every row.
    public static func fieldsApply(jobID: String, row: JobResultRow) -> Bool {
        switch jobID {
        case "inv.data-lab", "jrn.data-desk":
            return row.title.hasPrefix(ConfigurableAnalysisExecutor.analysisTitle)
        default:
            return true
        }
    }

    /// Jobs whose rows restate source values (tables, catalogues, logs, registers) may take a bulk
    /// decision over the rows shown; a job whose rows are professional conclusions may not — each is
    /// decided on its own. The decision is still recorded per row.
    public static func bulkAllowed(jobID: String) -> Bool {
        if ["inv.data-lab", "jrn.data-desk"].contains(jobID) { return true }
        guard let human = JobContracts.contract(for: jobID)?.human.lowercased() else { return false }
        return ["reads", "catalogues", "logs", "registers", "records", "extracts", "maps", "describes", "transcribes", "cites"]
            .contains { human.hasPrefix($0) }
    }
}
