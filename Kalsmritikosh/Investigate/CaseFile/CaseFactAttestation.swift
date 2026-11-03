//
//  CaseFactAttestation.swift
//  Kalsmritikosh
//
//  N3 (2026-11-03) — a "verified" mark only a person can set on a chronology entry (schema v169,
//  `case_fact_attestations`). The machine check (the quote was found in the pinned source,
//  CaseEvidenceVerifier) is a different thing and keeps its own label. A person marks an entry
//  verified, or withdraws the mark with a reason; every mark is a new append-only row naming who,
//  when, the note and the SHA-256 of the entry as it stood. The current state is the latest row.
//  If the entry has changed since (its text, date, source or quote differ from the digest, or the
//  result revision it was carried from is superseded), the mark reads "verified on an earlier
//  version — check again", never as current.
//
//  Human-only: `markVerified(entryID:…)` and `withdraw(entryID:…)` are called only from the case
//  file screen, when a person presses the button (CaseFactAttestationBoundaryTests scans for it).
//

import Foundation

public nonisolated enum CaseFactAttestationState: String, Sendable, Codable, CaseIterable {
    case verified, withdrawn
}

/// One recorded mark (or withdrawal) on a chronology entry.
public nonisolated struct CaseFactAttestation: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let caseID: UUID
    public let journalEntryID: UUID
    public let state: CaseFactAttestationState
    public let attestedBy: String
    public let attestedAt: Date
    /// The optional note of a verification, or the (required) reason for a withdrawal.
    public let note: String?
    /// SHA-256 of the entry's text, date, source and quote when the mark was made.
    public let entryDigest: String

    public init(id: UUID, caseID: UUID, journalEntryID: UUID, state: CaseFactAttestationState, attestedBy: String,
                attestedAt: Date, note: String?, entryDigest: String) {
        self.id = id; self.caseID = caseID; self.journalEntryID = journalEntryID; self.state = state
        self.attestedBy = attestedBy; self.attestedAt = attestedAt; self.note = note; self.entryDigest = entryDigest
    }
}

/// What a person's mark on an entry says now.
public nonisolated enum CaseFactMark: Sendable, Equatable {
    /// No person has marked it (or never did).
    case none
    /// Verified by a person, on the entry as it is now.
    case verified(by: String, at: Date)
    /// Verified by a person, but the entry has changed since — check again.
    case earlierVersion(by: String, at: Date)
    /// The latest mark is a withdrawal.
    case withdrawn(by: String, at: Date, reason: String)

    public var isCurrentVerification: Bool { if case .verified = self { return true }; return false }

    /// The screen's label (nil: show nothing).
    public var screenLabel: String? {
        switch self {
        case .none, .withdrawn: return nil
        case .verified(let by, let at): return "Verified by \(by) · \(CaseFileDocuments.d(at))"
        case .earlierVersion: return "Verified on an earlier version — check again"
        }
    }

    /// The report's line beside the machine check.
    public var reportLabel: String {
        switch self {
        case .none: return "Not verified by a person"
        case .verified(let by, let at): return "Verified by \(by) on \(CaseFileDocuments.d(at))"
        case .earlierVersion(let by, let at):
            return "Verified on an earlier version (by \(by) on \(CaseFileDocuments.d(at))) — the entry has changed since; check again"
        case .withdrawn(let by, let at, let reason):
            return "Not verified by a person (verification withdrawn by \(by) on \(CaseFileDocuments.d(at)): \(reason))"
        }
    }
}

public nonisolated enum CaseFactAttestationError: Error, Sendable, Equatable, LocalizedError {
    /// The entry is already verified, on its current version.
    case alreadyVerified(by: String, at: Date)
    /// There is no current verification to withdraw.
    case notVerified
    /// Only a chronology entry is a fact a person can verify.
    case notChronology

    public var errorDescription: String? {
        switch self {
        case .alreadyVerified(let by, let at):
            return "This entry is already verified by \(by) on \(CaseFileDocuments.t(at)); nothing changed since, so it was not marked again."
        case .notVerified: return "This entry is not marked verified, so there is nothing to withdraw."
        case .notChronology: return "Only a chronology entry can be marked verified."
        }
    }
}

public nonisolated enum CaseFactAttestations {
    /// SHA-256 over the entry's content as a person reads it: text, event date, source reference, quote.
    public static func digest(text: String, eventDate: Date?, evidenceRef: String?, quote: String?) -> String {
        let date = eventDate.map { String($0.timeIntervalSince1970) } ?? ""
        let canonical = "text=\(text)\u{1F}date=\(date)\u{1F}ref=\(evidenceRef ?? "")\u{1F}quote=\(quote ?? "")"
        return CaseFileHash.sha256(canonical)
    }

    public static func digest(of entry: CaseJournalEntry) -> String {
        digest(text: entry.text, eventDate: entry.eventDate, evidenceRef: entry.evidenceRef, quote: entry.quote)
    }

    /// The mark an entry carries now, from its attestation rows (any order). `superseded`: the result
    /// revision the entry was carried from is no longer the current one.
    public static func mark(for entry: CaseJournalEntry, history: [CaseFactAttestation], superseded: Bool) -> CaseFactMark {
        let mine = history.filter { $0.journalEntryID == entry.id }
        guard let last = latest(mine) else { return .none }
        switch last.state {
        case .withdrawn:
            return .withdrawn(by: last.attestedBy, at: last.attestedAt, reason: last.note ?? "")
        case .verified:
            if last.entryDigest == digest(of: entry), !superseded { return .verified(by: last.attestedBy, at: last.attestedAt) }
            return .earlierVersion(by: last.attestedBy, at: last.attestedAt)
        }
    }

    /// The latest row by time; rows at the same instant keep their stored order (`attestations(caseID:)`
    /// returns them oldest first, in insertion order), so the later-written one wins.
    static func latest(_ rows: [CaseFactAttestation]) -> CaseFactAttestation? {
        rows.enumerated().max { a, b in
            a.element.attestedAt != b.element.attestedAt ? a.element.attestedAt < b.element.attestedAt : a.offset < b.offset
        }?.element
    }
}

extension CaseFileSnapshot {
    /// N3 — the person's mark on a chronology entry, as it reads now.
    public func factMark(for entry: CaseJournalEntry) -> CaseFactMark {
        CaseFactAttestations.mark(for: entry, history: attestations, superseded: isSuperseded(entry.origin))
    }
    /// N3 — every attestation row for one entry, oldest first.
    public func attestationHistory(for entryID: UUID) -> [CaseFactAttestation] {
        attestations.filter { $0.journalEntryID == entryID }
    }
}
