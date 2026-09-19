//
//  SourceLifecycle.swift
//  Kalsmritikosh
//
//  A2 (module .importLifecycle) — the per-source lifecycle the audit's
//  import/coverage item asks for: one explicit state per source across its
//  whole life, plus honest partial-omission disclosure. It UNIFIES the signals
//  the pipeline already produces (FileIndexStatus classification, ingest
//  outcome, encryption) into a single deterministic state a UI can show.
//
//  Pure + deterministic (no DB, no I/O) so it is fully unit-tested. The module
//  gate governs whether callers surface the richer lifecycle state; OFF ⇒ the
//  existing FileIndexStatus label stands unchanged.
//

import Foundation

public enum SourceLifecycleState: String, Sendable, Equatable, CaseIterable {
    case queued          // accepted, not yet processed
    case processing      // actively being read/parsed/embedded
    case searchable      // fully indexed and answerable
    case partial         // some content recovered; limits disclosed
    case needsPassword   // encrypted; a user password is required to open
    case failed          // could not be read/parsed; retryable
    case excluded        // deliberately not indexed (user/policy)

    public var label: String {
        switch self {
        case .queued:        return "Queued"
        case .processing:    return "Processing"
        case .searchable:    return "Searchable"
        case .partial:       return "Partial — some content"
        case .needsPassword: return "Needs password"
        case .failed:        return "Couldn't read"
        case .excluded:      return "Not indexed"
        }
    }

    /// Whether the source is answerable in retrieval today.
    public var isAnswerable: Bool { self == .searchable || self == .partial }

    /// Whether a disclosure ("results may omit this source") should show.
    public var disclosesOmission: Bool {
        switch self {
        case .partial, .needsPassword, .failed, .excluded: return true
        case .queued, .processing, .searchable:            return false
        }
    }
}

public enum SourceLifecycle {

    /// Signals the pipeline already produces for a source.
    public struct Signals: Sendable, Equatable {
        public var index: FileIndexStatus?    // nil = not yet classified (queued/processing)
        public var inFlight: Bool             // currently being processed
        public var passwordProtected: Bool    // A4 — encrypted, needs a password
        public var failed: Bool               // an ingest attempt failed (retryable)
        public var excluded: Bool             // user/policy excluded from indexing
        public var partialOmission: Bool      // some members/pages omitted with disclosure
        public init(index: FileIndexStatus? = nil, inFlight: Bool = false,
                    passwordProtected: Bool = false, failed: Bool = false,
                    excluded: Bool = false, partialOmission: Bool = false) {
            self.index = index; self.inFlight = inFlight
            self.passwordProtected = passwordProtected; self.failed = failed
            self.excluded = excluded; self.partialOmission = partialOmission
        }
    }

    /// The single lifecycle state, priority-ordered so the most important
    /// account wins (excluded > needsPassword > failed > partial > searchable
    /// > processing > queued). Deterministic.
    public nonisolated static func derive(_ s: Signals) -> SourceLifecycleState {
        if s.excluded { return .excluded }
        if s.passwordProtected { return .needsPassword }
        if s.failed { return .failed }
        if let index = s.index {
            switch index {
            case .indexed, .transcribed, .expanded:
                return s.partialOmission ? .partial : .searchable
            case .limitedScan:
                return .partial
            case .notTranscribed, .notExpanded:
                return s.inFlight ? .processing : .partial
            case .unsupported:
                return .failed
            }
        }
        return s.inFlight ? .processing : .queued
    }
}
