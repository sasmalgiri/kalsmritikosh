//
//  FundsTracingMethod.swift
//  Kalsmritikosh
//
//  The recognized funds-tracing methods a forensic accountant applies. A tracing
//  schedule's conclusion depends entirely on WHICH method produced it — direct
//  tracing (specific identification) versus one of the indirect methods (net
//  worth, expenditures / source-and-application of funds, bank deposits). A
//  free-text schedule that never names its method invites an unstated,
//  unreviewable inference.
//
//  Pure reference value (no schema, no engine); the forensic-accounting DataLab
//  tracing template surfaces it so the method is chosen deliberately and stated.
//

import Foundation

public nonisolated struct FundsTracingMethod: Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let family: String     // "Direct" or "Indirect"
    public let detail: String
    public init(id: String, name: String, family: String, detail: String) {
        self.id = id; self.name = name; self.family = family; self.detail = detail
    }
}

public nonisolated enum FundsTracingMethods {

    public static let methods: [FundsTracingMethod] = [
        .init(id: "direct.specific", name: "Specific identification (direct tracing)", family: "Direct",
              detail: "Follow specific transactions from source to destination when the records are complete enough to do so."),
        .init(id: "indirect.networth", name: "Net worth method", family: "Indirect",
              detail: "Infer unreported funds from the change in net worth over a period, plus living expenses, less known income."),
        .init(id: "indirect.expenditures", name: "Expenditures (source & application of funds)", family: "Indirect",
              detail: "Compare known sources of funds against total expenditures; an unexplained excess signals unreported funds."),
        .init(id: "indirect.deposits", name: "Bank deposits method", family: "Indirect",
              detail: "Reconstruct income from total deposits, netting out transfers and identified non-income items.")
    ]

    /// The two families in stable order.
    public static func families() -> [String] {
        var seen = Set<String>(); var out: [String] = []
        for m in methods where !seen.contains(m.family) { seen.insert(m.family); out.append(m.family) }
        return out
    }

    /// One-line list of the recognized methods, for a field's help / template note.
    public static var helpSummary: String {
        "Recognized methods: " + methods.map(\.name).joined(separator: " · ") + "."
    }

    /// The discipline that governs method choice — surfaced with the schedule.
    public static let disciplineNote =
        "Use an indirect method only when direct tracing isn't possible, and state the method used — the schedule's conclusion depends on it."
}
