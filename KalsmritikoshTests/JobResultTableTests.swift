//
//  JobResultTableTests.swift
//  KalsmritikoshTests
//
//  Investigator workflow review 2026-10-30, I8 — the compact review's rules: the data lab's query
//  fields sit on its Analysis row only; filters and "unresolved only" keep the person's place in a
//  large result; bulk decisions exist only where rows restate source values.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Compact result review rules")
struct JobResultTableTests {

    @Test("The data lab's three query fields belong to the Analysis row alone; other jobs keep their fields on every row")
    func queryFieldsOnce() {
        let analysis = JobResultRow(title: "Analysis: filter: none · group by: label · total: amount", fields: ["filter": "", "groupBy": "label", "total": "amount"])
        let table = JobResultRow(title: "amount = ₹1,000", detail: "invoice.pdf")
        let group = JobResultRow(title: "Field amount: ₹1,000", detail: "1 value(s), 1 distinct")
        #expect(JobResultTable.fieldsApply(jobID: "inv.data-lab", row: analysis))
        #expect(!JobResultTable.fieldsApply(jobID: "inv.data-lab", row: table))
        #expect(!JobResultTable.fieldsApply(jobID: "inv.data-lab", row: group))
        #expect(JobResultTable.fieldsApply(jobID: "hr.statements", row: table))
        // 66 rows → 3 query controls, not 198.
        let rows = [analysis] + (0..<65).map { JobResultRow(title: "amount = ₹\($0)") }
        let controls = rows.filter { JobResultTable.fieldsApply(jobID: "inv.data-lab", row: $0) }.count * 3
        #expect(controls == 3)
        #expect(JobResultTable.prefersTable(jobID: "inv.data-lab", rowCount: 3) && JobResultTable.prefersTable(jobID: "hr.statements", rowCount: 40)
                && !JobResultTable.prefersTable(jobID: "hr.statements", rowCount: 5))
    }

    @Test("Filters: text over title, detail, flags and fields; unresolved-only keeps undecided rows; order is kept")
    func filters() {
        var a = JobResultRow(title: "amount = ₹10,000", detail: "bank-statement.txt", flags: ["computed"])
        a.decision = .accepted
        let b = JobResultRow(title: "date = 3 March", detail: "invoice.pdf", fields: ["witness": "Vikram Rao"])
        let c = JobResultRow(title: "amount = ₹2,000", detail: "refund.txt")
        let rows = [a, b, c]
        #expect(JobResultTable.visible(rows: rows, text: "", unresolvedOnly: false) == [0, 1, 2])
        #expect(JobResultTable.visible(rows: rows, text: "amount", unresolvedOnly: false) == [0, 2])
        #expect(JobResultTable.visible(rows: rows, text: "vikram", unresolvedOnly: false) == [1])
        #expect(JobResultTable.visible(rows: rows, text: "computed", unresolvedOnly: false) == [0])
        #expect(JobResultTable.visible(rows: rows, text: "", unresolvedOnly: true) == [1, 2])
        #expect(JobResultTable.visible(rows: rows, text: "amount", unresolvedOnly: true) == [2])
    }

    @Test("Bulk decisions only where rows restate source values — never for a job whose rows are conclusions")
    func bulkWhereSafe() {
        #expect(JobResultTable.bulkAllowed(jobID: "inv.data-lab"))
        #expect(!JobResultTable.bulkAllowed(jobID: "hr.statements"), "statements are compared and assessed one by one")
        #expect(!JobResultTable.bulkAllowed(jobID: "hr.allegations"))
        #expect(!JobResultTable.bulkAllowed(jobID: "law.witness-profiles"))
        for job in JobContracts.all where JobResultTable.bulkAllowed(jobID: job.job) {
            let h = job.human.lowercased()
            #expect(!h.hasPrefix("decides") && !h.hasPrefix("judges") && !h.hasPrefix("assesses") && !h.hasPrefix("concludes") && !h.hasPrefix("approves"),
                    "\(job.job) allows bulk decisions but its human act is \(job.human)")
        }
    }
}
