//
//  CaseMapProjection.swift
//  Kalsmritikosh
//
//  Living case map, package M1 (docs/IME_Living_Case_Map_Implementation_Plan_2026-11-06.md §5): the case's
//  existing records projected into typed nodes and typed links. PURE — it reads what the case services
//  already hold (the case file snapshot, the case's documents, contradictions with their review state,
//  hypotheses and their citations, evidence requests, the investigator's own map links) and decides
//  nothing. There is no second store of case records: every node names its canonical record.
//
//  • Identity is the case id + the canonical record kind + the canonical record id; the revision (a source
//    version, a record revision, a decision id) is kept separately, so re-reading the same records in
//    another order, or a re-ingested document, keeps the same identity.
//  • A link carries its endpoints, direction, the records and revisions it comes from, every source with its
//    version and locator, who asserted it (investigator, rule or model), its review state and whether it is
//    stale. Provenance, review, reliability and truth are never folded into one number.
//  • A note is labelled a note and never counts as documentary support; a document's presence says nothing
//    about the truth of what it states; same name is not same person.
//

import CryptoKit
import Foundation

// MARK: - Identity

/// The canonical record a map item stands for. Nodes are made from the first group; the rest are records
/// a link can come from (origins) without being drawn.
public nonisolated enum CaseMapRecordKind: String, Codable, Sendable, CaseIterable {
    case caseFile = "case", allegation, person, document, exhibit, interview, addendum, journal, hypothesis
    case contradiction, request, task, reportItem
    /// Smart-map M1 (v176): a supplied report or a recorded result, and one of its points.
    case report, reportPoint
    // origin-only records
    case allegationEvidence, hypothesisEvidence, requestReceipt, reviewDecision, investigatorLink, rule
    /// v176: a work link (raised from / serves) and a qualification of a point.
    case workLink, qualification, actionContract
    /// v177: an investigator-placed frame membership and an action dependency.
    case frameMember, actionDependency
    /// S3 (MAP-06, GRAPH-04): one money movement read from the case's documents (FundsTrace transaction identity).
    case moneyTransaction
    /// v179 (GRAPH-09): a recorded same-person / different-people decision about two case-person rows (origin only).
    case identityDecision
    /// S7 (MONEY-01, v183): the case's canonical financial records — an account and one money record (movement, invoice,
    /// claim, balance, allegation, estimate, asset or statement row) — and an account holder/owner/controller assertion (origin).
    case moneyAccount, moneyRecord, accountRelation

    /// Kinds an investigator's own map link may point at: each has a case-owned table the write checks.
    public static let linkable: Set<CaseMapRecordKind> = [.caseFile, .allegation, .person, .document, .exhibit, .interview,
                                                          .addendum, .journal, .hypothesis, .request, .reportItem, .task,
                                                          .report, .reportPoint, .moneyAccount, .moneyRecord]
}

/// One map item's stable identity: case + canonical record kind + canonical record id (no revision).
public nonisolated struct CaseMapNodeID: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public let caseID: UUID
    public let kind: CaseMapRecordKind
    public let recordID: String
    public init(caseID: UUID, kind: CaseMapRecordKind, recordID: String) {
        self.caseID = caseID; self.kind = kind; self.recordID = recordID.lowercased()
    }
    public init(caseID: UUID, kind: CaseMapRecordKind, id: UUID) { self.init(caseID: caseID, kind: kind, recordID: id.uuidString) }
    /// The key inside one case ("allegation:…").
    public var key: String { "\(kind.rawValue):\(recordID)" }
    public var description: String { key }
    public static func < (a: CaseMapNodeID, b: CaseMapNodeID) -> Bool {
        // The same order as comparing (case id text, kind, record id); the case id's text is only built when
        // the two cases differ (M9 §13.3: sorting tens of thousands of items built two strings per comparison).
        if a.caseID != b.caseID { return a.caseID.uuidString < b.caseID.uuidString }
        if a.kind != b.kind { return a.kind.rawValue < b.kind.rawValue }
        return a.recordID < b.recordID
    }
}

// MARK: - Node and link vocabulary

/// What a node is, as the person reads it.
public nonisolated enum CaseMapNodeKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case question, person, event, evidence, statement, hypothesis, contradiction, action, finding, note, group
    /// S3 (MAP-06): a money movement — payer, payee, amount and currency as the documents record them.
    case money
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .question: return "Question"
        case .person: return "Person or organisation"
        case .event: return "Event"
        case .evidence: return "Evidence"
        case .statement: return "Statement"
        case .hypothesis: return "Hypothesis or lead"
        case .contradiction: return "Contradiction"
        case .action: return "Action or request"
        case .finding: return "Finding or report item"
        case .note: return "Investigator's note"
        case .group: return "Group"
        case .money: return "Money movement"
        }
    }
    public var plural: String {
        switch self {
        case .question: return "Questions"
        case .person: return "People and organisations"
        case .event: return "Events"
        case .evidence: return "Evidence"
        case .statement: return "Statements"
        case .hypothesis: return "Hypotheses and leads"
        case .contradiction: return "Contradictions"
        case .action: return "Actions and requests"
        case .finding: return "Findings and report items"
        case .note: return "Notes"
        case .group: return "Groups"
        case .money: return "Money movements"
        }
    }
    /// An SF Symbol: every kind has its own icon, so the map never relies on colour alone.
    public var symbol: String {
        switch self {
        case .question: return "questionmark.circle"
        case .person: return "person.crop.circle"
        case .event: return "calendar"
        case .evidence: return "doc.text"
        case .statement: return "quote.bubble"
        case .hypothesis: return "lightbulb"
        case .contradiction: return "exclamationmark.triangle"
        case .action: return "checklist"
        case .finding: return "checkmark.seal"
        case .note: return "note.text"
        case .group: return "square.stack.3d.up"
        case .money: return "banknote"
        }
    }
    /// Material the "Unlinked material" group collects when nothing links to it.
    public var isMaterial: Bool { [.evidence, .statement, .event, .note].contains(self) }
}

/// The typed link vocabulary (plan §5.2).
public nonisolated enum CaseMapLinkType: String, Codable, Sendable, CaseIterable, Identifiable {
    case supports, challenges, mentions, attributedTo, occurredBefore, occurredAfter, possibleSamePerson
    case dependsOn, requestsEvidenceFor, receivedInResponseTo, derivedFrom, supersedes, selectedForReport
    /// v177: the investigator placed the item in this frame (a membership record, not a drawn link).
    case placedIn
    /// S3 (GRAPH-04): a money movement's payer and payee as the documents record them, and a recorded same-person decision.
    case moneyFrom, moneyTo, samePersonDecided
    /// S5 (REASON-02) — the item limits or conditions the other (a qualification, an exception); and an evidence row whose
    /// relevance nobody has assessed yet. Neither is support.
    case qualifies, relevanceUnassessed
    /// S7 (MONEY-09): an account → the person or organisation recorded as its holder, signatory, owner or controller, with the
    /// period and basis. A relationship to the account — never an authorisation of its payments or a liability.
    case accountRelation
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .supports: return "supports"
        case .challenges: return "challenges"
        case .mentions: return "mentions"
        case .attributedTo: return "attributed to"
        case .occurredBefore: return "occurred before"
        case .occurredAfter: return "occurred after"
        case .possibleSamePerson: return "possibly the same person (pending review)"
        case .dependsOn: return "depends on"
        case .requestsEvidenceFor: return "requests evidence for"
        case .receivedInResponseTo: return "received in response to"
        case .derivedFrom: return "derived from"
        case .supersedes: return "supersedes"
        case .selectedForReport: return "selected for report"
        case .placedIn: return "placed here"
        case .moneyFrom: return "money sent by (as recorded)"
        case .moneyTo: return "money received by (as recorded)"
        case .samePersonDecided: return "the same person (your recorded decision)"
        case .qualifies: return "qualifies"
        case .relevanceUnassessed: return "linked — relevance not assessed"
        case .accountRelation: return "held, signed for, owned or controlled by (as recorded)"
        }
    }
    /// How the line is drawn (never colour alone): solid, dashed or dotted.
    public enum Stroke: String, Sendable { case solid, dashed, dotted }
    public var stroke: Stroke {
        switch self {
        case .supports, .attributedTo, .receivedInResponseTo, .selectedForReport, .derivedFrom, .moneyFrom, .moneyTo, .samePersonDecided, .accountRelation: return .solid
        case .challenges, .supersedes, .occurredBefore, .occurredAfter, .qualifies: return .dashed
        case .mentions, .possibleSamePerson, .dependsOn, .requestsEvidenceFor, .placedIn, .relevanceUnassessed: return .dotted
        }
    }
    /// A link with an explicit direction (all of them except a possible-same-person pairing).
    public var directed: Bool { self != .possibleSamePerson && self != .samePersonDecided }
    /// Types an investigator draws as a map link (case_map_links). A frame membership is recorded with "Place in
    /// frame", and a possible-same-person pairing comes from the identity review, not from the link tool.
    public var drawable: Bool { ![.possibleSamePerson, .placedIn, .moneyFrom, .moneyTo, .samePersonDecided, .relevanceUnassessed, .accountRelation].contains(self) }
    /// GRAPH-04 — what kind of relationship it is: evidence, identity, event, work, financial or arrangement. None of them
    /// implies causation; there is deliberately no "caused" type (a cause is a finding, argued on evidence, not a line).
    public enum Family: String, Sendable, CaseIterable { case evidence, identity, event, work, financial, arrangement }
    public var family: Family {
        switch self {
        case .supports, .challenges, .mentions, .attributedTo, .derivedFrom, .supersedes, .selectedForReport, .qualifies, .relevanceUnassessed: return .evidence
        case .possibleSamePerson, .samePersonDecided: return .identity
        case .occurredBefore, .occurredAfter: return .event
        case .dependsOn, .requestsEvidenceFor, .receivedInResponseTo: return .work
        case .moneyFrom, .moneyTo, .accountRelation: return .financial
        case .placedIn: return .arrangement
        }
    }
}

/// GRAPH-04 — how certain the person who recorded a link said it is. Never inferred: a link nobody qualified says so.
public nonisolated enum CaseMapCertainty: String, Codable, Sendable, CaseIterable, Identifiable {
    case notStated, statedBySource, probable, possible, doubtful
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .notStated: return "Certainty not stated — the link records a connection, not that it is true"
        case .statedBySource: return "As the source states it (not checked further)"
        case .probable: return "Probable, in the investigator's view"
        case .possible: return "Possible, in the investigator's view"
        case .doubtful: return "Doubtful, in the investigator's view"
        }
    }
}

/// GRAPH-04 — when a link holds: a period (either end may be open) and/or the source's own wording. Nil: not recorded.
public nonisolated struct CaseMapValidity: Hashable, Sendable {
    public let from: Date?
    public let to: Date?
    public let text: String?
    public init(from: Date?, to: Date?, text: String?) { self.from = from; self.to = to; self.text = text }
    public var isRecorded: Bool { from != nil || to != nil || !(text ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
    public var label: String {
        guard isRecorded else { return "When it holds: not recorded" }
        var parts: [String] = []
        if from != nil || to != nil {
            parts.append((from.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "…") + " – " + (to.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "…"))
        }
        if let t = text?.trimmingCharacters(in: .whitespaces), !t.isEmpty { parts.append("“\(t)”") }
        return "When it holds: " + parts.joined(separator: " ")
    }
}

/// S3 (MAP-06/07) — the amount of a money movement, in its own currency (never converted or added across currencies).
public nonisolated struct CaseMapMoney: Hashable, Sendable {
    public let amount: Decimal
    public let currency: String
    public var display: String {
        if currency == FundsMoney.unstated { return FAMoney.format(amount, currency: "") + " (currency not stated)" }
        return FAMoney.format(amount, currency: currency)
    }
}


/// Who asserted a link or produced an item.
public nonisolated enum CaseMapAssertion: Hashable, Sendable {
    case investigator(String)
    case rule(String)
    case model(String)
    public var label: String {
        switch self {
        case .investigator(let who): return "Recorded by \(who)"
        case .rule(let what): return "Found by a rule (\(what))"
        case .model(let what): return "Proposed by the AI reading (\(what)) — checked against the documents, not a decision"
        }
    }
}

/// The human review state of an item or link, as recorded.
public nonisolated enum CaseMapReviewState: String, Codable, Sendable, CaseIterable {
    case notApplicable, unreviewed, pendingReview, accepted, completed, confirmed, dismissed, deferred, reopened, rejected, withdrawn
    /// S5 (REASON-06) — a contradiction explained as a real difference, or examined and left unresolved.
    case explained, unresolved
    public var label: String {
        switch self {
        case .notApplicable: return "No review needed"
        case .unreviewed: return "Not reviewed yet"
        case .pendingReview: return "Pending review"
        case .accepted: return "Accepted on review"
        case .completed: return "Completed result"
        case .confirmed: return "Confirmed"
        case .dismissed: return "Dismissed"
        case .deferred: return "Deferred"
        case .reopened: return "Reopened — a source changed"
        case .rejected: return "Rejected on review"
        case .withdrawn: return "Withdrawn"
        case .explained: return "Explained — a real difference"
        case .unresolved: return "Unresolved — cannot be settled on the case material"
        }
    }
    /// Waiting for the person.
    public var awaitingReview: Bool { [.unreviewed, .pendingReview, .deferred, .reopened].contains(self) }
}

/// The honest state of an item or link. Each kind is distinct: a failed read is not "unsupported", an
/// unassessed item is not "unsupported", a restricted source is not "unavailable".
public nonisolated struct CaseMapStatus: Hashable, Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        /// A state a person (or the record itself) recorded: "Open", "Confirmed by Ada", "Pending".
        case recorded
        /// Nobody has assessed it yet (e.g. a link recorded before verification existed).
        case unassessed
        /// Not supported by a verified passage or a live exhibit (a note, a passage that did not verify).
        case unsupported
        /// The source is not in this case any more, or was withdrawn.
        case unavailable
        /// The source is in the case but not readable under the current access policy.
        case restricted
        /// Changed since it was decided or carried (a revised source, a superseded result revision).
        case stale
        /// It could not be read.
        case failed

        public var label: String {
            switch self {
            case .recorded: return "Recorded"
            case .unassessed: return "Not yet assessed"
            case .unsupported: return "Not supported by a verified source"
            case .unavailable: return "Source unavailable"
            case .restricted: return "Restricted"
            case .stale: return "Needs review — changed since"
            case .failed: return "Could not be read"
            }
        }
        public var symbol: String {
            switch self {
            case .recorded: return "circle"
            case .unassessed: return "circle.dashed"
            case .unsupported: return "minus.circle"
            case .unavailable: return "questionmark.folder"
            case .restricted: return "lock"
            case .stale: return "arrow.triangle.2.circlepath"
            case .failed: return "xmark.octagon"
            }
        }
    }
    public let kind: Kind
    public let text: String
    public init(_ kind: Kind, _ text: String) { self.kind = kind; self.text = text }
    public static func recorded(_ text: String) -> CaseMapStatus { CaseMapStatus(.recorded, text) }
}

/// One source an item or link rests on: the exact version, the document, the passage locator.
public nonisolated struct CaseMapSourceRef: Hashable, Sendable {
    public let sourceVersionID: UUID?
    public let objectID: UUID?
    public let blockID: UUID?
    public let documentName: String?
    /// The exact words, held in memory for the inspector only (never written to preferences or logs).
    public let quote: String?
    public init(sourceVersionID: UUID?, objectID: UUID?, blockID: UUID? = nil, documentName: String?, quote: String?) {
        self.sourceVersionID = sourceVersionID; self.objectID = objectID; self.blockID = blockID
        self.documentName = documentName; self.quote = quote
    }
    /// A position inside the document is known (a block, or quoted words to find). A bare document
    /// reference shows "Position unavailable".
    public var positionAvailable: Bool { blockID != nil || !(quote ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public var locatorText: String {
        var parts: [String] = []
        if let sourceVersionID { parts.append("version \(sourceVersionID.uuidString.prefix(8))") } else { parts.append("no source version") }
        parts.append(blockID.map { "passage \($0.uuidString.prefix(8))" } ?? (positionAvailable ? "quoted words" : "Position unavailable"))
        return parts.joined(separator: " · ")
    }
}

/// A record (and its revision) a link or node comes from.
public nonisolated struct CaseMapOrigin: Hashable, Sendable {
    public let kind: CaseMapRecordKind
    public let recordID: String
    public let revision: String?
    public init(_ kind: CaseMapRecordKind, _ recordID: String, revision: String? = nil) {
        self.kind = kind; self.recordID = recordID.lowercased(); self.revision = revision
    }
    var key: String { "\(kind.rawValue):\(recordID)@\(revision ?? "-")" }
}

public nonisolated struct CaseMapNode: Identifiable, Hashable, Sendable {
    public let id: CaseMapNodeID
    /// The record's current revision (a source version, a record revision or a decision id); not identity.
    public let revision: String?
    public let kind: CaseMapNodeKind
    public let title: String
    /// The record's exact wording (statement text, quote, allegation, note) as stored.
    public let wording: String?
    public let status: CaseMapStatus
    public let review: CaseMapReviewState
    public let sources: [CaseMapSourceRef]
    public let author: CaseMapAssertion?
    public let recordedAt: Date?
    /// For events: when it happened, as recorded (never inferred here).
    public let eventDate: Date?
    /// Every recorded review decision, oldest first, as plain lines.
    public let history: [String]
    /// Set when a source behind it changed since it was decided or carried.
    public let changedSourceWarning: String?
    /// Verified documentary support (a verified passage or a live exhibit). A note is never documentary.
    public let isDocumentary: Bool
    /// v176 — a point's qualifications (uncertainty, limitation, exclusion, condition), as lines that travel with it.
    public var qualifications: [String] = []
    /// SRC-10 — the evidential origins its sources come from, the copies of each in the case, and the other records
    /// that cite the same origin (repeated references are shown, never counted as independent corroboration).
    public var dependence: CaseMapSourceDependence? = nil
    /// S3 (TIME-02 on the map) — how precise `eventDate` is and the source's own wording (nil: not recorded). A day-precision
    /// date is never shown with a time.
    public var datePrecision: DatePrecision? = nil
    public var dateText: String? = nil
    /// S5 (TIME-02 on the map) — a range end, the date's qualifier and the time zone it was read in, as recorded.
    public var dateEnd: Date? = nil
    public var dateQualifier: CaseTimeQualifier? = nil
    public var dateTimeZone: String? = nil
    /// The recorded time as a time value (nil: no date).
    public var timeValue: CaseTimeValue? {
        guard let d = eventDate else { return nil }
        return CaseTimeValue(start: d, end: dateEnd, precision: datePrecision ?? .unknown,
                             qualifier: dateQualifier ?? (dateEnd != nil ? .between : .stated), timeZoneID: dateTimeZone, originalText: dateText)
    }
    /// S3 (MAP-06/07) — a money movement's amount in its own currency.
    public var money: CaseMapMoney? = nil
    /// S3 (BRIEF-03/07) — for work (tasks and evidence requests): whether it is still open, and whether its task status is
    /// "blocked". Nil for anything that is not work. Kept apart from evidential and review states.
    public var workOpen: Bool? = nil
    public var workBlocked: Bool = false

    /// The recorded date as it may be shown, at its own precision, with the source's wording.
    public var dateLabel: String? {
        guard let d = eventDate else {
            // S12 (HELP-11) — a date kept only as written is shown as written, never converted.
            if let t = dateText?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { return "“\(t)” (as written; not placed in order)" }
            return nil
        }
        if dateEnd != nil || (dateQualifier != nil && dateQualifier != .stated) || dateTimeZone != nil { return timeValue?.label() }
        let p = datePrecision ?? .unknown
        var out: String
        switch p {
        case .decade, .year: out = d.formatted(.dateTime.year())
        case .quarter, .month: out = d.formatted(.dateTime.year().month(.wide))
        case .minute, .instant: out = d.formatted(date: .abbreviated, time: .shortened)
        case .day, .unknown: out = d.formatted(date: .abbreviated, time: .omitted)
        }
        if p == .unknown { out += " (precision not recorded)" }
        if let t = dateText?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { out += " — “\(t)”" }
        return out
    }
}

public nonisolated struct CaseMapLink: Identifiable, Hashable, Sendable {
    /// Stable: a digest of the type, the endpoints and the origin records (not of row order or time).
    public let id: String
    public let caseID: UUID
    public let from: CaseMapNodeID
    public let to: CaseMapNodeID
    public let type: CaseMapLinkType
    public let origins: [CaseMapOrigin]
    public let sources: [CaseMapSourceRef]
    public let assertedBy: CaseMapAssertion
    public let review: CaseMapReviewState
    public let status: CaseMapStatus
    /// Why this connection exists, in words (the recorded rationale or the record it comes from).
    public let basis: String
    /// GRAPH-04 / GRAPH-08 — the stated certainty, when it holds, when it was recorded, and the link it revises.
    public var certainty: CaseMapCertainty = .notStated
    public var validity: CaseMapValidity? = nil
    public var recordedAt: Date? = nil
    public var revisesLinkID: UUID? = nil
    public var directed: Bool { type.directed }

    static func makeID(type: CaseMapLinkType, from: CaseMapNodeID, to: CaseMapNodeID, origins: [CaseMapOrigin]) -> String {
        let canonical = ([type.rawValue, from.key, to.key] + origins.map { "\($0.kind.rawValue):\($0.recordID)" }.sorted()).joined(separator: "|")
        // The same lower-case hex as String(format: "%02x") per byte, without a format call per byte (M9 §13.3:
        // building link ids was the largest part of a projection at 50,000 records).
        var hex: [UInt8] = []
        hex.reserveCapacity(32)
        for b in SHA256.hash(data: Data(canonical.utf8)).prefix(16) {
            hex.append(hexDigits[Int(b >> 4)]); hex.append(hexDigits[Int(b & 0x0f)])
        }
        return "link-" + String(decoding: hex, as: UTF8.self)
    }
    private static let hexDigits: [UInt8] = Array("0123456789abcdef".utf8)
}

/// A structural group: it summarises (and names) its members; it states nothing new.
public nonisolated struct CaseMapGroup: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let kind: CaseMapNodeKind?
    public let members: [CaseMapNodeID]
    public static let unlinkedID = "group:unlinked"
}

// MARK: - Loading state

/// The parts of a case the map reads; each loads or fails on its own.
public nonisolated enum CaseMapPart: String, Sendable, CaseIterable, Hashable {
    case caseFile, documents, contradictions, hypotheses, requests, investigatorLinks, reports, money
    public var label: String {
        switch self {
        case .money: return "money movements"
        case .reports: return "reports, points and action contracts"
        case .caseFile: return "the case file"
        case .documents: return "the case's documents"
        case .contradictions: return "contradictions"
        case .hypotheses: return "hypotheses and leads"
        case .requests: return "evidence requests"
        case .investigatorLinks: return "your map links"
        }
    }
}

public nonisolated enum CaseMapPartState: Hashable, Sendable {
    case loaded
    case failed(String)
    case unavailable(String)
    public var isLoaded: Bool { if case .loaded = self { return true }; return false }
}

/// What the person sees about the load as a whole — never a failed read shown as an empty case.
public nonisolated enum CaseMapLoadState: Hashable, Sendable {
    /// Everything was read and the case holds nothing to map yet.
    case empty
    /// Everything was read.
    case complete
    /// Some parts could not be read; what is shown is incomplete and says which.
    case partial([CaseMapPart])
    /// The case itself could not be read: nothing is shown as if it were the case.
    case failed(String)
    /// The case changed while it was being read twice in a row; what is shown may mix two states.
    case stale(String)
}

// MARK: - Input from the canonical services

/// One of the case's documents: its stable logical source, the version in the case and the read document.
public nonisolated struct CaseMapDocument: Hashable, Sendable {
    public let sourceVersionID: UUID
    public let logicalSourceID: UUID
    public let name: String?
    public let objectID: UUID?
    public let isCurrent: Bool
    /// SRC-10 — the version's independence key (one message thread, or identical content): documents sharing it are
    /// copies of one evidential origin. Nil when no reliable identity is known (the document is its own origin).
    public var independenceKey: String? = nil
    /// S14 (QA-15) — set when the version is in the case but the app could not read it (a failed scan, an unsupported or
    /// damaged file): why. The map shows it as not read; it is never counted as read or searched. Nil: read (or unknown).
    public var notReadReason: String? = nil
    public init(sourceVersionID: UUID, logicalSourceID: UUID, name: String?, objectID: UUID?, isCurrent: Bool, independenceKey: String? = nil,
                notReadReason: String? = nil) {
        self.sourceVersionID = sourceVersionID; self.logicalSourceID = logicalSourceID; self.name = name
        self.objectID = objectID; self.isCurrent = isCurrent; self.independenceKey = independenceKey
        self.notReadReason = notReadReason
    }
}

/// A hypothesis with the citations recorded for and against it.
public nonisolated struct CaseMapHypothesis: Equatable, Sendable {
    public let hypothesis: InvestigationHypothesis
    public let evidence: [HypothesisEvidenceLink]
    public init(hypothesis: InvestigationHypothesis, evidence: [HypothesisEvidenceLink]) { self.hypothesis = hypothesis; self.evidence = evidence }
}

/// A link the investigator drew on the map (v171 case_map_links) — the only links with no other home.
public nonisolated struct CaseMapInvestigatorLink: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let caseID: UUID
    public let type: CaseMapLinkType
    public let from: CaseMapNodeID
    public let to: CaseMapNodeID
    public let rationale: String
    public let createdBy: String
    public let createdAt: Date
    public let withdrawnBy: String?
    public let withdrawnAt: Date?
    public let withdrawnReason: String?
    /// v179 (GRAPH-04/08) — stated certainty, validity and the link this one revises.
    public var certainty: CaseMapCertainty = .notStated
    public var validity: CaseMapValidity? = nil
    public var revisesLinkID: UUID? = nil
    public var isActive: Bool { withdrawnAt == nil }
}

/// Everything the projection reads. A nil part was not read (its state says why).
public nonisolated struct CaseMapInput: Sendable {
    public var snapshot: CaseFileSnapshot
    public var documents: [CaseMapDocument]
    public var contradictions: [CaseContradictionReviewItem]
    public var hypotheses: [CaseMapHypothesis]
    public var requests: [EvidenceRequestFile]
    public var investigatorLinks: [CaseMapInvestigatorLink]
    /// v176 — the case's supplied reports, their points and qualifications, work links and action contracts.
    public var reportLedger: CaseReportLedger
    /// S3 (MAP-06) — the money movements read from the case's documents (one transaction per real payment).
    public var money: [FundsTransaction] = []
    /// S7 (MONEY-01) — the case's canonical financial records (accounts, holders, money records). Nil: not read.
    public var moneyLedger: CaseMoneyLedger? = nil
    public var parts: [CaseMapPart: CaseMapPartState]
    public init(snapshot: CaseFileSnapshot, documents: [CaseMapDocument] = [], contradictions: [CaseContradictionReviewItem] = [],
                hypotheses: [CaseMapHypothesis] = [], requests: [EvidenceRequestFile] = [], investigatorLinks: [CaseMapInvestigatorLink] = [],
                reportLedger: CaseReportLedger = CaseReportLedger(), parts: [CaseMapPart: CaseMapPartState] = [:]) {
        self.snapshot = snapshot; self.documents = documents; self.contradictions = contradictions; self.hypotheses = hypotheses
        self.requests = requests; self.investigatorLinks = investigatorLinks; self.reportLedger = reportLedger; self.parts = parts
    }
}

// MARK: - The projection

public nonisolated struct CaseMapProjection: Sendable {
    public let caseID: UUID
    public let title: String
    public let stage: CaseStage
    public let isClosed: Bool
    /// The question the investigation is to answer (purpose, else what was reported); nil when not recorded.
    public let question: String?
    public let nodes: [CaseMapNode]
    public let links: [CaseMapLink]
    public let groups: [CaseMapGroup]
    public let parts: [CaseMapPart: CaseMapPartState]
    /// Investigator links whose endpoint is no longer in this case (shown as a count, never drawn to nothing).
    public let danglingLinks: Int
    /// Withdrawn investigator links (kept in the ledger, not drawn).
    public let withdrawnLinks: Int
    /// S15 (ARCH-10) — the case's money figures as the ONE money service computes them (CaseMoneyLedger.figures()): the map
    /// shows these lines, never its own sum of the items it draws. Empty when no money ledger was loaded.
    public internal(set) var moneyFigures: [CaseMoneyFigureLine] = []
    private let index: [CaseMapNodeID: Int]
    /// M9 (§13.3): link id → position, and each item's links by position, so a lookup is not a scan of every
    /// link (the stress case holds tens of thousands).
    private let linkIndex: [String: Int]
    private let adjacency: [CaseMapNodeID: [Int]]

    init(caseID: UUID, title: String, stage: CaseStage, isClosed: Bool, question: String?, nodes: [CaseMapNode], links: [CaseMapLink],
         groups: [CaseMapGroup], parts: [CaseMapPart: CaseMapPartState], danglingLinks: Int, withdrawnLinks: Int) {
        self.caseID = caseID; self.title = title; self.stage = stage; self.isClosed = isClosed; self.question = question
        self.nodes = nodes; self.links = links; self.groups = groups; self.parts = parts
        self.danglingLinks = danglingLinks; self.withdrawnLinks = withdrawnLinks
        var idx: [CaseMapNodeID: Int] = [:]
        for (i, n) in nodes.enumerated() { idx[n.id] = i }
        self.index = idx
        var lidx: [String: Int] = [:]
        var adj: [CaseMapNodeID: [Int]] = [:]
        for (i, l) in links.enumerated() {
            if lidx[l.id] == nil { lidx[l.id] = i }
            adj[l.from, default: []].append(i)
            if l.to != l.from { adj[l.to, default: []].append(i) }
        }
        self.linkIndex = lidx
        self.adjacency = adj
    }

    public func node(_ id: CaseMapNodeID) -> CaseMapNode? { index[id].map { nodes[$0] } }
    public func link(_ id: String) -> CaseMapLink? { linkIndex[id].map { links[$0] } }
    /// The links that touch an item, in the projection's link order.
    public func links(of id: CaseMapNodeID) -> [CaseMapLink] { (adjacency[id] ?? []).map { links[$0] } }
    public var failedParts: [CaseMapPart] {
        CaseMapPart.allCases.filter { parts[$0].map { !$0.isLoaded } ?? false }
    }
    /// How the whole load reads.
    public var loadState: CaseMapLoadState {
        let failed = failedParts
        if !failed.isEmpty { return .partial(failed) }
        return nodes.count <= 1 ? .empty : .complete   // the case question alone is an empty case
    }
    public func count(_ kind: CaseMapNodeKind) -> Int { nodes.filter { $0.kind == kind }.count }
    /// Material nothing links to.
    public var unlinked: [CaseMapNodeID] { groups.first { $0.id == CaseMapGroup.unlinkedID }?.members ?? [] }
}

/// Builds the projection from the canonical records. Deterministic: the same records in any order give
/// the same nodes, links and identities.
public nonisolated enum CaseMapProjector {

    /// The structural groups of a set of items: one per kind, and the material nothing links to. Used for a
    /// live projection and for a recorded state rebuilt from a checkpoint (M7), so both group alike.
    static func groups(_ sortedNodes: [CaseMapNode], _ sortedLinks: [CaseMapLink]) -> [CaseMapGroup] {
        var linked = Set<CaseMapNodeID>()
        for l in sortedLinks { linked.insert(l.from); linked.insert(l.to) }
        // One pass over the items (M9 §13.3), each kind's members kept in item order.
        var byKind: [CaseMapNodeKind: [CaseMapNodeID]] = [:]
        var unlinked: [CaseMapNodeID] = []
        for n in sortedNodes {
            byKind[n.kind, default: []].append(n.id)
            if n.kind.isMaterial && !linked.contains(n.id) { unlinked.append(n.id) }
        }
        var groups: [CaseMapGroup] = CaseMapNodeKind.allCases.compactMap { k in
            guard let members = byKind[k], !members.isEmpty else { return nil }
            return CaseMapGroup(id: "group:\(k.rawValue)", title: k.plural, kind: k, members: members)
        }
        groups.append(CaseMapGroup(id: CaseMapGroup.unlinkedID, title: "Unlinked material", kind: nil, members: unlinked))
        return groups
    }

    public static func project(_ input: CaseMapInput) -> CaseMapProjection { project(input, reusing: nil).projection }

    /// `kept` (already in order) and `added` (any order, none of them in `kept`) as one ordered list.
    static func mergeOrdered<T>(kept: [T], added: [T], by less: (T, T) -> Bool) -> [T] {
        guard !added.isEmpty else { return kept }
        let b = added.sorted(by: less)
        var out: [T] = []
        out.reserveCapacity(kept.count + b.count)
        var i = 0, j = 0
        while i < kept.count, j < b.count {
            if less(b[j], kept[i]) { out.append(b[j]); j += 1 } else { out.append(kept[i]); i += 1 }
        }
        out += kept[i...]; out += b[j...]
        return out
    }

    /// The projection, reusing what an earlier projection of the same case built for chronology entries that are
    /// unchanged (M9 §13.3: a refresh that adds 100 entries builds those 100, not all 50,000). An entry's item and
    /// links are reused only when the entry, its verification marks, whether its origin is superseded and the
    /// case's documents are all exactly as they were — the same inputs give the same output, so the result is
    /// identical to projecting from scratch. Returns the memo for the next refresh.
    public static func project(_ input: CaseMapInput, reusing memo: CaseMapProjectionMemo?) -> (projection: CaseMapProjection, memo: CaseMapProjectionMemo) {
        let s = input.snapshot
        let caseID = s.caseHeader.id
        let reuse = memo.flatMap { $0.caseID == caseID && $0.documents == input.documents ? $0.journal : nil } ?? [:]
        var nextJournal: [UUID: CaseMapProjectionMemo.JournalPiece] = [:]
        nextJournal.reserveCapacity(s.journal.count)
        var reusedEntries = 0
        var nodes: [CaseMapNodeID: CaseMapNode] = [:]
        var links: [String: CaseMapLink] = [:]
        nodes.reserveCapacity(s.journal.count + input.documents.count + s.people.count + s.grid.count + 16)
        links.reserveCapacity(s.journal.count + s.grid.count + 16)
        func id(_ kind: CaseMapRecordKind, _ uuid: UUID) -> CaseMapNodeID { CaseMapNodeID(caseID: caseID, kind: kind, id: uuid) }
        func add(_ n: CaseMapNode) { nodes[n.id] = n }
        @discardableResult
        func link(_ type: CaseMapLinkType, _ from: CaseMapNodeID, _ to: CaseMapNodeID, origins: [CaseMapOrigin], sources: [CaseMapSourceRef],
                  by: CaseMapAssertion, review: CaseMapReviewState, status: CaseMapStatus, basis: String) -> CaseMapLink? {
            guard from != to else { return nil }
            let lid = CaseMapLink.makeID(type: type, from: from, to: to, origins: origins)
            let l = CaseMapLink(id: lid, caseID: caseID, from: from, to: to, type: type, origins: origins, sources: sources,
                                assertedBy: by, review: review, status: status, basis: basis)
            links[lid] = l
            return l
        }

        // Documents: identity is the logical source (stable across re-ingest); the revision is the version.
        let docsByLogical = Dictionary(grouping: input.documents, by: \.logicalSourceID)
        var docForVersion: [UUID: CaseMapNodeID] = [:]
        var docForObject: [UUID: CaseMapNodeID] = [:]
        var nameForVersion: [UUID: String] = [:]
        var objectForVersion: [UUID: UUID] = [:]
        /// The version each document is shown at (its current version in the case) — v176 points cut from another are stale.
        var shownVersion: [CaseMapNodeID: UUID] = [:]
        for (logical, versions) in docsByLogical {
            let ordered = versions.sorted { ($0.isCurrent ? 0 : 1, $0.sourceVersionID.uuidString) < ($1.isCurrent ? 0 : 1, $1.sourceVersionID.uuidString) }
            guard let current = ordered.first else { continue }
            let nid = id(.document, logical)
            shownVersion[nid] = current.sourceVersionID
            for v in ordered {
                docForVersion[v.sourceVersionID] = nid
                if let o = v.objectID { docForObject[o] = nid; objectForVersion[v.sourceVersionID] = o }
                if let n = v.name { nameForVersion[v.sourceVersionID] = n }
            }
            let name = current.name ?? "Document \(logical.uuidString.prefix(8))"
            let older = ordered.count - 1
            // S14 (QA-15): a document in the case that the app could not read is shown as such, with its reason.
            let docStatus: CaseMapStatus = current.objectID == nil && current.notReadReason != nil
                ? CaseMapStatus(.failed, "In the case, not read — \(current.notReadReason ?? ""); not searched, quoted or counted as read")
                : .recorded(older > 0 ? "In the case — \(older) other version(s) also in scope" : "In the case")
            add(CaseMapNode(id: nid, revision: current.sourceVersionID.uuidString.lowercased(), kind: .evidence, title: name, wording: nil,
                            status: docStatus,
                            review: .notApplicable,
                            sources: ordered.map { CaseMapSourceRef(sourceVersionID: $0.sourceVersionID, objectID: $0.objectID, documentName: $0.name, quote: nil) },
                            author: nil, recordedAt: nil, eventDate: nil, history: [], changedSourceWarning: nil,
                            // A document's presence is not support for anything it states.
                            isDocumentary: false))
        }
        func docNode(version: UUID?, object: UUID?) -> CaseMapNodeID? {
            if let version, let d = docForVersion[version] { return d }
            if let object, let d = docForObject[object] { return d }
            return nil
        }
        func source(_ ref: StudioEvidenceRef) -> CaseMapSourceRef {
            CaseMapSourceRef(sourceVersionID: ref.sourceVersionID, objectID: ref.objectID ?? ref.sourceVersionID.flatMap { objectForVersion[$0] },
                             blockID: ref.blockID, documentName: ref.sourceVersionID.flatMap { nameForVersion[$0] }, quote: ref.quote)
        }
        /// The honest state of a stored verification, told apart: restricted (in the case, not readable under
        /// the policy), unavailable (not in the case), unassessed (never checked), failed (unreadable).
        func status(of support: CaseEvidenceSupport, version: UUID?) -> CaseMapStatus {
            switch support {
            case .documentary: return .recorded("Verified passage")
            case .exhibit(let n): return .recorded("Exhibit \(n) on the live register")
            case .note: return CaseMapStatus(.unsupported, "Investigator's note — not documentary support")
            case .unverified(let why):
                if why.contains("could not be read") { return CaseMapStatus(.failed, why) }
                if why.contains("before passage verification existed") { return CaseMapStatus(.unassessed, why) }
                if why.contains("not in this case or is not accessible") {
                    let inCase = version.map { docForVersion[$0] != nil } ?? false
                    return inCase ? CaseMapStatus(.restricted, "The source is in this case but not readable under the current access policy")
                                  : CaseMapStatus(.unavailable, "The cited source is not in this case")
                }
                if why.contains("not on this case's live register") { return CaseMapStatus(.unavailable, why) }
                return CaseMapStatus(.unsupported, why)
            }
        }
        func carried(_ state: String?) -> CaseMapReviewState {
            switch state.flatMap(CarriedReviewState.init(rawValue:)) {
            case .accepted?: return .accepted
            case .completed?: return .completed
            case .undecided?: return .unreviewed
            case .rejected?: return .rejected
            case nil:
                if state == "confirmed" { return .confirmed }
                return .notApplicable
            }
        }

        // The case and its question.
        let purpose = s.caseHeader.purpose?.trimmingCharacters(in: .whitespacesAndNewlines)
        let reported = s.profile.intake.allegationSummary?.trimmingCharacters(in: .whitespacesAndNewlines)
        let question = (purpose?.isEmpty == false ? purpose : nil) ?? (reported?.isEmpty == false ? reported : nil)
        let caseNode = id(.caseFile, caseID)
        add(CaseMapNode(id: caseNode, revision: String(s.caseHeader.revision), kind: .question, title: s.caseHeader.title,
                        wording: question, status: .recorded(question == nil ? "No question recorded yet" : "The question this case is to answer"),
                        review: .notApplicable, sources: [], author: .investigator(s.caseHeader.actor), recordedAt: s.caseHeader.createdAt,
                        eventDate: nil, history: [], changedSourceWarning: nil, isDocumentary: false))

        // Allegations (the case's questions).
        for a in s.allegations {
            let decided = a.disposition != .pending
            add(CaseMapNode(id: id(.allegation, a.id), revision: a.decidedAt.map { String($0.timeIntervalSince1970) }, kind: .question,
                            title: "\(a.label) — \(a.text)", wording: a.text,
                            status: .recorded(decided ? "\(a.disposition.label)" + (a.decidedBy.map { " — decided by \($0)" } ?? "") : "Open — not decided"),
                            review: decided ? .confirmed : .unreviewed, sources: [], author: nil, recordedAt: a.createdAt, eventDate: nil,
                            history: decided ? ["\(a.disposition.label) by \(a.decidedBy ?? "—")" + (a.rationale.map { ": \($0)" } ?? "")] : [],
                            changedSourceWarning: nil, isDocumentary: false))
        }

        // The evidence grid: one link per stored row. A typed note becomes a note node, never a document.
        // M9 (§13.3): look-ups by key, not a scan per row.
        let exhibitByNumber = Dictionary(s.exhibits.map { ($0.number, $0.id) }, uniquingKeysWith: { a, _ in a })
        let allegationLabel = Dictionary(s.allegations.map { ($0.id, $0.label) }, uniquingKeysWith: { a, _ in a })
        for e in s.grid {
            let target = id(.allegation, e.allegationID)
            guard nodes[target] != nil else { continue }
            let support = e.support
            let ref = CaseEvidenceReference.parse(e.evidenceRef)
            var fromNode: CaseMapNodeID?
            switch ref {
            case .sourceVersion(let v): fromNode = docNode(version: v, object: e.objectID)
            case .exhibit(let n): fromNode = exhibitByNumber[n].map { id(.exhibit, $0) }
            case .investigatorNote, .unresolved: fromNode = nil
            }
            if fromNode == nil {
                // A note or a reference that no longer resolves: its own node, labelled as what it is.
                let nid = id(.allegationEvidence, e.id)
                let isNote: Bool = { if case .investigatorNote = ref { return true }; return false }()
                add(CaseMapNode(id: nid, revision: nil, kind: isNote ? .note : .evidence,
                                title: e.label ?? (isNote ? "Note on \(e.allegationID.uuidString.prefix(4))" : e.evidenceRef),
                                wording: e.note ?? e.quote,
                                status: isNote ? CaseMapStatus(.unsupported, "Investigator's note — not documentary support")
                                               : CaseMapStatus(.unavailable, "The reference \(e.evidenceRef) does not resolve in this case"),
                                review: .notApplicable, sources: [], author: .investigator(e.addedBy), recordedAt: e.createdAt, eventDate: nil,
                                history: [], changedSourceWarning: nil, isDocumentary: false))
                fromNode = nid
            }
            guard let from = fromNode else { continue }
            // S5 (REASON-02) — the row's relation, so a qualification or an unassessed row is not drawn as a plain mention.
            let type: CaseMapLinkType = {
                switch e.relation {
                case .supports: return .supports
                case .challenges: return .challenges
                case .mentions: return .mentions
                case .qualifies: return .qualifies
                case .unassessed: return .relevanceUnassessed
                }
            }()
            var st = status(of: support, version: e.passage?.sourceVersionID)
            if s.isSuperseded(e.origin) { st = CaseMapStatus(.stale, "Carried from a result revision that is no longer the current one") }
            let src = e.passage.map(source) ?? (e.objectID.map { CaseMapSourceRef(sourceVersionID: nil, objectID: $0, blockID: e.blockID, documentName: nil, quote: e.quote) })
            link(type, from, target, origins: [CaseMapOrigin(.allegationEvidence, e.id.uuidString, revision: e.originDigest)],
                 sources: src.map { [$0] } ?? [], by: .investigator(e.addedBy), review: carried(e.reviewState), status: st,
                 basis: "Evidence grid row for \(allegationLabel[e.allegationID] ?? "the allegation")"
                    + (e.note.map { ": \($0)" } ?? "") + (e.origin.map { " (carried from \($0))" } ?? ""))
        }

        // People. Same name is not same person: each case-person row is its own node; a same-name pair whose
        // links do not tell them apart is offered as "possibly the same person", pending review.
        // v182 (PEOPLE-01): one row is one person; every role they hold is listed on it (none implies wrongdoing).
        var extraRoles: [UUID: [String]] = [:]
        for r in input.reportLedger.personRoles where r.caseID == caseID && r.isActive { extraRoles[r.personID, default: []].append(r.line) }
        for p in s.people {
            let roles = ([p.role.label] + (extraRoles[p.id] ?? [])).joined(separator: "; ")
            add(CaseMapNode(id: id(.person, p.id), revision: nil, kind: .person, title: p.name, wording: p.notes,
                            status: .recorded(roles + (p.entityID == nil ? " — not linked to a person in the documents" : "")),
                            review: .notApplicable, sources: [], author: nil, recordedAt: p.createdAt, eventDate: nil, history: [],
                            changedSourceWarning: nil, isDocumentary: false))
        }
        // v179 (GRAPH-09): a recorded decision about a pair replaces the rule's suggestion; both rows stay as they are.
        var decided: [String: CasePersonIdentityDecision] = [:]
        for d in input.reportLedger.identityDecisions where d.caseID == caseID && d.isActive { decided[d.pairKey] = d }
        for d in decided.values.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            let a = id(.person, d.personA), b = id(.person, d.personB)
            guard nodes[a] != nil, nodes[b] != nil else { continue }
            let same = d.decision == .samePerson
            link(same ? .samePersonDecided : .possibleSamePerson, a, b, origins: [CaseMapOrigin(.identityDecision, d.id.uuidString)], sources: [],
                 by: .investigator(d.decidedBy), review: same ? .confirmed : .dismissed,
                 status: .recorded(same ? "Recorded as the same person by \(d.decidedBy)" : "Recorded as different people by \(d.decidedBy)"),
                 basis: (same ? "Decided: the same person. " : "Decided: different people. ") + d.rationale
                    + " Both rows keep their own statements, links and history; withdrawing the decision puts the pair back to pending.")
        }
        let byName = Dictionary(grouping: s.people) { $0.name.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ") }
        for (_, same) in byName where same.count > 1 {
            let sorted = same.sorted { $0.id.uuidString < $1.id.uuidString }
            for i in 0..<sorted.count { for j in (i + 1)..<sorted.count {
                let a = sorted[i], b = sorted[j]
                if decided[CasePersonIdentityDecision.pairKey(a.id, b.id)] != nil { continue }   // decided: the decision is the link
                if let ea = a.entityID, let eb = b.entityID, ea != eb { continue }   // linked to different people: distinct
                if let ea = a.entityID, let eb = b.entityID, ea == eb {
                    link(.possibleSamePerson, id(.person, a.id), id(.person, b.id), origins: [CaseMapOrigin(.rule, "same-entity")], sources: [],
                         by: .rule("both rows are linked to the same person in the documents"), review: .pendingReview,
                         status: .recorded("Linked to the same person in the documents — still two rows until you merge them"),
                         basis: "Both case-person rows name the same person in the documents.")
                    continue
                }
                link(.possibleSamePerson, id(.person, a.id), id(.person, b.id), origins: [CaseMapOrigin(.rule, "same-name")], sources: [],
                     by: .rule("same name"), review: .pendingReview,
                     status: CaseMapStatus(.unassessed, "Same name only — not evidence that they are the same person"),
                     basis: "The two rows have the same name. A name alone does not make them the same person.")
            }}
        }

        // Exhibits.
        for x in s.exhibits {
            let nid = id(.exhibit, x.id)
            let withdrawn = x.withdrawnAt != nil
            add(CaseMapNode(id: nid, revision: x.sha256, kind: .evidence, title: "Exhibit \(x.number) — \(x.description)", wording: x.description,
                            status: withdrawn ? CaseMapStatus(.unavailable, "Withdrawn from the exhibit register") : .recorded("Exhibit on the live register"),
                            review: .notApplicable, sources: [], author: x.collectedBy.map { .investigator($0) }, recordedAt: x.createdAt, eventDate: x.collectedAt,
                            history: [], changedSourceWarning: nil, isDocumentary: !withdrawn))
            if let ref = x.sourceRef, case .sourceVersion(let v) = CaseEvidenceReference.parse(ref), let d = docNode(version: v, object: nil) {
                link(.derivedFrom, nid, d, origins: [CaseMapOrigin(.exhibit, x.id.uuidString, revision: x.sha256)],
                     sources: [CaseMapSourceRef(sourceVersionID: v, objectID: objectForVersion[v], documentName: nameForVersion[v], quote: nil)],
                     by: .investigator(x.collectedBy ?? "the investigator"), review: .notApplicable, status: .recorded("Exhibit made from this document"),
                     basis: "Exhibit \(x.number) records this document as its source.")
            }
        }

        // Statements: interviews with an account, and corrections to attested statements.
        for i in s.interviews {
            let nid = id(.interview, i.id)
            let wording = i.statementText ?? i.summary
            let speaker = s.person(i.personID)?.name
            var st: CaseMapStatus = .recorded(i.status.label + (i.attestedBy.map { " — attested by \($0)" } ?? ""))
            if i.statementSHA256 != nil, !i.statementIntact { st = CaseMapStatus(.stale, "The statement changed after it was attested") }
            add(CaseMapNode(id: nid, revision: i.statementSHA256, kind: .statement,
                            title: "Statement" + (speaker.map { " of \($0)" } ?? "") + " (\(i.status.label.lowercased()))", wording: wording,
                            status: st, review: i.attestedBy != nil ? .confirmed : .notApplicable, sources: [], author: nil, recordedAt: i.createdAt,
                            eventDate: i.scheduledAt, history: [], changedSourceWarning: nil, isDocumentary: false))
            if let pid = i.personID, nodes[id(.person, pid)] != nil {
                link(.attributedTo, nid, id(.person, pid), origins: [CaseMapOrigin(.interview, i.id.uuidString)], sources: [],
                     by: .investigator("the interview record"), review: .notApplicable, status: .recorded("Speaker recorded on the interview"),
                     basis: "The interview names \(speaker ?? "this person") as the person interviewed (direct account).")
            }
            for ref in [i.transcriptRef, i.recordingRef].compactMap({ $0 }) {
                if case .sourceVersion(let v) = CaseEvidenceReference.parse(ref), let d = docNode(version: v, object: nil) {
                    link(.derivedFrom, nid, d, origins: [CaseMapOrigin(.interview, i.id.uuidString)],
                         sources: [CaseMapSourceRef(sourceVersionID: v, objectID: objectForVersion[v], documentName: nameForVersion[v], quote: nil)],
                         by: .investigator("the interview record"), review: .notApplicable, status: .recorded("Recording or transcript of the interview"),
                         basis: "The interview names this document as its recording or transcript.")
                }
            }
        }
        for a in s.addenda {
            let nid = id(.addendum, a.id)
            add(CaseMapNode(id: nid, revision: a.sha256, kind: .statement, title: "Correction to a statement", wording: a.text,
                            status: a.intact ? .recorded(a.confirmedBy.map { "Confirmed by \($0)" } ?? "Recorded, not yet confirmed by the interviewee")
                                             : CaseMapStatus(.stale, "The correction's text does not match its fingerprint"),
                            review: a.confirmedBy != nil ? .confirmed : .unreviewed, sources: [], author: .investigator(a.recordedBy),
                            recordedAt: a.recordedAt, eventDate: nil, history: [], changedSourceWarning: nil, isDocumentary: false))
            if nodes[id(.interview, a.interviewID)] != nil {
                link(.supersedes, nid, id(.interview, a.interviewID), origins: [CaseMapOrigin(.addendum, a.id.uuidString, revision: a.sha256)],
                     sources: [], by: .investigator(a.recordedBy), review: a.confirmedBy != nil ? .confirmed : .unreviewed,
                     status: .recorded("Correction: \(a.reason)"), basis: "A correction recorded against the attested statement: \(a.reason)")
            }
        }

        // Chronology entries (events) and notes.
        let attestationsByEntry = Dictionary(grouping: s.attestations, by: \.journalEntryID)
        for e in s.journal {
            let attest = attestationsByEntry[e.id] ?? []
            let superseded = s.isSuperseded(e.origin)
            if let piece = reuse[e.id], piece.entry == e, piece.attestations == attest, piece.superseded == superseded {
                add(piece.node)
                for l in piece.links { links[l.id] = l }
                nextJournal[e.id] = piece
                reusedEntries += 1
                continue
            }
            let nid = id(.journal, e.id)
            let refs = e.citations.isEmpty
                ? (e.evidenceRef.flatMap { r -> StudioEvidenceRef? in
                    if case .sourceVersion(let v) = CaseEvidenceReference.parse(r) { return StudioEvidenceRef(sourceVersionID: v, objectID: objectForVersion[v], quote: e.quote) }
                    return nil } .map { [$0] } ?? [])
                : e.citations
            let isNote = e.kind == .note
            var st = isNote ? CaseMapStatus(.unsupported, "Investigator's note — not documentary support")
                            : (refs.isEmpty ? CaseMapStatus(.unsupported, "An entry with no cited source") : status(of: e.support, version: refs.first?.sourceVersionID))
            if superseded { st = CaseMapStatus(.stale, "Carried from a result revision that is no longer the current one") }
            var node = CaseMapNode(id: nid, revision: e.originDigest, kind: isNote ? .note : .event,
                            title: isNote ? "Note — \(String(e.text.prefix(60)))" : String(e.text.prefix(80)), wording: e.text,
                            status: st, review: carried(e.reviewState), sources: refs.map(source), author: .investigator(e.author),
                            recordedAt: e.createdAt, eventDate: isNote ? nil : e.eventDate,
                            history: attest.map { "\($0.state.rawValue.capitalized) by \($0.attestedBy) on \($0.attestedAt.formatted(date: .abbreviated, time: .omitted))" },
                            changedSourceWarning: superseded ? "The result revision this entry came from was replaced." : nil,
                            isDocumentary: !isNote && !refs.isEmpty && e.support.isDocumentary)
            if !isNote {
                node.datePrecision = e.datePrecision; node.dateText = e.dateText
                node.dateEnd = e.dateEnd; node.dateQualifier = e.dateQualifier; node.dateTimeZone = e.dateTimeZone
            }
            add(node)
            var made: [CaseMapLink] = []
            for ref in refs {
                guard let d = docNode(version: ref.sourceVersionID, object: ref.objectID) else { continue }
                if let l = link(isNote ? .mentions : .derivedFrom, nid, d, origins: [CaseMapOrigin(.journal, e.id.uuidString, revision: e.originDigest)],
                                sources: [source(ref)], by: .investigator(e.author), review: carried(e.reviewState),
                                status: isNote ? CaseMapStatus(.unsupported, "A note citing this document is not documentary support") : st,
                                basis: isNote ? "The note cites this document." : "The chronology entry cites this passage.") {
                    made.append(l)
                }
            }
            nextJournal[e.id] = CaseMapProjectionMemo.JournalPiece(entry: e, attestations: attest, superseded: superseded, node: node, links: made)
        }

        // Hypotheses and leads with their citations.
        for h in input.hypotheses {
            let hy = h.hypothesis
            guard hy.caseID == caseID else { continue }
            let nid = id(.hypothesis, hy.id)
            add(CaseMapNode(id: nid, revision: String(hy.revision), kind: .hypothesis,
                            title: (hy.kind == .lead ? "Lead — " : "Hypothesis — ") + hy.statement, wording: hy.statement,
                            status: .recorded(hy.status.rawValue.capitalized + (hy.status == .proposed ? " — not decided" : " by \(hy.actor)")),
                            review: hy.status == .proposed ? .unreviewed : (hy.status == .confirmed ? .confirmed : .rejected),
                            sources: [], author: .investigator(hy.actor), recordedAt: hy.createdAt, eventDate: nil, history: [],
                            changedSourceWarning: nil, isDocumentary: false))
            for ev in h.evidence {
                guard let d = docNode(version: ev.sourceVersionID, object: ev.knowledgeObjectID) else { continue }
                link(ev.stance == .supporting ? .supports : .challenges, d, nid,
                     origins: [CaseMapOrigin(.hypothesisEvidence, ev.id.uuidString)],
                     sources: [CaseMapSourceRef(sourceVersionID: ev.sourceVersionID, objectID: ev.knowledgeObjectID, documentName: nameForVersion[ev.sourceVersionID], quote: nil)],
                     by: .investigator(ev.addedBy), review: .notApplicable,
                     status: docForVersion[ev.sourceVersionID] == nil ? CaseMapStatus(.stale, "Cited at a version no longer in the case") : .recorded("Cited \(ev.stance == .supporting ? "for" : "against")"),
                     basis: "Cited \(ev.stance == .supporting ? "for" : "against") the hypothesis" + (ev.note.map { ": \($0)" } ?? "") + ". A citation count does not decide it.")
            }
        }

        // Contradictions with their review state.
        for item in input.contradictions {
            let c = item.contradiction
            let nid = id(.contradiction, c.id)
            let review: CaseMapReviewState = item.status.isReopened ? .reopened : {
                switch item.status.current {
                case .confirmed?: return .confirmed
                case .dismissed?: return .dismissed
                case .deferred?: return .deferred
                case .explained?: return .explained
                case .unresolved?: return .unresolved
                case nil: return .unreviewed
                }
            }()
            let by: CaseMapAssertion = {
                switch CaseContradictionFinder.provenance(of: c) {
                case .rules?: return .rule("the case's contradiction rules")
                case .aiRead?: return .model("case contradiction reading")
                case nil: return .rule("the archive scan")
                }
            }()
            let changed = item.status.changedObjects.compactMap { o in docForObject[o].flatMap { nodes[$0]?.title } }
            add(CaseMapNode(id: nid, revision: item.status.latest?.id.uuidString.lowercased(), kind: .contradiction,
                            title: JobResultHandoff.reviewText(c), wording: "A: \u{201C}\(c.claimA)\u{201D}\nB: \u{201C}\(c.claimB)\u{201D}",
                            status: item.status.isReopened ? CaseMapStatus(.stale, item.status.label()) : .recorded(item.status.latest == nil ? "Suggested — not reviewed" : item.status.label()),
                            review: review,
                            sources: [(c.evidenceA, c.claimA), (c.evidenceB, c.claimB)].map { obj, quote in
                                let v = obj.flatMap { o in item.currentVersions[o] ?? nil }
                                return CaseMapSourceRef(sourceVersionID: v, objectID: obj, documentName: obj.flatMap { docForObject[$0].flatMap { nodes[$0]?.title } }, quote: quote)
                            },
                            author: by, recordedAt: c.detectedAt, eventDate: nil, history: item.status.history.map(\.summary),
                            changedSourceWarning: changed.isEmpty ? (item.status.isReopened ? "A document behind it changed since it was decided." : nil)
                                                                  : "Changed since the decision: \(changed.joined(separator: ", ")).",
                            isDocumentary: false))
            for (obj, quote, side) in [(c.evidenceA, c.claimA, "A"), (c.evidenceB, c.claimB, "B")] {
                guard let obj, let d = docForObject[obj] else { continue }
                let v = item.currentVersions[obj] ?? nil
                link(.derivedFrom, nid, d, origins: [CaseMapOrigin(.contradiction, c.id.uuidString, revision: item.status.latest?.id.uuidString)],
                     sources: [CaseMapSourceRef(sourceVersionID: v, objectID: obj, documentName: nodes[d]?.title, quote: quote)],
                     by: by, review: review,
                     status: item.status.changedObjects.contains(obj) ? CaseMapStatus(.stale, "This document changed since the decision") : .recorded("Side \(side)"),
                     basis: "Side \(side) of a possible contradiction. Suggested conflicts stay open until a person decides.")
            }
        }

        // Evidence requests: what they serve and what arrived (a duplicate is shown and not counted).
        for file in input.requests {
            let r = file.request
            guard r.caseID == caseID else { continue }
            let nid = id(.request, r.id)
            let progress = file.progress
            add(CaseMapNode(id: nid, revision: String(r.revision), kind: .action, title: "Request — \(r.description)",
                            wording: [r.description, r.custodian.map { "Custodian: \($0)" }, r.question.map { "Question: \($0)" }].compactMap { $0 }.joined(separator: "\n"),
                            status: .recorded(r.status.rawValue.capitalized + " — " + progress.summary),
                            review: r.status.isOutstanding ? .pendingReview : .confirmed, sources: [], author: .investigator(r.actor),
                            recordedAt: r.createdAt, eventDate: r.dueAt,
                            history: file.events.map { "\($0.kind.rawValue) by \($0.actor) on \($0.occurredAt.formatted(date: .abbreviated, time: .omitted))" + ($0.detail.map { ": \($0)" } ?? "") },
                            changedSourceWarning: nil, isDocumentary: false))
            nodes[nid]?.workOpen = r.status.isOutstanding
            if let a = r.allegationID, nodes[id(.allegation, a)] != nil {
                link(.requestsEvidenceFor, nid, id(.allegation, a), origins: [CaseMapOrigin(.request, r.id.uuidString, revision: String(r.revision))], sources: [],
                     by: .investigator(r.actor), review: .notApplicable, status: .recorded("Recorded on the request"), basis: "The request names this allegation.")
            }
            if let h = r.hypothesisID, nodes[id(.hypothesis, h)] != nil {
                link(.requestsEvidenceFor, nid, id(.hypothesis, h), origins: [CaseMapOrigin(.request, r.id.uuidString, revision: String(r.revision))], sources: [],
                     by: .investigator(r.actor), review: .notApplicable, status: .recorded("Recorded on the request"), basis: "The request names this hypothesis.")
            }
            for rec in file.receipts where rec.isActive {
                guard let d = docNode(version: rec.sourceVersionID, object: rec.knowledgeObjectID) else { continue }
                link(.receivedInResponseTo, d, nid, origins: [CaseMapOrigin(.requestReceipt, rec.id.uuidString)],
                     sources: [CaseMapSourceRef(sourceVersionID: rec.sourceVersionID, objectID: rec.knowledgeObjectID, documentName: nameForVersion[rec.sourceVersionID], quote: nil)],
                     by: .investigator(rec.linkedBy), review: .notApplicable,
                     status: rec.duplicateOf != nil ? .recorded("Duplicate of a document already received — not counted") : .recorded("Received"),
                     basis: "Linked as received for this request" + (rec.duplicateOf != nil ? " (a duplicate copy; it does not count towards the request)" : "")
                        + ". An arrival does not fulfil the request; fulfilment is a recorded decision.")
            }
        }

        // Tasks. v176: a task with an action contract shows its purpose, expected result, people, review and outcome —
        // the outcome and review are separate from the task's status (a completed task can leave its question open).
        let ledger = input.reportLedger
        let contractByTask = Dictionary(ledger.contracts.filter { $0.caseID == caseID }.map { ($0.taskID, $0) }, uniquingKeysWith: { a, _ in a })
        for t in s.tasks {
            let overdue = t.isOverdue(at: Date())
            let c = contractByTask[t.task.id]
            var st = t.task.status.rawValue.capitalized + (overdue ? " — overdue" : "")
            var review: CaseMapReviewState = .notApplicable
            var history: [String] = []
            if let c {
                st += " · " + c.review.label + " · " + c.outcome.label
                switch c.review {
                case .notSubmitted: review = .notApplicable
                case .submitted: review = .pendingReview
                case .returned: review = .unreviewed
                case .accepted: review = .accepted
                }
                if let by = c.reviewedBy, let at = c.reviewedAt, let kind = c.reviewKind {
                    history.append("\(c.review.label) by \(by) on \(at.formatted(date: .abbreviated, time: .omitted)) — \(kind.label)" + (c.reviewNote.map { ": \($0)" } ?? ""))
                }
                if c.outcome != .notRecorded { history.append("Outcome: \(c.outcome.label)" + (c.outcomeNote.map { " — \($0)" } ?? "")) }
            }
            let wording: String? = c.map { c in
                ["Purpose: \(c.purpose)", "Expected result: \(c.deliverable)", c.responsible.map { "Responsible: \($0)" },
                 c.reviewer.map { "Reviewer: \($0)" }, "Review: \(c.review.label)", "Outcome: \(c.outcome.label)" + (c.outcomeNote.map { " — \($0)" } ?? "")]
                    .compactMap { $0 }.joined(separator: "\n")
            } ?? t.task.detail
            add(CaseMapNode(id: id(.task, t.task.id), revision: c.map { String($0.updatedAt.timeIntervalSince1970) }, kind: .action,
                            title: (c == nil ? "Task — " : "Action — ") + t.task.title, wording: wording,
                            status: .recorded(st), review: review, sources: [], author: c.map { .investigator($0.createdBy) },
                            recordedAt: t.task.createdAt, eventDate: t.deadline?.value.date,
                            history: history, changedSourceWarning: nil, isDocumentary: false))
            nodes[id(.task, t.task.id)]?.workOpen = !ProfessionalTaskStatus.finished.contains(t.task.status)
            nodes[id(.task, t.task.id)]?.workBlocked = t.task.status == .blocked
        }
        // Child actions: each names its parent action, else the mother case (containment, acyclic by the write's check).
        for c in contractByTask.values.sorted(by: { $0.taskID.uuidString < $1.taskID.uuidString }) {
            let child = id(.task, c.taskID)
            guard nodes[child] != nil else { continue }
            let parent = c.parentTaskID.map { id(.task, $0) } ?? caseNode
            guard nodes[parent] != nil else { continue }
            link(.derivedFrom, child, parent, origins: [CaseMapOrigin(.actionContract, c.taskID.uuidString)], sources: [],
                 by: .investigator(c.createdBy), review: .notApplicable,
                 status: .recorded(c.parentTaskID == nil ? "An action of the mother case" : "A child action"),
                 basis: (c.parentTaskID == nil ? "An action of this case" : "A child action of this action") + " — purpose: \(c.purpose); expected result: \(c.deliverable).")
        }

        // Report selections (findings / work products), with every citation.
        for r in s.reportItems {
            let nid = id(.reportItem, r.id)
            let refs = r.citations.isEmpty
                ? (r.evidenceRef.flatMap(UUID.init(uuidString:)).map { [StudioEvidenceRef(sourceVersionID: $0, objectID: objectForVersion[$0], quote: r.quote)] } ?? [])
                : r.citations
            let superseded = s.isSuperseded(r.origin)
            let st: CaseMapStatus = superseded ? CaseMapStatus(.stale, "Carried from a result revision that is no longer the current one")
                : (!r.included ? .recorded("Excluded from the report — \(r.exclusionReason ?? "reason not recorded")")
                   : (refs.isEmpty ? CaseMapStatus(.unsupported, "Selected for the report with no cited source") : status(of: r.support, version: refs.first?.sourceVersionID)))
            add(CaseMapNode(id: nid, revision: r.originDigest, kind: .finding, title: (r.included ? "Report — " : "Excluded — ") + String(r.text.prefix(80)),
                            wording: r.text, status: st, review: carried(r.reviewState), sources: refs.map(source), author: .investigator(r.addedBy),
                            recordedAt: r.createdAt, eventDate: nil, history: r.decidedBy.map { ["Decided by \($0)"] } ?? [],
                            changedSourceWarning: superseded ? "The result revision this item came from was replaced; review it again." : nil,
                            isDocumentary: r.included && !refs.isEmpty && r.support.isDocumentary))
            if let a = r.allegationID, nodes[id(.allegation, a)] != nil {
                link(.selectedForReport, nid, id(.allegation, a), origins: [CaseMapOrigin(.reportItem, r.id.uuidString, revision: r.originDigest)], sources: [],
                     by: .investigator(r.addedBy), review: carried(r.reviewState), status: st, basis: "Selected for the report under this allegation.")
            }
            for ref in refs {
                guard let d = docNode(version: ref.sourceVersionID, object: ref.objectID) else { continue }
                link(.derivedFrom, nid, d, origins: [CaseMapOrigin(.reportItem, r.id.uuidString, revision: r.originDigest)], sources: [source(ref)],
                     by: .investigator(r.addedBy), review: carried(r.reviewState), status: st, basis: "The report item cites this passage.")
            }
        }

        // v176 — supplied reports and results: identity, source version and what the report says about itself. Storing a
        // report says nothing about whether what it states is true; an amendment never replaces the first report.
        let reportByID = Dictionary(ledger.reports.filter { $0.caseID == caseID }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for r in reportByID.values.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            let nid = id(.report, r.id)
            let doc = r.sourceVersionID.flatMap { docNode(version: $0, object: nil) }
            let st: CaseMapStatus
            if !r.isActive { st = CaseMapStatus(.unavailable, "Withdrawn — \(r.withdrawnReason ?? "reason not recorded")") }
            else if r.sourceVersionID != nil && doc == nil { st = CaseMapStatus(.unavailable, "The report's document is not in this case") }
            else if let v = r.sourceVersionID, let d = doc, let shown = shownVersion[d], shown != v {
                st = CaseMapStatus(.stale, "A newer version of the report's document is in the case; this report and its points cite the version they were read from")
            } else { st = .recorded(r.kind.label + (r.sourceVersionID == nil ? " — no document in the case yet" : " — read from its document")) }
            let wording = [r.producer.map { "Producer: \($0)" }, r.author.map { "Author: \($0)" }, r.examinedMaterial.map { "Material examined: \($0)" },
                           (r.reportDateText ?? r.reportDate.map { $0.formatted(date: .abbreviated, time: .omitted) }).map { "Report date: \($0)" },
                           r.methods.map { "Methods: \($0)" }, r.limitations.map { "Limitations: \($0)" }].compactMap { $0 }.joined(separator: "\n")
            let src = r.sourceVersionID.map { [CaseMapSourceRef(sourceVersionID: $0, objectID: objectForVersion[$0], documentName: nameForVersion[$0], quote: nil)] } ?? []
            add(CaseMapNode(id: nid, revision: r.withdrawnAt.map { String($0.timeIntervalSince1970) }, kind: .evidence, title: "\(r.kind.label) — \(r.title)",
                            wording: wording.isEmpty ? nil : wording, status: st, review: .notApplicable, sources: src, author: .investigator(r.recordedBy),
                            recordedAt: r.recordedAt, eventDate: r.reportDate, history: [], changedSourceWarning: st.kind == .stale ? st.text : nil,
                            isDocumentary: false))
            if let d = doc {
                link(.derivedFrom, nid, d, origins: [CaseMapOrigin(.report, r.id.uuidString)], sources: src, by: .investigator(r.recordedBy), review: .notApplicable,
                     status: st.kind == .stale ? st : .recorded("Read from this document"), basis: "The report was read from this version of the document.")
            }
        }
        for r in reportByID.values.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            let nid = id(.report, r.id)
            if let a = r.amendsReportID, nodes[id(.report, a)] != nil {
                link(r.kind == .amendment ? .supersedes : .derivedFrom, nid, id(.report, a), origins: [CaseMapOrigin(.report, r.id.uuidString)], sources: [],
                     by: .investigator(r.recordedBy), review: .notApplicable, status: .recorded(r.kind == .amendment ? "Amends it" : "Supplements it"),
                     basis: (r.kind == .amendment ? "An amendment of" : "A supplement to") + " the earlier report. The earlier report is kept as it was.")
            }
            if let t = r.originTaskID, nodes[id(.task, t)] != nil {
                link(.receivedInResponseTo, nid, id(.task, t), origins: [CaseMapOrigin(.report, r.id.uuidString)], sources: [],
                     by: .investigator(r.recordedBy), review: .notApplicable, status: .recorded("The result of this action"),
                     basis: "Recorded as the result of this action. Recording a result does not answer the action's question.")
            }
        }
        // v176 — points: the investigator's statement of what a report says, with the exact words and their locator, and
        // every qualification attached (so a conditional result never reads as unconditional).
        let qualsByPoint = Dictionary(grouping: ledger.qualifications.filter { $0.caseID == caseID }, by: \.pointID)
        for pt in ledger.points where pt.caseID == caseID {
            let nid = id(.reportPoint, pt.id)
            // v178 (SRC-03): what the quoted words left out of their source sentence travels with the point too.
            let quals = (qualsByPoint[pt.id] ?? []).map(\.line) + (pt.sourceCheck?.lines ?? [])
            let reportNode = id(.report, pt.reportID)
            let doc = pt.sourceVersionID.flatMap { docNode(version: $0, object: pt.objectID) }
            let st: CaseMapStatus
            if !pt.isActive { st = CaseMapStatus(.unavailable, "Withdrawn — \(pt.withdrawnReason ?? "reason not recorded")") }
            else if let v = pt.sourceVersionID, let d = doc, let shown = shownVersion[d], shown != v {
                st = CaseMapStatus(.stale, "Taken from an earlier version of the document — check the passage in the current version")
            } else if pt.sourceVersionID != nil && doc == nil { st = CaseMapStatus(.unavailable, "The point's document is not in this case") }
            else if !pt.isVerified { st = CaseMapStatus(.unsupported, pt.supportDetail ?? "The quoted words were not verified in the report's document") }
            else if let check = pt.sourceCheck, check.flagsMeaning {
                // The words are in the source, but cut so they lose what changes their meaning, or the statement made of
                // them is not supported: never shown as a plain verified passage.
                let left: String = check.context.dropped.filter(\.changesMeaning).map { $0.label.lowercased() }.joined(separator: ", ")
                let why: String = check.context.changesMeaning
                    ? "The quoted words are cut from a longer sentence and leave out \(left) — read the full sentence"
                    : "The quoted words are in the report, but they do not support the statement — \(check.statementIssues.joined(separator: "; "))"
                st = CaseMapStatus(.unsupported, why)
            }
            else { st = .recorded("\(pt.kind.label) in the report — verified passage") }
            let review: CaseMapReviewState = pt.review == .accepted ? .accepted : pt.review == .rejected ? .rejected : .unreviewed
            let wording = ([pt.statement] + quals.map { "Qualified — \($0)" }).joined(separator: "\n")
            var node = CaseMapNode(id: nid, revision: pt.reviewedAt.map { String($0.timeIntervalSince1970) }, kind: .statement,
                                   title: "\(pt.kind.label) — \(String(pt.statement.prefix(70)))" + (quals.isEmpty ? "" : " (qualified)"), wording: wording,
                                   status: st, review: review,
                                   sources: [CaseMapSourceRef(sourceVersionID: pt.sourceVersionID, objectID: pt.objectID ?? pt.sourceVersionID.flatMap { objectForVersion[$0] },
                                                              blockID: pt.blockID, documentName: pt.sourceVersionID.flatMap { nameForVersion[$0] }, quote: pt.quote)],
                                   author: .investigator(pt.recordedBy), recordedAt: pt.recordedAt, eventDate: nil,
                                   history: pt.reviewedBy.map { [pt.review.label + " by \($0)" + (pt.reviewedAt.map { " on \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "")] } ?? [],
                                   changedSourceWarning: st.kind == .stale ? st.text : nil,
                                   // That the report states it is verified; that it is true is not.
                                   isDocumentary: pt.isActive && pt.isVerified && st.kind == .recorded)
            node.qualifications = quals
            add(node)
            if nodes[reportNode] != nil {
                link(.derivedFrom, nid, reportNode, origins: [CaseMapOrigin(.reportPoint, pt.id.uuidString)], sources: node.sources,
                     by: .investigator(pt.recordedBy), review: review, status: st,
                     basis: "A point of this report: the investigator's statement of what the report says. Storing it does not make it true.")
            }
        }
        // v176 — work links: a question or action raised from a point, an action serving several questions.
        for w in ledger.workLinks where w.caseID == caseID && w.isActive {
            let from: CaseMapNodeID = {
                switch w.workKind {
                case .allegation: return id(.allegation, w.workID)
                case .task: return id(.task, w.workID)
                case .report: return id(.report, w.workID)
                case .request: return id(.request, w.workID)
                }
            }()
            let to: CaseMapNodeID = {
                switch w.targetKind {
                case .point: return id(.reportPoint, w.targetID)
                case .allegation: return id(.allegation, w.targetID)
                case .hypothesis: return id(.hypothesis, w.targetID)
                case .report: return id(.report, w.targetID)
                case .task: return id(.task, w.targetID)
                }
            }()
            guard nodes[from] != nil, nodes[to] != nil else { continue }
            // v180 (REPORT-04): a comparison action names the record it compares its point with.
            let words: (status: String, basis: String) = {
                switch w.role {
                case .raisedFrom: return ("Raised from it", "Raised from this item")
                case .serves: return ("Work for it", "Work serving this item")
                case .compares: return ("Compared with it", "A comparison with this item (comparing is work, not a finding)")
                }
            }()
            link(w.role == .raisedFrom ? .derivedFrom : .requestsEvidenceFor, from, to, origins: [CaseMapOrigin(.workLink, w.id.uuidString)], sources: [],
                 by: .investigator(w.createdBy), review: .notApplicable, status: .recorded(words.status),
                 basis: words.basis + (w.purpose.map { " — \($0)" } ?? "") + ".")
        }

        // v177 — frame memberships the investigator placed (anchor → member) and action dependencies (task → the task it
        // waits for). Each is its own record; the member and both tasks are stored once and appear wherever they are linked.
        // (Frame memberships are linked after the money records below, so a money account or record placed in a branch is drawn there.)
        for d in ledger.dependencies where d.caseID == caseID {
            let from = id(.task, d.taskID), to = id(.task, d.dependsOnTaskID)
            guard nodes[from] != nil, nodes[to] != nil else { continue }
            link(.dependsOn, from, to, origins: [CaseMapOrigin(.actionDependency, d.id.uuidString)], sources: [],
                 by: .rule("task dependency"), review: .notApplicable, status: .recorded("Waits for it"),
                 basis: "This action waits for the other one (recorded in the task's dependencies).")
        }

        // S3 (MAP-06, GRAPH-04) — money movements read from the case's documents: one node per transaction (however many
        // documents record it), payer and payee as recorded, every document it was read from. An amount read from a
        // document is what the document states — not a verified payment — and currencies are never added together.
        let personByEntity = Dictionary(s.people.compactMap { p in p.entityID.map { ($0.uuidString.uppercased(), p.id) } }, uniquingKeysWith: { a, _ in a })
        for t in input.money {
            let nid = CaseMapNodeID(caseID: caseID, kind: .moneyTransaction, recordID: String(CaseFileHash.sha256(t.id).prefix(32)))
            let money = CaseMapMoney(amount: t.money.amount, currency: t.money.currency)
            let docs = t.documentIDs.compactMap { UUID(uuidString: $0) }.compactMap { docForObject[$0] }
            let st: CaseMapStatus = t.isUnconfirmedMerge
                ? CaseMapStatus(.unassessed, "Matched across \(t.documentIDs.count) documents on amount and parties only — check whether this is one payment or several")
                : .recorded("Read from \(t.documentIDs.count) document(s)" + (t.reference.map { " — reference \($0)" } ?? ""))
            var node = CaseMapNode(id: nid, revision: t.factIDs.sorted().joined(separator: ",").isEmpty ? nil : String(CaseFileHash.sha256(t.factIDs.sorted().joined(separator: ",")).prefix(16)),
                                   kind: .money, title: "\(money.display) — \(t.fromLabel) → \(t.toLabel)",
                                   wording: ["Payer (as recorded): \(t.fromLabel)", "Payee (as recorded): \(t.toLabel)", "Amount: \(money.display)",
                                             t.reference.map { "Reference: \($0)" }, "Identity basis: \(t.identityBasis.rawValue)"].compactMap { $0 }.joined(separator: "\n"),
                                   status: st, review: t.isUnconfirmedMerge ? .unreviewed : .notApplicable,
                                   sources: t.documentIDs.compactMap { UUID(uuidString: $0) }.map { o in
                                       CaseMapSourceRef(sourceVersionID: nil, objectID: o, documentName: docForObject[o].flatMap { nodes[$0]?.title }, quote: nil) },
                                   author: .rule("amounts read from the documents (FundsTrace)"), recordedAt: nil, eventDate: t.date, history: [],
                                   changedSourceWarning: nil, isDocumentary: false)
            node.money = money
            if t.date != nil { node.datePrecision = .day }
            add(node)
            for d in docs {
                link(.derivedFrom, nid, d, origins: [CaseMapOrigin(.moneyTransaction, nid.recordID)], sources: [], by: .rule("amounts read from the documents"),
                     review: .notApplicable, status: .recorded("Read from this document"), basis: "The amount and parties were read from this document. Reading them is not verifying the payment.")
            }
            for (type, entity, label) in [(CaseMapLinkType.moneyFrom, t.fromID, t.fromLabel), (.moneyTo, t.toID, t.toLabel)] {
                guard let pid = personByEntity[entity.uppercased()], nodes[id(.person, pid)] != nil else { continue }
                link(type, nid, id(.person, pid), origins: [CaseMapOrigin(.moneyTransaction, nid.recordID)], sources: [], by: .rule("the person's link to the documents"),
                     review: .notApplicable, status: .recorded(type == .moneyFrom ? "Payer as recorded" : "Payee as recorded"),
                     basis: "The documents name \(label) as the \(type == .moneyFrom ? "payer" : "payee"); this case person is linked to that name. A payment is not proof of wrongdoing.")
            }
        }

        // S7 (MONEY-01) — the case's canonical financial records: each account and each current money record is ONE item, the
        // same record in the money, people (holder links), time (its day) and question (investigator links) views. A record's
        // amount is the exact value in its own currency; a mention of money (invoice, balance, allegation…) says it is not a
        // movement; an amended record is shown replaced, never counted; holding an account is never shown as authorising it.
        if let ml = input.moneyLedger, ml.caseID == caseID {
            let (txs, _) = ml.transactions()
            let txOf = Dictionary(txs.flatMap { t in t.records.map { ($0.id, t) } }, uniquingKeysWith: { a, _ in a })
            for a in ml.accounts where a.isActive {
                let rel = ml.ownership.filter { $0.isActive && $0.accountID == a.id }
                add(CaseMapNode(id: id(.moneyAccount, a.id), revision: nil, kind: .money, title: a.title,
                                wording: ([a.identifier, a.institution, a.currency].compactMap { $0 }.joined(separator: " · ")
                                          + (rel.isEmpty ? "\nNo holder or controller recorded." : "\n" + rel.map(\.line).joined(separator: "\n"))
                                          + "\n" + CaseMoneyRelation.impliesNothing),
                                status: .recorded(rel.isEmpty ? "Account recorded — no holder recorded" : "Account recorded — \(rel.count) relation(s) recorded"),
                                review: .notApplicable,
                                sources: a.sourceVersionID.map { [CaseMapSourceRef(sourceVersionID: $0, objectID: objectForVersion[$0], documentName: nameForVersion[$0], quote: a.quote)] } ?? [],
                                author: .investigator(a.recordedBy), recordedAt: a.recordedAt, eventDate: nil, history: [], changedSourceWarning: nil, isDocumentary: false))
                for r in rel {
                    guard let p = r.holderPersonID, nodes[id(.person, p)] != nil else { continue }
                    link(.accountRelation, id(.moneyAccount, a.id), id(.person, p), origins: [CaseMapOrigin(.accountRelation, r.id.uuidString)],
                         sources: r.sourceVersionID.map { [CaseMapSourceRef(sourceVersionID: $0, objectID: objectForVersion[$0], documentName: nameForVersion[$0], quote: r.quote)] } ?? [],
                         by: .investigator(r.recordedBy), review: .notApplicable, status: .recorded("\(r.relation.label) — \(r.period)"),
                         basis: "\(r.line). \(CaseMoneyRelation.impliesNothing)")
                }
            }
            let replaced = ml.amended
            for r in ml.records where r.isActive {
                let nid = id(.moneyRecord, r.id)
                let t = txOf[r.id]
                let st: CaseMapStatus
                if replaced.contains(r.id) { st = CaseMapStatus(.stale, "Replaced by an amendment — kept, not counted") }
                else if r.kind == .unclassified { st = CaseMapStatus(.unassessed, "Amount not yet classified — in no figure") }
                else if !r.kind.isMovement { st = .recorded("\(r.kind.label) — a mention of money, never added to paid or lost") }
                else if r.amount == nil { st = CaseMapStatus(.unassessed, "Amount not readable without guessing — in no figure") }
                else if t?.basis == .unresolved { st = CaseMapStatus(.unassessed, "May be the same payment as another record — confirm or split it") }
                else { st = .recorded(t.map { $0.records.count > 1 ? "\($0.basis.label) (\($0.records.count) records)" : "Recorded movement" } ?? "Recorded movement") }
                var node = CaseMapNode(id: nid, revision: r.amendsRecordID.map { "amends:" + $0.uuidString.lowercased() }, kind: .money,
                                       title: "\(r.display) — \(r.kind.label)",
                                       wording: ["Amount as written: \(r.amountText) (\(r.amountBasis))", r.date.map { "Day: \($0)" } ?? r.dateText.map { "Date as written: \($0)" },
                                                 r.reference.map { "Reference: \($0)" }, r.description, r.isDisputed ? "Disputed: \(r.disputeNote ?? "")" : nil,
                                                 r.amendReason.map { "Amends an earlier record: \($0)" }, "Source: \(r.provenance)"].compactMap { $0 }.joined(separator: "\n"),
                                       status: st, review: (t?.basis == .unresolved || r.kind == .unclassified) ? .unreviewed : .notApplicable,
                                       sources: r.sourceVersionID.map { [CaseMapSourceRef(sourceVersionID: $0, objectID: objectForVersion[$0], blockID: r.blockID, documentName: nameForVersion[$0] ?? r.sourceName, quote: r.quote)] } ?? [],
                                       author: .investigator(r.recordedBy), recordedAt: r.recordedAt, eventDate: r.date.flatMap(CaseMoneyLedger.date), history: [],
                                       changedSourceWarning: nil, isDocumentary: false)
                if let v = r.amount { node.money = CaseMapMoney(amount: v.magnitude, currency: r.currency.isEmpty ? FundsMoney.unstated : r.currency) }
                if r.date != nil { node.datePrecision = .day } else if let dt = r.dateText { node.dateText = dt }
                add(node)
                for (type, acct) in [(CaseMapLinkType.moneyFrom, r.payerAccountID), (.moneyTo, r.payeeAccountID)] {
                    guard let acct, nodes[id(.moneyAccount, acct)] != nil else { continue }
                    link(type, nid, id(.moneyAccount, acct), origins: [CaseMapOrigin(.moneyRecord, r.id.uuidString)], sources: [], by: .investigator(r.recordedBy),
                         review: .notApplicable, status: .recorded(type == .moneyFrom ? "Paid from this account (as recorded)" : "Paid into this account (as recorded)"),
                         basis: "The money record names this account. A movement is what the source records — not proof of wrongdoing.")
                }
                if let v = r.sourceVersionID, let d = docForVersion[v] {
                    link(.derivedFrom, nid, d, origins: [CaseMapOrigin(.moneyRecord, r.id.uuidString)], sources: [], by: .investigator(r.recordedBy),
                         review: .notApplicable, status: .recorded("Recorded from this document"), basis: "The money record was recorded from this document (\(r.provenance)).")
                }
                if let a = r.amendsRecordID, nodes[id(.moneyRecord, a)] != nil || ml.record(a) != nil {
                    link(.supersedes, nid, id(.moneyRecord, a), origins: [CaseMapOrigin(.moneyRecord, r.id.uuidString)], sources: [], by: .investigator(r.recordedBy),
                         review: .notApplicable, status: .recorded("Amends it"), basis: r.amendReason ?? "An amendment")
                }
            }
        }

        // v177 frame memberships, linked once every placeable kind (money accounts and records included) has its node — S13:
        // placed before the money nodes existed, a money record placed in a branch silently did not appear there.
        for m in ledger.frameMembers where m.caseID == caseID && m.isActive {
            guard let fk = CaseMapRecordKind(rawValue: m.frameKind), let mk = CaseMapRecordKind(rawValue: m.memberKind) else { continue }
            let frame = CaseMapNodeID(caseID: caseID, kind: fk, recordID: m.frameID), member = CaseMapNodeID(caseID: caseID, kind: mk, recordID: m.memberID)
            guard nodes[frame] != nil, nodes[member] != nil else { continue }
            link(.placedIn, frame, member, origins: [CaseMapOrigin(.frameMember, m.id.uuidString)], sources: [],
                 by: .investigator(m.addedBy), review: .notApplicable, status: .recorded("Placed here by \(m.addedBy)"),
                 basis: "Placed in this branch" + (m.purpose.map { " — \($0)" } ?? "") + ".")
        }

        // The investigator's own links: drawn only between items in this case; others are counted.
        var dangling = 0
        var withdrawn = 0
        for l in input.investigatorLinks where l.caseID == caseID {
            guard l.isActive else { withdrawn += 1; continue }
            guard nodes[l.from] != nil, nodes[l.to] != nil else { dangling += 1; continue }
            if var made = link(l.type, l.from, l.to, origins: [CaseMapOrigin(.investigatorLink, l.id.uuidString)], sources: [],
                               by: .investigator(l.createdBy), review: .notApplicable, status: .recorded("Drawn by \(l.createdBy)"), basis: l.rationale) {
                made.certainty = l.certainty; made.validity = l.validity; made.recordedAt = l.createdAt; made.revisesLinkID = l.revisesLinkID
                links[made.id] = made
            }
        }

        // SRC-10 — source dependence: copies of one origin, and every other record citing it, on each item with sources.
        CaseSourceDependence.annotate(&nodes, documents: input.documents)

        // Groups: one per kind, and the material nothing links to.
        // M9 (§13.3): with the previous projection of this case, its order is kept for the items still present and
        // only the new ones are sorted and merged in (the same order as sorting everything; linear, not n log n).
        let previous = memo.flatMap { $0.caseID == caseID ? $0.previous : nil }
        let sortedNodes: [CaseMapNode] = previous.map { prev in
            mergeOrdered(kept: prev.nodes.compactMap { nodes[$0.id] }, added: nodes.values.filter { prev.node($0.id) == nil }, by: { $0.id < $1.id })
        } ?? nodes.values.sorted { $0.id < $1.id }
        let sortedLinks: [CaseMapLink] = previous.map { prev in
            mergeOrdered(kept: prev.links.compactMap { links[$0.id] }, added: links.values.filter { prev.link($0.id) == nil }, by: { $0.id < $1.id })
        } ?? links.values.sorted { $0.id < $1.id }
        let groups = Self.groups(sortedNodes, sortedLinks)

        var parts = input.parts
        for p in CaseMapPart.allCases where parts[p] == nil { parts[p] = .loaded }
        var projection = CaseMapProjection(caseID: caseID, title: s.caseHeader.title, stage: s.caseHeader.status == .closed ? .closed : s.profile.stage,
                                           isClosed: s.caseHeader.status == .closed, question: question, nodes: sortedNodes, links: sortedLinks,
                                           groups: groups, parts: parts, danglingLinks: dangling, withdrawnLinks: withdrawn)
        if let ml = input.moneyLedger, ml.caseID == caseID { projection.moneyFigures = ml.figures() }
        return (projection, CaseMapProjectionMemo(caseID: caseID, documents: input.documents, journal: nextJournal, previous: projection,
                                                         reusedEntries: reusedEntries))
    }
}

/// M9 (§13.3) — what one projection built for each chronology entry, with the inputs it was built from, so the next
/// projection of the same case can reuse it when those inputs are unchanged. Holds no record that the projection
/// itself does not hold; kept in memory only (never stored).
public nonisolated struct CaseMapProjectionMemo: Sendable {
    struct JournalPiece: Sendable {
        let entry: CaseJournalEntry
        let attestations: [CaseFactAttestation]
        let superseded: Bool
        let node: CaseMapNode
        let links: [CaseMapLink]
    }
    let caseID: UUID
    /// The case's documents the pieces were built against (a document's name, version or object changes every piece).
    let documents: [CaseMapDocument]
    let journal: [UUID: JournalPiece]
    /// The projection this memo came from (its order is reused for the items still present).
    let previous: CaseMapProjection
    /// How many chronology entries this projection took from the memo it was given (not built again).
    public let reusedEntries: Int
    /// How many chronology entries this memo holds.
    public var entries: Int { journal.count }
}
