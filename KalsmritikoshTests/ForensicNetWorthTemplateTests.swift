//
//  ForensicNetWorthTemplateTests.swift
//  KalsmritikoshTests
//
//  Forensic accountant net-worth workpaper (DataLab template). Proves the
//  derived formulas are well-formed over the shared Workbench expression
//  engine — each parses, references only columns defined before it (so
//  applying them top-to-bottom always resolves) — and that the classic
//  net-worth identity computes the expected income-from-unknown-sources.
//

import Testing
@testable import Kalsmritikosh

@Suite("FORENSIC — net-worth workpaper template")
struct ForensicNetWorthTemplateTests {

    @Test("Every derived formula parses and references only columns defined before it")
    func formulasResolveInOrder() throws {
        let derived = ForensicNetWorthTemplate.derivedColumns
        #expect(derived.count == 4)
        #expect(derived.map(\.shape) == [.money, .money, .money, .money])
        #expect(ForensicNetWorthTemplate.transformSpecs.count == 4)

        for (i, col) in derived.enumerated() {
            let formula = try #require(col.formula, "\(col.name) must carry a formula")
            let expr = try WorkbenchExpressionParser.parse(formula)
            let refs = Set(expr.referencedFields)
            #expect(!refs.isEmpty, "\(col.name): a derived column must reference inputs")
            let allowed = ForensicNetWorthTemplate.namesAvailable(beforeDerivedIndex: i)
            let undefined = refs.subtracting(allowed)
            #expect(undefined.isEmpty, "\(col.name): references undefined columns \(undefined)")
        }
        // Input columns carry NO formula (the user fills them from sources).
        #expect(ForensicNetWorthTemplate.inputColumns.allSatisfy { $0.formula == nil })
        // The truth-boundary caveat is present.
        let hasLeadCaveat = ForensicNetWorthTemplate.caveats.contains { $0.contains("LEAD, not proof") }
        #expect(hasLeadCaveat, "the unexplained-increase-is-a-lead caveat must be carried")
    }

    @Test("The classic net-worth identity computes income from unknown sources")
    func identityMathIsCorrect() throws {
        // A worked example: assets 300k, liabilities 100k → closing net worth 200k;
        // opening net worth 150k → increase 50k; + known expenditures 40k → funds
        // applied 90k; − reported income 60k → 30k income from unknown sources.
        var values: [String: WorkbenchValue] = [
            "Assets": .number(300_000), "Liabilities": .number(100_000),
            "OpeningNetWorth": .number(150_000), "ReportedIncome": .number(60_000),
            "KnownExpenditures": .number(40_000),
        ]
        // Apply each derived column in order, feeding its result back in — exactly
        // how DataLabView applies the template top to bottom.
        for col in ForensicNetWorthTemplate.derivedColumns {
            let formula = try #require(col.formula)
            let expr = try WorkbenchExpressionParser.parse(formula)
            let result = try WorkbenchExpressionEvaluator.evaluate(
                expr, in: WorkbenchRowContext(values: values))
            values[col.name] = result
        }
        #expect(values["ClosingNetWorth"] == .number(200_000))
        #expect(values["IncreaseInNetWorth"] == .number(50_000))
        #expect(values["TotalFundsApplied"] == .number(90_000))
        #expect(values["UnexplainedIncome"] == .number(30_000),
                "funds applied 90k − reported income 60k = 30k from unknown sources")
    }
}
