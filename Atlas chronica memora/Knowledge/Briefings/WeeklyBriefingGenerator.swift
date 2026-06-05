//
//  WeeklyBriefingGenerator.swift
//  Atlas chronica memora
//
//  Asks: "what changed this week?" — purely from the MemoryChange log.
//  Each MemoryObject that mutated within the window contributes a
//  digest line (status change, added events, narrative rewrite).
//  Optionally calls the Summarizer to weave the lines into a narrative
//  via the capability registry; falls back to a structured bullet list.
//

import Foundation

public struct WeeklyBriefing: Codable, Sendable, Hashable {
    public let window: Window
    public let perSubject: [SubjectDigest]
    public let narrative: String
    public let generatedAt: Date

    public struct Window: Codable, Sendable, Hashable {
        public let start: Date
        public let end: Date
    }

    public struct SubjectDigest: Codable, Sendable, Hashable {
        public let subjectKind: MemoryObject.SubjectKind
        public let subjectIdentifier: String
        public let changeCount: Int
        public let statusChanges: [String]
        public let addedEventCount: Int
        public let narrativeRewritten: Bool
    }
}

public actor WeeklyBriefingGenerator {
    public enum Period: Sendable {
        case lastWeek
        case lastMonth
        case sinceDate(Date)
        case custom(start: Date, end: Date)

        public func window(now: Date = .init()) -> WeeklyBriefing.Window {
            let calendar = Calendar.current
            switch self {
            case .lastWeek:
                let start = calendar.date(byAdding: .day, value: -7, to: now) ?? now
                return .init(start: start, end: now)
            case .lastMonth:
                let start = calendar.date(byAdding: .month, value: -1, to: now) ?? now
                return .init(start: start, end: now)
            case .sinceDate(let s):
                return .init(start: s, end: now)
            case .custom(let s, let e):
                return .init(start: s, end: e)
            }
        }
    }

    private let memory: MemoryRepository
    private let summarizer: any Summarizer
    private let capabilities: CapabilityRegistry

    public init(
        memory: MemoryRepository,
        summarizer: any Summarizer,
        capabilities: CapabilityRegistry
    ) {
        self.memory = memory
        self.summarizer = summarizer
        self.capabilities = capabilities
    }

    public func briefing(period: Period = .lastWeek) async throws -> WeeklyBriefing {
        let window = period.window()
        let changes = try await memory.changesSince(
            subjectKind: nil,
            subjectIdentifier: nil,
            since: window.start,
            limit: 500
        )
        let perSubject = aggregate(changes: changes)
        let narrative = await renderNarrative(window: window, digests: perSubject)
        return WeeklyBriefing(
            window: window,
            perSubject: perSubject,
            narrative: narrative,
            generatedAt: .init()
        )
    }

    public func subjectBriefing(
        kind: MemoryObject.SubjectKind,
        identifier: String,
        period: Period = .lastMonth
    ) async throws -> WeeklyBriefing {
        let window = period.window()
        let changes = try await memory.changesSince(
            subjectKind: kind,
            subjectIdentifier: identifier,
            since: window.start,
            limit: 200
        )
        let perSubject = aggregate(changes: changes)
        let narrative = await renderNarrative(window: window, digests: perSubject)
        return WeeklyBriefing(
            window: window,
            perSubject: perSubject,
            narrative: narrative,
            generatedAt: .init()
        )
    }

    // MARK: - Internals

    private func aggregate(changes: [MemoryChange]) -> [WeeklyBriefing.SubjectDigest] {
        let grouped = Dictionary(grouping: changes) { c in
            "\(c.subjectKind.rawValue)|\(c.subjectIdentifier)"
        }
        return grouped.map { _, list -> WeeklyBriefing.SubjectDigest in
            let first = list.first!
            return WeeklyBriefing.SubjectDigest(
                subjectKind: first.subjectKind,
                subjectIdentifier: first.subjectIdentifier,
                changeCount: list.count,
                statusChanges: list.compactMap { c in
                    c.delta.statusChanged.map { "\($0.from) → \($0.to)" }
                },
                addedEventCount: list.reduce(0) { $0 + $1.delta.addedEventIDs.count },
                narrativeRewritten: list.contains { $0.delta.narrativeRewrite }
            )
        }
        .sorted { $0.changeCount > $1.changeCount }
    }

    private func renderNarrative(
        window: WeeklyBriefing.Window,
        digests: [WeeklyBriefing.SubjectDigest]
    ) async -> String {
        let bullets = digests.prefix(12).map { d -> String in
            var parts: [String] = ["\(d.subjectIdentifier) (\(d.subjectKind.rawValue))"]
            if d.addedEventCount > 0 { parts.append("+\(d.addedEventCount) events") }
            if !d.statusChanges.isEmpty { parts.append("status: \(d.statusChanges.joined(separator: ", "))") }
            if d.narrativeRewritten { parts.append("memory rewritten") }
            return "- " + parts.joined(separator: " · ")
        }.joined(separator: "\n")

        let header = "Briefing window: \(window.start.formatted(date: .abbreviated, time: .omitted)) – \(window.end.formatted(date: .abbreviated, time: .omitted))"
        if digests.isEmpty {
            return "\(header)\n\nNothing changed in this window."
        }

        // Try the LLM summarizer for a narrative cover; fall back to
        // the structured bullet list if no provider is registered.
        let scopeRange = Summary.Scope.Range(start: window.start, end: window.end)
        if let summary = try? await summarizer.summarize(
            scope: .timeline(scopeRange),
            level: .timeline,
            length: .medium
        ), !summary.body.isEmpty,
           !summary.body.localizedCaseInsensitiveContains("nothing changed") {
            _ = capabilities // explicit dep — registry is required to be alive
            return "\(header)\n\n\(summary.body)\n\nDelta highlights:\n\(bullets)"
        }
        return "\(header)\n\nDelta highlights:\n\(bullets)"
    }
}
