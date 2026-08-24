//
//  StudioAudit.swift
//  Kalsmritikosh
//
//  The shared audit trail for every persona studio: each deliverable carries a
//  document history (created, example loaded, report exported, …) that is
//  preserved with the record and PRINTED in the exported hardcopy as an
//  appendix — so the history is presentable on demand and travels with the
//  document, the way a professional file expects.
//

import Foundation

public struct StudioAuditEntry: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var date: Date
    public var action: String
    public init(date: Date, action: String) { self.date = date; self.action = action }
}

public nonisolated enum StudioAudit {
    /// Append an entry to an optional history (all studio models carry
    /// `history: [StudioAuditEntry]?` — optional so records saved before the
    /// audit trail existed still decode).
    public static func record(_ history: inout [StudioAuditEntry]?, _ action: String, at date: Date = Date()) {
        var h = history ?? []
        h.append(StudioAuditEntry(date: date, action: action))
        history = h
    }

    /// The hardcopy appendix — printed at the end of every studio report.
    public static func appendix(_ history: [StudioAuditEntry]?) -> String {
        guard let history, !history.isEmpty else { return "" }
        let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .short
        var out = "\n## Appendix — Document history (audit trail)\n\n"
        for e in history.sorted(by: { $0.date < $1.date }) {
            out += "- \(df.string(from: e.date)) — \(e.action)\n"
        }
        return out
    }
}
