//
//  ParseCoverageReport.swift
//  Kalsmritikosh
//
//  PAR-002 — the per-source coverage report. PAR-001 says what a FORMAT can do; this says
//  what actually happened to THIS source after parsing, classified into the locked
//  contract's support states so the Sources UI can show it honestly and nothing is ever
//  silently dropped.
//
//  Deterministic. Derived from a ParsedDocument's extraction status + blocks + warnings.
//

import Foundation

/// The locked-contract §5 support states, as they apply to an actual ingested source.
public enum SourceCoverageState: String, Codable, Sendable, Hashable {
    case full           = "FULL"            // structure recovered; searchable + citable
    case partial        = "PARTIAL"         // some content recovered, disclosed limits
    case preservedOnly  = "PRESERVED-ONLY"  // identity/hash kept; content not interpretable
    case deferred       = "DEFERRED"        // recognized, processing postponed
    case encrypted      = "ENCRYPTED"       // locked; never treated as empty
    case corrupt        = "CORRUPT"         // unreadable; quarantined + visible
    case failed         = "FAILED"          // attempt failed; retry info kept, not "processed"

    /// May a source in this state be counted as "processed / searchable"?
    public nonisolated var isSearchable: Bool { self == .full || self == .partial }
    /// User-facing claim allowed for this state.
    public var userLabel: String {
        switch self {
        case .full: return "Supported"
        case .partial: return "Partially supported"
        case .preservedOnly: return "Preserved, not searchable"
        case .deferred: return "Pending processing"
        case .encrypted: return "Locked (encrypted)"
        case .corrupt: return "Unreadable (quarantined)"
        case .failed: return "Failed (will retry)"
        }
    }
}

public struct ParseCoverageReport: Codable, Sendable, Hashable {
    public let filename: String
    public let detectedType: String
    public let state: SourceCoverageState
    public let blockCount: Int
    public let reason: String

    public nonisolated init(filename: String, detectedType: String, state: SourceCoverageState,
                            blockCount: Int, reason: String) {
        self.filename = filename
        self.detectedType = detectedType
        self.state = state
        self.blockCount = blockCount
        self.reason = reason
    }

    /// USF-002 — the compatibility presentation projected from the DURABLE readiness authority.
    /// ParseCoverageReport is no longer an independent readiness authority: prefer this projection
    /// (or `SourceReadinessSummary(snapshots:)`) over deriving coverage straight from a
    /// ParsedDocument. `from(_ doc:)` below survives only as an internal pre-persistence parser
    /// signal, not as the source of truth.
    public nonisolated static func from(_ snapshot: SourceReadinessSnapshot, filename: String, detectedType: String) -> ParseCoverageReport {
        let state: SourceCoverageState
        switch snapshot.completionState {
        case .evidenceReady: state = .full
        case .searchablePartial: state = .partial
        case .preservedOnly, .unsupported: state = .preservedOnly
        case .deferred: state = .deferred
        case .encrypted: state = .encrypted
        case .corrupt: state = .corrupt
        case .failed: state = .failed
        }
        let blocks = snapshot.dimension(.structuralExtraction)?.completedUnits ?? 0
        return ParseCoverageReport(filename: filename, detectedType: detectedType, state: state,
                                   blockCount: blocks, reason: "projected from source readiness (\(snapshot.completionState.rawValue))")
    }

    /// Classify an ingested ParsedDocument into a coverage report. USF-002.1 — INTERNAL parser
    /// signal only, NOT the readiness authority: application code must use the durable path
    /// (SourceReadinessRepository → SourceReadinessSnapshot → `from(_ snapshot:)`), never derive a
    /// readiness-style status straight from a ParsedDocument. Kept internal so it cannot be mistaken
    /// for authoritative source readiness.
    nonisolated static func from(_ doc: ParsedDocument) -> ParseCoverageReport {
        let blocks = doc.meaningfulBlocks.count
        let hasError = doc.warnings.contains { $0.severity == .error }
        let (state, reason) = classify(status: doc.extractionStatus, meaningfulBlocks: blocks, hasError: hasError)
        return ParseCoverageReport(filename: doc.filename, detectedType: doc.detectedType.rawValue,
                                   state: state, blockCount: blocks, reason: reason)
    }

    /// Pure classification from the raw signals (decoupled for testing).
    public nonisolated static func classify(
        status: ExtractionStatus, meaningfulBlocks: Int, hasError: Bool
    ) -> (SourceCoverageState, String) {
        switch status {
        case .complete:
            return meaningfulBlocks > 0
                ? (.full, "structure recovered (\(meaningfulBlocks) block(s))")
                : (.preservedOnly, "parsed but no meaningful content extracted")
        case .partial:
            return (.partial, hasError ? "some blocks failed (errors present)" : "some content recovered with disclosed limits")
        case .empty:
            return (.preservedOnly, "no extractable content")
        case .unsupported:
            return (.preservedOnly, "no structural parser for this format")
        case .encrypted:
            return (.encrypted, "source is locked/encrypted")
        case .corrupt:
            return (.corrupt, "source could not be reliably parsed")
        case .deferred:
            return (.deferred, "recognized; processing postponed (e.g. media/OCR)")
        case .failed:
            return (.failed, "parse attempt failed; retry information retained")
        }
    }
}
