//
//  CaseFile.swift
//  Kalsmritikosh
//
//  Investigations Made Easy (docs/INVESTIGATIONS_MADE_EASY_TODO.md, phases C/E/P/A) — the case file
//  around an InvestigationCase (schema v151). This is the INVESTIGATOR'S record of how the case is run:
//  intake, triage, stage, owner, plan, allegations and their evidence grid, people, interviews, exhibits,
//  holds, redactions, review batches, conflict checks, journal and manual chronology. Evidence is
//  referenced by id, never copied; tasks and deadlines live in the ONE task engine and are only linked.
//  Judgement stays human: nothing here decides an allegation — a person records the disposition.
//

import CryptoKit
import Foundation

// MARK: - Stage, intake, triage

/// Where a case is in its life. `InvestigationCaseStatus` (open / scopeConfirmed / closed) stays the
/// scope authority; the stage is the working status the caseload shows.
public nonisolated enum CaseStage: String, Codable, Sendable, CaseIterable, Identifiable {
    case intake, triage, open, inProgress, onHold, findings, closed, declined, referred
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .intake: return "Intake"
        case .triage: return "Triage"
        case .open: return "Open"
        case .inProgress: return "In progress"
        case .onHold: return "On hold"
        case .findings: return "Findings"
        case .closed: return "Closed"
        case .declined: return "Declined"
        case .referred: return "Referred"
        }
    }
    /// Stages a case can move to from this one. Closing goes through the closure decision (rationale +
    /// seal), so `.closed` is never offered here; reopening goes through the closure repository too.
    public var next: [CaseStage] {
        switch self {
        case .intake: return [.triage]
        case .triage: return [.open, .declined, .referred]
        case .open: return [.inProgress, .onHold]
        case .inProgress: return [.onHold, .findings]
        case .onHold: return [.inProgress]
        case .findings: return [.inProgress]
        case .closed, .declined, .referred: return []
        }
    }
    public var isActive: Bool { ![.closed, .declined, .referred].contains(self) }
}

public nonisolated enum CaseSeverity: String, Codable, Sendable, CaseIterable, Identifiable {
    case low, medium, high, critical
    public var id: String { rawValue }
    public var label: String { rawValue.capitalized }
    public var rank: Int { CaseSeverity.allCases.firstIndex(of: self) ?? 0 }
}

public nonisolated enum CaseTriageDecision: String, Codable, Sendable, CaseIterable, Identifiable {
    case accept, decline, refer
    public var id: String { rawValue }
    public var label: String { rawValue.capitalized }
}

/// How a matter reached the investigator.
public nonisolated enum CaseIntakeChannel: String, Codable, Sendable, CaseIterable, Identifiable {
    case hotline, email, web, referral, walkIn, letter, audit, media, selfInitiated, other
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .hotline: return "Hotline"
        case .email: return "Email"
        case .web: return "Web form"
        case .referral: return "Referral"
        case .walkIn: return "In person"
        case .letter: return "Letter"
        case .audit: return "Audit finding"
        case .media: return "Media report"
        case .selfInitiated: return "Self-initiated"
        case .other: return "Other"
        }
    }
}

/// The typed intake. An anonymous intake stores NO complainant identity or contact — the fields are
/// cleared before the row is written, not hidden in the UI.
public nonisolated struct CaseIntake: Sendable, Equatable {
    public var receivedAt: Date?
    public var channel: CaseIntakeChannel?
    public var anonymous: Bool
    public var complainant: String?
    public var complainantContact: String?
    public var allegationSummary: String?
    public var incidentDate: String?
    public var incidentLocation: String?
    public var peopleNamed: String?

    public init(receivedAt: Date? = nil, channel: CaseIntakeChannel? = nil, anonymous: Bool = false, complainant: String? = nil,
                complainantContact: String? = nil, allegationSummary: String? = nil, incidentDate: String? = nil,
                incidentLocation: String? = nil, peopleNamed: String? = nil) {
        self.receivedAt = receivedAt; self.channel = channel; self.anonymous = anonymous; self.complainant = complainant
        self.complainantContact = complainantContact; self.allegationSummary = allegationSummary
        self.incidentDate = incidentDate; self.incidentLocation = incidentLocation; self.peopleNamed = peopleNamed
    }

    /// The form as it is stored: identity removed when the intake is anonymous.
    public var stored: CaseIntake {
        guard anonymous else { return self }
        var s = self; s.complainant = nil; s.complainantContact = nil; return s
    }
}

public nonisolated struct CaseTriage: Sendable, Equatable {
    public var severity: CaseSeverity?
    public var riskNote: String?
    public var decision: CaseTriageDecision?
    public var reason: String?
    public var decidedBy: String?
    public var decidedAt: Date?
    public init(severity: CaseSeverity? = nil, riskNote: String? = nil, decision: CaseTriageDecision? = nil,
                reason: String? = nil, decidedBy: String? = nil, decidedAt: Date? = nil) {
        self.severity = severity; self.riskNote = riskNote; self.decision = decision; self.reason = reason
        self.decidedBy = decidedBy; self.decidedAt = decidedAt
    }
}

/// The investigation plan (C-5): scope comes from the case itself; this is how it will be run.
public nonisolated struct CasePlan: Sendable, Equatable {
    public var method: String?
    public var evidenceToCollect: String?
    public var interviewsToHold: String?
    public var notes: String?
    public init(method: String? = nil, evidenceToCollect: String? = nil, interviewsToHold: String? = nil, notes: String? = nil) {
        self.method = method; self.evidenceToCollect = evidenceToCollect; self.interviewsToHold = interviewsToHold; self.notes = notes
    }
    public var isEmpty: Bool { [method, evidenceToCollect, interviewsToHold, notes].allSatisfy { ($0 ?? "").isEmpty } }
}

/// The case profile: one row per case.
public nonisolated struct CaseProfile: Sendable, Equatable {
    public let caseID: UUID
    public var kind: String?
    public var stage: CaseStage
    public var triage: CaseTriage
    public var owner: String?
    public var team: [String]
    public var reviewer: String?
    public var intake: CaseIntake
    public var plan: CasePlan
    public var retentionPolicy: String?
    public var retainUntil: Date?
    public var archivedAt: Date?
    public var updatedAt: Date

    public init(caseID: UUID, kind: String? = nil, stage: CaseStage = .intake, triage: CaseTriage = .init(), owner: String? = nil,
                team: [String] = [], reviewer: String? = nil, intake: CaseIntake = .init(), plan: CasePlan = .init(),
                retentionPolicy: String? = nil, retainUntil: Date? = nil, archivedAt: Date? = nil, updatedAt: Date = Date()) {
        self.caseID = caseID; self.kind = kind; self.stage = stage; self.triage = triage; self.owner = owner; self.team = team
        self.reviewer = reviewer; self.intake = intake; self.plan = plan; self.retentionPolicy = retentionPolicy
        self.retainUntil = retainUntil; self.archivedAt = archivedAt; self.updatedAt = updatedAt
    }
}

// MARK: - Allegations and the evidence grid

public nonisolated enum AllegationDisposition: String, Codable, Sendable, CaseIterable, Identifiable {
    case pending, substantiated, unsubstantiated, inconclusive, withdrawn
    public var id: String { rawValue }
    public var label: String { rawValue.capitalized }
}

public nonisolated enum GridStance: String, Codable, Sendable, CaseIterable, Identifiable {
    case supports, contradicts, neutral
    public var id: String { rawValue }
    public var label: String { rawValue.capitalized }
}

public nonisolated struct CaseAllegation: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let caseID: UUID
    public let sequence: Int
    public var text: String
    public var disposition: AllegationDisposition
    public var rationale: String?
    public var decidedBy: String?
    public var decidedAt: Date?
    public let createdAt: Date
    /// "A1", "A2" … — how the report and the grid refer to it.
    public var label: String { "A\(sequence)" }
}

public nonisolated struct AllegationEvidence: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let allegationID: UUID
    public let evidenceRef: String
    public let label: String?
    public let stance: GridStance
    public let note: String?
    public let addedBy: String
    public let createdAt: Date
}

// MARK: - Journal and chronology

public nonisolated enum CaseJournalKind: String, Codable, Sendable, CaseIterable {
    case note, chronology
}

public nonisolated struct CaseJournalEntry: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let caseID: UUID
    public let kind: CaseJournalKind
    /// For a chronology entry: when the thing happened (an investigator entry, marked as such).
    public let eventDate: Date?
    public let text: String
    public let evidenceRef: String?
    public let author: String
    public let createdAt: Date
}

// MARK: - People, contacts, interviews, credibility

public nonisolated enum CasePersonRole: String, Codable, Sendable, CaseIterable, Identifiable {
    case subject, witness, complainant, custodian, other
    public var id: String { rawValue }
    public var label: String { rawValue.capitalized }
}

public nonisolated struct CasePerson: Identifiable, Sendable, Equatable, Hashable {
    public let id: UUID
    public let caseID: UUID
    public var name: String
    public var role: CasePersonRole
    public var entityID: UUID?
    public var contact: String?
    public var notes: String?
    public let createdAt: Date
}

public nonisolated struct CaseContact: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let personID: UUID
    public let at: Date
    public let mode: String
    public let note: String?
    public let by: String
}

public nonisolated enum InterviewStatus: String, Codable, Sendable, CaseIterable, Identifiable {
    case planned, scheduled, held, summarised, attested, cancelled
    public var id: String { rawValue }
    public var label: String { rawValue.capitalized }
}

public nonisolated struct CaseInterview: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let caseID: UUID
    public var personID: UUID?
    public var status: InterviewStatus
    public var scheduledAt: Date?
    public var mode: String?
    public var location: String?
    public var questions: String?
    /// Source refs of the recording and its transcript in the ledger (the transcript is the
    /// ingested KnowledgeObject of the recording — never retyped here).
    public var recordingRef: String?
    public var transcriptRef: String?
    public var summary: String?
    public var statementText: String?
    public var attestedBy: String?
    public var attestedAt: Date?
    /// SHA-256 of the statement as attested; any later edit breaks the match and is shown.
    public var statementSHA256: String?
    public let createdAt: Date
    public var updatedAt: Date

    public var statementIntact: Bool {
        guard let statementSHA256, let statementText else { return statementSHA256 == nil }
        return CaseFileHash.sha256(statementText) == statementSHA256
    }
}

/// A correction to an attested statement (implementation brief §9). The attested statement is never
/// edited: a correction is a new, append-only record linked to it, with its own fingerprint, the reason,
/// and — once the interviewee confirms it — who confirmed it and when. A confirmation entered here is a
/// recorded assertion, not cryptographic proof of the interviewee's identity.
public nonisolated struct StatementAddendum: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let interviewID: UUID
    public let caseID: UUID
    public let text: String
    public let reason: String
    public let sha256: String
    public let recordedBy: String
    public let recordedAt: Date
    public let confirmedBy: String?
    public let confirmedAt: Date?
    public var intact: Bool { CaseFileHash.sha256(text) == sha256 }
}

public nonisolated enum CredibilityFactor: String, Codable, Sendable, CaseIterable, Identifiable {
    case consistency, corroboration, plausibility, motive, demeanour
    public var id: String { rawValue }
    public var label: String { rawValue.capitalized }
    public var prompt: String {
        switch self {
        case .consistency: return "Is the account consistent within itself and over time?"
        case .corroboration: return "Do documents or other witnesses support it?"
        case .plausibility: return "Is it plausible given the other evidence?"
        case .motive: return "Does the person have a reason to shade the account?"
        case .demeanour: return "Observed demeanour (weigh lightly; record what was seen, not a conclusion)."
        }
    }
}

public nonisolated enum CredibilityAssessment: String, Codable, Sendable, CaseIterable, Identifiable {
    case supports, neutral, undermines
    public var id: String { rawValue }
    public var label: String { rawValue.capitalized }
}

public nonisolated struct CredibilityNote: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let interviewID: UUID
    public let factor: CredibilityFactor
    public let assessment: CredibilityAssessment
    public let note: String?
    public let evidenceRef: String?
    public let by: String
    public let createdAt: Date
}

// MARK: - Exhibits, holds, redactions, review batches, conflicts, actions

public nonisolated struct CaseExhibit: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let caseID: UUID
    public let number: String
    public var description: String
    public var sourceRef: String?
    public var sha256: String?
    public var collectedBy: String?
    public var collectedAt: Date?
    public var collectedWhere: String?
    public let createdAt: Date
    public var withdrawnAt: Date?
}

public nonisolated struct CaseHoldNotice: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let caseID: UUID
    public let custodian: String
    public let personID: UUID?
    public let noticeText: String
    public let issuedAt: Date
    public let issuedBy: String
    public var acknowledgedAt: Date?
    public var reminderDue: Date?
    public var releasedAt: Date?
    public var releaseReason: String?
    public var isOutstanding: Bool { releasedAt == nil && acknowledgedAt == nil }
}

public nonisolated struct CaseRedaction: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let caseID: UUID
    public let sourceRef: String
    public let location: String
    public let reason: String
    public let redactedBy: String
    public let at: Date
}

public nonisolated enum ReviewBatchStatus: String, Codable, Sendable, CaseIterable {
    case open, firstPassDone, qcDone
    public var label: String {
        switch self { case .open: return "In review"; case .firstPassDone: return "First pass done"; case .qcDone: return "QC done" }
    }
}

public nonisolated struct CaseReviewBatch: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let caseID: UUID
    public var name: String
    public var reviewer: String?
    public var sourceRefs: [String]
    public var status: ReviewBatchStatus
    public var qcReviewer: String?
    public var qcNote: String?
    public let createdAt: Date
    public var updatedAt: Date
}

public nonisolated enum ConflictCheckResult: String, Codable, Sendable, CaseIterable {
    case clear, conflict, waived
}

public nonisolated struct CaseConflictCheck: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let caseID: UUID
    public let investigator: String
    public let result: ConflictCheckResult
    public let matched: String?
    public let note: String?
    public let checkedBy: String
    public let checkedAt: Date
}

public nonisolated struct CaseAction: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let caseID: UUID
    public let sequence: Int
    public let actor: String
    public let action: String
    public let detail: String?
    public let at: Date
}

/// A linked task (from the one task engine) with its confirmed deadline, if any.
public nonisolated struct CaseTaskItem: Identifiable, Sendable, Equatable {
    public let task: ProfessionalTask
    public let deadline: Deadline?
    public var id: UUID { task.id }
    public func isOverdue(at date: Date) -> Bool {
        guard let deadline, ![.completed, .cancelled, .archived].contains(task.status) else { return false }
        return deadline.isOverdue(at: date)
    }
}

public nonisolated enum CaseFileError: Error, Sendable, Equatable, LocalizedError {
    case blank(String)
    case caseNotFound(UUID)
    case notFound(String, UUID)
    case invalidStageMove(from: CaseStage, to: CaseStage)
    case duplicateExhibitNumber(String)
    case statementAlreadyAttested
    case noStatement
    case attestedFieldLocked(String)
    case notAttested
    case addendumAlreadyConfirmed
    case taskEngineUnavailable
    /// The record exists but belongs to another case (implementation brief §3).
    case notInCase(String, UUID)
    /// The case is closed; reopen it to change it.
    case caseClosed
    /// The record changed since it was read; reload and try again.
    case staleRecord(String, UUID)

    public var errorDescription: String? {
        switch self {
        case .blank(let f): return "\(f) can't be empty."
        case .caseNotFound: return "The case was not found."
        case .notFound(let what, _): return "The \(what) was not found."
        case .invalidStageMove(let a, let b): return "A case can't move from \(a.label) to \(b.label)."
        case .duplicateExhibitNumber(let n): return "Exhibit \(n) already exists in this case."
        case .statementAlreadyAttested: return "The statement is already attested. Record a new statement instead of changing it."
        case .noStatement: return "There is no statement to attest."
        case .attestedFieldLocked(let what): return "The statement is confirmed, so its \(what) can't be changed. Add a correction instead."
        case .notAttested: return "Only a confirmed statement takes a correction; edit the statement directly."
        case .addendumAlreadyConfirmed: return "This correction is already confirmed."
        case .taskEngineUnavailable: return "Tasks aren't available yet."
        case .notInCase(let what, _): return "That \(what) belongs to another case."
        case .caseClosed: return "The case is closed. Reopen it to make changes."
        case .staleRecord(let what, _): return "The \(what) changed since it was opened. Reload it and try again."
        }
    }
}

// MARK: - The investigator on this Mac (S-3)

/// The named investigator profile for this Mac user. v1 is single-user: the name is recorded on
/// every case action, task, note and decision. There are no roles or permissions in v1.
public nonisolated enum InvestigatorProfile {
    public static let nameKey = "kalsmritikosh.investigatorName"
    public static let organisationKey = "kalsmritikosh.investigatorOrganisation"

    public static var name: String {
        let stored = UserDefaults.standard.string(forKey: nameKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !stored.isEmpty { return stored }
        let full = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        return full.isEmpty ? NSUserName() : full
    }
    public static var organisation: String? {
        let o = UserDefaults.standard.string(forKey: organisationKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return o.isEmpty ? nil : o
    }
}

// MARK: - Hashing (attested statements)

public nonisolated enum CaseFileHash {
    public static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
