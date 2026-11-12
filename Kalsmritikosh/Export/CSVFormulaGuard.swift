//
//  CSVFormulaGuard.swift
//  Kalsmritikosh
//
//  Smart-map S14 (SEC-10) — CSV formula injection. A case's text comes from untrusted documents: a title such as
//  `=HYPERLINK("https://…","open")` or `@SUM(…)` written into a CSV cell is run as a formula by a spreadsheet that opens
//  the export (it can fetch a URL or show a forged value). Every cell of the case's CSV exports passes through
//  `neutralised`, which prefixes such a cell with an apostrophe so a spreadsheet shows it as text. A plain number
//  (including a negative amount such as -50,000.00) is left exactly as it is, so amounts are not altered.
//  The original text stays in the ledger and in the other export formats; only the CSV cell is guarded.
//

import Foundation

public nonisolated enum CSVFormulaGuard {
    /// Characters a spreadsheet treats as the start of a formula (or a DDE command), including full-width look-alikes.
    static let triggers: Set<Character> = ["=", "+", "-", "@", "\t", "\r", "＝", "＋", "－", "＠"]

    /// The cell as text a spreadsheet will not evaluate. Leading spaces are looked through (spreadsheets ignore them).
    public static func neutralised(_ cell: String) -> String {
        guard let first = cell.first(where: { $0 != " " }), triggers.contains(first) else { return cell }
        if isPlainNumber(cell.trimmingCharacters(in: .whitespaces)) { return cell }
        return "'" + cell
    }

    /// Whether the cell needed guarding.
    public static func isFormulaLike(_ cell: String) -> Bool { neutralised(cell) != cell }

    /// "-50", "+3.5", "-50,000.00": a sign and digits with grouping commas and one decimal point, nothing else.
    static func isPlainNumber(_ s: String) -> Bool {
        guard let sign = s.first, sign == "-" || sign == "+" else { return false }
        let rest = s.dropFirst()
        guard let firstDigit = rest.first, firstDigit.isASCII, firstDigit.isNumber else { return false }
        var dots = 0
        for c in rest {
            if c == "." { dots += 1; if dots > 1 { return false }; continue }
            if c == "," { continue }
            guard c.isASCII, c.isNumber else { return false }
        }
        return rest.last.map { $0.isASCII && $0.isNumber } ?? false
    }
}
