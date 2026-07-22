//
//  MissingEvidenceTaxonomy.swift
//  Kalsmritikosh
//
//  CLM-004 — a complete, NEUTRAL taxonomy for why requested evidence is absent, with the
//  scope that was searched. The locked contract is strict here: "a missing item is never
//  presented as proof of wrongdoing." Every gap states what was looked for, where, and the
//  benign reason it was not found — it never implies concealment or guilt.
//
//  Deterministic, offline. Pairs with RET-006 (which detects WHICH requested fields the
//  evidence lacks); this classifies WHY and frames it neutrally for the user.
//

import Foundation

public enum MissingEvidenceKind: String, Codable, Sendable, CaseIterable {
    case notInCorpus         // no source in the added corpus covers this
    case searchedNotFound    // sources searched, no matching evidence present
    case deferredProcessing  // recognized source not yet fully processed (e.g. media/OCR pending)
    case encrypted           // source is present but locked
    case corrupt             // source could not be reliably parsed
    case preservedOnly       // format retained but not yet interpretable (no parser)
    case redactedOut         // present but withheld by a redaction/privilege policy
    case outOfTimeScope      // evidence may exist but outside the question's time window

    /// A neutral, non-accusatory phrasing. NEVER implies wrongdoing or concealment.
    public var neutralPhrase: String {
        switch self {
        case .notInCorpus:        return "no added source covers this"
        case .searchedNotFound:   return "searched the available sources; no matching evidence found"
        case .deferredProcessing: return "a relevant source is recognized but not yet fully processed"
        case .encrypted:          return "a relevant source is present but locked/encrypted"
        case .corrupt:            return "a relevant source could not be reliably read"
        case .preservedOnly:      return "a relevant source is preserved but not yet interpretable in this version"
        case .redactedOut:        return "withheld under the active redaction/privilege settings"
        case .outOfTimeScope:     return "evidence may exist outside the requested time range"
        }
    }
}

/// One scoped, neutral gap: what was sought, why it's absent, and the search scope.
public struct MissingEvidence: Codable, Sendable, Hashable {
    public let requestedField: String
    public let kind: MissingEvidenceKind
    public let documentsSearched: Int
    /// Optional time window that was in scope, for honest disclosure.
    public let timeScopeNote: String?

    public nonisolated init(requestedField: String, kind: MissingEvidenceKind,
                            documentsSearched: Int, timeScopeNote: String? = nil) {
        self.requestedField = requestedField
        self.kind = kind
        self.documentsSearched = documentsSearched
        self.timeScopeNote = timeScopeNote
    }

    /// Neutral, scoped one-liner for the answer's missing-evidence section.
    public nonisolated func disclosure() -> String {
        var s = "\(requestedField): \(kind.neutralPhrase) (\(documentsSearched) document(s) searched)"
        if let t = timeScopeNote { s += "; \(t)" }
        return s + "."
    }
}

public struct MissingEvidenceClassifier: Sendable {
    public nonisolated init() {}

    /// Classify why each missing field is absent, given lightweight corpus context. Defaults
    /// to the most benign, honest explanation; escalates to a more specific benign reason
    /// only when the context supports it. Never infers concealment.
    public nonisolated func classify(
        missingFields: [String],
        documentsSearched: Int,
        hasDeferredSources: Bool = false,
        hasEncryptedSources: Bool = false,
        hasPreservedOnlySources: Bool = false,
        outOfTimeScope: Bool = false,
        timeScopeNote: String? = nil
    ) -> [MissingEvidence] {
        missingFields.map { field in
            let kind: MissingEvidenceKind
            if outOfTimeScope { kind = .outOfTimeScope }
            else if documentsSearched == 0 { kind = .notInCorpus }
            else if hasEncryptedSources { kind = .encrypted }
            else if hasDeferredSources { kind = .deferredProcessing }
            else if hasPreservedOnlySources { kind = .preservedOnly }
            else { kind = .searchedNotFound }
            return MissingEvidence(requestedField: field, kind: kind,
                                   documentsSearched: documentsSearched,
                                   timeScopeNote: outOfTimeScope ? timeScopeNote : nil)
        }
    }
}
