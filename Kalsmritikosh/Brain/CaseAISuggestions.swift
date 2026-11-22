//
//  CaseAISuggestions.swift
//  Kalsmritikosh
//
//  Unified path AI-37 (owner 2026-11-22, round 2) — not tested yet. The "AI suggestions" section of the case
//  briefing: one extra reader call per case document set asks the AI for leads to check, questions to ask and
//  gaps, each tied to the documents it rests on as [D<n>]. The app keeps an item only when every number it
//  cites is a real document of the case and, when it gives a quote, the quote is found verbatim in one of the
//  documents it cites. Every kept line says "AI suggestion": it is a pointer for the investigator, never
//  evidence, never a finding.
//

import Foundation
import os

public nonisolated enum CaseAISuggestions {
    /// The most items kept per kind.
    public static let perKind = 8
    public static let replyTokens = 2_000

    /// The task the reader is given after the briefing and the documents.
    public static let task = """
    Task: suggest next steps for the investigator of this case. Read the briefing and the documents. Reply with JSON only, \
    in this shape: {"leads": [ITEM], "questions": [ITEM], "gaps": [ITEM]} where ITEM is {"text": "...", "documents": [N, ...], \
    "quote": "..."}. "leads" are things worth checking further; "questions" are questions worth asking a person or a \
    source; "gaps" are things the documents should hold but do not. At most \(perKind) of each. "documents" lists the \
    numbers of the documents (Document N) the item rests on — at least one. "quote", optional, is an exact passage \
    copied from one of those documents. Do not state findings or conclusions; suggest only.
    """

    public struct Item: Sendable, Equatable {
        public let kind: String
        public let text: String
        public let documents: [Int]
    }

    public struct Outcome: Sendable, Equatable {
        public let items: [Item]
        public let dropped: Int
        /// The briefing section (empty when nothing was kept).
        public var section: String {
            guard !items.isEmpty else { return "" }
            var lines = ["## AI suggestions (written by the AI from this case's documents; pointers to check, NOT evidence or findings)"]
            for i in items {
                let label: String
                switch i.kind {
                case "leads": label = "lead to check"
                case "questions": label = "question to ask"
                default: label = "gap"
                }
                lines.append("- AI suggestion (\(label)): \(String(i.text.prefix(280))) " + i.documents.map { "[D\($0)]" }.joined(separator: " "))
            }
            return lines.joined(separator: "\n")
        }
    }

    /// Check the reply against the case's documents (`texts[n-1]` is Document n).
    public static func verify(reply: String, texts: [String]) -> Outcome {
        let body = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = body.firstIndex(of: "{"), let end = body.lastIndex(of: "}"), start < end,
              let data = String(body[start...end]).data(using: .utf8) else { return Outcome(items: [], dropped: 0) }
        let root: [String: Any]
        do {
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return Outcome(items: [], dropped: 0) }
            root = obj
        } catch {
            KalsmritikoshLog.brain.info("AI suggestions: the reply is not JSON (\(error.localizedDescription, privacy: .public))")
            return Outcome(items: [], dropped: 0)
        }
        var items: [Item] = [], dropped = 0
        for kind in ["leads", "questions", "gaps"] {
            var kept = 0
            for raw in (root[kind] as? [Any]) ?? [] {
                guard let obj = raw as? [String: Any], let text = (obj["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty else { dropped += 1; continue }
                let numbers = ((obj["documents"] as? [Any]) ?? []).compactMap { ($0 as? Int) ?? Int(String(describing: $0)) }
                let valid = Array(Set(numbers.filter { $0 >= 1 && $0 <= texts.count })).sorted()
                // Every cited number must be a real case document, and at least one must be cited.
                guard !valid.isEmpty, valid.count == Set(numbers).count else { dropped += 1; continue }
                if let quote = (obj["quote"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !quote.isEmpty,
                   !valid.contains(where: { texts[$0 - 1].contains(quote) }) { dropped += 1; continue }
                guard kept < perKind else { dropped += 1; continue }
                kept += 1
                items.append(Item(kind: kind, text: text, documents: valid))
            }
        }
        return Outcome(items: items, dropped: dropped)
    }

    /// The briefing with the section inserted before its end line (unchanged when the section is empty).
    public static func insert(_ section: String, into briefing: String) -> String {
        guard !section.isEmpty, !briefing.isEmpty else { return briefing }
        let endLine = "\n=== End of the case briefing ==="
        guard let r = briefing.range(of: endLine, options: .backwards) else { return briefing + "\n" + section }
        return briefing.replacingCharacters(in: r, with: "\n" + section + endLine)
    }
}
