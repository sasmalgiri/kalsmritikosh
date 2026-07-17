//
//  SuggestedQuestionBuilder.swift
//  Kalsmritikosh
//
//  Data-grounded "questions from your archive" (inspired by NotebookLM's
//  suggested questions / FAQ, done the evidence-ledger way). Instead of static
//  per-persona prompts, this turns what's ACTUALLY in the ledger — the top
//  people/organizations/projects, recent dated events, open contradictions, and
//  missing-evidence gaps — into concrete questions the user can tap to ask.
//
//  Pure and deterministic: NO model, NO database, NO network. AppState gathers
//  the plain snapshots; this ranks + phrases them, persona-weighted, so it works
//  even when no reasoning model is available.
//

import Foundation

public struct SuggestedQuestion: Identifiable, Sendable, Hashable {
    public enum Category: String, Sendable, Hashable {
        case person, organization, project, contradiction, gap, event
    }
    public let id: String
    public let text: String
    public let category: Category

    public init(id: String = UUID().uuidString, text: String, category: Category) {
        self.id = id
        self.text = text
        self.category = category
    }
}

public struct SuggestedQuestionBuilder: Sendable {

    /// Plain snapshots pulled from the ledger by the caller (already ranked by
    /// mention count / recency where relevant).
    public struct Inputs: Sendable {
        public var people: [String]
        public var organizations: [String]
        public var projects: [String]
        public var events: [String]
        public var contradictions: [String]
        public var gaps: [String]
        public init(
            people: [String] = [], organizations: [String] = [], projects: [String] = [],
            events: [String] = [], contradictions: [String] = [], gaps: [String] = []
        ) {
            self.people = people; self.organizations = organizations; self.projects = projects
            self.events = events; self.contradictions = contradictions; self.gaps = gaps
        }

        public var isEmpty: Bool {
            people.isEmpty && organizations.isEmpty && projects.isEmpty
                && events.isEmpty && contradictions.isEmpty && gaps.isEmpty
        }
    }

    public init() {}

    /// Build up to `limit` grounded questions, interleaved by the persona's
    /// category priority so a lawyer leads with conflicts/gaps and an
    /// investigator with people/events.
    public func build(persona: String, inputs: Inputs, limit: Int = 8) -> [SuggestedQuestion] {
        // Per-category question queues.
        var queues: [SuggestedQuestion.Category: [SuggestedQuestion]] = [
            .person: inputs.people.map { q(.person, "Who is \($0), and what is their role across the documents?") },
            .organization: inputs.organizations.map { q(.organization, "What is \($0)'s involvement across the documents?") },
            .project: inputs.projects.map { q(.project, "What happened with \($0)?") },
            .event: inputs.events.map { q(.event, "What led up to \(clip($0))?") },
            .contradiction: inputs.contradictions.map { q(.contradiction, "The sources seem to disagree — \(clip($0)). Which is better supported?") },
            .gap: inputs.gaps.map { q(.gap, "\(clip($0)) — what does the archive show?") }
        ]

        var out: [SuggestedQuestion] = []
        var seen: Set<String> = []
        // Round-robin across the persona's priority order until we hit the limit
        // or every queue is drained.
        let order = Self.priority(for: persona)
        var progressed = true
        while out.count < limit && progressed {
            progressed = false
            for cat in order {
                guard out.count < limit, var queue = queues[cat], !queue.isEmpty else { continue }
                let item = queue.removeFirst()
                queues[cat] = queue
                progressed = true
                guard seen.insert(item.text).inserted else { continue }
                out.append(item)
            }
        }
        return out
    }

    private func q(_ cat: SuggestedQuestion.Category, _ text: String) -> SuggestedQuestion {
        SuggestedQuestion(text: text, category: cat)
    }

    /// Trim a long label to a readable clause for a question.
    private func clip(_ s: String, max: Int = 90) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > max else { return t }
        return String(t.prefix(max)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Category priority per persona id (matches PersonaWorkCatalog ids).
    static func priority(for persona: String) -> [SuggestedQuestion.Category] {
        switch persona {
        case "legal":         return [.contradiction, .gap, .event, .person, .organization, .project]
        case "investigation": return [.person, .event, .contradiction, .organization, .gap, .project]
        case "journalism":    return [.contradiction, .person, .event, .organization, .gap, .project]
        case "research":      return [.event, .project, .person, .organization, .gap, .contradiction]
        default:              return [.person, .event, .organization, .project, .gap, .contradiction]
        }
    }
}
