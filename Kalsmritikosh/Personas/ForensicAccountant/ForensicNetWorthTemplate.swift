//
//  ForensicNetWorthTemplate.swift
//  Kalsmritikosh
//
//  Forensic accountant — the NET-WORTH (a.k.a. lifestyle-analysis) workpaper
//  as a DataLab template (owner request 2026-08-20). The net-worth method is
//  the Supreme-Court-endorsed INDIRECT proof of unreported income: an
//  unsubstantiated increase in a subject's net worth, once known living
//  expenses are added and reported income is subtracted, is income from
//  unknown sources. This template lays that computation out as a per-period
//  schedule over the shared Workbench (LAB-002) — the same transform engine,
//  lineage, and cited-cell provenance every DataLab column carries.
//
//  PURE configuration only (no store, no UI): a set of INPUT columns the user
//  fills from source documents, and an ORDERED list of DERIVED columns, each a
//  real WorkbenchTransformSpec.calculatedColumn whose formula references only
//  columns defined before it. DataLabView applies them in order to a dataset;
//  the WorkbenchTransformEngine computes each cell and records which cells fed
//  it. A derived amount is deterministically calculated — never presented as
//  source-observed.
//
//  Truth boundary the caveats carry: an unexplained increase is a LEAD, not
//  proof — it quantifies income from unknown sources; it does not identify the
//  source or establish wrongdoing.
//

import Foundation

public nonisolated enum ForensicNetWorthTemplate {

    public static let id = "fa.datalab.net-worth"
    public static let displayName = "Net-worth workpaper"
    public static let purpose =
        "Lay out the net-worth method: from assets, liabilities, reported income and known expenditures, compute each period's net-worth increase and the income from unknown sources — every input traced to a source document."

    /// One column definition.
    public nonisolated struct Column: Sendable, Equatable {
        public let name: String
        public let shape: FactSchemaRegistry.ValueShape
        /// Present only on derived columns: the formula over earlier columns.
        public let formula: String?
        public let help: String
        public nonisolated init(_ name: String, _ shape: FactSchemaRegistry.ValueShape,
                                formula: String? = nil, help: String) {
            self.name = name; self.shape = shape; self.formula = formula; self.help = help
        }
    }

    /// The columns the user fills from source documents (no formula).
    public static let inputColumns: [Column] = [
        Column("Period", .text, help: "The year or period this row covers — e.g. 2024."),
        Column("Assets", .money, help: "Total assets at the END of the period, each traced to a statement, deed, or title."),
        Column("Liabilities", .money, help: "Total liabilities at the END of the period (loans, mortgages, cards owed)."),
        Column("OpeningNetWorth", .money, help: "Net worth at the START of the period — the prior period's closing net worth, from a firm starting point."),
        Column("ReportedIncome", .money, help: "Income the subject reported for the period (tax returns, W-2/1099, declared income)."),
        Column("KnownExpenditures", .money, help: "Known living expenses and outlays for the period (rent, cards, cash spending evidenced)."),
    ]

    /// The derived columns, IN ORDER. Each formula references only input
    /// columns or derived columns defined before it, so applying them top to
    /// bottom always resolves.
    public static let derivedColumns: [Column] = [
        Column("ClosingNetWorth", .money, formula: "Assets - Liabilities",
               help: "Net worth at period end = assets − liabilities."),
        Column("IncreaseInNetWorth", .money, formula: "ClosingNetWorth - OpeningNetWorth",
               help: "Change over the period = closing − opening net worth."),
        Column("TotalFundsApplied", .money, formula: "IncreaseInNetWorth + KnownExpenditures",
               help: "Funds the subject used = net-worth increase + known expenditures."),
        Column("UnexplainedIncome", .money, formula: "TotalFundsApplied - ReportedIncome",
               help: "Income from unknown sources = funds applied − reported income. A LEAD, not proof."),
    ]

    /// The legal/analytical caveats shown with the workpaper.
    public static let caveats: [String] = [
        "An unexplained increase is a LEAD, not proof — it quantifies income from unknown sources; it does not identify the source or establish wrongdoing.",
        "Every input amount must trace to a source document; a derived cell is deterministically calculated, never source-observed.",
        "Opening net worth must rest on a firm starting point — an unproven opening figure undermines every period after it.",
    ]

    /// The derived columns as real Workbench transform specs, in apply order.
    public static var transformSpecs: [WorkbenchTransformSpec] {
        derivedColumns.compactMap { col in
            col.formula.map { WorkbenchTransformSpec.calculatedColumn(newField: col.name, shape: col.shape, formula: $0) }
        }
    }

    /// All column names defined at or before `index` in the derived list,
    /// unioned with every input column — the names a derived formula at
    /// `index` is allowed to reference.
    public static func namesAvailable(beforeDerivedIndex index: Int) -> Set<String> {
        var names = Set(inputColumns.map(\.name))
        for i in 0..<index { names.insert(derivedColumns[i].name) }
        return names
    }
}
