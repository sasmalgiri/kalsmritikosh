//
//  TimelineEngine.swift
//  Atlas chronica memora
//
//  Read-side over the events table. Produces the global / project /
//  person / company / financial timeline views.
//

import Foundation

public actor TimelineEngine {
    public enum View: Sendable, Hashable {
        case global
        case project(String)
        case person(String)
        case company(String)
        case financial
    }

    private let events: EventsRepository

    public init(events: EventsRepository) {
        self.events = events
    }

    public func reconstruct(_ view: View, in range: ClosedRange<Date>? = nil) async throws -> [Event] {
        let lower = range?.lowerBound ?? .distantPast
        let upper = range?.upperBound ?? .distantFuture
        let all = try await events.between(start: lower, end: upper, limit: 2000)
        switch view {
        case .global:
            return all
        case .financial:
            return all.filter { e in
                e.kind == .invoiceIssued || e.kind == .invoicePaid
            }
        case .project(let name):
            return all.filter { event in
                event.title.localizedCaseInsensitiveContains(name) ||
                (event.summary?.localizedCaseInsensitiveContains(name) ?? false)
            }
        case .person(let name), .company(let name):
            return all.filter { event in
                event.title.localizedCaseInsensitiveContains(name) ||
                (event.summary?.localizedCaseInsensitiveContains(name) ?? false)
            }
        }
    }
}
