//
//  EvidenceRequestFollowUp.swift
//  Kalsmritikosh
//
//  Owner's implementation plan 2026-11-04, P1-B — an evidence request the investigator can follow
//  through (schema v170). The request names what it is for (an allegation or a question), whom it is
//  asked of, the items expected (three monthly statements are three items), a due date, and keeps the
//  history of asking and answering. Each document received is linked to the request — and to the item it
//  answers — as a source version of the case; a duplicate of a document already received is kept and
//  marked, never counted twice. What is still outstanding is computed from the items and the receipts.
//  Whether the request is fulfilled, partial, refused or cannot be obtained is a person's recorded
//  decision: no arrival changes the status, and nothing here changes an approved finding.
//
//  Pure value types and functions (matching suggestions, the draft request text, the "may need
//  revisiting" notices) so they are testable without a database; persistence is in
//  InvestigationAnalysisRepository.
//

import Foundation

/// One item a request expects (a statement for one month, one contract, one log export).
public nonisolated struct EvidenceRequestItem: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let requestID: UUID
    public let ordinal: Int
    public let label: String
    public let periodStart: Date?
    public let periodEnd: Date?
    public init(id: UUID, requestID: UUID, ordinal: Int, label: String, periodStart: Date?, periodEnd: Date?) {
        self.id = id; self.requestID = requestID; self.ordinal = ordinal; self.label = label
        self.periodStart = periodStart; self.periodEnd = periodEnd
    }
}

/// What the person asks for when creating an item.
public nonisolated struct EvidenceRequestItemSpec: Sendable, Equatable {
    public var label: String
    public var periodStart: Date?
    public var periodEnd: Date?
    public init(label: String, periodStart: Date? = nil, periodEnd: Date? = nil) {
        self.label = label; self.periodStart = periodStart; self.periodEnd = periodEnd
    }

    /// One item per calendar month from `start` to `end` inclusive ("Bank statement — January 2026").
    public static func monthly(_ what: String, from start: Date, to end: Date, calendar: Calendar = .current) -> [EvidenceRequestItemSpec] {
        var out: [EvidenceRequestItemSpec] = []
        guard var month = calendar.dateInterval(of: .month, for: start)?.start else { return [] }
        let stop = calendar.dateInterval(of: .month, for: end)?.start ?? end
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.calendar = calendar; f.timeZone = calendar.timeZone
        f.dateFormat = "MMMM yyyy"
        let base = what.trimmingCharacters(in: .whitespacesAndNewlines)
        while month <= stop, out.count < 120 {
            guard let interval = calendar.dateInterval(of: .month, for: month) else { break }
            let last = interval.end.addingTimeInterval(-1)
            out.append(EvidenceRequestItemSpec(label: (base.isEmpty ? "" : base + " — ") + f.string(from: month),
                                               periodStart: interval.start, periodEnd: last))
            month = interval.end
        }
        return out
    }
}

/// Everything a new request records (all but the description are optional).
public nonisolated struct EvidenceRequestDetails: Sendable, Equatable {
    public var description: String
    public var hypothesisID: UUID?
    public var allegationID: UUID?
    public var question: String?
    public var custodian: String?
    public var periodStart: Date?
    public var periodEnd: Date?
    public var dueAt: Date?
    public var items: [EvidenceRequestItemSpec]
    public init(description: String, hypothesisID: UUID? = nil, allegationID: UUID? = nil, question: String? = nil,
                custodian: String? = nil, periodStart: Date? = nil, periodEnd: Date? = nil, dueAt: Date? = nil,
                items: [EvidenceRequestItemSpec] = []) {
        self.description = description; self.hypothesisID = hypothesisID; self.allegationID = allegationID; self.question = question
        self.custodian = custodian; self.periodStart = periodStart; self.periodEnd = periodEnd; self.dueAt = dueAt; self.items = items
    }
}

/// How a received document was linked: by the person choosing it, or by accepting a suggestion.
public nonisolated enum EvidenceReceiptOrigin: String, Codable, Sendable, Equatable { case manual, suggestion }

/// One document received against a request (a source version of the case).
public nonisolated struct EvidenceRequestReceipt: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let requestID: UUID
    public let itemID: UUID?
    public let sourceVersionID: UUID
    public let knowledgeObjectID: UUID?
    public let contentHash: String?
    /// The earlier receipt with the same content (this one is a duplicate copy; not counted).
    public let duplicateOf: UUID?
    public let origin: EvidenceReceiptOrigin
    public let note: String?
    public let linkedBy: String
    public let linkedAt: Date
    public let withdrawnBy: String?
    public let withdrawnAt: Date?
    public let withdrawnReason: String?
    public init(id: UUID, requestID: UUID, itemID: UUID?, sourceVersionID: UUID, knowledgeObjectID: UUID?, contentHash: String?,
                duplicateOf: UUID?, origin: EvidenceReceiptOrigin, note: String?, linkedBy: String, linkedAt: Date,
                withdrawnBy: String?, withdrawnAt: Date?, withdrawnReason: String?) {
        self.id = id; self.requestID = requestID; self.itemID = itemID; self.sourceVersionID = sourceVersionID
        self.knowledgeObjectID = knowledgeObjectID; self.contentHash = contentHash; self.duplicateOf = duplicateOf
        self.origin = origin; self.note = note; self.linkedBy = linkedBy; self.linkedAt = linkedAt
        self.withdrawnBy = withdrawnBy; self.withdrawnAt = withdrawnAt; self.withdrawnReason = withdrawnReason
    }
    public var isActive: Bool { withdrawnAt == nil }
    /// Counts toward its item: active and not a duplicate copy.
    public var counts: Bool { isActive && duplicateOf == nil }
}

/// One entry in a request's history.
public nonisolated enum EvidenceRequestEventKind: String, Codable, Sendable, Equatable, CaseIterable {
    case created, requested, responded, received, duplicateReceived, receiptWithdrawn, statusDecided, note

    public var label: String {
        switch self {
        case .created: return "Created"
        case .requested: return "Asked for"
        case .responded: return "Reply recorded"
        case .received: return "Received"
        case .duplicateReceived: return "Duplicate received"
        case .receiptWithdrawn: return "Link withdrawn"
        case .statusDecided: return "Decision"
        case .note: return "Note"
        }
    }
}

public nonisolated struct EvidenceRequestEvent: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let requestID: UUID
    public let kind: EvidenceRequestEventKind
    public let statusAfter: EvidenceRequestStatus?
    public let itemID: UUID?
    public let receiptID: UUID?
    public let detail: String?
    public let actor: String
    public let occurredAt: Date
    public init(id: UUID, requestID: UUID, kind: EvidenceRequestEventKind, statusAfter: EvidenceRequestStatus?, itemID: UUID?,
                receiptID: UUID?, detail: String?, actor: String, occurredAt: Date) {
        self.id = id; self.requestID = requestID; self.kind = kind; self.statusAfter = statusAfter; self.itemID = itemID
        self.receiptID = receiptID; self.detail = detail; self.actor = actor; self.occurredAt = occurredAt
    }
}

/// What has arrived against the expected items — a fact computed from the links, not a decision.
public nonisolated struct EvidenceRequestProgress: Sendable, Equatable {
    public enum State: String, Sendable, Equatable {
        case noItemsListed       // a request without expected items (e.g. made before v170)
        case nothingReceived
        case partlyReceived
        case allReceived
    }
    public let expected: Int
    public let received: [EvidenceRequestItem]
    public let outstanding: [EvidenceRequestItem]
    public let duplicates: Int
    /// Documents linked to the request but to no item.
    public let unassigned: Int

    public var state: State {
        if expected == 0 { return .noItemsListed }
        if received.isEmpty { return .nothingReceived }
        return outstanding.isEmpty ? .allReceived : .partlyReceived
    }

    public static func compute(items: [EvidenceRequestItem], receipts: [EvidenceRequestReceipt]) -> EvidenceRequestProgress {
        let counted = receipts.filter(\.counts)
        let answered = Set(counted.compactMap(\.itemID))
        let sorted = items.sorted { $0.ordinal < $1.ordinal }
        return EvidenceRequestProgress(expected: items.count, received: sorted.filter { answered.contains($0.id) },
                                       outstanding: sorted.filter { !answered.contains($0.id) },
                                       duplicates: receipts.filter { $0.isActive && $0.duplicateOf != nil }.count,
                                       unassigned: counted.filter { $0.itemID == nil }.count)
    }

    /// The visible line ("2 of 3 received · still missing: Bank statement — March 2026").
    public var summary: String {
        switch state {
        case .noItemsListed:
            return unassigned == 0 ? "No expected items listed." : "\(unassigned) document(s) linked; no expected items listed."
        case .nothingReceived:
            return "Nothing received yet (\(expected) expected)."
        case .partlyReceived, .allReceived:
            var s = "\(received.count) of \(expected) received"
            if !outstanding.isEmpty { s += " · still missing: " + outstanding.map(\.label).joined(separator: "; ") }
            if duplicates > 0 { s += " · \(duplicates) duplicate cop\(duplicates == 1 ? "y" : "ies") not counted" }
            return s
        }
    }
}

/// A request with everything recorded against it.
public nonisolated struct EvidenceRequestFile: Identifiable, Sendable, Equatable {
    public let request: EvidenceRequest
    public let items: [EvidenceRequestItem]
    public let receipts: [EvidenceRequestReceipt]
    public let events: [EvidenceRequestEvent]
    public var id: UUID { request.id }
    public var progress: EvidenceRequestProgress { .compute(items: items, receipts: receipts) }
    public var latestReceiptAt: Date? { receipts.filter(\.isActive).map(\.linkedAt).max() }
    public init(request: EvidenceRequest, items: [EvidenceRequestItem], receipts: [EvidenceRequestReceipt], events: [EvidenceRequestEvent]) {
        self.request = request; self.items = items; self.receipts = receipts; self.events = events
    }
}

// MARK: - Suggestions: a new source that may answer a request

/// A case document that could be linked (from the case's custody, with its name and any document date).
public nonisolated struct EvidenceRequestCandidate: Sendable, Equatable {
    public let sourceVersionID: UUID
    public let knowledgeObjectID: UUID?
    public let name: String
    public let documentDate: Date?
    public init(sourceVersionID: UUID, knowledgeObjectID: UUID? = nil, name: String, documentDate: Date? = nil) {
        self.sourceVersionID = sourceVersionID; self.knowledgeObjectID = knowledgeObjectID; self.name = name; self.documentDate = documentDate
    }
}

public nonisolated struct EvidenceRequestSuggestion: Sendable, Equatable, Identifiable {
    public let candidate: EvidenceRequestCandidate
    public let itemID: UUID?
    public let why: String
    public var id: String { candidate.sourceVersionID.uuidString + "|" + (itemID?.uuidString ?? "-") }
}

public nonisolated enum EvidenceRequestMatcher {
    /// Suggestions only — the person links. A candidate already linked is not suggested; a candidate is
    /// suggested for an OUTSTANDING item when its document date falls in the item's period or its name
    /// carries the item's month and year; for a request without items, when its name contains the
    /// custodian's name. Anything else (an unrelated file) is not suggested.
    public static func suggestions(for file: EvidenceRequestFile, candidates: [EvidenceRequestCandidate],
                                   calendar: Calendar = .current) -> [EvidenceRequestSuggestion] {
        guard file.request.status != .cancelled else { return [] }
        let linked = Set(file.receipts.filter(\.isActive).map(\.sourceVersionID))
        let outstanding = file.progress.outstanding
        var out: [EvidenceRequestSuggestion] = []
        for c in candidates where !linked.contains(c.sourceVersionID) {
            if let item = outstanding.first(where: { item in
                guard let date = c.documentDate, let s = item.periodStart, let e = item.periodEnd else { return false }
                return date >= s && date <= e
            }), let date = c.documentDate {
                out.append(.init(candidate: c, itemID: item.id, why: "dated \(date.formatted(date: .abbreviated, time: .omitted)), within \(item.label)"))
                continue
            }
            if let item = outstanding.first(where: { nameNamesPeriod(c.name, $0, calendar: calendar) }) {
                out.append(.init(candidate: c, itemID: item.id, why: "its name gives the month of \(item.label)"))
                continue
            }
            if file.items.isEmpty, let custodian = file.request.custodian, nameContains(c.name, custodian) {
                out.append(.init(candidate: c, itemID: nil, why: "its name contains \(custodian)"))
            }
        }
        return out
    }

    /// The name carries the item's month and year: "2026-02", "202602", "Feb 2026", "February 2026".
    static func nameNamesPeriod(_ name: String, _ item: EvidenceRequestItem, calendar: Calendar) -> Bool {
        guard let start = item.periodStart, let end = item.periodEnd,
              calendar.isDate(start, equalTo: end, toGranularity: .month) else { return false }
        let c = calendar.dateComponents([.year, .month], from: start)
        guard let y = c.year, let m = c.month else { return false }
        let lower = name.lowercased()
        let mm = String(format: "%02d", m)
        let numeric = ["\(y)-\(mm)", "\(y)_\(mm)", "\(y).\(mm)", "\(y)\(mm)", "\(mm)-\(y)", "\(mm)_\(y)"]
        if numeric.contains(where: { lower.contains($0) }) { return true }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        let names = [f.monthSymbols[m - 1].lowercased(), f.shortMonthSymbols[m - 1].lowercased()]
        return lower.contains(String(y)) && names.contains { word in
            lower.range(of: "(^|[^a-z])\(word)([^a-z]|$)", options: .regularExpression) != nil
        }
    }

    static func nameContains(_ name: String, _ who: String) -> Bool {
        let tokens = who.lowercased().split { !$0.isLetter && !$0.isNumber }.filter { $0.count >= 4 }
        let lower = name.lowercased()
        return !tokens.isEmpty && tokens.contains { lower.contains($0) }
    }
}

// MARK: - The draft request text (nothing is sent)

public nonisolated enum EvidenceRequestDraft {
    /// A plain request letter from the record, for the person to edit and send themselves.
    public static func text(_ file: EvidenceRequestFile, caseTitle: String, about: String?, requester: String) -> String {
        let r = file.request
        let df: (Date) -> String = { $0.formatted(date: .long, time: .omitted) }
        var lines: [String] = []
        lines.append("To: \(r.custodian?.isEmpty == false ? r.custodian! : "[custodian]")")
        lines.append("Re: \(caseTitle) — request for records")
        lines.append("")
        lines.append("In connection with the matter above, please provide the following:")
        let wanted = file.items.isEmpty ? [] : (file.progress.received.isEmpty ? file.items.sorted { $0.ordinal < $1.ordinal } : file.progress.outstanding)
        if wanted.isEmpty {
            lines.append("  • \(r.description)")
        } else {
            lines.append("  \(r.description):")
            for (i, item) in wanted.enumerated() { lines.append("  \(i + 1). \(item.label)") }
        }
        if let s = r.periodStart, let e = r.periodEnd { lines.append("covering \(df(s)) to \(df(e)).") }
        if let about, !about.isEmpty { lines.append(""); lines.append("This relates to: \(about)") }
        if !file.progress.received.isEmpty {
            lines.append(""); lines.append("Already received, with thanks: " + file.progress.received.map(\.label).joined(separator: "; ") + ".")
        }
        if let due = r.dueAt { lines.append(""); lines.append("Please provide these by \(df(due)).") }
        lines.append(""); lines.append("If any of these cannot be provided, please say which and why.")
        lines.append(""); lines.append(requester)
        return lines.joined(separator: "\n")
    }
}

// MARK: - What may need revisiting after new material arrives

public nonisolated enum EvidenceRequestRevisit {
    /// The linked allegation or hypothesis, when material arrived after it was decided (or while it is
    /// still open). A notice only: no finding or decision is changed.
    public static func notices(_ file: EvidenceRequestFile, allegations: [CaseAllegation], hypotheses: [InvestigationHypothesis]) -> [String] {
        guard let arrived = file.latestReceiptAt else { return [] }
        var out: [String] = []
        if let aid = file.request.allegationID, let a = allegations.first(where: { $0.id == aid }) {
            if a.disposition != .pending, let decided = a.decidedAt, decided < arrived {
                out.append("\(a.label) was decided (\(a.disposition.label)) before this material arrived. It may need revisiting; the finding has not been changed.")
            } else if a.disposition == .pending {
                out.append("\(a.label) is still open: weigh the material received for it.")
            }
        }
        if let hid = file.request.hypothesisID, let h = hypotheses.first(where: { $0.id == hid }),
           [.confirmed, .rejected].contains(h.status), h.updatedAt < arrived {
            out.append("The hypothesis “\(h.statement)” was \(h.status.rawValue) before this material arrived. It may need revisiting; the decision has not been changed.")
        }
        return out
    }
}

// MARK: - Plain reasons shown in the case file

extension InvestigationHypothesisError: LocalizedError {
    public nonisolated var errorDescription: String? {
        switch self {
        case .caseNotFound: return "That case no longer exists."
        case .caseClosed: return "The case is closed. Reopen it to change its requests or analysis."
        case .requestNotFound: return "That evidence request no longer exists."
        case .requestItemNotFound: return "That expected item is not part of this request."
        case .receiptNotFound: return "That link no longer exists or was already withdrawn."
        case .alreadyReceived: return "That document is already linked to this request."
        case .requestItemsOutstanding(let missing):
            return "Still missing: \(missing.joined(separator: "; ")). To record the request as fulfilled anyway, say why in the note."
        case .decisionNoteRequired(let status):
            return status == .cancelled ? "Say why the link is being withdrawn." : "Recording “\(status.label)” needs the reason in the note."
        case .requestClosed: return "The request was cancelled; it takes no new documents."
        case .allegationNotFound: return "That allegation is not part of this case."
        case .evidenceOutOfScope: return "That document is not in this case's scope. Add it to the case first."
        case .evidenceObjectMismatch: return "That passage does not belong to the chosen document version."
        case .blankStatement: return "Say what is requested."
        case .blankActor: return "Your name is needed to record this."
        case .revisionConflict: return "The request changed meanwhile. It has been reloaded; try again."
        default: return String(describing: self)
        }
    }
}

extension InvestigationDeskError: LocalizedError {
    public nonisolated var errorDescription: String? {
        switch self {
        case .reasonRequired: return "Choose why you are dismissing it."
        case .noteRequired: return "Say why in the note (“Other” was chosen)."
        case .caseClosed: return "The case is closed. Reopen it to record decisions."
        case .contradictionOutOfScope: return "A document behind this contradiction is no longer in the case's scope."
        case .contradictionNotFound: return "That contradiction no longer exists."
        case .blankActor: return "Your name is needed to record this."
        default: return String(describing: self)
        }
    }
}
