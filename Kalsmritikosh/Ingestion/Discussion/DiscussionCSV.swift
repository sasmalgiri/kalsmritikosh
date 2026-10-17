//
//  DiscussionCSV.swift
//  Kalsmritikosh
//
//  DISC-2 — shared RFC 4180 CSV reader for the platform mappers. Every platform
//  that exports CSV (YouTube comments, Reddit comments/posts/messages, newer
//  Discord packages) needs the same three things handled, and they are exactly
//  the three a naive `split(separator: ",")` gets wrong: quoted fields containing
//  commas, quoted fields containing NEWLINES, and doubled quotes. Discussion
//  bodies contain all three routinely, and each mistake silently loses or splits
//  a message — which in an investigation is a wrong answer, not a cosmetic bug.
//
//  One implementation so a fix reaches every platform at once.
//

import Foundation

enum DiscussionCSV {

    /// Parses the whole document into rows of fields. Never throws: malformed
    /// input yields the rows it could read, because a damaged export should still
    /// produce the evidence that survived.
    nonisolated static func parse(_ text: String) -> [[String]] {
        // F30 — the shared scalar-level reader (CRLF / LF / CR). Blank lines are skipped
        // rather than emitted as phantom rows.
        CSVRowReader.rows(text).filter { !($0.count == 1 && $0[0].isEmpty) }
    }

    /// Column-name → index lookup over a header row, so mappers address fields by
    /// name. Platforms add and reorder columns between export versions; addressing
    /// by position is how a mapper starts reading the wrong field after an update.
    struct Header {
        private let indices: [String: Int]
        let columns: [String]

        init(_ row: [String]) {
            self.columns = row
            var map: [String: Int] = [:]
            for (i, name) in row.enumerated() {
                let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if map[key] == nil { map[key] = i }   // first occurrence wins
            }
            self.indices = map
        }

        /// Index of the first of `names` present, matched case-insensitively.
        func index(_ names: String...) -> Int? {
            for name in names {
                if let i = indices[name.lowercased()] { return i }
            }
            return nil
        }

        func has(_ names: String...) -> Bool {
            names.allSatisfy { indices[$0.lowercased()] != nil }
        }
    }

    /// Non-empty trimmed value at `index`, or nil. Empty is nil on purpose: an
    /// empty CSV cell means "absent", and carrying "" forward makes an absent
    /// author look like an author whose name is blank.
    nonisolated static func field(_ row: [String], _ index: Int?) -> String? {
        guard let index, index >= 0, index < row.count else { return nil }
        let value = row[index].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
