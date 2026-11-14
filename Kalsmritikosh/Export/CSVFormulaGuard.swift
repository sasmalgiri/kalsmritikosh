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
    /// "\r\n" is its own Character in Swift (one grapheme), so it is listed beside the lone "\r" and "\n" (deep dive batch 3).
    static let triggers: Set<Character> = ["=", "+", "-", "@", "\t", "\r", "\n", "\r\n", "＝", "＋", "－", "＠"]

    /// The cell as text a spreadsheet will not evaluate. Leading spaces are looked through (spreadsheets ignore them).
    public static func neutralised(_ cell: String) -> String {
        guard let first = cell.first(where: { $0 != " " }), triggers.contains(first) else { return cell }
        if isPlainNumber(cell.trimmingCharacters(in: .whitespaces)) { return cell }
        return "'" + cell
    }

    /// Deep dive batch 3 — the ONE CSV cell writer every CSV export goes through. The cell is guarded at its start and
    /// after every line break inside it (a reader that splits on CR or LF must not find a line starting with a formula),
    /// then quoted (RFC 4180) when any SCALAR is a comma, a quote, CR or LF — checked on unicodeScalars, because a CRLF is a
    /// single Swift Character that matches neither "\r" nor "\n". `alwaysQuote` keeps writers that quote every field.
    public static func csvField(_ raw: String, alwaysQuote: Bool = false) -> String {
        let s = neutralisedLines(raw)
        let special = s.unicodeScalars.contains { $0 == "," || $0 == "\"" || $0 == "\r" || $0 == "\n" }
        guard special || alwaysQuote else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// `neutralised` applied to the cell and to the text after each CR, LF or CRLF inside it.
    static func neutralisedLines(_ cell: String) -> String {
        guard cell.unicodeScalars.contains(where: { $0 == "\r" || $0 == "\n" }) else { return neutralised(cell) }
        var out = ""
        var line = ""
        for scalar in cell.unicodeScalars {
            if scalar == "\r" || scalar == "\n" {
                out += neutralised(line)
                out.unicodeScalars.append(scalar)
                line = ""
                continue
            }
            line.unicodeScalars.append(scalar)
        }
        out += neutralised(line)
        // The cell's own start too (a cell that begins with a line break is guarded as a whole, as before).
        return neutralised(out)
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
