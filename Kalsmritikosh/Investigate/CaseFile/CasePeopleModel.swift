//
//  CasePeopleModel.swift
//  Kalsmritikosh
//
//  Smart-map S6 (docs/IME_Full_Smart_Map_Implementation_TODO_2026-11-08.md §14 PEOPLE; Appendix L2.3; schema v182). People
//  in a case — witnesses, sources, account holders, investigators — over the ONE case file repository and its savepoint.
//  Nothing here calls a model or the network; nothing here merges people.
//
//  • Identity vs role (PEOPLE-01): one case-person row is one person; their roles (witness, source, account holder,
//    investigator…) are separate records with a context and period. Adding a person already in the case through the same
//    documents' person adds a ROLE to that row instead of a second row. No role implies wrongdoing.
//  • Sourced profile (PEOPLE-02): every alias, organisation, contact, identifier, background line and relationship has an
//    origin — a cited source, who supplied it, the investigator's note, or "unsourced" — and a period. The card's old
//    free-text notes and contact are shown as unsourced.
//  • Whereabouts (PEOPLE-03): observations of where a person WAS, with time, precision, basis and uncertainty. There is no
//    "current location": the latest observation is labelled as a past observation with its age.
//  • Interview detail (PEOPLE-04): individual questions and responses with recording/transcript locators; after the
//    statement is confirmed an item changes only through a recorded correction (with an addendum), never in place.
//  • Participants (PEOPLE-05, local part): the people who RECORDED actions on this Mac and those REPORTED as having done
//    work stay distinct; neither is an authenticated account (accounts need the owner's team/identity decision, ARCH-08).
//  • Work histories (PEOPLE-06): assignments, reassignments, performed work, submitted results and reviews per person,
//    each opening its record on the map.
//  • Same-person candidates (PEOPLE-07): a versioned rule lists every reason two rows match or stay separate; a same name
//    alone never makes a strong candidate, and nothing is merged without a person's recorded decision.
//  • Capabilities and conflicts (PEOPLE-08): declared capabilities and unavailability; routing lists who is eligible and
//    why, alphabetically — no score, no inferred expertise.
//  • Team changes (PEOPLE-09): memberships end with a reason, pending work is transferred, attribution is kept; an ended
//    member cannot act — checked in the ledger at the moment of acting, never from a cached grant.
//  • Restrictions (PEOPLE-10, local part): a restricted profile's attributes, observations and statement items are
//    withheld from profile reads and statement histories, named as restricted, never shown as absent.
//

import Foundation
import os

// MARK: - PEOPLE-01 roles

public nonisolated enum CasePersonRoleKind: String, Sendable, CaseIterable, Codable, Identifiable {
    case subject, witness, complainant, custodian, source, accountHolder, investigator, reporter, other
    public var id: String { rawValue }
    /// Neutral wording: a role says how the person comes into the case, never that they did anything wrong.
    public var label: String {
        switch self {
        case .subject: return "Person the inquiry concerns (no wrongdoing implied)"
        case .witness: return "Witness"
        case .complainant: return "Complainant"
        case .custodian: return "Custodian of records"
        case .source: return "Source of information"
        case .accountHolder: return "Account holder"
        case .investigator: return "Investigator"
        case .reporter: return "Reporter (made the report)"
        case .other: return "Other"
        }
    }
    init(_ legacy: CasePersonRole) {
        switch legacy {
        case .subject: self = .subject
        case .witness: self = .witness
        case .complainant: self = .complainant
        case .custodian: self = .custodian
        case .other: self = .other
        }
    }
}

public nonisolated struct CasePersonRoleRecord: Identifiable, Sendable, Equatable, Hashable {
    public let id: UUID
    public let caseID: UUID
    public let personID: UUID
    public let role: CasePersonRoleKind
    public let context: String?
    public let validFrom: Date?
    public let validTo: Date?
    public let recordedBy: String
    public let recordedAt: Date
    public let endedAt: Date?
    public let endedReason: String?
    public var isActive: Bool { endedAt == nil }
    public var line: String { role.label + (context.map { " — \($0)" } ?? "") + (isActive ? "" : " (ended: \(endedReason ?? ""))") }
}

/// One canonical person of the case with every role they hold.
public nonisolated struct CasePersonIdentityView: Identifiable, Sendable, Equatable {
    public let person: CasePerson
    /// The role on the person's card first, then the recorded roles.
    public let roles: [String]
    /// Other rows of this case linked to the same person in the documents (they stay rows until a person decides).
    public let sameEntityRows: [UUID]
    public var id: UUID { person.id }
}

public nonisolated enum CasePersonAddOutcome: Equatable, Sendable {
    case added(UUID)
    /// The person was already in the case (same person in the documents): a role was added to that row instead.
    case roleAdded(person: UUID, role: UUID)
}

// MARK: - PEOPLE-02 profile attributes

public nonisolated enum CasePersonAttributeKind: String, Sendable, CaseIterable, Codable {
    case alias, organisation, contact, identifier, background, relationship
    public var label: String {
        switch self {
        case .alias: return "Also known as"
        case .organisation: return "Organisation"
        case .contact: return "Contact"
        case .identifier: return "Identifier"
        case .background: return "Background (as supplied)"
        case .relationship: return "Relationship"
        }
    }
}

public nonisolated enum CasePersonAttributeOrigin: String, Sendable, CaseIterable, Codable {
    case source, supplied, investigatorNote, unsourced
}

public nonisolated struct CasePersonAttribute: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let personID: UUID
    public let kind: CasePersonAttributeKind
    public let value: String
    public let origin: CasePersonAttributeOrigin
    public let sourceVersionID: UUID?
    public let quote: String?
    public let suppliedBy: String?
    public let validFrom: Date?
    public let validTo: Date?
    public let validText: String?
    public let recordedBy: String
    public let recordedAt: Date
    public let withdrawnAt: Date?
    public var isActive: Bool { withdrawnAt == nil }
    /// Where it comes from, always stated.
    public var originLabel: String {
        switch origin {
        case .source: return "From a source (version \(sourceVersionID.map { String($0.uuidString.prefix(8)) } ?? "?"))" + (quote.map { ": “\($0)”" } ?? "")
        case .supplied: return "Supplied by \(suppliedBy ?? "someone") — not checked against a source"
        case .investigatorNote: return "Investigator's note — not from a source"
        case .unsourced: return "Unsourced — no origin recorded"
        }
    }
    public var periodLabel: String? {
        guard validFrom != nil || validTo != nil || validText != nil else { return nil }
        let range = (validFrom != nil || validTo != nil)
            ? (validFrom.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "…") + " – " + (validTo.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "…") : ""
        return [range, validText.map { "“\($0)”" } ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
    }
    public var line: String { "\(kind.label): \(value)" + (periodLabel.map { " (\($0))" } ?? "") + " — \(originLabel)" }
}

// MARK: - PEOPLE-03 whereabouts

public nonisolated enum CaseLocationTimePrecision: String, Sendable, CaseIterable, Codable { case instant, minute, day, month, year, unknown }
public nonisolated enum CaseLocationPlacePrecision: String, Sendable, CaseIterable, Codable { case exact, street, area, city, region, country, unknown }
public nonisolated enum CaseLocationBasis: String, Sendable, CaseIterable, Codable {
    case supplied, authorisedRecord, source, investigatorObservation
    public var label: String {
        switch self {
        case .supplied: return "supplied to the case"
        case .authorisedRecord: return "an authorised record"
        case .source: return "a document in the case"
        case .investigatorObservation: return "the investigator's own observation"
        }
    }
}

public nonisolated struct CasePersonLocation: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let personID: UUID
    public let place: String
    public let observedFrom: Date?
    public let observedTo: Date?
    public let timePrecision: CaseLocationTimePrecision
    public let placePrecision: CaseLocationPlacePrecision
    public let basis: CaseLocationBasis
    public let sourceVersionID: UUID?
    public let authority: String?
    public let uncertainty: String?
    public let recordedBy: String
    public let recordedAt: Date
    public let withdrawnAt: Date?
    public var isActive: Bool { withdrawnAt == nil }

    /// Always a past observation, with its age — never "where they are".
    public func label(now: Date = Date()) -> String {
        let when: String
        if let f = observedFrom {
            let fmt: (Date) -> String = { d in
                switch self.timePrecision {
                case .year: return d.formatted(.dateTime.year())
                case .month: return d.formatted(.dateTime.year().month(.wide))
                case .day, .unknown: return d.formatted(date: .abbreviated, time: .omitted)
                case .minute, .instant: return d.formatted(date: .abbreviated, time: .shortened)
                }
            }
            when = fmt(f) + (observedTo.map { " – " + fmt($0) } ?? "")
        } else { when = "time not recorded" }
        let days = observedFrom.map { max(0, Int(now.timeIntervalSince($0) / 86_400)) }
        let age = days.map { " — observed \($0) day(s) ago" } ?? ""
        var out = "Observed at \(place) (\(placePrecision.rawValue) precision), \(when) (\(timePrecision.rawValue) precision), from \(basis.label)\(age). "
        out += "A past observation, not the person's current location."
        if let u = uncertainty, !u.isEmpty { out += " Uncertainty: \(u)." }
        return out
    }
}

// MARK: - PEOPLE-04 interview items

public nonisolated struct CaseInterviewItem: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let interviewID: UUID
    public let ordinal: Int
    public let question: String
    public let response: String?
    public let recordingRef: String?
    public let recordingOffset: Double?
    public let transcriptRef: String?
    public let transcriptLocator: String?
    public let correctsID: UUID?
    public let correctionReason: String?
    public let addendumID: UUID?
    public let recordedBy: String
    public let recordedAt: Date
    public let supersededBy: UUID?
    public var isCurrent: Bool { supersededBy == nil }
}

/// One line of a witness's statement history, oldest first.
public nonisolated struct CaseStatementHistoryEntry: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable { case interview, confirmed, item, correction, attribution, restricted }
    public let id: String
    public let at: Date
    public let kind: Kind
    public let text: String
    public let record: CaseMapNodeID?
}

// MARK: - PEOPLE-05 participants (local)

public nonisolated struct CaseParticipant: Identifiable, Sendable, Equatable {
    public enum Appearance: String, Sendable, CaseIterable {
        /// Recorded actions in this ledger under this name (a local name on this Mac — not an authenticated account).
        case recordingUser
        /// Reported as having done work someone else entered (the external performer).
        case reportedPerformer
        /// A person of the case (witness, subject, …) — never a user of the app.
        case casePerson
    }
    public let name: String
    public let appearances: Set<Appearance>
    public let actionsRecorded: Int
    public let actionsReported: Int
    /// This Mac's account names the actions were recorded under (the session, not an identity check).
    public let sessionAccounts: [String]
    public var id: String { name }
    public let authenticated: Bool = false
}

// MARK: - PEOPLE-06 assignments and work history

public nonisolated struct CaseWorkAssignment: Identifiable, Sendable, Equatable {
    public enum WorkKind: String, Sendable, CaseIterable, Codable { case task, request, allegation, interview, report, other }
    public enum EndReason: String, Sendable, CaseIterable, Codable { case completed, released, reassigned, transferred }
    public let id: UUID
    public let caseID: UUID
    public let workKind: WorkKind
    public let workID: String
    public let assignee: String
    public let capability: String?
    public let assignedBy: String
    public let assignedAt: Date
    public let note: String?
    public let endedAt: Date?
    public let endedBy: String?
    public let endReason: EndReason?
    public let reassignedTo: String?
    public var isOpen: Bool { endedAt == nil }
    public var target: CaseMapNodeID? { Self.node(caseID: caseID, kind: workKind.rawValue, id: workID) }

    /// The map record of a piece of work (nil for "other").
    public static func node(caseID: UUID, kind: String?, id: String?) -> CaseMapNodeID? {
        guard let id, !id.isEmpty else { return nil }
        switch kind {
        case "task": return CaseMapNodeID(caseID: caseID, kind: .task, recordID: id)
        case "request": return CaseMapNodeID(caseID: caseID, kind: .request, recordID: id)
        case "allegation": return CaseMapNodeID(caseID: caseID, kind: .allegation, recordID: id)
        case "interview": return CaseMapNodeID(caseID: caseID, kind: .interview, recordID: id)
        case "report": return CaseMapNodeID(caseID: caseID, kind: .report, recordID: id)
        default: return nil
        }
    }
}

public nonisolated struct CaseWorkHistoryEntry: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable, CaseIterable {
        case assigned, reassignedAway, receivedByReassignment, transferredAway, completed, released, performed, reportedPerformer, submitted, reviewed, joined, left
        public var label: String {
            switch self {
            case .assigned: return "Assigned"
            case .reassignedAway: return "Reassigned to someone else"
            case .receivedByReassignment: return "Received by reassignment"
            case .transferredAway: return "Transferred on leaving the team"
            case .completed: return "Assignment completed"
            case .released: return "Assignment released"
            case .performed: return "Recorded work"
            case .reportedPerformer: return "Reported as having done the work (entered by someone else)"
            case .submitted: return "Submitted a result"
            case .reviewed: return "Reviewed"
            case .joined: return "Joined the case team"
            case .left: return "Left the case team"
            }
        }
    }
    public let id: String
    public let at: Date
    public let kind: Kind
    public let text: String
    /// The record it opens on the map; nil with `unavailable` saying why.
    public let target: CaseMapNodeID?
    public let unavailable: String?
}

public nonisolated struct CaseInvestigatorHistory: Sendable, Equatable {
    public let name: String
    public let entries: [CaseWorkHistoryEntry]
    /// First and last recorded involvement (nil: no involvement recorded).
    public let firstInvolved: Date?
    public let lastInvolved: Date?
    /// Recorded team periods ("lead from … to …").
    public let periods: [String]
    public let openAssignments: Int
}

// MARK: - PEOPLE-07 same-person assessment

public nonisolated struct CasePersonMatchReason: Codable, Sendable, Equatable, Hashable {
    public enum Kind: String, Codable, Sendable { case identifierMatch, identifierConflict, entitySame, entityDifferent, nameExact, nameVariant, nameDifferent, attributeMatch, attributeConflict }
    public let kind: Kind
    public let detail: String
    public var counts: String {
        switch kind {
        case .identifierMatch, .attributeMatch: return "points to the same person"
        case .identifierConflict, .entityDifferent, .attributeConflict, .nameDifferent: return "points to different people"
        case .entitySame: return "weak: the documents' person register merges identical names"
        case .nameExact, .nameVariant: return "weak: a name alone never shows two records are one person"
        }
    }
}

public nonisolated struct CasePersonMatchAssessment: Identifiable, Sendable, Equatable {
    public enum Verdict: String, Sendable, Codable {
        case strongCandidate, weakCandidate, keepSeparate, insufficient
        public var label: String {
            switch self {
            case .strongCandidate: return "Strong candidate — an identifier matches and nothing conflicts. Still two records until you decide."
            case .weakCandidate: return "Weak candidate — only the name (or the documents' register) matches. A name alone cannot merge two people."
            case .keepSeparate: return "Keep separate — recorded details conflict."
            case .insufficient: return "Not enough recorded to compare."
            }
        }
    }
    public let id: UUID
    public let personA: UUID
    public let personB: UUID
    public let ruleVersion: Int
    public let verdict: Verdict
    public let reasons: [CasePersonMatchReason]
    public let assessedBy: String
    public let assessedAt: Date
}

/// What the rule compares about one case-person row: its name, documents' person and recorded identifiers/attributes.
public nonisolated struct CasePersonEvidence: Sendable, Equatable {
    public var name: String
    public var entityID: UUID?
    /// "email:…", "phone:…", "id:…" (normalised).
    public var identifiers: Set<String>
    /// "organisation:…", "relationship:…" (normalised).
    public var attributes: Set<String>
    public init(name: String, entityID: UUID? = nil, identifiers: Set<String> = [], attributes: Set<String> = []) {
        self.name = name; self.entityID = entityID; self.identifiers = identifiers; self.attributes = attributes
    }
}

public nonisolated enum CasePersonMatcher {
    /// Bump when a rule changes: every stored assessment keeps the version it was made under.
    public static let ruleVersion = 1

    static func normalisedName(_ s: String) -> [String] {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
    }

    /// Pull identifiers out of free text (emails and phone numbers) — exact rules, no guessing.
    public static func identifiers(in text: String?) -> Set<String> {
        guard let text, !text.isEmpty else { return [] }
        var out = Set<String>()
        for word in text.components(separatedBy: CharacterSet(charactersIn: " ,;\n\t<>()")) {
            let w = word.trimmingCharacters(in: CharacterSet(charactersIn: ".:"))
            if w.contains("@"), w.contains(".") { out.insert("email:" + w.lowercased()) }
        }
        let digits = text.components(separatedBy: CharacterSet(charactersIn: "0123456789+ -()").inverted)
        for d in digits {
            let only = d.filter(\.isNumber)
            if only.count >= 8 { out.insert("phone:" + String(only.suffix(10))) }
        }
        return out
    }

    public static func assess(_ a: CasePersonEvidence, _ b: CasePersonEvidence) -> (CasePersonMatchAssessment.Verdict, [CasePersonMatchReason]) {
        var reasons: [CasePersonMatchReason] = []
        // Identifiers of the same type: a shared one matches; both having that type with none shared conflicts.
        let shared = a.identifiers.intersection(b.identifiers)
        for s in shared.sorted() { reasons.append(.init(kind: .identifierMatch, detail: "Both records carry \(s)")) }
        func type(_ s: String) -> String { String(s.prefix { $0 != ":" }) }
        for t in Set(a.identifiers.map(type)).intersection(Set(b.identifiers.map(type))).sorted() {
            let x = a.identifiers.filter { type($0) == t }, y = b.identifiers.filter { type($0) == t }
            if x.intersection(y).isEmpty {
                reasons.append(.init(kind: .identifierConflict, detail: "Different \(t): \(x.sorted().joined(separator: ", ")) vs \(y.sorted().joined(separator: ", "))"))
            }
        }
        if let ea = a.entityID, let eb = b.entityID {
            reasons.append(ea == eb ? .init(kind: .entitySame, detail: "Both rows are linked to the same person in the documents' register")
                                    : .init(kind: .entityDifferent, detail: "The rows are linked to different people in the documents' register"))
        }
        let na = normalisedName(a.name), nb = normalisedName(b.name)
        if !na.isEmpty, na == nb { reasons.append(.init(kind: .nameExact, detail: "Same name: “\(a.name)”")) }
        else if na.count >= 2, nb.count >= 2, na.last == nb.last, na.first?.first == nb.first?.first {
            reasons.append(.init(kind: .nameVariant, detail: "Similar name (same surname and initial): “\(a.name)” / “\(b.name)”"))
        } else if !na.isEmpty, !nb.isEmpty { reasons.append(.init(kind: .nameDifferent, detail: "Different names: “\(a.name)” / “\(b.name)”")) }
        for s in a.attributes.intersection(b.attributes).sorted() { reasons.append(.init(kind: .attributeMatch, detail: "Both: \(s)")) }
        let conflicts = reasons.contains { [.identifierConflict, .entityDifferent, .attributeConflict].contains($0.kind) }
        let strong = reasons.contains { $0.kind == .identifierMatch }
        let weak = reasons.contains { [.nameExact, .nameVariant, .entitySame, .attributeMatch].contains($0.kind) }
        let verdict: CasePersonMatchAssessment.Verdict = conflicts ? .keepSeparate : strong ? .strongCandidate : weak ? .weakCandidate : .insufficient
        return (verdict, reasons)
    }
}

// MARK: - PEOPLE-08 capabilities and routing

public nonisolated struct CaseInvestigatorCapability: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let investigator: String
    public let capability: String
    public let basis: String
    public let declaredBy: String
    public let declaredAt: Date
    public let withdrawnAt: Date?
    public var isActive: Bool { withdrawnAt == nil }
}

public nonisolated struct CaseRoutingCandidate: Identifiable, Sendable, Equatable {
    public let name: String
    public let eligible: Bool
    /// Every reason, for and against — declared facts only (capability, availability, conflict check, team).
    public let reasons: [String]
    public var id: String { name }
}

// MARK: - PEOPLE-09 team and the acting gate

public nonisolated struct CaseTeamMembership: Identifiable, Sendable, Equatable {
    public enum Role: String, Sendable, CaseIterable, Codable { case lead, investigator, reviewer, contributor }
    public let id: UUID
    public let caseID: UUID
    public let member: String
    public let role: Role
    public let startedAt: Date
    public let endedAt: Date?
    public let endReason: String?
    public let transferredTo: String?
    public var isActive: Bool { endedAt == nil }
}

public nonisolated enum CaseMembershipGate {
    /// Why `name` may not act in the case now, or nil. A case with no team recorded is a solo case (anyone recording on this
    /// Mac acts). Once a team is recorded, a person whose every membership has ended cannot act — read from the ledger at
    /// the moment of acting, so no cached grant or queued job outlives the departure.
    static func refusal(_ db: isolated Database, caseID: UUID, name: String) throws -> String? {
        guard try !db.query("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'case_team_memberships';", []).isEmpty else { return nil }
        let rows = try db.query("SELECT ended_at, end_reason FROM case_team_memberships WHERE case_id = ? AND member = ?;", [.uuid(caseID), .text(name)])
        if rows.contains(where: { $0.isNull(0) }) { return nil }
        if let ended = rows.first { return "\(name)'s membership of this case team ended (\(ended.string(1) ?? "no reason recorded"))." }
        return nil
    }
    static func require(_ db: isolated Database, caseID: UUID, name: String) throws {
        if let why = try refusal(db, caseID: caseID, name: name) { throw CasePeopleError.notActiveMember(why) }
    }
}

// MARK: - PEOPLE-10 restrictions and the profile

public nonisolated struct CasePersonRestriction: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let personID: UUID
    public let reason: String
    public let setBy: String
    public let setAt: Date
    public let liftedAt: Date?
    public var isActive: Bool { liftedAt == nil }
}

/// A person's profile as a reader may see it: every line says where it comes from; a restricted profile withholds its
/// content and says how much was withheld.
public nonisolated struct CasePersonProfile: Sendable, Equatable {
    public let person: CasePerson
    public let roles: [CasePersonRoleRecord]
    public let attributes: [CasePersonAttribute]
    public let locations: [CasePersonLocation]
    /// The card's free-text notes and contact, shown as unsourced.
    public let unsourcedCardLines: [String]
    /// Names the documents' person register holds for them (each from the documents, not checked).
    public let registerAliases: [String]
    public let restriction: CasePersonRestriction?
    public let withheld: Int
    public var isRestricted: Bool { restriction != nil }
    /// Every line the profile shows, each with its origin.
    public var lines: [String] {
        if let r = restriction {
            return ["\(person.name) — \(CasePersonRoleKind(person.role).label)",
                    "Restricted profile: \(withheld) item(s) withheld (\(r.reason), set by \(r.setBy)). They exist; they are not shown or exported while the restriction stands."]
        }
        var out = ["\(person.name) — " + ([CasePersonRoleKind(person.role).label] + roles.filter(\.isActive).map(\.line)).joined(separator: "; ")]
        out += attributes.filter(\.isActive).map(\.line)
        out += unsourcedCardLines
        out += registerAliases.map { "Also known as: \($0) — from the documents' person register (not checked)" }
        out += locations.filter(\.isActive).map { $0.label() }
        return out
    }
}

public nonisolated enum CasePeopleError: Error, Equatable, LocalizedError {
    case notAPerson
    case duplicateRole
    case alreadyEnded
    case futureObservation
    case statementConfirmed
    case notConfirmed
    case itemSuperseded
    case notFound(String)
    case alreadyAssigned(String)
    case conflictRecorded(String)
    case capabilityNotDeclared(String)
    case notActiveMember(String)
    case pendingWorkNeedsTransfer(Int)
    case alreadyRestricted
    case samePerson
    public var errorDescription: String? {
        switch self {
        case .notAPerson: return "Choose a person of this case."
        case .duplicateRole: return "This person already holds that role in that context."
        case .alreadyEnded: return "It has already ended."
        case .futureObservation: return "An observation is of where someone was; a time in the future is a plan, not an observation."
        case .statementConfirmed: return "The statement is confirmed: record a correction instead of changing it."
        case .notConfirmed: return "The statement is not confirmed yet; change the item directly."
        case .itemSuperseded: return "That item was already corrected; correct the current one."
        case .notFound(let what): return "The \(what) was not found in this case."
        case .alreadyAssigned(let who): return "This work is assigned to \(who). Reassign it instead."
        case .conflictRecorded(let who): return "\(who) has a recorded conflict in this case (not waived), so the work cannot be assigned to them."
        case .capabilityNotDeclared(let why): return why
        case .notActiveMember(let why): return why
        case .pendingWorkNeedsTransfer(let n): return "\(n) piece(s) of work are still assigned to this person. Name who takes them over."
        case .alreadyRestricted: return "This profile is already restricted."
        case .samePerson: return "Choose two different people."
        }
    }
}

// MARK: - Repository

extension CaseFileRepository {

    /// The map record kind of a before/after copy's record kind (nil: not a map record).
    nonisolated static func mapKind(revisionKind: String?) -> CaseMapRecordKind? {
        guard let k = revisionKind else { return nil }
        if k == "profile" { return .caseFile }
        guard let kind = CaseMapRecordKind(rawValue: k), CaseMapRecordKind.nodeKinds.contains(kind) else { return nil }
        return kind
    }

    static func requirePerson(_ db: isolated Database, _ id: UUID, caseID: UUID) throws {
        guard try !db.query("SELECT 1 FROM case_people WHERE case_id = ? AND id IN (?, ?) AND removed_at IS NULL;",
                            [.uuid(caseID), .text(id.uuidString), .text(id.uuidString.lowercased())]).isEmpty else { throw CasePeopleError.notAPerson }
    }

    // MARK: PEOPLE-01

    @discardableResult
    public func addPersonRole(caseID: UUID, personID: UUID, role: CasePersonRoleKind, context: String?, validFrom: Date? = nil, validTo: Date? = nil,
                              actor: String, at date: Date = Date()) async throws -> UUID {
        let who = try Self.clean(actor, "Actor")
        if let a = validFrom, let b = validTo, b < a { throw CaseReasoningError.badPeriod }
        let ctx = Self.blankToNil(context)
        let id = UUID()
        try await write("cf_prole", caseID: caseID, actor: who, action: "personRoleAdded", detail: role.rawValue + (ctx.map { ": \($0)" } ?? ""), at: date) { db in
            try Self.requirePerson(db, personID, caseID: caseID)
            let dup = try db.query("SELECT 1 FROM case_person_roles WHERE case_id = ? AND lower(case_person_id) = ? AND role = ? AND coalesce(context,'') = ? AND ended_at IS NULL;",
                                   [.uuid(caseID), .text(personID.uuidString.lowercased()), .text(role.rawValue), .text(ctx ?? "")])
            if !dup.isEmpty { throw CasePeopleError.duplicateRole }
            try db.exec("""
                INSERT INTO case_person_roles (id, case_id, case_person_id, role, context, valid_from, valid_to, recorded_by, recorded_at) VALUES (?,?,?,?,?,?,?,?,?);
                """, [.uuid(id), .uuid(caseID), .text(personID.uuidString.lowercased()), .text(role.rawValue), .optionalText(ctx), .optionalDate(validFrom),
                      .optionalDate(validTo), .text(who), .date(date)])
        }
        return id
    }

    public func endPersonRole(caseID: UUID, id: UUID, reason: String, actor: String, at date: Date = Date()) async throws {
        let who = try Self.clean(actor, "Actor"), why = try Self.clean(reason, "The reason")
        try await write("cf_prolex", caseID: caseID, actor: who, action: "personRoleEnded", detail: why, at: date) { db in
            guard let r = try db.query("SELECT ended_at FROM case_person_roles WHERE id = ? AND case_id = ?;", [.uuid(id), .uuid(caseID)]).first else {
                throw CasePeopleError.notFound("role")
            }
            guard r.isNull(0) else { throw CasePeopleError.alreadyEnded }
            try db.exec("UPDATE case_person_roles SET ended_by = ?, ended_at = ?, ended_reason = ? WHERE id = ?;", [.text(who), .date(date), .text(why), .uuid(id)])
        }
    }

    public func personRoles(caseID: UUID) async throws -> [CasePersonRoleRecord] {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        return try await database.query("""
            SELECT id, case_person_id, role, context, valid_from, valid_to, recorded_by, recorded_at, ended_at, ended_reason
            FROM case_person_roles WHERE case_id = ? ORDER BY recorded_at, id;
            """, [.uuid(caseID)]).compactMap { r in
            guard let id = r.uuid(0), let p = r.uuid(1), let role = r.string(2).flatMap(CasePersonRoleKind.init(rawValue:)), let by = r.string(6),
                  let at = r.date(7) else { return nil }
            return CasePersonRoleRecord(id: id, caseID: caseID, personID: p, role: role, context: r.string(3), validFrom: r.date(4), validTo: r.date(5),
                                        recordedBy: by, recordedAt: at, endedAt: r.date(8), endedReason: r.string(9))
        }
    }

    /// Add a person, or — when a row of this case is already linked to the same person in the documents — add the role
    /// to that row instead of creating a second one for the same person.
    public func addPersonOrRole(caseID: UUID, name: String, role: CasePersonRoleKind, context: String?, entityID: UUID?, actor: String,
                                at date: Date = Date()) async throws -> CasePersonAddOutcome {
        try await CaseAccessPolicy.requireChange(database, caseID: caseID, actor: actor, .work)
        if let entityID, let existing = try await people(caseID: caseID).first(where: { $0.entityID == entityID }) {
            if CasePersonRoleKind(existing.role) == role, Self.blankToNil(context) == nil { throw CasePeopleError.duplicateRole }
            let r = try await addPersonRole(caseID: caseID, personID: existing.id, role: role, context: context, actor: actor, at: date)
            return .roleAdded(person: existing.id, role: r)
        }
        let legacy: CasePersonRole = {
            switch role {
            case .subject: return .subject
            case .witness: return .witness
            case .complainant: return .complainant
            case .custodian: return .custodian
            default: return .other
            }
        }()
        let id = try await addPerson(caseID: caseID, name: name, role: legacy, entityID: entityID, contact: nil, notes: nil, actor: actor, at: date)
        if legacy == .other, role != .other {
            _ = try await addPersonRole(caseID: caseID, personID: id, role: role, context: context, actor: actor, at: date)
        }
        return .added(id)
    }

    /// Each canonical person with all their roles, and other rows linked to the same documents' person.
    public func identityViews(caseID: UUID) async throws -> [CasePersonIdentityView] {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        let people = try await people(caseID: caseID)
        let roles = try await personRoles(caseID: caseID).filter(\.isActive)
        return people.map { p in
            let same = p.entityID.map { e in people.filter { $0.id != p.id && $0.entityID == e }.map(\.id) } ?? []
            return CasePersonIdentityView(person: p, roles: [CasePersonRoleKind(p.role).label] + roles.filter { $0.personID == p.id }.map(\.line), sameEntityRows: same)
        }
    }

    // MARK: PEOPLE-02

    @discardableResult
    public func addPersonAttribute(caseID: UUID, personID: UUID, kind: CasePersonAttributeKind, value: String, origin: CasePersonAttributeOrigin,
                                   sourceVersionID: UUID? = nil, blockID: UUID? = nil, quote: String? = nil, suppliedBy: String? = nil,
                                   validFrom: Date? = nil, validTo: Date? = nil, validText: String? = nil, actor: String, at date: Date = Date()) async throws -> UUID {
        let who = try Self.clean(actor, "Actor"), v = try Self.clean(value, "The value")
        if origin == .source, sourceVersionID == nil { throw CaseWorkError.sourceNotInCase }
        if origin == .supplied, Self.blankToNil(suppliedBy) == nil { throw CaseFileError.blank("Who supplied it") }
        if let a = validFrom, let b = validTo, b < a { throw CaseReasoningError.badPeriod }
        let id = UUID()
        try await write("cf_pattr", caseID: caseID, actor: who, action: "personAttributeRecorded", detail: "\(kind.rawValue) (\(origin.rawValue))", at: date) { db in
            try Self.requirePerson(db, personID, caseID: caseID)
            if let s = sourceVersionID, !(try Self.versionInCase(db, s, caseID: caseID)) { throw CaseWorkError.sourceNotInCase }
            try db.exec("""
                INSERT INTO case_person_attributes (id, case_id, case_person_id, attribute, value, origin, source_version_id, block_id, quote, supplied_by,
                    valid_from, valid_to, valid_text, recorded_by, recorded_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
                """, [.uuid(id), .uuid(caseID), .text(personID.uuidString.lowercased()), .text(kind.rawValue), .text(v), .text(origin.rawValue),
                      sourceVersionID.map { .uuid($0) } ?? .null, blockID.map { .uuid($0) } ?? .null, .optionalText(Self.blankToNil(quote)),
                      .optionalText(Self.blankToNil(suppliedBy)), .optionalDate(validFrom), .optionalDate(validTo), .optionalText(Self.blankToNil(validText)),
                      .text(who), .date(date)])
        }
        return id
    }

    public func withdrawPersonAttribute(caseID: UUID, id: UUID, reason: String, actor: String, at date: Date = Date()) async throws {
        let who = try Self.clean(actor, "Actor"), why = try Self.clean(reason, "The reason")
        try await write("cf_pattrw", caseID: caseID, actor: who, action: "personAttributeWithdrawn", detail: why, at: date) { db in
            guard let r = try db.query("SELECT withdrawn_at FROM case_person_attributes WHERE id = ? AND case_id = ?;", [.uuid(id), .uuid(caseID)]).first else {
                throw CasePeopleError.notFound("attribute")
            }
            guard r.isNull(0) else { throw CasePeopleError.alreadyEnded }
            try db.exec("UPDATE case_person_attributes SET withdrawn_by = ?, withdrawn_at = ?, withdrawn_reason = ? WHERE id = ?;", [.text(who), .date(date), .text(why), .uuid(id)])
        }
    }

    public func personAttributes(caseID: UUID) async throws -> [CasePersonAttribute] {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        return try await database.query("""
            SELECT id, case_person_id, attribute, value, origin, source_version_id, quote, supplied_by, valid_from, valid_to, valid_text, recorded_by, recorded_at, withdrawn_at
            FROM case_person_attributes WHERE case_id = ? ORDER BY recorded_at, id;
            """, [.uuid(caseID)]).compactMap { r in
            guard let id = r.uuid(0), let p = r.uuid(1), let k = r.string(2).flatMap(CasePersonAttributeKind.init(rawValue:)), let v = r.string(3),
                  let o = r.string(4).flatMap(CasePersonAttributeOrigin.init(rawValue:)), let by = r.string(11), let at = r.date(12) else { return nil }
            return CasePersonAttribute(id: id, personID: p, kind: k, value: v, origin: o, sourceVersionID: r.uuid(5), quote: r.string(6), suppliedBy: r.string(7),
                                       validFrom: r.date(8), validTo: r.date(9), validText: r.string(10), recordedBy: by, recordedAt: at, withdrawnAt: r.date(13))
        }
    }

    // MARK: PEOPLE-03

    @discardableResult
    public func recordLocationObservation(caseID: UUID, personID: UUID, place: String, observedFrom: Date?, observedTo: Date? = nil,
                                          timePrecision: CaseLocationTimePrecision, placePrecision: CaseLocationPlacePrecision, basis: CaseLocationBasis,
                                          sourceVersionID: UUID? = nil, quote: String? = nil, authority: String? = nil, uncertainty: String? = nil,
                                          actor: String, at date: Date = Date()) async throws -> UUID {
        let who = try Self.clean(actor, "Actor"), where_ = try Self.clean(place, "The place")
        if let f = observedFrom, f > date.addingTimeInterval(60) { throw CasePeopleError.futureObservation }
        if let a = observedFrom, let b = observedTo, b < a { throw CaseReasoningError.badPeriod }
        if basis == .source, sourceVersionID == nil { throw CaseWorkError.sourceNotInCase }
        if basis == .authorisedRecord, Self.blankToNil(authority) == nil { throw CaseFileError.blank("The authority for the record") }
        let id = UUID()
        try await write("cf_ploc", caseID: caseID, actor: who, action: "locationObserved", detail: basis.rawValue, at: date) { db in
            try Self.requirePerson(db, personID, caseID: caseID)
            if let s = sourceVersionID, !(try Self.versionInCase(db, s, caseID: caseID)) { throw CaseWorkError.sourceNotInCase }
            try db.exec("""
                INSERT INTO case_person_locations (id, case_id, case_person_id, place, observed_from, observed_to, time_precision, place_precision, basis,
                    source_version_id, quote, authority, uncertainty, recorded_by, recorded_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
                """, [.uuid(id), .uuid(caseID), .text(personID.uuidString.lowercased()), .text(where_), .optionalDate(observedFrom), .optionalDate(observedTo),
                      .text(timePrecision.rawValue), .text(placePrecision.rawValue), .text(basis.rawValue), sourceVersionID.map { .uuid($0) } ?? .null,
                      .optionalText(Self.blankToNil(quote)), .optionalText(Self.blankToNil(authority)), .optionalText(Self.blankToNil(uncertainty)), .text(who), .date(date)])
        }
        return id
    }

    public func locationObservations(caseID: UUID) async throws -> [CasePersonLocation] {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        return try await database.query("""
            SELECT id, case_person_id, place, observed_from, observed_to, time_precision, place_precision, basis, source_version_id, authority, uncertainty,
                   recorded_by, recorded_at, withdrawn_at
            FROM case_person_locations WHERE case_id = ? ORDER BY coalesce(observed_from, recorded_at), id;
            """, [.uuid(caseID)]).compactMap { r in
            guard let id = r.uuid(0), let p = r.uuid(1), let place = r.string(2), let tp = r.string(5).flatMap(CaseLocationTimePrecision.init(rawValue:)),
                  let pp = r.string(6).flatMap(CaseLocationPlacePrecision.init(rawValue:)), let b = r.string(7).flatMap(CaseLocationBasis.init(rawValue:)),
                  let by = r.string(11), let at = r.date(12) else { return nil }
            return CasePersonLocation(id: id, personID: p, place: place, observedFrom: r.date(3), observedTo: r.date(4), timePrecision: tp, placePrecision: pp,
                                      basis: b, sourceVersionID: r.uuid(8), authority: r.string(9), uncertainty: r.string(10), recordedBy: by, recordedAt: at,
                                      withdrawnAt: r.date(13))
        }
    }

    // MARK: PEOPLE-04

    static func requireRefInCase(_ db: isolated Database, _ ref: String?, caseID: UUID) throws {
        guard let ref = Self.blankToNil(ref) else { return }
        if let problem = try CaseEvidenceReference.problem(ref, caseID: caseID, in: db) { throw CaseFileError.unresolvedReference(ref, problem) }
    }

    /// Record one question and its response. Refused once the statement is confirmed (record a correction instead).
    @discardableResult
    public func addInterviewItem(caseID: UUID, interviewID: UUID, question: String, response: String?, recordingRef: String? = nil, recordingOffset: Double? = nil,
                                 transcriptRef: String? = nil, transcriptLocator: String? = nil, actor: String, at date: Date = Date()) async throws -> UUID {
        let who = try Self.clean(actor, "Actor"), q = try Self.clean(question, "The question")
        let id = UUID()
        try await write("cf_ivitem", caseID: caseID, actor: who, action: "interviewItemRecorded", detail: String(q.prefix(80)), at: date) { db in
            guard let st = try db.query("SELECT status FROM case_interviews WHERE id = ? AND case_id = ?;", [.uuid(interviewID), .uuid(caseID)]).first?.string(0) else {
                throw CaseFileError.notInCase("interview", interviewID)
            }
            guard st != "attested" else { throw CasePeopleError.statementConfirmed }
            try Self.requireRefInCase(db, recordingRef, caseID: caseID)
            try Self.requireRefInCase(db, transcriptRef, caseID: caseID)
            let next = (try db.query("SELECT coalesce(MAX(ordinal), 0) FROM case_interview_items WHERE interview_id = ?;", [.uuid(interviewID)]).first?.int(0) ?? 0) + 1
            try db.exec("""
                INSERT INTO case_interview_items (id, case_id, interview_id, ordinal, question, response, recording_ref, recording_offset, transcript_ref,
                    transcript_locator, recorded_by, recorded_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?);
                """, [.uuid(id), .uuid(caseID), .uuid(interviewID), .integer(next), .text(q), .optionalText(Self.blankToNil(response)),
                      .optionalText(Self.blankToNil(recordingRef)), recordingOffset.map { .real($0) } ?? .null, .optionalText(Self.blankToNil(transcriptRef)),
                      .optionalText(Self.blankToNil(transcriptLocator)), .text(who), .date(date)])
        }
        return id
    }

    /// Change an item while the statement is not confirmed yet.
    public func updateInterviewItem(caseID: UUID, id: UUID, question: String, response: String?, actor: String, at date: Date = Date()) async throws {
        let who = try Self.clean(actor, "Actor"), q = try Self.clean(question, "The question")
        try await write("cf_ivitemu", caseID: caseID, actor: who, action: "interviewItemUpdated", detail: String(q.prefix(80)), at: date) { db in
            guard let r = try db.query("""
                SELECT i.status, it.superseded_by FROM case_interview_items it JOIN case_interviews i ON i.id = it.interview_id WHERE it.id = ? AND it.case_id = ?;
                """, [.uuid(id), .uuid(caseID)]).first else { throw CasePeopleError.notFound("interview item") }
            guard r.string(0) != "attested" else { throw CasePeopleError.statementConfirmed }
            guard r.isNull(1) else { throw CasePeopleError.itemSuperseded }
            try db.exec("UPDATE case_interview_items SET question = ?, response = ? WHERE id = ?;", [.text(q), .optionalText(Self.blankToNil(response)), .uuid(id)])
        }
    }

    /// Correct an item of a CONFIRMED statement: an addendum (the correction and its reason) and a new item that corrects
    /// the old one, in one savepoint. The old item stays exactly as confirmed.
    @discardableResult
    public func correctInterviewItem(caseID: UUID, id: UUID, question: String?, response: String?, reason: String, actor: String,
                                     at date: Date = Date()) async throws -> (item: UUID, addendum: UUID) {
        let who = try Self.clean(actor, "Actor"), why = try Self.clean(reason, "Reason for the correction")
        let newID = UUID(), addendum = UUID()
        try await write("cf_ivitemc", caseID: caseID, actor: who, action: "interviewItemCorrected", detail: why, at: date) { db in
            guard let r = try db.query("""
                SELECT it.interview_id, it.ordinal, it.question, it.response, it.recording_ref, it.recording_offset, it.transcript_ref, it.transcript_locator,
                       it.superseded_by, i.status
                FROM case_interview_items it JOIN case_interviews i ON i.id = it.interview_id WHERE it.id = ? AND it.case_id = ?;
                """, [.uuid(id), .uuid(caseID)]).first, let iv = r.uuid(0) else { throw CasePeopleError.notFound("interview item") }
            guard r.string(9) == "attested" else { throw CasePeopleError.notConfirmed }
            guard r.isNull(8) else { throw CasePeopleError.itemSuperseded }
            let q = Self.blankToNil(question) ?? (r.string(2) ?? "")
            let resp = response.map { Self.blankToNil($0) } ?? r.string(3)
            let text = "Correction to question \(r.int(1) ?? 0) (“\(q.prefix(80))”): " + (resp ?? "no response recorded")
            try db.exec("""
                INSERT INTO case_statement_addenda (id, interview_id, case_id, text, reason, sha256, recorded_by, recorded_at) VALUES (?,?,?,?,?,?,?,?);
                """, [.uuid(addendum), .uuid(iv), .uuid(caseID), .text(text), .text(why), .text(CaseFileHash.sha256(text)), .text(who), .date(date)])
            try db.exec("""
                INSERT INTO case_interview_items (id, case_id, interview_id, ordinal, question, response, recording_ref, recording_offset, transcript_ref,
                    transcript_locator, corrects_id, correction_reason, addendum_id, recorded_by, recorded_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
                """, [.uuid(newID), .uuid(caseID), .uuid(iv), .integer(r.int(1) ?? 1), .text(q), .optionalText(resp), .optionalText(r.string(4)),
                      r.double(5).map { .real($0) } ?? .null, .optionalText(r.string(6)), .optionalText(r.string(7)),
                      .uuid(id), .text(why), .uuid(addendum), .text(who), .date(date)])
            try db.exec("UPDATE case_interview_items SET superseded_by = ? WHERE id = ?;", [.uuid(newID), .uuid(id)])
        }
        return (newID, addendum)
    }

    public func interviewItems(caseID: UUID) async throws -> [CaseInterviewItem] {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        return try await database.query("""
            SELECT id, interview_id, ordinal, question, response, recording_ref, recording_offset, transcript_ref, transcript_locator, corrects_id, correction_reason,
                   addendum_id, recorded_by, recorded_at, superseded_by
            FROM case_interview_items WHERE case_id = ? ORDER BY interview_id, ordinal, recorded_at;
            """, [.uuid(caseID)]).compactMap { r in
            guard let id = r.uuid(0), let iv = r.uuid(1), let q = r.string(3), let by = r.string(12), let at = r.date(13) else { return nil }
            return CaseInterviewItem(id: id, interviewID: iv, ordinal: Int(r.int(2) ?? 1), question: q, response: r.string(4), recordingRef: r.string(5),
                                     recordingOffset: r.double(6), transcriptRef: r.string(7), transcriptLocator: r.string(8),
                                     correctsID: r.uuid(9), correctionReason: r.string(10), addendumID: r.uuid(11), recordedBy: by, recordedAt: at,
                                     supersededBy: r.uuid(14))
        }
    }

    /// A witness's statement history: their interviews, confirmations, questions and responses, corrections and the
    /// statements attributed to them — oldest first. A restricted profile withholds the content and says so.
    public func statementHistory(caseID: UUID, personID: UUID) async throws -> [CaseStatementHistoryEntry] {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        let restricted = try await activeRestriction(caseID: caseID, personID: personID)
        let ivs = try await interviews(caseID: caseID).filter { $0.personID == personID }
        let ivIDs = Set(ivs.map(\.id))
        let items = try await interviewItems(caseID: caseID).filter { ivIDs.contains($0.interviewID) }
        let addenda = try await addenda(caseID: caseID).filter { ivIDs.contains($0.interviewID) }
        let attributions = try await database.query("""
            SELECT id, claim, mode, recorded_at FROM case_assertion_attributions WHERE case_id = ? AND lower(case_person_id) = ? AND withdrawn_at IS NULL;
            """, [.uuid(caseID), .text(personID.uuidString.lowercased())])
        if let r = restricted {
            let n = ivs.count + items.count + addenda.count + attributions.count
            return [CaseStatementHistoryEntry(id: "restricted", at: r.setAt, kind: .restricted,
                                              text: "Restricted profile: \(n) statement record(s) withheld (\(r.reason)). They exist and are kept.", record: nil)]
        }
        var out: [CaseStatementHistoryEntry] = []
        for iv in ivs {
            let node = CaseMapNodeID(caseID: caseID, kind: .interview, id: iv.id)
            out.append(.init(id: "iv:\(iv.id)", at: iv.scheduledAt ?? iv.createdAt, kind: .interview,
                             text: "Interview (\(iv.status.label))" + (iv.location.map { " at \($0)" } ?? ""), record: node))
            if let at = iv.attestedAt {
                out.append(.init(id: "att:\(iv.id)", at: at, kind: .confirmed,
                                 text: "Statement confirmed by \(iv.attestedBy ?? "the interviewee")" + (iv.statementIntact ? "" : " — the stored text no longer matches what was confirmed"),
                                 record: node))
            }
        }
        for it in items {
            out.append(.init(id: "item:\(it.id)", at: it.recordedAt, kind: it.correctsID == nil ? .item : .correction,
                             text: (it.correctsID == nil ? "Q\(it.ordinal): " : "Correction of Q\(it.ordinal) (\(it.correctionReason ?? "")): ")
                                + "\(it.question) — \(it.response ?? "no response recorded")" + (it.isCurrent ? "" : " [corrected later; kept as confirmed]"),
                             record: CaseMapNodeID(caseID: caseID, kind: .interview, id: it.interviewID)))
        }
        for a in addenda {
            out.append(.init(id: "add:\(a.id)", at: a.recordedAt, kind: .correction, text: "Addendum: \(a.text) (reason: \(a.reason))",
                             record: CaseMapNodeID(caseID: caseID, kind: .addendum, id: a.id)))
        }
        for r in attributions {
            guard let id = r.string(0), let at = r.date(3) else { continue }
            out.append(.init(id: "attr:\(id)", at: at, kind: .attribution, text: "Attributed statement (\(r.string(2) ?? "")): \(r.string(1) ?? "")", record: nil))
        }
        return out.sorted { $0.at != $1.at ? $0.at < $1.at : $0.id < $1.id }
    }

    // MARK: PEOPLE-05 (local part)

    /// The names that recorded actions in this ledger, the names reported as performers, and the case's people — kept
    /// apart. None is an authenticated account.
    public func participants(caseID: UUID) async throws -> [CaseParticipant] {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        var recorded: [String: Int] = [:], reported: [String: Int] = [:], accounts: [String: Set<String>] = [:]
        for r in try await database.query("SELECT actor, performed_by, session_account FROM case_actions WHERE case_id = ?;", [.uuid(caseID)]) {
            if let a = r.string(0) { recorded[a, default: 0] += 1; if let s = r.string(2) { accounts[a, default: []].insert(s) } }
            if let p = r.string(1) { reported[p, default: 0] += 1 }
        }
        let people = Set(try await people(caseID: caseID).map(\.name))
        let names = Set(recorded.keys).union(reported.keys).union(people)
        return names.sorted().map { n in
            var app = Set<CaseParticipant.Appearance>()
            if recorded[n] != nil { app.insert(.recordingUser) }
            if reported[n] != nil { app.insert(.reportedPerformer) }
            if people.contains(n) { app.insert(.casePerson) }
            return CaseParticipant(name: n, appearances: app, actionsRecorded: recorded[n] ?? 0, actionsReported: reported[n] ?? 0,
                                   sessionAccounts: (accounts[n] ?? []).sorted())
        }
    }

    // MARK: PEOPLE-06 / PEOPLE-08 / PEOPLE-09 assignments

    /// Assign work to a person. Refused when it is already assigned (reassign instead), when the person has an unwaived
    /// conflict recorded in this case, when a required capability is not declared by them, or when either person's team
    /// membership has ended.
    @discardableResult
    public func assignWork(caseID: UUID, kind: CaseWorkAssignment.WorkKind, workID: String, to assignee: String, capability: String? = nil, note: String? = nil,
                           actor: String, at date: Date = Date()) async throws -> UUID {
        let who = try Self.clean(actor, "Actor"), to = try Self.clean(assignee, "Who it is assigned to"), work = try Self.clean(workID, "The work")
        let cap = Self.blankToNil(capability)
        let id = UUID()
        try await write("cf_assign", caseID: caseID, actor: who, action: "workAssigned", detail: "\(kind.rawValue) → \(to)", at: date,
                        capture: .workAssignment(id)) { db in
            try Self.checkAssignable(db, caseID: caseID, kind: kind, workID: work, assignee: to, capability: cap, actor: who, at: date)
            try db.exec("""
                INSERT INTO case_work_assignments (id, case_id, work_kind, work_id, assignee, capability, assigned_by, assigned_at, note) VALUES (?,?,?,?,?,?,?,?,?);
                """, [.uuid(id), .uuid(caseID), .text(kind.rawValue), .text(work.lowercased()), .text(to), .optionalText(cap), .text(who), .date(date),
                      .optionalText(Self.blankToNil(note))])
        }
        return id
    }

    static func checkAssignable(_ db: isolated Database, caseID: UUID, kind: CaseWorkAssignment.WorkKind, workID: String, assignee: String, capability: String?,
                                actor: String, at date: Date) throws {
        try CaseMembershipGate.require(db, caseID: caseID, name: actor)
        try CaseMembershipGate.require(db, caseID: caseID, name: assignee)
        if let open = try db.query("SELECT assignee FROM case_work_assignments WHERE case_id = ? AND work_kind = ? AND work_id = ? AND ended_at IS NULL;",
                                   [.uuid(caseID), .text(kind.rawValue), .text(workID.lowercased())]).first?.string(0) {
            throw CasePeopleError.alreadyAssigned(open)
        }
        let checks = try db.query("SELECT result FROM case_conflict_checks WHERE case_id = ? AND investigator = ? ORDER BY checked_at DESC LIMIT 1;",
                                  [.uuid(caseID), .text(assignee)])
        if checks.first?.string(0) == "conflict" { throw CasePeopleError.conflictRecorded(assignee) }
        if let cap = capability {
            let declared = try db.query("SELECT 1 FROM investigator_capabilities WHERE investigator = ? AND lower(capability) = lower(?) AND withdrawn_at IS NULL;",
                                        [.text(assignee), .text(cap)])
            if declared.isEmpty {
                throw CasePeopleError.capabilityNotDeclared("\(assignee) has not declared “\(cap)”. Assignment never assumes expertise: record the capability first, or assign without it.")
            }
        }
    }

    /// Hand open work to someone else: the old assignment ends "reassigned to …" and a new one starts. Attribution of
    /// everything done so far is untouched.
    @discardableResult
    public func reassignWork(caseID: UUID, assignmentID: UUID, to newAssignee: String, reason: String, actor: String, at date: Date = Date()) async throws -> UUID {
        let who = try Self.clean(actor, "Actor"), to = try Self.clean(newAssignee, "Who takes it over"), why = try Self.clean(reason, "The reason")
        let id = UUID()
        try await write("cf_reassign", caseID: caseID, actor: who, action: "workAssignmentEnded", detail: "reassigned → \(to): \(why)", at: date,
                        capture: .workAssignment(assignmentID), alsoCapture: [.workAssignment(id)]) { db in
            guard let r = try db.query("SELECT work_kind, work_id, capability, ended_at FROM case_work_assignments WHERE id = ? AND case_id = ?;",
                                       [.uuid(assignmentID), .uuid(caseID)]).first,
                  let kind = r.string(0).flatMap(CaseWorkAssignment.WorkKind.init(rawValue:)), let work = r.string(1) else { throw CasePeopleError.notFound("assignment") }
            guard r.isNull(3) else { throw CasePeopleError.alreadyEnded }
            try db.exec("UPDATE case_work_assignments SET ended_at = ?, ended_by = ?, end_reason = 'reassigned', reassigned_to = ? WHERE id = ?;",
                        [.date(date), .text(who), .text(to), .uuid(assignmentID)])
            try Self.checkAssignable(db, caseID: caseID, kind: kind, workID: work, assignee: to, capability: r.string(2), actor: who, at: date)
            try db.exec("""
                INSERT INTO case_work_assignments (id, case_id, work_kind, work_id, assignee, capability, assigned_by, assigned_at, note) VALUES (?,?,?,?,?,?,?,?,?);
                """, [.uuid(id), .uuid(caseID), .text(kind.rawValue), .text(work), .text(to), .optionalText(r.string(2)), .text(who), .date(date), .text(why)])
        }
        return id
    }

    public func endAssignment(caseID: UUID, assignmentID: UUID, reason: CaseWorkAssignment.EndReason, actor: String, at date: Date = Date()) async throws {
        let who = try Self.clean(actor, "Actor")
        guard reason == .completed || reason == .released else { throw CasePeopleError.notFound("end reason (use reassign)") }
        try await write("cf_assignend", caseID: caseID, actor: who, action: "workAssignmentEnded", detail: reason.rawValue, at: date,
                        capture: .workAssignment(assignmentID)) { db in
            guard let r = try db.query("SELECT ended_at FROM case_work_assignments WHERE id = ? AND case_id = ?;", [.uuid(assignmentID), .uuid(caseID)]).first else {
                throw CasePeopleError.notFound("assignment")
            }
            guard r.isNull(0) else { throw CasePeopleError.alreadyEnded }
            try db.exec("UPDATE case_work_assignments SET ended_at = ?, ended_by = ?, end_reason = ? WHERE id = ?;",
                        [.date(date), .text(who), .text(reason.rawValue), .uuid(assignmentID)])
        }
    }

    public func assignments(caseID: UUID) async throws -> [CaseWorkAssignment] {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        return try await database.query("""
            SELECT id, work_kind, work_id, assignee, capability, assigned_by, assigned_at, note, ended_at, ended_by, end_reason, reassigned_to
            FROM case_work_assignments WHERE case_id = ? ORDER BY assigned_at, id;
            """, [.uuid(caseID)]).compactMap { r in
            guard let id = r.uuid(0), let k = r.string(1).flatMap(CaseWorkAssignment.WorkKind.init(rawValue:)), let w = r.string(2), let a = r.string(3),
                  let by = r.string(5), let at = r.date(6) else { return nil }
            return CaseWorkAssignment(id: id, caseID: caseID, workKind: k, workID: w, assignee: a, capability: r.string(4), assignedBy: by, assignedAt: at,
                                      note: r.string(7), endedAt: r.date(8), endedBy: r.string(9), endReason: r.string(10).flatMap(CaseWorkAssignment.EndReason.init(rawValue:)),
                                      reassignedTo: r.string(11))
        }
    }

    /// PEOPLE-06 — one person's work history in the case: assignments and how each ended, work they recorded, work reported
    /// as theirs, results they submitted and reviews they made, with team periods. Each entry names the map record it opens.
    public func workHistory(caseID: UUID, person name: String) async throws -> CaseInvestigatorHistory {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        let who = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var out: [CaseWorkHistoryEntry] = []
        func unavailable(_ t: CaseMapNodeID?) -> String? { t == nil ? "This entry has no record on the case map (it is in the case log)." : nil }
        let all = try await assignments(caseID: caseID)
        for a in all where a.assignee == who {
            out.append(.init(id: "as:\(a.id)", at: a.assignedAt, kind: .assigned, text: "\(a.workKind.rawValue.capitalized) assigned by \(a.assignedBy)"
                                + (a.capability.map { " (needs: \($0))" } ?? ""), target: a.target, unavailable: unavailable(a.target)))
            if let e = a.endedAt, let reason = a.endReason {
                let kind: CaseWorkHistoryEntry.Kind = reason == .reassigned ? .reassignedAway : reason == .transferred ? .transferredAway : reason == .completed ? .completed : .released
                out.append(.init(id: "ae:\(a.id)", at: e, kind: kind, text: kind.label + (a.reassignedTo.map { " → \($0)" } ?? "") + (a.endedBy.map { " (by \($0))" } ?? ""),
                                 target: a.target, unavailable: unavailable(a.target)))
            }
        }
        for a in all where a.reassignedTo == who && a.endReason == .reassigned {
            out.append(.init(id: "ar:\(a.id)", at: a.endedAt ?? a.assignedAt, kind: .receivedByReassignment, text: "Took over from \(a.assignee)",
                             target: a.target, unavailable: unavailable(a.target)))
        }
        for r in try await database.query("""
            SELECT a.id, a.action, a.detail, a.at, a.actor, a.performed_by, r.record_kind, r.record_id
            FROM case_actions a LEFT JOIN case_record_revisions r ON r.action_id = a.id
            WHERE a.case_id = ? AND (a.actor = ? OR a.performed_by = ?) ORDER BY a.at, a.sequence;
            """, [.uuid(caseID), .text(who), .text(who)]) {
            guard let id = r.string(0), let action = r.string(1), let at = r.date(3) else { continue }
            if case .cosmetic = CaseChangeClassifier.classify(action: action) { continue }
            let kind = Self.mapKind(revisionKind: r.string(6))
            let target = kind.flatMap { k in r.string(7).map { CaseMapNodeID(caseID: caseID, kind: k, recordID: $0) } }
            let reportedOnly = r.string(5) == who && r.string(4) != who
            out.append(.init(id: "ac:\(id)", at: at, kind: reportedOnly ? .reportedPerformer : (action == "actionSubmitted" ? .submitted : .performed),
                             text: action + (r.string(2).map { ": \($0.prefix(120))" } ?? "") + (reportedOnly ? " (entered by \(r.string(4) ?? "someone else"))" : ""),
                             target: target, unavailable: unavailable(target)))
        }
        for r in try await database.query("SELECT id, item_kind, item_id, decision, decided_at FROM investigation_review_decisions WHERE case_id = ? AND actor = ?;",
                                          [.uuid(caseID), .text(who)]) {
            guard let id = r.string(0), let at = r.date(4) else { continue }
            let target = r.string(1) == "contradiction" ? r.string(2).map { CaseMapNodeID(caseID: caseID, kind: .contradiction, recordID: $0) } : nil
            out.append(.init(id: "rv:\(id)", at: at, kind: .reviewed, text: "Review: \(r.string(1) ?? "") \(r.string(3) ?? "")", target: target, unavailable: unavailable(target)))
        }
        var periods: [String] = []
        for m in try await teamMemberships(caseID: caseID) where m.member == who {
            periods.append("\(m.role.rawValue) from \(m.startedAt.formatted(date: .abbreviated, time: .omitted))"
                           + (m.endedAt.map { " to \($0.formatted(date: .abbreviated, time: .omitted)) (\(m.endReason ?? ""))" } ?? " (current)"))
            out.append(.init(id: "mj:\(m.id)", at: m.startedAt, kind: .joined, text: "Joined as \(m.role.rawValue)", target: nil, unavailable: "Team membership is not a map record."))
            if let e = m.endedAt {
                out.append(.init(id: "ml:\(m.id)", at: e, kind: .left, text: "Left: \(m.endReason ?? "")" + (m.transferredTo.map { "; work transferred to \($0)" } ?? ""),
                                 target: nil, unavailable: "Team membership is not a map record."))
            }
        }
        let sorted = out.sorted { $0.at != $1.at ? $0.at < $1.at : $0.id < $1.id }
        return CaseInvestigatorHistory(name: who, entries: sorted, firstInvolved: sorted.first?.at, lastInvolved: sorted.last?.at, periods: periods,
                                       openAssignments: all.filter { $0.assignee == who && $0.isOpen }.count)
    }

    // MARK: PEOPLE-07

    /// Compare two case-person rows under the current versioned rule and store the assessment with every reason. It merges
    /// nothing and records no decision.
    @discardableResult
    public func assessSamePerson(caseID: UUID, personA: UUID, personB: UUID, actor: String, at date: Date = Date()) async throws -> CasePersonMatchAssessment {
        let who = try Self.clean(actor, "Actor")
        guard personA != personB else { throw CasePeopleError.samePerson }
        let (a, b) = personA.uuidString.lowercased() < personB.uuidString.lowercased() ? (personA, personB) : (personB, personA)
        let people = try await people(caseID: caseID)
        guard let pa = people.first(where: { $0.id == a }), let pb = people.first(where: { $0.id == b }) else { throw CasePeopleError.notAPerson }
        let attrs = try await personAttributes(caseID: caseID).filter(\.isActive)
        func evidence(_ p: CasePerson) -> CasePersonEvidence {
            var ids = CasePersonMatcher.identifiers(in: p.contact)
            var other = Set<String>()
            for at in attrs where at.personID == p.id {
                switch at.kind {
                case .contact: ids.formUnion(CasePersonMatcher.identifiers(in: at.value))
                case .identifier: ids.insert("id:" + at.value.lowercased().filter { !$0.isWhitespace })
                case .organisation, .relationship: other.insert("\(at.kind.rawValue): \(at.value.lowercased())")
                default: break
                }
            }
            return CasePersonEvidence(name: p.name, entityID: p.entityID, identifiers: ids, attributes: other)
        }
        let (verdict, reasons) = CasePersonMatcher.assess(evidence(pa), evidence(pb))
        let id = UUID()
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        let json = String(decoding: try enc.encode(reasons), as: UTF8.self)
        try await write("cf_match", caseID: caseID, actor: who, action: "samePersonAssessed", detail: "rule v\(CasePersonMatcher.ruleVersion): \(verdict.rawValue)", at: date) { db in
            try db.exec("""
                INSERT INTO case_person_match_assessments (id, case_id, person_a, person_b, rule_version, verdict, reasons_json, assessed_by, assessed_at)
                VALUES (?,?,?,?,?,?,?,?,?);
                """, [.uuid(id), .uuid(caseID), .text(a.uuidString.lowercased()), .text(b.uuidString.lowercased()), .integer(Int64(CasePersonMatcher.ruleVersion)),
                      .text(verdict.rawValue), .text(json), .text(who), .date(date)])
        }
        return CasePersonMatchAssessment(id: id, personA: a, personB: b, ruleVersion: CasePersonMatcher.ruleVersion, verdict: verdict, reasons: reasons,
                                         assessedBy: who, assessedAt: date)
    }

    public func matchAssessments(caseID: UUID) async throws -> [CasePersonMatchAssessment] {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        return try await database.query("""
            SELECT id, person_a, person_b, rule_version, verdict, reasons_json, assessed_by, assessed_at FROM case_person_match_assessments
            WHERE case_id = ? ORDER BY assessed_at, id;
            """, [.uuid(caseID)]).compactMap { r in
            guard let id = r.uuid(0), let a = r.uuid(1), let b = r.uuid(2), let v = r.string(4).flatMap(CasePersonMatchAssessment.Verdict.init(rawValue:)),
                  let by = r.string(6), let at = r.date(7) else { return nil }
            let reasons = (r.string(5)?.data(using: .utf8)).flatMap { try? JSONDecoder().decode([CasePersonMatchReason].self, from: $0) } ?? []
            return CasePersonMatchAssessment(id: id, personA: a, personB: b, ruleVersion: Int(r.int(3) ?? 1), verdict: v, reasons: reasons, assessedBy: by, assessedAt: at)
        }
    }

    // MARK: PEOPLE-08

    @discardableResult
    public func declareCapability(investigator: String, capability: String, basis: String, actor: String, at date: Date = Date()) async throws -> UUID {
        let name = try Self.clean(investigator, "The investigator"), cap = try Self.clean(capability, "The capability")
        let why = try Self.clean(basis, "What the declaration rests on"), who = try Self.clean(actor, "Actor")
        let id = UUID()
        try await database.withSavepoint("cf_cap_\(UUID().uuidString.prefix(8))") { db in
            try db.exec("INSERT INTO investigator_capabilities (id, investigator, capability, basis, declared_by, declared_at) VALUES (?,?,?,?,?,?);",
                        [.uuid(id), .text(name), .text(cap), .text(why), .text(who), .date(date)])
        }
        return id
    }

    public func withdrawCapability(id: UUID, actor: String, at date: Date = Date()) async throws {
        let who = try Self.clean(actor, "Actor")
        try await database.withSavepoint("cf_capw_\(UUID().uuidString.prefix(8))") { db in
            guard try !db.query("SELECT 1 FROM investigator_capabilities WHERE id = ? AND withdrawn_at IS NULL;", [.uuid(id)]).isEmpty else { throw CasePeopleError.alreadyEnded }
            try db.exec("UPDATE investigator_capabilities SET withdrawn_by = ?, withdrawn_at = ? WHERE id = ?;", [.text(who), .date(date), .uuid(id)])
        }
    }

    @discardableResult
    public func declareUnavailable(investigator: String, from: Date, to: Date, note: String?, actor: String, at date: Date = Date()) async throws -> UUID {
        let name = try Self.clean(investigator, "The investigator"), who = try Self.clean(actor, "Actor")
        guard to >= from else { throw CaseReasoningError.badPeriod }
        let id = UUID()
        try await database.withSavepoint("cf_unav_\(UUID().uuidString.prefix(8))") { db in
            try db.exec("INSERT INTO investigator_availability (id, investigator, unavailable_from, unavailable_to, note, declared_by, declared_at) VALUES (?,?,?,?,?,?,?);",
                        [.uuid(id), .text(name), .date(from), .date(to), .optionalText(Self.blankToNil(note)), .text(who), .date(date)])
        }
        return id
    }

    public func capabilities(investigator: String? = nil) async throws -> [CaseInvestigatorCapability] {
        let rows = try await database.query("""
            SELECT id, investigator, capability, basis, declared_by, declared_at, withdrawn_at FROM investigator_capabilities
            WHERE (? IS NULL OR investigator = ?) ORDER BY investigator, capability;
            """, [.optionalText(investigator), .optionalText(investigator)])
        return rows.compactMap { r in
            guard let id = r.uuid(0), let n = r.string(1), let c = r.string(2), let b = r.string(3), let by = r.string(4), let at = r.date(5) else { return nil }
            return CaseInvestigatorCapability(id: id, investigator: n, capability: c, basis: b, declaredBy: by, declaredAt: at, withdrawnAt: r.date(6))
        }
    }

    /// Remove an investigator's own profile data (declared capabilities and unavailability). Case records they made keep
    /// their attribution.
    public func removeInvestigatorProfile(investigator: String) async throws -> Int {
        let name = try Self.clean(investigator, "The investigator")
        return try await database.withSavepoint("cf_invrm_\(UUID().uuidString.prefix(8))") { db -> Int in
            let n = Int(try db.query("SELECT (SELECT COUNT(*) FROM investigator_capabilities WHERE investigator = ?) + (SELECT COUNT(*) FROM investigator_availability WHERE investigator = ?);",
                                     [.text(name), .text(name)]).first?.int(0) ?? 0)
            try db.exec("DELETE FROM investigator_capabilities WHERE investigator = ?;", [.text(name)])
            try db.exec("DELETE FROM investigator_availability WHERE investigator = ?;", [.text(name)])
            return n
        }
    }

    /// Who could take work needing `capability` on `date`: the case team (or, with no team recorded, everyone who declared
    /// anything), each with every reason for and against. Alphabetical — never ranked or scored.
    public func routingCandidates(caseID: UUID, capability: String?, on date: Date = Date()) async throws -> [CaseRoutingCandidate] {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        let team = try await teamMemberships(caseID: caseID)
        let caps = try await capabilities().filter(\.isActive)
        var names = Set(team.map(\.member))
        if team.isEmpty { names.formUnion(caps.map(\.investigator)) }
        let unavailable = try await database.query("SELECT investigator, note FROM investigator_availability WHERE unavailable_from <= ? AND unavailable_to >= ?;",
                                                   [.date(date), .date(date)])
        let checks = try await conflictChecks(caseID: caseID)
        return names.sorted().map { n in
            var reasons: [String] = [], ok = true
            if !team.isEmpty {
                if team.contains(where: { $0.member == n && $0.isActive }) { reasons.append("On the case team") } else { ok = false; reasons.append("Membership of the case team ended") }
            }
            if let cap = capability {
                if let c = caps.first(where: { $0.investigator == n && $0.capability.caseInsensitiveCompare(cap) == .orderedSame }) {
                    reasons.append("Declared “\(c.capability)” (\(c.basis))")
                } else { ok = false; reasons.append("Has not declared “\(cap)”") }
            }
            if let u = unavailable.first(where: { $0.string(0) == n }) { ok = false; reasons.append("Declared unavailable on this date" + (u.string(1).map { " (\($0))" } ?? "")) }
            if let latest = checks.filter({ $0.investigator == n }).max(by: { $0.checkedAt < $1.checkedAt }) {
                switch latest.result {
                case .conflict: ok = false; reasons.append("Conflict recorded in this case")
                case .waived: reasons.append("Conflict recorded and waived: \(latest.note ?? "")")
                case .clear: reasons.append("Conflict check clear")
                }
            } else { reasons.append("No conflict check recorded in this case") }
            return CaseRoutingCandidate(name: n, eligible: ok, reasons: reasons)
        }
    }

    // MARK: PEOPLE-09

    @discardableResult
    public func addTeamMember(caseID: UUID, member: String, role: CaseTeamMembership.Role, actor: String, at date: Date = Date()) async throws -> UUID {
        let who = try Self.clean(actor, "Actor"), m = try Self.clean(member, "The member")
        let id = UUID()
        try await write("cf_team", caseID: caseID, actor: who, action: "teamMemberAdded", detail: "\(m) (\(role.rawValue))", at: date) { db in
            guard try db.query("SELECT 1 FROM case_team_memberships WHERE case_id = ? AND member = ? AND ended_at IS NULL;", [.uuid(caseID), .text(m)]).isEmpty else {
                throw CasePeopleError.duplicateRole
            }
            try db.exec("INSERT INTO case_team_memberships (id, case_id, member, role, started_by, started_at) VALUES (?,?,?,?,?,?);",
                        [.uuid(id), .uuid(caseID), .text(m), .text(role.rawValue), .text(who), .date(date)])
        }
        return id
    }

    /// End a membership with the reason. Open work must be transferred to an active member (it is, in the same savepoint);
    /// everything the person recorded keeps their name.
    public func endTeamMembership(caseID: UUID, membershipID: UUID, reason: String, transferTo: String?, actor: String, at date: Date = Date()) async throws {
        let who = try Self.clean(actor, "Actor"), why = try Self.clean(reason, "The reason")
        let target = Self.blankToNil(transferTo)
        try await write("cf_teamend", caseID: caseID, actor: who, action: "teamMembershipEnded", detail: why, at: date) { db in
            guard let r = try db.query("SELECT member, ended_at FROM case_team_memberships WHERE id = ? AND case_id = ?;", [.uuid(membershipID), .uuid(caseID)]).first,
                  let member = r.string(0) else { throw CasePeopleError.notFound("membership") }
            guard r.isNull(1) else { throw CasePeopleError.alreadyEnded }
            let open = try db.query("SELECT id, work_kind, work_id, capability FROM case_work_assignments WHERE case_id = ? AND assignee = ? AND ended_at IS NULL;",
                                    [.uuid(caseID), .text(member)])
            if !open.isEmpty && target == nil { throw CasePeopleError.pendingWorkNeedsTransfer(open.count) }
            try db.exec("UPDATE case_team_memberships SET ended_by = ?, ended_at = ?, end_reason = ?, transferred_to = ? WHERE id = ?;",
                        [.text(who), .date(date), .text(why), .optionalText(target), .uuid(membershipID)])
            if let to = target {
                try CaseMembershipGate.require(db, caseID: caseID, name: to)
                for o in open {
                    guard let aid = o.string(0), let k = o.string(1), let w = o.string(2) else { continue }
                    try db.exec("UPDATE case_work_assignments SET ended_at = ?, ended_by = ?, end_reason = 'transferred', reassigned_to = ? WHERE id = ?;",
                                [.date(date), .text(who), .text(to), .text(aid)])
                    try db.exec("""
                        INSERT INTO case_work_assignments (id, case_id, work_kind, work_id, assignee, capability, assigned_by, assigned_at, note) VALUES (?,?,?,?,?,?,?,?,?);
                        """, [.uuid(UUID()), .uuid(caseID), .text(k), .text(w), .text(to), .optionalText(o.string(3)), .text(who), .date(date),
                              .text("Transferred from \(member): \(why)")])
                }
            }
        }
    }

    public func teamMemberships(caseID: UUID) async throws -> [CaseTeamMembership] {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        return try await database.query("""
            SELECT id, member, role, started_at, ended_at, end_reason, transferred_to FROM case_team_memberships WHERE case_id = ? ORDER BY started_at, id;
            """, [.uuid(caseID)]).compactMap { r in
            guard let id = r.uuid(0), let m = r.string(1), let role = r.string(2).flatMap(CaseTeamMembership.Role.init(rawValue:)), let at = r.date(3) else { return nil }
            return CaseTeamMembership(id: id, caseID: caseID, member: m, role: role, startedAt: at, endedAt: r.date(4), endReason: r.string(5), transferredTo: r.string(6))
        }
    }

    // MARK: PEOPLE-10

    @discardableResult
    public func restrictProfile(caseID: UUID, personID: UUID, reason: String, actor: String, at date: Date = Date()) async throws -> UUID {
        let who = try Self.clean(actor, "Actor"), why = try Self.clean(reason, "The reason")
        let id = UUID()
        try await write("cf_prestr", caseID: caseID, actor: who, action: "profileRestricted", detail: why, at: date) { db in
            try Self.requirePerson(db, personID, caseID: caseID)
            guard try db.query("SELECT 1 FROM case_person_restrictions WHERE case_id = ? AND lower(case_person_id) = ? AND lifted_at IS NULL;",
                               [.uuid(caseID), .text(personID.uuidString.lowercased())]).isEmpty else { throw CasePeopleError.alreadyRestricted }
            try db.exec("INSERT INTO case_person_restrictions (id, case_id, case_person_id, reason, set_by, set_at) VALUES (?,?,?,?,?,?);",
                        [.uuid(id), .uuid(caseID), .text(personID.uuidString.lowercased()), .text(why), .text(who), .date(date)])
        }
        return id
    }

    public func liftProfileRestriction(caseID: UUID, id: UUID, reason: String, actor: String, at date: Date = Date()) async throws {
        let who = try Self.clean(actor, "Actor"), why = try Self.clean(reason, "The reason")
        try await write("cf_prestrl", caseID: caseID, actor: who, action: "profileRestrictionLifted", detail: why, at: date) { db in
            guard let r = try db.query("SELECT lifted_at FROM case_person_restrictions WHERE id = ? AND case_id = ?;", [.uuid(id), .uuid(caseID)]).first else {
                throw CasePeopleError.notFound("restriction")
            }
            guard r.isNull(0) else { throw CasePeopleError.alreadyEnded }
            try db.exec("UPDATE case_person_restrictions SET lifted_by = ?, lifted_at = ?, lifted_reason = ? WHERE id = ?;", [.text(who), .date(date), .text(why), .uuid(id)])
        }
    }

    public func activeRestriction(caseID: UUID, personID: UUID) async throws -> CasePersonRestriction? {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        return try await database.query("""
            SELECT id, reason, set_by, set_at FROM case_person_restrictions WHERE case_id = ? AND lower(case_person_id) = ? AND lifted_at IS NULL LIMIT 1;
            """, [.uuid(caseID), .text(personID.uuidString.lowercased())]).first.flatMap { r in
            guard let id = r.uuid(0), let why = r.string(1), let by = r.string(2), let at = r.date(3) else { return nil }
            return CasePersonRestriction(id: id, personID: personID, reason: why, setBy: by, setAt: at, liftedAt: nil)
        }
    }

    /// PEOPLE-02 / PEOPLE-10 — the person's profile: roles, sourced attributes, unsourced card lines, register aliases and
    /// observations, each with its origin; a restricted profile withholds them and counts what it withheld.
    public func personProfile(caseID: UUID, personID: UUID) async throws -> CasePersonProfile {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        guard let p = try await people(caseID: caseID).first(where: { $0.id == personID }) else { throw CasePeopleError.notAPerson }
        let roles = try await personRoles(caseID: caseID).filter { $0.personID == personID }
        let attrs = try await personAttributes(caseID: caseID).filter { $0.personID == personID }
        let locs = try await locationObservations(caseID: caseID).filter { $0.personID == personID }
        var card: [String] = []
        if let n = Self.blankToNil(p.notes) { card.append("Note on the person's card: \(n) — unsourced (no origin recorded)") }
        if let c = Self.blankToNil(p.contact) { card.append("Contact on the person's card: \(c) — unsourced (no origin recorded)") }
        var aliases: [String] = []
        if let e = p.entityID {
            aliases = try await database.query("SELECT alias_normalized FROM entity_aliases WHERE entity_id IN (?, ?) ORDER BY alias_normalized;",
                                               [.text(e.uuidString), .text(e.uuidString.lowercased())]).compactMap { $0.string(0) }
                .filter { $0.caseInsensitiveCompare(p.name) != .orderedSame }
        }
        if let r = try await activeRestriction(caseID: caseID, personID: personID) {
            let n = attrs.filter(\.isActive).count + locs.filter(\.isActive).count + card.count + aliases.count + roles.filter(\.isActive).count
            return CasePersonProfile(person: p, roles: [], attributes: [], locations: [], unsourcedCardLines: [], registerAliases: [], restriction: r, withheld: n)
        }
        return CasePersonProfile(person: p, roles: roles, attributes: attrs, locations: locs, unsourcedCardLines: card, registerAliases: aliases, restriction: nil, withheld: 0)
    }
}
