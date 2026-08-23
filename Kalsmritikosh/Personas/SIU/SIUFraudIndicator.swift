//
//  SIUFraudIndicator.swift
//  Kalsmritikosh
//
//  A recognized taxonomy of insurance red-flag INDICATORS for the SIU persona.
//  Real Special Investigations Units screen against standard indicator groups
//  (claim timing, coverage changes, documentation anomalies, prior history, …);
//  a free-text "indicators" box invites ad-hoc, inconsistent screening.
//
//  The load-bearing discipline is baked in: a red flag is an INDICATOR that
//  warrants further inquiry — never, on its own, proof of fraud. This is a pure
//  reference value (no schema, no engine); the SIU DataLab triage template
//  surfaces it so screening is structured and the "indicator ≠ proof" line is
//  always in view.
//

import Foundation

public nonisolated struct SIUFraudIndicatorCategory: Sendable, Identifiable, Equatable {
    public let id: String
    public let group: String
    public let title: String
    public let detail: String
    public init(id: String, group: String, title: String, detail: String) {
        self.id = id; self.group = group; self.title = title; self.detail = detail
    }
}

public nonisolated enum SIUFraudIndicators {

    /// The discipline that governs every indicator — surfaced wherever red flags are recorded.
    public static let disciplineNote =
        "Red flags are INDICATORS that warrant further inquiry — never, on their own, proof of fraud."

    /// Recognized red-flag categories, grouped as SIUs commonly screen them.
    public static let categories: [SIUFraudIndicatorCategory] = [
        .init(id: "timing.inception", group: "Claim timing",
              title: "Loss soon after inception", detail: "Loss occurs shortly after the policy incepts."),
        .init(id: "timing.lapse", group: "Claim timing",
              title: "Loss near lapse / reinstatement", detail: "Loss just before lapse, or soon after reinstatement."),
        .init(id: "coverage.increase", group: "Coverage",
              title: "Recent coverage increase", detail: "Limits or scheduled items increased shortly before the loss."),
        .init(id: "claimant.pressure", group: "Claimant behavior",
              title: "Pressure for fast settlement", detail: "Unusual urgency or fluency with claim terminology / process."),
        .init(id: "claimant.contact", group: "Claimant behavior",
              title: "Hard to reach / cell-only", detail: "Reachable only by mobile; no verifiable fixed address."),
        .init(id: "incident.noreport", group: "Loss / incident",
              title: "No independent report", detail: "No police/fire report; only claimant-connected witnesses."),
        .init(id: "incident.inconsistent", group: "Loss / incident",
              title: "Inconsistent accounts", detail: "The account of the loss changes or conflicts across tellings."),
        .init(id: "docs.altered", group: "Documentation",
              title: "Altered / duplicated documents", detail: "Receipts appear altered, duplicated, or oddly sequential."),
        .init(id: "docs.round", group: "Documentation",
              title: "Round-number / missing originals", detail: "Round-number values; originals unavailable on request."),
        .init(id: "provider.repeat", group: "Provider / vendor",
              title: "Same provider across claims", detail: "One provider/vendor recurs across unrelated claims."),
        .init(id: "provider.inflated", group: "Provider / vendor",
              title: "Treatment / repair mismatch", detail: "Billed treatment or repair inconsistent with the reported loss."),
        .init(id: "history.prior", group: "History",
              title: "Prior similar claims", detail: "A pattern of prior or related claims by the claimant or associates."),
        .init(id: "history.overlap", group: "History",
              title: "Overlapping policies", detail: "Multiple policies covering the same risk or item."),
        .init(id: "financial.distress", group: "Financial",
              title: "Financial distress / over-insurance", detail: "Signs of financial pressure, or the risk is over-insured.")
    ]

    /// The groups in first-seen order (stable).
    public static func groups() -> [String] {
        var seen = Set<String>(); var out: [String] = []
        for c in categories where !seen.contains(c.group) { seen.insert(c.group); out.append(c.group) }
        return out
    }

    /// A one-line summary of the recognized groups, for a field's help text.
    public static var helpSummary: String {
        "Common groups: " + groups().joined(separator: " · ") + "."
    }
}
