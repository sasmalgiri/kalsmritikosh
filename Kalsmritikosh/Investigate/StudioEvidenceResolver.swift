//
//  StudioEvidenceResolver.swift
//  Kalsmritikosh
//
//  Final brief §3.2 — "evidenced" means the evidence was RESOLVED, not that a reference list is
//  non-empty. At preview and export, every field the gate would call evidenced is checked against the
//  draft's own case, under the current access policy:
//    • the draft is assigned to a case (otherwise nothing can be checked);
//    • a passage reference (block): its source version is in the case and accessible, the block still
//      exists in that version, and the quoted words are in the block's text;
//    • a document reference (object): the document is in the case and accessible, and the quote is the
//      document's name or words found in its text;
//    • a short value (an amount, a date, a name) appears in the passage it cites.
//  A field with no reference that resolves is reported with the reason. The person may then say it is
//  their own entry — it is printed as such, never as documentary evidence. An edited field already
//  lost its documentary status (StudioExportGate.status).
//

import Foundation

public nonisolated struct StudioEvidenceContext: Sendable {
    public let eligibleSourceVersions: Set<UUID>
    public let caseObjects: Set<UUID>
    public let documentNames: [UUID: String]
    public let blockText: @Sendable (UUID) async -> (sourceVersionID: UUID?, text: String)?
    public let objectText: @Sendable (UUID) async -> String?

    public init(eligibleSourceVersions: Set<UUID>, caseObjects: Set<UUID>, documentNames: [UUID: String],
                blockText: @escaping @Sendable (UUID) async -> (sourceVersionID: UUID?, text: String)?,
                objectText: @escaping @Sendable (UUID) async -> String?) {
        self.eligibleSourceVersions = eligibleSourceVersions; self.caseObjects = caseObjects; self.documentNames = documentNames
        self.blockText = blockText; self.objectText = objectText
    }
}

public nonisolated enum StudioEvidenceResolver {

    public static let notAssigned = "the draft is not assigned to a case, so its sources cannot be checked — use Fill from case"

    /// Field path → why its documentary support did not resolve. Only fields the gate would count as
    /// evidenced are checked; empty, unsupported and investigator-entry fields are not.
    public static func unresolved(values: [String: String], provenance: StudioProvenance?,
                                  context: StudioEvidenceContext?) async -> [String: String] {
        var out: [String: String] = [:]
        for path in values.keys.sorted() {
            let value = values[path] ?? ""
            guard StudioExportGate.status(of: value, provenance: provenance?[path]) == .evidenced,
                  let refs = provenance?[path]?.evidence else { continue }
            guard let context else { out[path] = notAssigned; continue }
            var reason = "no source is recorded"
            var resolved = false
            for ref in refs {
                switch await check(ref, value: value, context) {
                case nil: resolved = true
                case let r?: reason = r
                }
                if resolved { break }
            }
            if !resolved { out[path] = reason }
        }
        return out
    }

    /// nil when the reference resolves; otherwise the reason.
    static func check(_ ref: StudioEvidenceRef, value: String, _ c: StudioEvidenceContext) async -> String? {
        guard let quote = ref.quote?.trimmingCharacters(in: .whitespacesAndNewlines), !quote.isEmpty else {
            return "the reference quotes no passage"
        }
        let q = norm(quote)
        if let block = ref.blockID {
            guard let version = ref.sourceVersionID else { return "the passage reference names no source version" }
            guard c.eligibleSourceVersions.contains(version) else { return "the cited source is not in this case or is not accessible" }
            guard let b = await c.blockText(block) else { return "the cited passage no longer exists" }
            if let bv = b.sourceVersionID, bv != version { return "the cited passage belongs to a different version of the source" }
            guard norm(b.text).contains(q) else { return "the quoted words are not in the cited passage" }
            return supports(value, q) ? nil : "the cited passage does not contain this value"
        }
        if let object = ref.objectID {
            guard c.caseObjects.contains(object) else { return "the cited document is not in this case or is not accessible" }
            if let name = c.documentNames[object], norm(name) == q { return nil }   // a document reference
            guard let text = await c.objectText(object) else { return "the cited document cannot be read" }
            guard norm(text).contains(q) else { return "the quoted words are not in the cited document" }
            return supports(value, q) ? nil : "the cited passage does not contain this value"
        }
        if let version = ref.sourceVersionID {
            return c.eligibleSourceVersions.contains(version) ? "the reference names a source but no passage in it" : "the cited source is not in this case or is not accessible"
        }
        return "the reference names no source"
    }

    /// A short value (amount, date, name) must be in the passage; long text (a description, a quote)
    /// is the passage itself or drawn from it.
    static func supports(_ value: String, _ normalizedQuote: String) -> Bool {
        let v = norm(value)
        guard !v.isEmpty, v.count <= 80 else { return true }
        if normalizedQuote.contains(v) { return true }
        // "₹1,000" vs "Rs 1000": the digits must appear.
        let digits = v.filter(\.isNumber)
        return digits.count >= 2 && normalizedQuote.filter(\.isNumber).contains(digits)
    }

    static func norm(_ s: String) -> String {
        s.replacingOccurrences(of: "[“”″]", with: "\"", options: .regularExpression)
            .replacingOccurrences(of: "[‘’′]", with: "'", options: .regularExpression)
            .replacingOccurrences(of: "[–—]", with: "-", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces).lowercased()
    }
}
