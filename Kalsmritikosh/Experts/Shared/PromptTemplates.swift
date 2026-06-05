//
//  PromptTemplates.swift
//  Kalsmritikosh
//
//  Per-domain prompt builders. Each takes a UserIntent + RetrievalResult
//  and emits a prompt the registered reasoning model can consume.
//  Templates never name a model.
//

import Foundation

public enum PromptTemplates {
    public static func emailAnalysis(intent: UserIntent, retrieval: RetrievalResult) -> String {
        let events = retrieval.events.filter {
            $0.kind == .emailSent || $0.kind == .emailReceived
        }
        let evidence = events.prefix(20).map { event in
            "- [\(event.date.formatted(date: .abbreviated, time: .shortened))] \(event.title)"
        }.joined(separator: "\n")
        return """
        Task: Analyze the email evidence below for the question:
        "\(intent.rawQuestion)"

        Identify:
        - Who corresponded with whom and when
        - Notable thread shifts (delays, escalations, decisions)

        Return up to 6 short findings, each on its own line starting with "- ".

        Email events:
        \(evidence.isEmpty ? "(no events found)" : evidence)
        """
    }

    public static func financialAnalysis(intent: UserIntent, retrieval: RetrievalResult) -> String {
        let events = retrieval.events.filter {
            $0.kind == .invoiceIssued || $0.kind == .invoicePaid
        }
        let evidence = events.prefix(20).map { event in
            "- [\(event.date.formatted(date: .abbreviated, time: .omitted))] \(event.title)"
        }.joined(separator: "\n")
        return """
        Task: Summarize the financial signal below for the question:
        "\(intent.rawQuestion)"

        Note invoices issued vs paid, outstanding amounts, and overdue items.
        Return up to 6 short findings, each on its own line starting with "- ".

        Financial events:
        \(evidence.isEmpty ? "(no events found)" : evidence)
        """
    }

    public static func legalAnalysis(intent: UserIntent, retrieval: RetrievalResult) -> String {
        let events = retrieval.events.filter {
            $0.kind == .contractSigned || $0.kind == .contractModified
        }
        let evidence = events.prefix(10).map { event in
            "- [\(event.date.formatted(date: .abbreviated, time: .omitted))] \(event.title)"
        }.joined(separator: "\n")
        return """
        Task: Identify contractual signals for the question:
        "\(intent.rawQuestion)"

        Call out signings, amendments, obligations, and risks.
        Return up to 5 short findings, each on its own line starting with "- ".

        Contract events:
        \(evidence.isEmpty ? "(no events found)" : evidence)
        """
    }

    public static func projectAnalysis(intent: UserIntent, retrieval: RetrievalResult) -> String {
        let events = retrieval.events.prefix(20).map { event in
            "- [\(event.date.formatted(date: .abbreviated, time: .omitted))] \(event.kind.rawValue): \(event.title)"
        }.joined(separator: "\n")
        let people = retrieval.entities.filter { $0.kind == .person }.prefix(8).map(\.value)
        let orgs = retrieval.entities.filter { $0.kind == .organization }.prefix(8).map(\.value)
        let stakeholders = (people + orgs).joined(separator: ", ")
        return """
        Task: Reconstruct the project's state from the evidence below.
        Question: "\(intent.rawQuestion)"

        Stakeholders mentioned: \(stakeholders.isEmpty ? "(none)" : stakeholders)

        Return up to 6 findings about milestones, blockers, and risks.
        Each finding goes on its own line starting with "- ".

        Events:
        \(events.isEmpty ? "(no events found)" : events)
        """
    }

    public static func timelineAnalysis(intent: UserIntent, retrieval: RetrievalResult) -> String {
        let events = retrieval.events.prefix(25).map { event in
            "- \(event.date.formatted(date: .abbreviated, time: .omitted)): \(event.title)"
        }.joined(separator: "\n")
        return """
        Task: Produce a chronological reconstruction for the question:
        "\(intent.rawQuestion)"

        Return findings as date-prefixed lines starting with "- ".

        Events:
        \(events.isEmpty ? "(no events found)" : events)
        """
    }

    public static func researchAnalysis(intent: UserIntent, retrieval: RetrievalResult) -> String {
        let chunks = retrieval.chunks.prefix(6).map { hit -> String in
            let snippet = String(hit.chunk.text.prefix(240))
                .replacingOccurrences(of: "\n", with: " ")
            return "- (\(hit.viaLayer.rawValue)) \(snippet)"
        }.joined(separator: "\n")
        return """
        Task: From the literature snippets below, extract the key citations
        and findings relevant to:
        "\(intent.rawQuestion)"

        Return up to 5 findings as bullet lines starting with "- ".

        Snippets:
        \(chunks.isEmpty ? "(no snippets)" : chunks)
        """
    }
}

// MARK: - Findings parsing

public enum ExpertResponseParser {
    /// Splits an LLM response into individual bullet findings.
    public static func bullets(from response: String) -> [String] {
        response
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .compactMap { line -> String? in
                guard !line.isEmpty else { return nil }
                let stripped = line.hasPrefix("-")
                    ? String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                    : line.hasPrefix("•")
                        ? String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                        : line
                return stripped.isEmpty ? nil : stripped
            }
    }
}
