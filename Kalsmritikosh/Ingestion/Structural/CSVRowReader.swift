//
//  CSVRowReader.swift
//  Kalsmritikosh
//
//  F30 — the ONE RFC-4180 row reader behind every CSV importer (structural parser,
//  discussion mappers, Workbench). It walks unicode SCALARS, not Characters: Swift
//  treats "\r\n" as a single Character, so a Character loop that tests "\r" and "\n"
//  separately sees neither and collapses a whole Windows CSV into one row. Scalars also
//  keep a combining mark after a comma or quote from hiding the delimiter.
//
//  Row endings: CRLF, LF and bare CR. Quoted fields keep commas, doubled quotes and
//  embedded newlines exactly. A leading UTF-8 BOM is dropped so it never becomes part
//  of the first header. Blank lines are kept as `[""]` so row numbers stay the file's
//  own line positions (row citations depend on that); a final line ending adds no row.
//  Callers decide whether to skip blank rows.
//

import Foundation

enum CSVRowReader {

    nonisolated static func rows(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = String.UnicodeScalarView()
        var inQuotes = false
        var scalars = Array(text.unicodeScalars)
        if scalars.first == "\u{FEFF}" { scalars.removeFirst() }

        func endField() { row.append(String(field)); field = String.UnicodeScalarView() }
        func endRow() { endField(); rows.append(row); row = [] }

        var i = 0
        while i < scalars.count {
            let s = scalars[i]
            if inQuotes {
                if s == "\"" {
                    if i + 1 < scalars.count, scalars[i + 1] == "\"" {
                        field.append("\""); i += 2; continue   // "" inside quotes = one quote
                    }
                    inQuotes = false
                } else {
                    field.append(s)                            // includes newlines, deliberately
                }
                i += 1; continue
            }
            switch s {
            case "\"": inQuotes = true
            case ",":  endField()
            case "\r":
                endRow()
                if i + 1 < scalars.count, scalars[i + 1] == "\n" { i += 1 }   // CRLF = one ending
            case "\n": endRow()
            default:   field.append(s)
            }
            i += 1
        }
        // Trailing field/row with no final line ending.
        if !field.isEmpty || !row.isEmpty { endRow() }
        return rows
    }
}
