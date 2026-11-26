//
//  ReaderTextCleaner.swift
//  Kalsmritikosh
//
//  Unified-path program (owner, 2026-11-22), AI-19 — the text the case reader receives. The Cleaner's
//  normalisation used to run only to classify a file and was then thrown away; this keeps a reader copy
//  (knowledge_objects.clean_content, v199) with:
//    • encoding repaired, whitespace collapsed (as the Cleaner does);
//    • quoted earlier messages (">" runs) collapsed — the earlier message is its own document;
//    • an e-mail signature after the standard "-- " delimiter dropped;
//    • standard confidentiality / virus-scan disclaimer paragraphs dropped.
//  The stored `content` is never changed: the original text stays the evidence and every quote the
//  verifier checks is checked against it as well (see CaseReader.passages).
//
//  Not tested yet (owner 2026-11-22: implement now, test later).
//

import Foundation

public nonisolated enum ReaderTextCleaner {
    /// ALCOA ALC-17 — stored beside every cleaned text (knowledge_objects.clean_cleaner_version); change it whenever
    /// `clean` would produce a different text, so each kept version names the cleaner that made it.
    public static let version = "reader-clean-1"
    /// The boilerplate compaction's rewrite of a cleaned text.
    public static let compactedVersion = version + "+boilerplate-compaction-1"
    /// Paragraph openings of the standard e-mail disclaimers (lower-cased, matched at the paragraph start).
    static let disclaimerOpenings = [
        "this email and any attachments", "this e-mail and any attachments", "this message and any attachments",
        "this email is confidential", "this e-mail is confidential", "confidentiality notice", "confidentiality note",
        "the information contained in this email", "the information contained in this e-mail",
        "the information in this email", "if you are not the intended recipient", "disclaimer:",
        "this email has been scanned", "this message has been scanned", "please consider the environment before printing",
    ]

    public static func clean(_ text: String) -> String {
        var s = text.replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
        s = dropSignature(s)
        s = collapseQuoted(s)
        s = dropDisclaimers(s)
        return collapseWhitespace(s).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Everything after a line that is exactly "-- " (RFC 3676 signature delimiter), when what follows is short.
    static func dropSignature(_ s: String) -> String {
        let lines = s.components(separatedBy: "\n")
        guard let i = lines.lastIndex(where: { $0 == "-- " || $0 == "--" }), lines.count - i <= 15 else { return s }
        return lines[..<i].joined(separator: "\n")
    }

    static func collapseQuoted(_ s: String) -> String {
        var out: [String] = [], run = 0
        let lines = s.components(separatedBy: "\n")
        func flush(_ upTo: Int) {
            if run >= 2 { out.append("[quoted earlier message collapsed]") }
            else if run == 1 { out.append(lines[upTo - 1]) }
            run = 0
        }
        for (i, line) in lines.enumerated() {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix(">") { run += 1; continue }
            flush(i)
            out.append(line)
        }
        flush(lines.count)
        return out.joined(separator: "\n")
    }

    static func dropDisclaimers(_ s: String) -> String {
        let paragraphs = s.components(separatedBy: "\n\n")
        let kept = paragraphs.filter { p in
            let lower = p.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return !disclaimerOpenings.contains { lower.hasPrefix($0) }
        }
        return kept.joined(separator: "\n\n")
    }

    static func collapseWhitespace(_ s: String) -> String {
        var result = "", lastWasSpace = false, newlines = 0
        for ch in s {
            if ch == "\n" {
                newlines += 1; lastWasSpace = false
                if newlines <= 2 { result.append("\n") }
            } else if ch.isWhitespace {
                if !lastWasSpace && newlines == 0 { result.append(" "); lastWasSpace = true }
            } else {
                result.append(ch); lastWasSpace = false; newlines = 0
            }
        }
        return result
    }
}
