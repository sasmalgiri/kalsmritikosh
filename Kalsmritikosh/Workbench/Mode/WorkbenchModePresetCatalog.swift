//
//  WorkbenchModePresetCatalog.swift
//  Kalsmritikosh
//
//  LAB-006 (Stage C closure) — the guided analyses Simple mode offers. This is the proof that "Simple
//  calculations = the Advanced transformation engine": each preset is outcome-first, minimal-terminology
//  guidance that COMPILES to a real LAB-002 WorkbenchTransformSpec. There is NO separate easy-mode
//  calculator — a Simple preset and an Advanced hand-written transform run through the exact same
//  WorkbenchTransformEngine and produce the exact same lineage-carrying result. Compilation fails closed
//  when a required parameter is missing, rather than guessing.
//

import Foundation

/// The closed set of guided Simple-mode analyses. Each maps to a supported LAB-002 transform.
public nonisolated enum WorkbenchAnalysisPresetKind: String, Codable, Sendable, Equatable, CaseIterable {
    case totalByCategory
    case countByCategory
    case averageByCategory
    case keepRowsAbove
    case keepRowsBelow
    case sortLowToHigh
    case sortHighToLow
    case runningTotal
    case removeDuplicates
}

/// The parameters a preset needs (all optional here; `compile` enforces which are required per kind).
public nonisolated struct WorkbenchPresetParameters: Sendable, Equatable {
    public var groupByField: String?
    public var valueField: String?
    public var threshold: String?
    public var sortField: String?
    public var keyField: String?
    public var newFieldName: String?

    public nonisolated init(groupByField: String? = nil, valueField: String? = nil, threshold: String? = nil,
                            sortField: String? = nil, keyField: String? = nil, newFieldName: String? = nil) {
        self.groupByField = groupByField; self.valueField = valueField; self.threshold = threshold
        self.sortField = sortField; self.keyField = keyField; self.newFieldName = newFieldName
    }
}

/// One guided analysis: an outcome-first title + plain-language description, resolvable to a real spec.
public nonisolated struct WorkbenchAnalysisPreset: Identifiable, Sendable, Equatable {
    public let id: String
    public let kind: WorkbenchAnalysisPresetKind
    public let title: String
    public let plainLanguage: String
    public nonisolated init(kind: WorkbenchAnalysisPresetKind, title: String, plainLanguage: String) {
        self.id = kind.rawValue; self.kind = kind; self.title = title; self.plainLanguage = plainLanguage
    }
}

public nonisolated enum WorkbenchModePresetError: Error, Sendable, Equatable {
    case missingParameter(String)
}

public nonisolated enum WorkbenchModePresetCatalog {

    /// The guided analyses Simple mode presents (outcome-first, minimal terminology).
    public nonisolated static let simplePresets: [WorkbenchAnalysisPreset] = [
        .init(kind: .totalByCategory,   title: "Total by category",     plainLanguage: "Add up a number for each group."),
        .init(kind: .countByCategory,   title: "Count by category",     plainLanguage: "Count how many rows are in each group."),
        .init(kind: .averageByCategory, title: "Average by category",   plainLanguage: "Find the average of a number for each group."),
        .init(kind: .keepRowsAbove,     title: "Keep rows above a value", plainLanguage: "Show only rows where a number is greater than a value."),
        .init(kind: .keepRowsBelow,     title: "Keep rows below a value", plainLanguage: "Show only rows where a number is less than a value."),
        .init(kind: .sortLowToHigh,     title: "Sort low to high",      plainLanguage: "Order rows from smallest to largest."),
        .init(kind: .sortHighToLow,     title: "Sort high to low",      plainLanguage: "Order rows from largest to smallest."),
        .init(kind: .runningTotal,      title: "Running total",         plainLanguage: "Add a column that keeps a running sum."),
        .init(kind: .removeDuplicates,  title: "Remove duplicates",     plainLanguage: "Keep only the first row for each repeated value.")]

    /// Compile a guided preset into a REAL LAB-002 transform spec — the same spec type the Advanced
    /// formula path produces, executed by the same engine.
    public nonisolated static func compile(_ kind: WorkbenchAnalysisPresetKind,
                                           parameters p: WorkbenchPresetParameters) throws -> WorkbenchTransformSpec {
        func need(_ value: String?, _ name: String) throws -> String {
            guard let v = value, !v.trimmingCharacters(in: .whitespaces).isEmpty else { throw WorkbenchModePresetError.missingParameter(name) }
            return v
        }
        func fieldRef(_ name: String) -> String { "[\(name)]" }

        switch kind {
        case .totalByCategory:
            return .aggregate(function: .sum, field: try need(p.valueField, "valueField"), groupBy: [try need(p.groupByField, "groupByField")])
        case .countByCategory:
            return .aggregate(function: .count, field: nil, groupBy: [try need(p.groupByField, "groupByField")])
        case .averageByCategory:
            return .aggregate(function: .average, field: try need(p.valueField, "valueField"), groupBy: [try need(p.groupByField, "groupByField")])
        case .keepRowsAbove:
            return .filter(predicate: "\(fieldRef(try need(p.valueField, "valueField"))) > \(try need(p.threshold, "threshold"))")
        case .keepRowsBelow:
            return .filter(predicate: "\(fieldRef(try need(p.valueField, "valueField"))) < \(try need(p.threshold, "threshold"))")
        case .sortLowToHigh:
            return .sort(field: try need(p.sortField, "sortField"), direction: .ascending)
        case .sortHighToLow:
            return .sort(field: try need(p.sortField, "sortField"), direction: .descending)
        case .runningTotal:
            return .runningTotal(newField: try need(p.newFieldName, "newFieldName"), over: try need(p.valueField, "valueField"))
        case .removeDuplicates:
            return .deduplicate(keyFields: [try need(p.keyField, "keyField")])
        }
    }
}
