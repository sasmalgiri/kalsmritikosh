//
//  WorkCenterReports.swift
//  Kalsmritikosh
//
//  WORK-CENTER parity pass (owner request 2026-08-17) — the PURE half of the
//  runner conveniences ported from maxmailin: reserved attestation keys,
//  auto-complete eligibility, the technical run report, the plain-language
//  stakeholder summary, and the documents-register filter. No store, no UI;
//  everything here is unit-tested.
//

import Foundation

// MARK: - Reserved per-step keys (attestation + note)

/// Keys stored alongside the user's field values in a step's value map but
/// owned by the system, not the recipe. Same convention as the source
/// system's "__refs": a "__" prefix means "not a recipe field".
public nonisolated enum WCReservedKey {
    /// Epoch-seconds string stamped when the step is confirmed.
    public static let confirmedAt = "__confirmedAt"
    /// Who confirmed the step (the attestation).
    public static let confirmedBy = "__confirmedBy"
    /// The user's optional free-text note for the step.
    public static let note = "__note"
    /// JSON list of evidence attached to the step (WCStepRef).
    public static let refs = "__refs"

    public static func isReserved(_ key: String) -> Bool { key.hasPrefix("__") }

    /// The step's confirmation attestation, if it has been confirmed.
    public static func attestation(in values: [String: String]) -> (at: Date, by: String)? {
        guard let raw = values[confirmedAt], let epoch = Double(raw) else { return nil }
        return (Date(timeIntervalSince1970: epoch), values[confirmedBy] ?? "")
    }
}

// MARK: - Step evidence refs (attach files to a step)

/// A piece of evidence attached to a step — an external file the user picked
/// while doing the work. Rides as JSON under the reserved `__refs` key, so
/// the run and its posted documents carry what the step rested on.
public nonisolated struct WCStepRef: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let detail: String

    public init(id: String, title: String, detail: String) {
        self.id = id; self.title = title; self.detail = detail
    }

    public static func decodeList(_ json: String?) -> [WCStepRef] {
        guard let json, let data = json.data(using: .utf8),
              let list = try? JSONDecoder().decode([WCStepRef].self, from: data) else { return [] }
        return list
    }

    public static func encodeList(_ refs: [WCStepRef]) -> String {
        guard let data = try? JSONEncoder().encode(refs),
              let s = String(data: data, encoding: .utf8) else { return "[]" }
        return s
    }
}

// MARK: - Field derivation (prefill from what the ledger already knows)

/// Prefills a step's empty fields from context the app already has, so the
/// user checks instead of retypes. Two sources: the examiner (macOS account
/// name) and CARRY-OVER — the newest non-empty value another run recorded
/// under the same field key (people run related workflows on one matter).
/// Derived values must NEVER mark a step touched: auto-complete requires
/// genuine engagement (see WCAutoComplete).
public nonisolated enum WCFieldDerivation {
    /// Field keys that carry over between runs — identity of the matter, not
    /// findings of a specific run.
    public static let carryOverKeys: Set<String> =
        ["caseNumber", "custodian", "matter", "reviewer", "dataset", "scope", "question"]

    /// Values to prefill for `op`, given prior runs (newest first). Only
    /// fills keys the op actually has, and never invents values.
    public static func derive(for op: WCOperation,
                              examiner: String,
                              priorRuns: [WCDocument]) -> [String: String] {
        var out: [String: String] = [:]
        for field in op.fields {
            if field.key == "reviewer", !examiner.isEmpty {
                out[field.key] = examiner
                continue
            }
            guard carryOverKeys.contains(field.key) else { continue }
            outer: for run in priorRuns {
                for (_, values) in run.fieldValues.sorted(by: { $0.key < $1.key }) {
                    if let v = values[field.key],
                       !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        out[field.key] = v
                        break outer
                    }
                }
            }
        }
        return out
    }
}

// MARK: - Auto-complete eligibility (pure)

/// When a step may mark itself done without a button press. Mirrors the
/// source system's guard: never on seeded defaults alone — a tool step needs
/// its tool opened, any other step needs a field actually touched.
public nonisolated enum WCAutoComplete {
    public static func eligible(_ op: WCOperation,
                                confirmed: Set<Int>,
                                lockedReasons: [String],
                                values: [String: String],
                                touched: Bool,
                                openedTool: Bool) -> Bool {
        guard !confirmed.contains(op.seq), lockedReasons.isEmpty else { return false }
        guard op.fields.contains(where: \.required) else { return false }
        guard WCFieldValidation.missingRequired(op.fields, values: values).isEmpty else { return false }
        if op.launchesSurface != nil { return openedTool }
        return touched
    }
}

// MARK: - Technical run report (monospace / printable)

/// Plain-text report of a run — the printable document form. Field values,
/// attestations, notes and posted document numbers, step by step.
public nonisolated struct WCInstanceReport {
    public let run: WCDocument
    public let definition: WCWorkflowDefinition
    /// The step documents this run posted (for the "→ DOC-…" echoes).
    public let documents: [WCDocument]

    public init(run: WCDocument, definition: WCWorkflowDefinition, documents: [WCDocument]) {
        self.run = run; self.definition = definition; self.documents = documents
    }

    public func rendered() -> String {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium; fmt.timeStyle = .short
        var out = "WORKFLOW \(run.docNumber)\n"
        out += String(repeating: "=", count: ("WORKFLOW " + run.docNumber).count) + "\n"
        out += "Title:   \(run.title)\n"
        out += "Status:  \(run.status.rawValue.uppercased())\n"
        out += "By:      \(run.actor)\n"
        out += "Started: \(fmt.string(from: run.createdAt))\n"
        out += "Progress: \(run.confirmedSeqs.count)/\(definition.operations.count) operations\n\nOPERATIONS\n"
        for op in definition.operations {
            let vals = run.fieldValues[op.seq] ?? [:]
            let mark = run.confirmedSeqs.contains(op.seq) ? "[x]" : "[ ]"
            out += "  \(mark) \(op.seq). \(op.title)\n"
            if let att = WCReservedKey.attestation(in: vals) {
                out += "        \(fmt.string(from: att.at)) by \(att.by.isEmpty ? "?" : att.by)"
                if let doc = documents.first(where: { $0.stepSeq == op.seq }) {
                    out += " → \(doc.docNumber)"
                }
                out += "\n"
            }
            if let note = vals[WCReservedKey.note], !note.isEmpty {
                out += "        note: \(note)\n"
            }
            for field in op.fields {
                let v = vals[field.key] ?? ""
                guard !v.isEmpty else { continue }
                out += "        \(field.label): \(v)\n"
            }
            for ref in WCStepRef.decodeList(vals[WCReservedKey.refs]) {
                out += "        Evidence: \(ref.title)\(ref.detail.isEmpty ? "" : " — \(ref.detail)")\n"
            }
        }
        out += "\nGenerated by Kalsmritikosh — record kept on-device.\n"
        return out
    }
}

// MARK: - Stakeholder summary (plain language, no jargon)

/// A clean, plain-language rendering of a run for a NON-technical reader —
/// counsel, a manager, a prosecutor. No seqs, no key dumps; prose plus the
/// values that matter. Pure and unit-tested.
public nonisolated struct WCStakeholderSummary {
    public let run: WCDocument
    public let definition: WCWorkflowDefinition
    public let documents: [WCDocument]
    public let preparedAt: Date

    public init(run: WCDocument, definition: WCWorkflowDefinition,
                documents: [WCDocument], preparedAt: Date) {
        self.run = run; self.definition = definition
        self.documents = documents; self.preparedAt = preparedAt
    }

    private var intro: String {
        switch definition.persona {
        case "Investigator":
            return "This is a plain-language summary of the evidence handling and review performed on this matter, for case reviewers, counsel, and other stakeholders who need to understand what was done without technical detail."
        case "Lawyer / Professional Reviewer":
            return "This is a plain-language summary of the document review and production performed for this matter, for counsel and stakeholders."
        case "Journalist":
            return "This is a plain-language summary of the sourcing, verification, and reporting steps behind this story."
        case "Researcher / Historian":
            return "This is a plain-language summary of how this review was conducted — from protocol to edition — for readers and reviewers."
        default:
            return "This is a plain-language summary of the work performed on these records."
        }
    }

    public func rendered() -> String {
        let fmt = DateFormatter()
        fmt.dateStyle = .long; fmt.timeStyle = .short
        let dayFmt = DateFormatter(); dayFmt.dateStyle = .long

        let done = run.confirmedSeqs.count
        let total = definition.operations.count

        var out = "# \(run.title)\n\n"
        out += "**Reference:** \(run.docNumber)  \n"
        out += "**Prepared by:** \(run.actor)  \n"
        out += "**Date:** \(fmt.string(from: preparedAt))  \n"
        let statusLine = done == total
            ? "Complete — all \(total) steps done"
            : "In progress — \(done) of \(total) steps done"
        out += "**Status:** \(statusLine)\n\n"
        out += intro + "\n\n"

        out += "## What was done\n\n"
        for op in definition.operations {
            let vals = run.fieldValues[op.seq] ?? [:]
            if run.confirmedSeqs.contains(op.seq) {
                out += "**\(op.title)** — completed"
                if let att = WCReservedKey.attestation(in: vals) {
                    out += " \(dayFmt.string(from: att.at))"
                    if !att.by.isEmpty { out += " by \(att.by)" }
                }
                out += ".\n"
                for field in op.fields {
                    let v = vals[field.key] ?? ""
                    guard !v.isEmpty else { continue }
                    out += "- \(field.label): \(v)\n"
                }
                for ref in WCStepRef.decodeList(vals[WCReservedKey.refs]) {
                    out += "- Evidence: \(ref.title)\n"
                }
                if let note = vals[WCReservedKey.note], !note.isEmpty {
                    out += "- Note: \(note)\n"
                }
                out += "\n"
            } else {
                out += "**\(op.title)** — not yet started.\n\n"
            }
        }

        let docNumbers = definition.operations.compactMap { op in
            documents.first { $0.stepSeq == op.seq }?.docNumber
        }
        if !docNumbers.isEmpty {
            out += "## Records produced\n\n"
            for d in docNumbers { out += "- \(d)\n" }
            out += "\n"
        }

        out += "---\n"
        out += "_This document was produced automatically by Kalsmritikosh as the work was performed. All records are kept on this device._\n"
        return out
    }
}

// MARK: - Documents-register filter (pure)

/// Search + date filtering for the documents register: a document matches if
/// the query appears in its number, type name, title, actor, or any entered
/// field value (reserved system keys excluded, notes included).
public nonisolated enum WCDocumentFilter {
    public static func matches(_ doc: WCDocument, query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        var haystack = [doc.docNumber, WCDocType.displayName(doc.docType), doc.title, doc.actor]
        for (_, values) in doc.fieldValues {
            for (key, value) in values where !value.isEmpty {
                if !WCReservedKey.isReserved(key) || key == WCReservedKey.note {
                    haystack.append(value)
                } else if key == WCReservedKey.refs {
                    // Attached evidence is searchable by its title/detail.
                    for ref in WCStepRef.decodeList(value) {
                        haystack.append(ref.title)
                        haystack.append(ref.detail)
                    }
                }
            }
        }
        return haystack.contains { $0.range(of: q, options: .caseInsensitive) != nil }
    }

    /// Inclusive day-range check on the document's creation time.
    public static func inRange(_ doc: WCDocument, from: Date, to: Date, calendar: Calendar) -> Bool {
        let start = calendar.startOfDay(for: from)
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: to)) ?? to
        return doc.createdAt >= start && doc.createdAt < end
    }
}
