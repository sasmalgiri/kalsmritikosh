//
//  ChronologyDrafter.swift
//  Kalsmritikosh
//
//  N-1 — draft legal work products from the chronology, deterministically: every
//  sentence comes from one ledger event and carries its source and date, so a
//  draft can never assert something the ledger does not hold. Two outputs:
//    statement of facts — numbered paragraphs in date order, grouped by issue when given;
//    deposition outline — per issue, questions anchored to each event.
//

import Foundation

public nonisolated struct ChronologyEntry: Sendable, Identifiable, Hashable {
    public let id: UUID
    public let date: Date
    public let title: String
    public let summary: String?
    public let source: String
    public let issues: [String]
}

public nonisolated enum ChronologyDrafter {

    static func day(_ d: Date) -> String { d.formatted(date: .long, time: .omitted) }

    public static func statementOfFacts(_ entries: [ChronologyEntry], title: String, byIssue: Bool) -> String {
        var out = ["# Statement of facts — \(title)", "",
                   "_Drafted from the ledger. Each paragraph cites the document it comes from; verify before filing._", ""]
        var n = 0
        func paragraph(_ e: ChronologyEntry) -> String {
            n += 1
            let detail = e.summary.map { " \($0.trimmingCharacters(in: .whitespacesAndNewlines))" } ?? ""
            return "\(n). On \(day(e.date)), \(e.title.trimmingCharacters(in: .whitespacesAndNewlines)).\(detail) [Source: \(e.source), \(day(e.date))]"
        }
        let sorted = entries.sorted { $0.date < $1.date }
        if byIssue {
            let issues = Array(Set(sorted.flatMap(\.issues))).sorted()
            for issue in issues {
                out.append("## \(issue)"); out.append("")
                for e in sorted where e.issues.contains(issue) { out.append(paragraph(e)) }
                out.append("")
            }
            let untagged = sorted.filter { $0.issues.isEmpty }
            if !untagged.isEmpty {
                out.append("## Other facts"); out.append("")
                untagged.forEach { out.append(paragraph($0)) }
            }
        } else {
            sorted.forEach { out.append(paragraph($0)) }
        }
        return out.joined(separator: "\n")
    }

    public static func depositionOutline(_ entries: [ChronologyEntry], witness: String) -> String {
        var out = ["# Deposition outline — \(witness)", "",
                   "_Each question is anchored to a ledger event and its source document._", ""]
        let sorted = entries.sorted { $0.date < $1.date }
        let issues = Array(Set(sorted.flatMap(\.issues))).sorted()
        for issue in issues.isEmpty ? ["Chronology"] : issues {
            out.append("## \(issue)"); out.append("")
            for e in sorted where issues.isEmpty || e.issues.contains(issue) {
                out.append("- Q: What do you know about \(e.title.trimmingCharacters(in: .whitespacesAndNewlines)) on \(day(e.date))?")
                out.append("  - Q: Who else was involved, and how did you learn of it?")
                out.append("  - Exhibit: \(e.source)")
            }
            out.append("")
        }
        return out.joined(separator: "\n")
    }
}
