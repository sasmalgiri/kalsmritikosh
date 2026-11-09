//
//  CaseChangeImpact.swift
//  Kalsmritikosh
//
//  Smart-map S6 (docs/IME_Full_Smart_Map_Implementation_TODO_2026-11-08.md §13 CHANGE; plan §7 and §18 SM-06; schema v182).
//  Meaningful updates and their transitive impact, over the ONE case projection, the change feed and the case file's
//  savepoint. Nothing here calls a model or the network, and nothing here reverses or re-decides a recorded decision.
//
//  • Categories (CHANGE-01): every case-log action is classified as a semantic change (new material, amendment, scope,
//    identity, relationship, assignment, review, access, work, output) or a cosmetic / working-aid change (layout, saved
//    views, briefs about the case). Cosmetic changes never enter the feed.
//  • Derivation inputs (CHANGE-02): a summary, comparison, finding or output is bound to the exact inputs it was derived
//    from — each input's revision and a fingerprint of the input as it was. Inspecting it explains, per input, why it is
//    stale (a newer source version, a changed review, changed wording, an input that left the case).
//  • Typed transitive traversal (CHANGE-03): a change follows DEPENDENCY links only — evidence (supports, challenges,
//    qualifies), derivation, work results and dependencies, report selection, corrections, and recorded derivation
//    inputs — to any depth, each record once (cycle-safe), cancellable, with the path that makes it depend. Mentions,
//    attribution to a person, same-person pairings, money parties, time order and placements are NOT followed: social or
//    mention adjacency never invalidates a conclusion. The walk reads only; decisions stay as recorded.
//  • Refresh is not approval (CHANGE-04) and late results are fenced (CHANGE-08): a generated brief is written as a new,
//    unaccepted version beside the accepted one, and only if, at the moment it is applied, nobody wrote a newer version,
//    the case's inputs are the ones it was produced from, the policy is unchanged, the requester is still on the team and
//    the case is open. Every attempt is recorded; a result for a closed case is queued, never dropped.
//  • Personal review (CHANGE-05): each person's seen position, and substantive acknowledgements kept apart from it.
//  • Aggregation (CHANGE-06): groups with their full member lists, impact and what is still unresolved.
//  • Closed cases (CHANGE-07): late contributions are queued with an explicit admit / decline / ask-to-reopen workflow.
//  • Reconciliation (CHANGE-09): impact notifications are written idempotently from canonical state with a durable
//    checkpoint, so a crash or a missed event neither loses nor duplicates them.
//

import Foundation
import os

// MARK: - CHANGE-01 categories

/// What kind of change a case action or a feed entry is.
public nonisolated enum CaseChangeCategory: String, Sendable, CaseIterable, Codable {
    case newMaterial, amendment, scope, identity, relationship, assignment, review, access, work, output
    public var label: String {
        switch self {
        case .newMaterial: return "New material"
        case .amendment: return "Amendments and corrections"
        case .scope: return "Case scope"
        case .identity: return "Identity (same or different person)"
        case .relationship: return "Relationships and links"
        case .assignment: return "Assignments and roles"
        case .review: return "Reviews and decisions"
        case .access: return "Access and team"
        case .work: return "Work and tasks"
        case .output: return "Outputs and stage"
        }
    }
}

/// How a case-log action is classified.
public nonisolated enum CaseActionClass: Equatable, Sendable {
    case semantic(CaseChangeCategory)
    /// Presentation or the person's own working aids (layout, saved views, briefs about the case): never a case change.
    case cosmetic
}

public nonisolated enum CaseChangeClassifier {
    /// Actions that change only how the case is shown or the person's own aids about it.
    public static let cosmeticActions: Set<String> = Set(CaseRecordRevisions.displayActions + CaseFileRepository.briefActions)
        .union(["layoutSaved", "layoutReset", "viewed", "exported", "printed", "copied"])

    /// Every case action is one or the other; an action this build does not know is treated as semantic work, never hidden.
    public static func classify(action: String) -> CaseActionClass {
        if cosmeticActions.contains(action) { return .cosmetic }
        switch action {
        case "gridLinked", "gridUnlinked", "workLinked", "placedInFrame", "removedFromFrame", "dependencyAdded", "dependencyRemoved",
             "evidenceRelationSet", "attributionRecorded", "attributionWithdrawn", "dependenceReviewed", "qualificationAdded":
            return .semantic(.relationship)
        case "reportItemSupplied", "pointAdded", "pointsSuggested", "exhibitRegistered", "intakeReceived", "lateContributionQueued":
            return .semantic(.newMaterial)
        case "statementCorrected", "correctionConfirmed", "pointRestated", "journalRetracted", "exhibitWithdrawn", "reportWithdrawn",
             "timeAsserted", "timeInterpreted", "timeWithdrawn", "personUpdated", "interviewUpdated", "interviewItemCorrected",
             "interviewItemRecorded", "interviewItemUpdated", "profileSaved", "personAttributeRecorded", "personAttributeWithdrawn",
             "locationObserved", "locationWithdrawn":
            return .semantic(.amendment)
        case "sourceIncluded", "sourceExcluded":
            return .semantic(.scope)
        case "identityDecided", "identityDecisionWithdrawn", "samePersonAssessed":
            return .semantic(.identity)
        case "taskAssigned", "workAssigned", "workAssignmentEnded", "personRoleAdded", "personRoleEnded", "personAdded", "personRetracted":
            return .semantic(.assignment)
        case "allegationDecided", "pointReviewed", "proposalDecided", "factVerified", "factVerificationWithdrawn", "responseRecorded",
             "reviewFlagCleared", "conflictFollowUpOutcome", "lateContributionDecided", "changeAcknowledged", "derivationBound":
            return .semantic(.review)
        case "profileRestricted", "profileRestrictionLifted", "teamMemberAdded", "teamMembershipEnded", "conflictCheck", "redactionLogged",
             "holdIssued", "holdReleased", "holdAcknowledged":
            return .semantic(.access)
        case "stage", "triage", "closed", "reopened", "archived", "actionOutcome", "actionSubmitted", "generatedResultApplied":
            return .semantic(.output)
        default:
            return .semantic(.work)
        }
    }
}

nonisolated extension CaseChangeKind {
    /// CHANGE-01 — the category of a feed entry. Every feed entry is semantic: layout never reaches the feed.
    public var category: CaseChangeCategory {
        switch self {
        case .documentAdmitted, .requestReceipt, .requestDuplicate, .lateContribution: return .newMaterial
        case .documentRevised, .documentUnreadable, .documentNewlyReadable, .questionRevised, .hypothesisRevised, .findingRevised,
             .caseDetailsRevised, .statementAmended: return .amendment
        case .documentExcluded: return .scope
        case .identityChanged: return .identity
        case .linkAdded, .linkWithdrawn: return .relationship
        case .assignmentChanged, .roleChanged: return .assignment
        case .reviewDecided, .reviewReopened, .detected, .noLongerDetected, .requestStatusDecided: return .review
        case .accessChanged: return .access
        case .taskDueChanged, .taskStatusChanged: return .work
        case .outputApproved, .outputReleased, .stageChanged: return .output
        }
    }
}

// MARK: - CHANGE-03 typed dependency traversal

public nonisolated enum CaseDependencyRule {
    /// Link types a change does NOT travel along: mention, attribution to a person, identity pairings, money parties, time
    /// order, placements and rows nobody assessed. Adjacency through them never invalidates anything.
    public static let notFollowed: Set<CaseMapLinkType> = [.mentions, .attributedTo, .possibleSamePerson, .samePersonDecided, .moneyFrom, .moneyTo,
                                                           .occurredBefore, .occurredAfter, .placedIn, .relevanceUnassessed]

    /// The record that depends on `changed` through `l`, or nil when the change does not travel along it.
    /// Evidence, received results and corrections point AT what rests on them (from → to); derivations, dependencies, report
    /// selections and requests' questions are held BY what rests on them (to → from).
    public static func dependent(of changed: CaseMapNodeID, via l: CaseMapLink) -> CaseMapNodeID? {
        guard !notFollowed.contains(l.type), l.from != l.to else { return nil }
        switch l.type {
        case .supports, .challenges, .qualifies, .receivedInResponseTo, .supersedes, .requestsEvidenceFor:
            return l.from == changed ? l.to : nil
        case .derivedFrom, .dependsOn, .selectedForReport:
            return l.to == changed ? l.from : nil
        default:
            return nil
        }
    }
}

/// One record a change reaches, with the path that makes it depend.
public nonisolated struct CaseImpactEntry: Identifiable, Hashable, Sendable {
    /// "allegation:…" for a map record, "brief:…" / "output:…" for a recorded derivation outside the map.
    public let key: String
    public let node: CaseMapNodeID?
    public let title: String
    /// 1 = rests on the changed record directly.
    public let depth: Int
    /// Each step: "“Invoice A” supports “Supplier paid twice”".
    public let path: [String]
    /// Its recorded review state, shown as it is — the walk changes nothing.
    public let review: CaseMapReviewState
    public var id: String { key }
    public var explanation: String { path.joined(separator: " → ") }
    /// A recorded decision rests on the change: it stays as recorded and is flagged for review, never reversed.
    public var keepsDecision: Bool { [.accepted, .completed, .confirmed, .dismissed, .rejected, .explained, .unresolved].contains(review) }
}

public nonisolated struct CaseImpactTrace: Sendable, Equatable {
    public enum State: Equatable, Sendable {
        case complete
        /// Stopped because the caller cancelled: the entries so far are listed and the trace says it is incomplete.
        case cancelled
        /// Stopped at the record budget: incomplete, with how many were reached.
        case budgetReached(Int)
    }
    public let changed: String
    public let entries: [CaseImpactEntry]
    /// Links touching reached records that the change did not travel along, by type (counted, never hidden).
    public let notFollowed: [CaseMapLinkType: Int]
    public let state: State
    public var isComplete: Bool { state == .complete }
    public var nodes: [CaseMapNodeID] { entries.compactMap(\.node) }
    public var deepest: Int { entries.map(\.depth).max() ?? 0 }
    public var notFollowedLine: String? {
        let n = notFollowed.values.reduce(0, +)
        guard n > 0 else { return nil }
        return "\(n) link(s) were not followed because they record a mention, an attribution, an identity pairing, a money party, a time order or a placement — adjacency is not dependency: "
            + notFollowed.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key.label) (\($0.value))" }.joined(separator: ", ")
    }
}

public nonisolated enum CaseDependencyTraversal {
    /// Everything that rests on `changed`, at any depth, each record once. `derivations` adds recorded derivation inputs
    /// (input → derived item), including items outside the map (briefs, outputs). Cancellable; never writes.
    public static func trace(from changed: CaseMapNodeID, in p: CaseMapProjection, derivations: [CaseDerivationBinding] = [],
                             budget: Int = 200_000, isCancelled: () -> Bool = { Task.isCancelled }) -> CaseImpactTrace {
        trace(fromKey: changed.key, in: p, derivations: derivations, budget: budget, isCancelled: isCancelled)
    }

    public static func trace(fromKey start: String, in p: CaseMapProjection, derivations: [CaseDerivationBinding] = [],
                             budget: Int = 200_000, isCancelled: () -> Bool = { Task.isCancelled }) -> CaseImpactTrace {
        // input key → derived items (latest binding of each derived item only).
        var derivedBy: [String: [(key: String, label: String)]] = [:]
        for b in CaseDerivation.latest(derivations) {
            for i in b.inputs { derivedBy[i.key, default: []].append((b.derivedKey, b.label)) }
        }
        func node(for key: String) -> CaseMapNodeID? {
            guard let colon = key.firstIndex(of: ":"), let kind = CaseMapRecordKind(rawValue: String(key[..<colon])) else { return nil }
            let id = CaseMapNodeID(caseID: p.caseID, kind: kind, recordID: String(key[key.index(after: colon)...]))
            return p.node(id) != nil ? id : nil
        }
        func title(_ key: String) -> String {
            if let n = node(for: key), let t = p.node(n)?.title { return t }
            for (_, list) in derivedBy { if let d = list.first(where: { $0.key == key }) { return d.label } }
            return key
        }
        var seen: Set<String> = [start]
        var queue: [(key: String, depth: Int, path: [String])] = [(start, 0, [])]
        var head = 0
        var out: [CaseImpactEntry] = []
        var skipped: [CaseMapLinkType: Int] = [:]
        var countedSkips = Set<String>()
        var state: CaseImpactTrace.State = .complete
        while head < queue.count {
            if head % 64 == 0, isCancelled() { state = .cancelled; break }
            if out.count >= budget { state = .budgetReached(out.count); break }
            let (key, depth, path) = queue[head]; head += 1
            var next: [(String, String)] = []   // (dependent key, step text)
            if let n = node(for: key) {
                for l in p.links(of: n) {
                    if let d = CaseDependencyRule.dependent(of: n, via: l) {
                        let how = l.from == n ? "“\(title(key))” \(l.type.label) “\(title(d.key))”" : "“\(title(d.key))” \(l.type.label) “\(title(key))”"
                        next.append((d.key, how))
                    } else if CaseDependencyRule.notFollowed.contains(l.type), countedSkips.insert(l.id).inserted {
                        skipped[l.type, default: 0] += 1
                    }
                }
            }
            for d in derivedBy[key] ?? [] { next.append((d.key, "“\(d.label)” was derived from “\(title(key))”")) }
            for (k, step) in next.sorted(by: { $0.0 < $1.0 }) where seen.insert(k).inserted {
                let nid = node(for: k)
                let entry = CaseImpactEntry(key: k, node: nid, title: title(k), depth: depth + 1, path: path + [step],
                                            review: nid.flatMap { p.node($0)?.review } ?? .notApplicable)
                out.append(entry)
                queue.append((k, depth + 1, path + [step]))
            }
        }
        return CaseImpactTrace(changed: start, entries: out.sorted { ($0.depth, $0.key) < ($1.depth, $1.key) }, notFollowed: skipped, state: state)
    }
}

// MARK: - CHANGE-02 derivation inputs

public nonisolated enum CaseDerivedKind: String, Sendable, CaseIterable, Codable {
    case brief, comparison, finding, output, summary, reportPoint, decision
    public var label: String {
        switch self {
        case .brief: return "Brief"
        case .comparison: return "Comparison"
        case .finding: return "Finding"
        case .output: return "Output"
        case .summary: return "Summary"
        case .reportPoint: return "Report point"
        case .decision: return "Decision"
        }
    }
    /// The map record a derived item IS, when it is one (a finding is a report item, a decision is its question's).
    var mapKind: CaseMapRecordKind? {
        switch self {
        case .finding: return .reportItem
        case .reportPoint: return .reportPoint
        case .decision: return .allegation
        default: return nil
        }
    }
}

/// An input as it was when the item was derived — identifiers and states, never document text.
public nonisolated struct CaseDerivationSnapshot: Codable, Hashable, Sendable {
    public var title: String
    public var revision: String?
    public var wordingDigest: String?
    public var review: String
    public var status: String
    public var sourceVersions: [String]
    public var present: Bool
}

public nonisolated struct CaseDerivationInput: Hashable, Sendable {
    public let key: String
    public let revision: String?
    public let fingerprint: String
    public let snapshot: CaseDerivationSnapshot
}

public nonisolated struct CaseDerivationBinding: Identifiable, Hashable, Sendable {
    public let bindID: UUID
    public let caseID: UUID
    public let derivedKind: CaseDerivedKind
    public let derivedID: String
    public let label: String
    public let inputs: [CaseDerivationInput]
    public let boundBy: String
    public let boundAt: Date
    public var id: UUID { bindID }
    public var derivedKey: String {
        if let k = derivedKind.mapKind { return "\(k.rawValue):\(derivedID.lowercased())" }
        return "\(derivedKind.rawValue):\(derivedID.lowercased())"
    }
}

/// Why a derived item is (or is not) stale, input by input.
public nonisolated struct CaseDerivationStaleness: Sendable, Equatable {
    public let derivedKey: String
    public let label: String
    public let boundAt: Date
    public let reasons: [String]
    public let unchangedInputs: Int
    public var isStale: Bool { !reasons.isEmpty }
}

public nonisolated enum CaseDerivation {
    public static func snapshot(of n: CaseMapNode) -> CaseDerivationSnapshot {
        CaseDerivationSnapshot(title: n.title, revision: n.revision, wordingDigest: n.wording.map { CaseFileHash.sha256($0) },
                               review: n.review.rawValue, status: n.status.kind.rawValue,
                               sourceVersions: n.sources.compactMap { $0.sourceVersionID?.uuidString.lowercased() }.sorted(), present: true)
    }

    public static func fingerprint(_ s: CaseDerivationSnapshot) -> String {
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        return CaseFileHash.sha256(String(decoding: (try? enc.encode(s)) ?? Data(), as: UTF8.self))
    }

    /// The latest binding of each derived item.
    public static func latest(_ all: [CaseDerivationBinding]) -> [CaseDerivationBinding] {
        var best: [String: CaseDerivationBinding] = [:]
        for b in all {
            if let cur = best[b.derivedKey], (cur.boundAt, cur.bindID.uuidString) >= (b.boundAt, b.bindID.uuidString) { continue }
            best[b.derivedKey] = b
        }
        return best.values.sorted { $0.derivedKey < $1.derivedKey }
    }

    /// Explain, per input, why the latest binding of `derivedKey` is stale against the projection now. An input that is
    /// itself a derived item is stale when it was derived again since, or when it is stale itself (cycle-safe).
    public static func staleness(of derivedKey: String, bindings: [CaseDerivationBinding], in p: CaseMapProjection) -> CaseDerivationStaleness? {
        var visiting = Set<String>()
        return staleness(derivedKey, latest(bindings), p, &visiting)
    }

    private static func staleness(_ key: String, _ latest: [CaseDerivationBinding], _ p: CaseMapProjection, _ visiting: inout Set<String>) -> CaseDerivationStaleness? {
        guard let b = latest.first(where: { $0.derivedKey == key }) else { return nil }
        visiting.insert(key)
        var reasons: [String] = []
        var unchanged = 0
        for i in b.inputs {
            if let derived = latest.first(where: { $0.derivedKey == i.key }) {
                if derived.bindID.uuidString.lowercased() != i.revision {
                    reasons.append("“\(i.snapshot.title)” was derived again on \(derived.boundAt.formatted(date: .abbreviated, time: .shortened)) after this used it.")
                } else if !visiting.contains(i.key), let inner = staleness(i.key, latest, p, &visiting), inner.isStale {
                    reasons.append("“\(i.snapshot.title)” rests on inputs that changed: " + inner.reasons.joined(separator: " "))
                } else { unchanged += 1 }
                continue
            }
            guard let colon = i.key.firstIndex(of: ":"), let kind = CaseMapRecordKind(rawValue: String(i.key[..<colon])),
                  let n = p.node(CaseMapNodeID(caseID: p.caseID, kind: kind, recordID: String(i.key[i.key.index(after: colon)...]))) else {
                reasons.append("“\(i.snapshot.title)” is no longer in this case (it was removed, excluded or withdrawn).")
                continue
            }
            let now = snapshot(of: n)
            guard fingerprint(now) != i.fingerprint else { unchanged += 1; continue }
            var why: [String] = []
            if now.sourceVersions != i.snapshot.sourceVersions {
                why.append("its source version changed (\(i.snapshot.sourceVersions.map { String($0.prefix(8)) }.joined(separator: ", ")) → \(now.sourceVersions.map { String($0.prefix(8)) }.joined(separator: ", ")))")
            }
            if now.revision != i.snapshot.revision { why.append("its revision changed (\(i.snapshot.revision ?? "none") → \(now.revision ?? "none"))") }
            if now.review != i.snapshot.review {
                why.append("its review changed (\(CaseMapReviewState(rawValue: i.snapshot.review)?.label ?? i.snapshot.review) → \(n.review.label))")
            }
            if now.status != i.snapshot.status {
                why.append("its state changed (\(CaseMapStatus.Kind(rawValue: i.snapshot.status)?.label ?? i.snapshot.status) → \(n.status.kind.label))")
            }
            if now.wordingDigest != i.snapshot.wordingDigest { why.append("its wording changed") }
            if now.title != i.snapshot.title { why.append("its title changed") }
            reasons.append("“\(i.snapshot.title)”: " + (why.isEmpty ? "it changed" : why.joined(separator: "; ")) + ".")
        }
        visiting.remove(key)
        return CaseDerivationStaleness(derivedKey: key, label: b.label, boundAt: b.boundAt, reasons: reasons, unchangedInputs: unchanged)
    }
}

// MARK: - CHANGE-06 aggregation

public nonisolated struct CaseChangeGroup: Identifiable, Sendable, Equatable {
    public let category: CaseChangeCategory
    public let kind: CaseChangeKind
    /// Every change in the group — the drill-down is complete.
    public let members: [CaseChange]
    /// Distinct records resting (at any depth) on the group's changed evidence.
    public let impact: Int
    /// Members not acknowledged that change evidence or touch a record waiting for review.
    public let unresolved: Int
    public var id: String { kind.rawValue }
    public var count: Int { members.count }
    public var line: String {
        var parts = ["\(count) × \(kind.label)"]
        if impact > 0 { parts.append("\(impact) record(s) rest on it") }
        if unresolved > 0 { parts.append("\(unresolved) unresolved") }
        return parts.joined(separator: " · ")
    }
}

public nonisolated enum CaseChangeDigest {
    /// The new changes grouped by category and kind — nothing dropped: every group lists every member, and the feed's
    /// own display cap is carried separately (`load.omitted`).
    public static func groups(_ load: CaseChangeFeedLoad, projection p: CaseMapProjection, acknowledged: Set<String> = [],
                              derivations: [CaseDerivationBinding] = []) -> [CaseChangeGroup] {
        let byKind = Dictionary(grouping: load.newChanges, by: \.kind)
        var traces: [CaseMapNodeID: CaseImpactTrace] = [:]
        func trace(_ r: CaseMapNodeID) -> CaseImpactTrace {
            if let t = traces[r] { return t }
            let t = CaseDependencyTraversal.trace(from: r, in: p, derivations: derivations)
            traces[r] = t
            return t
        }
        return byKind.map { kind, members -> CaseChangeGroup in
            var affected = Set<String>()
            var unresolved = 0
            for ch in members {
                var open = false
                if kind.affectsEvidence, let r = ch.record {
                    let t = trace(r)
                    affected.formUnion(t.entries.map(\.key))
                    open = !t.entries.isEmpty
                }
                if let r = ch.record, p.node(r)?.review.awaitingReview == true { open = true }
                if [.reviewReopened, .detected, .noLongerDetected, .lateContribution].contains(kind) { open = true }
                if open && !acknowledged.contains(ch.id) { unresolved += 1 }
            }
            return CaseChangeGroup(category: kind.category, kind: kind, members: members, impact: affected.count, unresolved: unresolved)
        }.sorted { a, b in
            let ia = CaseChangeCategory.allCases.firstIndex(of: a.category) ?? 0, ib = CaseChangeCategory.allCases.firstIndex(of: b.category) ?? 0
            return ia != ib ? ia < ib : a.kind.rawValue < b.kind.rawValue
        }
    }
}

// MARK: - CHANGE-05 acknowledgements and review obligations

public nonisolated struct CaseChangeAcknowledgement: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let caseID: UUID
    public let changeID: String
    public let record: CaseMapNodeID?
    public let note: String
    public let acknowledgedBy: String
    public let acknowledgedAt: Date
}

/// A change that needs a substantive look: what rests on it, and whether someone acknowledged it.
public nonisolated struct CaseReviewObligation: Identifiable, Sendable, Equatable {
    public let change: CaseChange
    public let dependents: [CaseImpactEntry]
    public let acknowledgedBy: [String]
    public var id: String { change.id }
    public var isOpen: Bool { acknowledgedBy.isEmpty }
}

public nonisolated enum CaseChangeObligations {
    /// Changes to evidence with records resting on them, reopened reviews, new detections and late contributions — each
    /// stays an obligation until someone acknowledges it with a note. Moving the seen position never clears one.
    /// `notifications` are the durable impact notifications (CHANGE-09): an obligation written there stays listed after the
    /// change has scrolled out of the feed's window (after "Mark as seen"), until it is acknowledged.
    public static func list(_ load: CaseChangeFeedLoad, projection p: CaseMapProjection, acknowledgements: [CaseChangeAcknowledgement],
                            notifications: [CaseImpactNotification] = [], derivations: [CaseDerivationBinding] = []) -> [CaseReviewObligation] {
        var byChange: [String: [String]] = [:]
        for a in acknowledgements { byChange[a.changeID, default: []].append(a.acknowledgedBy) }
        let listed = Set(load.changes.map(\.id))
        var durable: [String: [CaseImpactNotification]] = [:]
        for n in notifications where !listed.contains(n.changeID) { durable[n.changeID, default: []].append(n) }
        let fromLedger = durable.keys.sorted().compactMap { id -> CaseReviewObligation? in
            guard let notes = durable[id], let first = notes.first else { return nil }
            let kind = CaseChangeKind(rawValue: String(id.prefix { $0 != ":" })) ?? .documentRevised
            let changed: CaseMapNodeID? = {
                guard let colon = first.changed.firstIndex(of: ":"), let k = CaseMapRecordKind(rawValue: String(first.changed[..<colon])) else { return nil }
                return CaseMapNodeID(caseID: p.caseID, kind: k, recordID: String(first.changed[first.changed.index(after: colon)...]))
            }()
            let ch = CaseChange(id: id, kind: kind, record: changed, recordedAt: first.createdAt, actor: nil,
                                summary: "\(kind.label) — recorded as an impact notification; it needs a look even though it is before your seen position.",
                                basis: .recorded("the impact notifications"), isNew: false)
            let deps = notes.map { n -> CaseImpactEntry in
                let node: CaseMapNodeID? = {
                    guard let colon = n.dependent.firstIndex(of: ":"), let k = CaseMapRecordKind(rawValue: String(n.dependent[..<colon])) else { return nil }
                    let nid = CaseMapNodeID(caseID: p.caseID, kind: k, recordID: String(n.dependent[n.dependent.index(after: colon)...]))
                    return p.node(nid) != nil ? nid : nil
                }()
                return CaseImpactEntry(key: n.dependent, node: node, title: node.flatMap { p.node($0)?.title } ?? n.dependent, depth: n.depth, path: [n.path],
                                       review: node.flatMap { p.node($0)?.review } ?? .notApplicable)
            }
            return CaseReviewObligation(change: ch, dependents: deps, acknowledgedBy: byChange[id] ?? [])
        }
        return fromLedger + load.changes.compactMap { ch -> CaseReviewObligation? in
            var deps: [CaseImpactEntry] = []
            if ch.kind.affectsEvidence, let r = ch.record { deps = CaseDependencyTraversal.trace(from: r, in: p, derivations: derivations).entries }
            let needs = !deps.isEmpty || [.reviewReopened, .detected, .lateContribution, .identityChanged].contains(ch.kind)
            guard needs else { return nil }
            return CaseReviewObligation(change: ch, dependents: deps, acknowledgedBy: byChange[ch.id] ?? [])
        }
    }
}

// MARK: - CHANGE-07 / CHANGE-08 vocabulary

public nonisolated enum CaseLateContributionKind: String, Sendable, CaseIterable, Codable {
    case document, result, note, request, other
}

public nonisolated struct CaseLateContribution: Identifiable, Sendable, Equatable {
    public enum State: String, Sendable { case queued, reopenRequested, admitted, declined
        public var label: String {
            switch self {
            case .queued: return "Waiting — the case is closed; nothing was added to it"
            case .reopenRequested: return "Reopening asked for — the case stays closed until a person reopens it"
            case .admitted: return "Admitted after the case was reopened"
            case .declined: return "Declined with a reason (kept)"
            }
        }
    }
    public enum Decision: String, Sendable { case admit, decline, requestReopen }
    public let id: UUID
    public let caseID: UUID
    public let kind: CaseLateContributionKind
    public let sourceRef: String?
    public let description: String
    public let contributedBy: String
    public let softwareActor: String?
    public let receivedAt: Date
    public let state: State
    public let decidedBy: String?
    public let decidedAt: Date?
    public let decisionReason: String?
}

public nonisolated enum CaseContributionOutcome: Equatable, Sendable {
    case applied
    /// The case is closed: the contribution was queued (its id), not applied and not dropped.
    case queued(UUID)
}

/// What an automated result was produced against (CHANGE-08). Taken when the job starts.
public nonisolated struct CaseResultFence: Sendable, Equatable {
    public let caseID: UUID
    public let anchor: CaseMapNodeID
    /// The newest brief version the job read (0: none).
    public let baseVersion: Int
    /// The case's content fence when the job read it.
    public let baseFence: String
    /// The policy in force when the job started (for example the AI mode and the case's permission).
    public let policy: String
    /// Who asked for it (checked against the team at application time).
    public let requestedBy: String
    public let generation: UInt64
}

public nonisolated enum CaseResultApplication: Equatable, Sendable {
    case applied(UUID)
    case refusedNewerEdit(String)
    case refusedInputsChanged(String)
    case refusedPolicyChanged(String)
    /// The case is closed: the result was queued as a late contribution (its id).
    case refusedClosed(UUID)
    case superseded(String)
    var outcome: String {
        switch self {
        case .applied: return "applied"
        case .refusedNewerEdit: return "refusedNewerEdit"
        case .refusedInputsChanged: return "refusedInputsChanged"
        case .refusedPolicyChanged: return "refusedPolicyChanged"
        case .refusedClosed: return "refusedClosed"
        case .superseded: return "superseded"
        }
    }
    public var isApplied: Bool { if case .applied = self { return true }; return false }
}

/// CHANGE-04 — an anchor's brief as the person should see it: the accepted (recorded) version with its staleness, and the
/// newest unaccepted proposal beside it. A proposal never replaces the accepted text until a person accepts it.
public nonisolated struct CaseBriefRefreshView: Sendable, Equatable {
    public let accepted: CaseBriefVersion?
    public let acceptedIsStale: Bool
    public let proposal: CaseBriefVersion?
    public static func resolve(_ ledger: CaseBriefLedger, anchor: CaseMapNodeID) -> CaseBriefRefreshView {
        let versions = ledger.versions(of: anchor)
        let accepted = versions.first { $0.isAccepted }
        let proposal = versions.first.flatMap { $0.isAccepted ? nil : $0 }
        return CaseBriefRefreshView(accepted: accepted, acceptedIsStale: accepted.map(ledger.isStale) ?? false, proposal: proposal)
    }
}

public nonisolated enum CaseChangeWorkError: Error, Equatable, LocalizedError {
    case caseNotClosed
    case reopenFirst
    case alreadyDecided
    case notFound(String)
    case inputNotInCase(String)
    case noInputs
    case notEligible(String)
    case blankNote
    public var errorDescription: String? {
        switch self {
        case .caseNotClosed: return "The case is open: add the material to it directly."
        case .reopenFirst: return "The case is closed. Reopen it (a recorded decision) before admitting what arrived."
        case .alreadyDecided: return "This contribution was already admitted or declined."
        case .notFound(let what): return "The \(what) was not found in this case."
        case .inputNotInCase(let key): return "\(key) is not in this case's map, so it cannot be recorded as an input."
        case .noInputs: return "Choose at least one input it was derived from."
        case .notEligible(let why): return why
        case .blankNote: return "Say what you checked: an acknowledgement needs a note."
        }
    }
}

// MARK: - Repository (one savepoint per write, with its case log row)

extension CaseFileRepository {

    static func caseIsClosed(_ db: isolated Database, _ caseID: UUID) throws -> Bool {
        if try !db.query("SELECT 1 FROM case_profiles WHERE case_id = ? AND stage = 'closed' LIMIT 1;", [.uuid(caseID)]).isEmpty { return true }
        return try !db.query("SELECT 1 FROM investigation_cases WHERE id = ? AND status = 'closed' LIMIT 1;", [.uuid(caseID)]).isEmpty
    }

    // MARK: CHANGE-02

    /// Bind a derived item to the exact inputs it was derived from, as the projection shows them now. An input may also be
    /// another derived item ("brief:<id>") that was bound before.
    @discardableResult
    public func bindDerivation(caseID: UUID, derived: CaseDerivedKind, derivedID: String, label: String, inputs: [String],
                               projection p: CaseMapProjection, actor: String, at date: Date = Date()) async throws -> UUID {
        let who = try Self.clean(actor, "Actor")
        let name = try Self.clean(label, "The item's name")
        let did = try Self.clean(derivedID, "The item")
        guard p.caseID == caseID else { throw CaseWorkError.notInCase("map") }
        guard !inputs.isEmpty else { throw CaseChangeWorkError.noInputs }
        let earlier = CaseDerivation.latest(try await derivationBindings(caseID: caseID))
        var resolved: [CaseDerivationInput] = []
        for raw in Set(inputs.map { $0.lowercased() }).sorted() {
            if let b = earlier.first(where: { $0.derivedKey == raw }) {
                let s = CaseDerivationSnapshot(title: b.label, revision: b.bindID.uuidString.lowercased(), wordingDigest: nil, review: "", status: "",
                                               sourceVersions: [], present: true)
                resolved.append(CaseDerivationInput(key: raw, revision: s.revision, fingerprint: CaseDerivation.fingerprint(s), snapshot: s))
                continue
            }
            guard let colon = raw.firstIndex(of: ":"), let kind = CaseMapRecordKind(rawValue: String(raw[..<colon])),
                  let n = p.node(CaseMapNodeID(caseID: caseID, kind: kind, recordID: String(raw[raw.index(after: colon)...]))) else {
                throw CaseChangeWorkError.inputNotInCase(raw)
            }
            let s = CaseDerivation.snapshot(of: n)
            resolved.append(CaseDerivationInput(key: raw, revision: n.revision, fingerprint: CaseDerivation.fingerprint(s), snapshot: s))
        }
        let bind = UUID()
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        let rows = try resolved.map { ($0, String(decoding: try enc.encode($0.snapshot), as: UTF8.self)) }
        try await write("cf_deriv", caseID: caseID, actor: who, action: "derivationBound", detail: "\(derived.rawValue) \(did.prefix(12)): \(resolved.count) input(s)", at: date) { db in
            for (i, json) in rows {
                guard let colon = i.key.firstIndex(of: ":") else { continue }
                try db.exec("""
                    INSERT INTO case_derivation_inputs (id, case_id, bind_id, derived_kind, derived_id, derived_label, input_kind, input_id, input_revision,
                        input_fingerprint, input_snapshot_json, bound_by, bound_at)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?);
                    """, [.uuid(UUID()), .uuid(caseID), .uuid(bind), .text(derived.rawValue), .text(did.lowercased()), .text(name),
                          .text(String(i.key[..<colon])), .text(String(i.key[i.key.index(after: colon)...])), .optionalText(i.revision),
                          .text(i.fingerprint), .text(json), .text(who), .date(date)])
            }
        }
        return bind
    }

    public func derivationBindings(caseID: UUID) async throws -> [CaseDerivationBinding] {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        let rows = try await database.query("""
            SELECT bind_id, derived_kind, derived_id, derived_label, input_kind, input_id, input_revision, input_fingerprint, input_snapshot_json, bound_by, bound_at
            FROM case_derivation_inputs WHERE case_id = ? ORDER BY bound_at, bind_id, input_kind, input_id;
            """, [.uuid(caseID)])
        var order: [UUID] = []
        var parts: [UUID: (kind: CaseDerivedKind, id: String, label: String, by: String, at: Date, inputs: [CaseDerivationInput])] = [:]
        for r in rows {
            guard let bind = r.uuid(0), let kind = r.string(1).flatMap(CaseDerivedKind.init(rawValue:)), let did = r.string(2), let label = r.string(3),
                  let ik = r.string(4), let iid = r.string(5), let fp = r.string(7), let by = r.string(9), let at = r.date(10) else { continue }
            let snap = (r.string(8)?.data(using: .utf8)).flatMap { try? JSONDecoder().decode(CaseDerivationSnapshot.self, from: $0) }
                ?? CaseDerivationSnapshot(title: "\(ik):\(iid)", revision: r.string(6), wordingDigest: nil, review: "", status: "", sourceVersions: [], present: true)
            if parts[bind] == nil { order.append(bind); parts[bind] = (kind, did, label, by, at, []) }
            parts[bind]?.inputs.append(CaseDerivationInput(key: "\(ik):\(iid)", revision: r.string(6), fingerprint: fp, snapshot: snap))
        }
        return order.compactMap { b in
            parts[b].map { CaseDerivationBinding(bindID: b, caseID: caseID, derivedKind: $0.kind, derivedID: $0.id, label: $0.label, inputs: $0.inputs,
                                                 boundBy: $0.by, boundAt: $0.at) }
        }
    }

    // MARK: CHANGE-07

    /// Queue material or a result that arrived for a CLOSED case. Refused for an open case (add it directly).
    @discardableResult
    public func queueLateContribution(caseID: UUID, kind: CaseLateContributionKind, sourceRef: String?, description: String, contributedBy: String,
                                      softwareActor: String? = nil, at date: Date = Date()) async throws -> UUID {
        let who = try Self.clean(contributedBy, "Who contributed it")
        let what = try Self.clean(description, "What arrived")
        let id = UUID()
        try await write("cf_late", caseID: caseID, actor: who, action: "lateContributionQueued", detail: "\(kind.rawValue): \(what.prefix(120))", at: date,
                        allowedWhenClosed: true) { db in
            guard try Self.caseIsClosed(db, caseID) else { throw CaseChangeWorkError.caseNotClosed }
            try db.exec("""
                INSERT INTO case_late_contributions (id, case_id, kind, source_ref, description, contributed_by, software_actor, received_at)
                VALUES (?,?,?,?,?,?,?,?);
                """, [.uuid(id), .uuid(caseID), .text(kind.rawValue), .optionalText(Self.blankToNil(sourceRef)), .text(what), .text(who),
                      .optionalText(Self.blankToNil(softwareActor)), .date(date)])
        }
        return id
    }

    /// Background work: try to apply; when the case turns out to be closed, queue the contribution instead — it neither
    /// changes the closed case nor disappears.
    public func contributeOrQueue(caseID: UUID, kind: CaseLateContributionKind, sourceRef: String?, description: String, contributedBy: String,
                                  softwareActor: String? = nil, apply: @Sendable () async throws -> Void) async throws -> CaseContributionOutcome {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        do {
            try await apply()
            return .applied
        } catch let e as CaseFileError where e == .caseClosed {
            KalsmritikoshLog.app.info("Late contribution queued for a closed case")
        } catch InvestigationCaseError.caseClosed {
            KalsmritikoshLog.app.info("Late contribution queued for a closed case (case header)")
        }
        return .queued(try await queueLateContribution(caseID: caseID, kind: kind, sourceRef: sourceRef, description: description,
                                                       contributedBy: contributedBy, softwareActor: softwareActor))
    }

    /// Decide a queued contribution: admit (only once the case is reopened), decline (kept, with the reason) or ask for the
    /// case to be reopened (it stays closed until a person reopens it). Never deletes it.
    public func decideLateContribution(caseID: UUID, id: UUID, decision: CaseLateContribution.Decision, reason: String, actor: String,
                                       at date: Date = Date()) async throws {
        let who = try Self.clean(actor, "Actor")
        let why = try Self.clean(reason, "The reason")
        try await write("cf_lated", caseID: caseID, actor: who, action: "lateContributionDecided", detail: "\(decision.rawValue): \(why.prefix(120))", at: date,
                        allowedWhenClosed: true) { db in
            try CaseMembershipGate.require(db, caseID: caseID, name: who)
            guard let r = try db.query("SELECT state FROM case_late_contributions WHERE id = ? AND case_id = ?;", [.uuid(id), .uuid(caseID)]).first,
                  let state = r.string(0) else { throw CaseChangeWorkError.notFound("contribution") }
            guard state == "queued" || state == "reopenRequested" else { throw CaseChangeWorkError.alreadyDecided }
            let next: String
            switch decision {
            case .admit:
                guard try !Self.caseIsClosed(db, caseID) else { throw CaseChangeWorkError.reopenFirst }
                next = "admitted"
            case .decline: next = "declined"
            case .requestReopen: next = "reopenRequested"
            }
            try db.exec("UPDATE case_late_contributions SET state = ?, decided_by = ?, decided_at = ?, decision_reason = ? WHERE id = ?;",
                        [.text(next), .text(who), .date(date), .text(why), .uuid(id)])
        }
    }

    public func lateContributions(caseID: UUID) async throws -> [CaseLateContribution] {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        return try await database.query("""
            SELECT id, kind, source_ref, description, contributed_by, software_actor, received_at, state, decided_by, decided_at, decision_reason
            FROM case_late_contributions WHERE case_id = ? ORDER BY received_at, id;
            """, [.uuid(caseID)]).compactMap { r in
            guard let id = r.uuid(0), let k = r.string(1).flatMap(CaseLateContributionKind.init(rawValue:)), let d = r.string(3), let by = r.string(4),
                  let at = r.date(6), let st = r.string(7).flatMap(CaseLateContribution.State.init(rawValue:)) else { return nil }
            return CaseLateContribution(id: id, caseID: caseID, kind: k, sourceRef: r.string(2), description: d, contributedBy: by, softwareActor: r.string(5),
                                        receivedAt: at, state: st, decidedBy: r.string(8), decidedAt: r.date(9), decisionReason: r.string(10))
        }
    }

    // MARK: CHANGE-04 / CHANGE-08

    /// Take the fence a job must carry: the newest brief version of the anchor, the case's content fence, the policy and
    /// who asked. A job can check `resultFenceIsCurrent` before expensive work and stop early when it is not.
    public func resultFence(caseID: UUID, anchor: CaseMapNodeID, policy: String, requestedBy: String, generation: UInt64 = 0) async throws -> CaseResultFence {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        let (version, fence) = try await database.withSavepoint("cf_rfence_\(UUID().uuidString.prefix(8))") { db -> (Int, String) in
            let v = Int(try db.query("SELECT coalesce(MAX(version), 0) FROM case_briefs WHERE case_id = ? AND anchor_kind = ? AND anchor_id = ?;",
                                     [.uuid(caseID), .text(anchor.kind.rawValue), .text(anchor.recordID)]).first?.int(0) ?? 0)
            return (v, try CaseMapRepository.fence(db, caseID: caseID, ignoringActions: Self.briefActions + Self.resultActions,
                                                  ignoringRevisionKinds: Self.briefRecordKinds))
        }
        return CaseResultFence(caseID: caseID, anchor: anchor, baseVersion: version, baseFence: fence, policy: policy, requestedBy: requestedBy, generation: generation)
    }

    nonisolated static let resultActions = ["generatedResultApplied", "generatedResultRefused"]

    /// Whether a job's fence still holds (nobody wrote a newer version, the inputs and policy are unchanged): a job may
    /// cancel itself when this is false instead of producing a result that will be refused.
    public func resultFenceIsCurrent(_ f: CaseResultFence, policyNow: String) async throws -> Bool {
        guard f.policy == policyNow else { return false }
        let now = try await resultFence(caseID: f.caseID, anchor: f.anchor, policy: policyNow, requestedBy: f.requestedBy)
        return now.baseVersion == f.baseVersion && now.baseFence == f.baseFence
    }

    /// CHANGE-04 + CHANGE-08 — apply a generated brief as a PROPOSAL (a new, unaccepted version labelled as generated),
    /// only if every fence still holds at this moment. A person's newer version, changed inputs, a changed policy, a
    /// requester no longer on the team or a closed case refuse it; every attempt is recorded, and a result for a closed case
    /// is queued as a late contribution. The accepted version is never touched; only a person accepts the proposal.
    public func applyGeneratedBrief(_ f: CaseResultFence, text: CaseBriefText, generatedBy: String, policyNow: String,
                                    at date: Date = Date()) async throws -> CaseResultApplication {
        let producer = try Self.clean(generatedBy, "What generated it")
        guard !text.isEmpty else { throw CaseBriefError.emptyBrief }
        let caseID = f.caseID, anchor = f.anchor
        // Decide in one savepoint; then write (re-checked inside the write) or record the refusal.
        let verdict: CaseResultApplication? = try await database.withSavepoint("cf_rcheck_\(UUID().uuidString.prefix(8))") { db -> CaseResultApplication? in
            try Self.resultVerdict(db, f, policyNow: policyNow)
        }
        if let refused = verdict {
            if case .refusedClosed = refused {
                let late = try await queueLateContribution(caseID: caseID, kind: .result, sourceRef: nil,
                                                           description: "Generated brief for \(anchor.key) (\(producer)) arrived after the case was closed",
                                                           contributedBy: f.requestedBy, softwareActor: producer, at: date)
                try await recordApplication(f, .refusedClosed(late), producer: producer, at: date)
                return .refusedClosed(late)
            }
            try await recordApplication(f, refused, producer: producer, at: date)
            return refused
        }
        let id = UUID()
        func clean(_ s: String?) -> SQLValue { Self.blankToNil(s).map { .text($0) } ?? .null }
        let values = [clean(text.purpose), clean(text.position), clean(text.unresolved), clean(text.alternatives), clean(text.nextWork)]
        do {
            try await write("cf_rapply", caseID: caseID, actor: f.requestedBy, action: "generatedResultApplied", detail: "\(anchor.key) v\(f.baseVersion + 1) by \(producer)",
                            at: date, capture: CaseRecordCapture(kind: "brief", table: "case_briefs", recordID: id)) { db in
                if let late = try Self.resultVerdict(db, f, policyNow: policyNow) { throw ResultRace(verdict: late) }
                let previous = try db.query("SELECT id FROM case_briefs WHERE case_id = ? AND anchor_kind = ? AND anchor_id = ? AND version = ?;",
                                            [.uuid(caseID), .text(anchor.kind.rawValue), .text(anchor.recordID), .integer(Int64(f.baseVersion))]).first?.string(0)
                try db.exec("""
                    INSERT INTO case_briefs (id, case_id, anchor_kind, anchor_id, version, purpose, position, unresolved, alternatives, next_work, origin,
                                             generated_by, fence, written_by, written_at, supersedes_id)
                    VALUES (?,?,?,?,?,?,?,?,?,?, 'generated', ?,?,?,?,?);
                    """, [.uuid(id), .uuid(caseID), .text(anchor.kind.rawValue), .text(anchor.recordID), .integer(Int64(f.baseVersion + 1))] + values
                        + [.text(producer), .text(f.baseFence), .text(f.requestedBy), .date(date), previous.map { .text($0) } ?? .null])
                try Self.insertApplication(db, f, outcome: "applied", detail: "Written as version \(f.baseVersion + 1), a proposal waiting for a person.",
                                           producer: producer, appliedID: id, at: date)
            }
        } catch let race as ResultRace {
            try await recordApplication(f, race.verdict, producer: producer, at: date)
            return race.verdict
        }
        return .applied(id)
    }

    struct ResultRace: Error { let verdict: CaseResultApplication }

    /// Nil when the result may be applied; otherwise why not.
    static func resultVerdict(_ db: isolated Database, _ f: CaseResultFence, policyNow: String) throws -> CaseResultApplication? {
        let caseID = f.caseID
        guard try !db.query("SELECT 1 FROM investigation_cases WHERE id = ?;", [.uuid(caseID)]).isEmpty else { throw CaseFileError.caseNotFound(caseID) }
        if try caseIsClosed(db, caseID) { return .refusedClosed(UUID()) }
        if let why = try CaseMembershipGate.refusal(db, caseID: caseID, name: f.requestedBy) {
            return .refusedPolicyChanged("The person who asked for it can no longer act in this case: \(why)")
        }
        if f.policy != policyNow {
            return .refusedPolicyChanged("The policy changed while it was being produced (\(f.policy) → \(policyNow)); it was not applied.")
        }
        let rows = try db.query("SELECT version, origin, accepted_at FROM case_briefs WHERE case_id = ? AND anchor_kind = ? AND anchor_id = ? ORDER BY version DESC LIMIT 1;",
                                [.uuid(caseID), .text(f.anchor.kind.rawValue), .text(f.anchor.recordID)])
        let newest = Int(rows.first?.int(0) ?? 0)
        if newest != f.baseVersion {
            return .refusedNewerEdit("A newer version (\(newest)) was written while it was being produced from version \(f.baseVersion); the newer version stands.")
        }
        // A person's unaccepted draft is their work in progress: a generated text does not go on top of it.
        if let r = rows.first, r.string(1) == "manual", r.isNull(2) {
            return .refusedNewerEdit("The newest version is a person's draft that is not accepted yet; a generated text is not put on top of it.")
        }
        let fenceNow = try CaseMapRepository.fence(db, caseID: caseID, ignoringActions: briefActions + resultActions, ignoringRevisionKinds: briefRecordKinds)
        if fenceNow != f.baseFence {
            return .refusedInputsChanged("The case changed while it was being produced, so it rests on inputs that are no longer current.")
        }
        return nil
    }

    static func insertApplication(_ db: isolated Database, _ f: CaseResultFence, outcome: String, detail: String, producer: String, appliedID: UUID?, at date: Date) throws {
        try db.exec("""
            INSERT INTO case_result_applications (id, case_id, target_kind, target_id, base_version, base_fence, policy_at_start, generation, outcome, detail,
                produced_by, applied_id, at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(UUID()), .uuid(f.caseID), .text(f.anchor.kind.rawValue), .text(f.anchor.recordID), .integer(Int64(f.baseVersion)), .text(f.baseFence),
                  .text(f.policy), .integer(Int64(truncatingIfNeeded: f.generation)), .text(outcome), .text(detail), .text(producer),
                  appliedID.map { .uuid($0) } ?? .null, .date(date)])
    }

    /// A refused attempt is recorded even for a closed case (it changes no case record).
    func recordApplication(_ f: CaseResultFence, _ verdict: CaseResultApplication, producer: String, at date: Date) async throws {
        let detail: String
        switch verdict {
        case .applied: detail = "Applied"
        case .refusedNewerEdit(let w), .refusedInputsChanged(let w), .refusedPolicyChanged(let w), .superseded(let w): detail = w
        case .refusedClosed(let late): detail = "The case is closed; queued as late contribution \(late.uuidString.prefix(8))."
        }
        try await database.withSavepoint("cf_rrec_\(UUID().uuidString.prefix(8))") { db in
            try Self.insertApplication(db, f, outcome: verdict.outcome, detail: detail, producer: producer, appliedID: nil, at: date)
        }
    }

    public func resultApplications(caseID: UUID) async throws -> [(outcome: String, detail: String, at: Date)] {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        return try await database.query("SELECT outcome, detail, at FROM case_result_applications WHERE case_id = ? ORDER BY at, rowid;", [.uuid(caseID)]).compactMap { r in
            guard let o = r.string(0), let d = r.string(1), let at = r.date(2) else { return nil }
            return (o, d, at)
        }
    }
}

// MARK: - Feed service additions (CHANGE-05, CHANGE-09)

public nonisolated struct CaseImpactNotification: Identifiable, Sendable, Equatable {
    public let id: String
    public let changeID: String
    public let changed: String
    public let dependent: String
    public let depth: Int
    public let path: String
    public let createdAt: Date
    public let acknowledgedBy: String?
}

public nonisolated struct CaseReconcileReport: Sendable, Equatable {
    public let inserted: Int
    public let alreadyKnown: Int
    public let runs: Int
    public let reconciledThrough: Date
}

extension CaseChangeFeedService {

    /// CHANGE-05 — acknowledge one change substantively, with what was checked. It decides nothing about the records the
    /// change touches and does not move anybody's seen position.
    @discardableResult
    public func acknowledge(_ change: CaseChange, caseID: UUID, note: String, actor: String, at date: Date = Date()) async throws -> UUID {
        let who = actor.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !who.isEmpty else { throw CaseChangeFeedError.blankActor }
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw CaseChangeWorkError.blankNote }
        let id = UUID()
        try await database.withSavepoint("ccack_\(UUID().uuidString.prefix(8))") { db in
            try CaseAccessPolicy.require(db, caseID: caseID, actor: who, .read)
            guard try db.query("SELECT 1 FROM investigation_cases WHERE id = ?;", [.uuid(caseID)]).first != nil else { throw CaseChangeFeedError.caseNotFound }
            try db.exec("""
                INSERT INTO case_change_acknowledgements (id, case_id, change_id, record_kind, record_id, note, acknowledged_by, acknowledged_at)
                VALUES (?,?,?,?,?,?,?,?);
                """, [.uuid(id), .uuid(caseID), .text(change.id), .optionalText(change.record?.kind.rawValue), .optionalText(change.record?.recordID),
                      .text(text), .text(who), .date(date)])
        }
        return id
    }

    public func acknowledgements(caseID: UUID) async throws -> [CaseChangeAcknowledgement] {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        return try await database.query("""
            SELECT id, change_id, record_kind, record_id, note, acknowledged_by, acknowledged_at FROM case_change_acknowledgements
            WHERE case_id = ? ORDER BY acknowledged_at, id;
            """, [.uuid(caseID)]).compactMap { r in
            guard let id = r.uuid(0), let ch = r.string(1), let note = r.string(4), let by = r.string(5), let at = r.date(6) else { return nil }
            let rec = r.string(2).flatMap(CaseMapRecordKind.init(rawValue:)).flatMap { k in r.string(3).map { CaseMapNodeID(caseID: caseID, kind: k, recordID: $0) } }
            return CaseChangeAcknowledgement(id: id, caseID: caseID, changeID: ch, record: rec, note: note, acknowledgedBy: by, acknowledgedAt: at)
        }
    }

    /// CHANGE-09 — write the impact notifications of every listed change to evidence, idempotently (one row per change and
    /// dependent), and move the case's durable checkpoint, in ONE savepoint: a crash part-way leaves nothing half-written,
    /// and running it again after a crash, a reconnect or a missed event adds only what is missing.
    @discardableResult
    public func reconcileImpacts(_ load: CaseChangeFeedLoad, projection p: CaseMapProjection, derivations: [CaseDerivationBinding] = [],
                                 failAfter: Int? = nil, at date: Date = Date()) async throws -> CaseReconcileReport {
        if case .failed = load.state { throw CaseChangeFeedError.feedNotLoaded }
        guard p.caseID == load.caseID else { throw CaseChangeFeedError.feedNotLoaded }
        let caseID = load.caseID
        var rows: [(id: String, change: CaseChange, changed: CaseMapNodeID, entry: CaseImpactEntry)] = []
        for ch in load.changes where ch.kind.affectsEvidence {
            guard let r = ch.record else { continue }
            for e in CaseDependencyTraversal.trace(from: r, in: p, derivations: derivations).entries {
                rows.append((CaseFileHash.sha256("\(caseID.uuidString.lowercased())|\(ch.id)|\(e.key)"), ch, r, e))
            }
        }
        let list = rows
        let run = UUID().uuidString.lowercased(), through = load.readAt
        return try await database.withSavepoint("ccrec_\(UUID().uuidString.prefix(8))") { db -> CaseReconcileReport in
            try CaseAccessPolicy.require(db, caseID: caseID, actor: nil, .read)
            guard try db.query("SELECT 1 FROM investigation_cases WHERE id = ?;", [.uuid(caseID)]).first != nil else { throw CaseChangeFeedError.caseNotFound }
            var inserted = 0, known = 0
            for (n, row) in list.enumerated() {
                if let failAfter, n >= failAfter { throw CaseChangeFeedService.InjectedFault(part: "reconciliation (after \(failAfter) notification(s))") }
                let colon = row.entry.key.firstIndex(of: ":") ?? row.entry.key.endIndex
                let dk = String(row.entry.key[..<colon])
                let did = colon < row.entry.key.endIndex ? String(row.entry.key[row.entry.key.index(after: colon)...]) : row.entry.key
                let before = try db.query("SELECT 1 FROM case_impact_notifications WHERE id = ?;", [.text(row.id)]).isEmpty
                try db.exec("""
                    INSERT OR IGNORE INTO case_impact_notifications (id, case_id, change_id, changed_kind, changed_id, dependent_kind, dependent_id, depth,
                        path_text, created_at) VALUES (?,?,?,?,?,?,?,?,?,?);
                    """, [.text(row.id), .uuid(caseID), .text(row.change.id), .text(row.changed.kind.rawValue), .text(row.changed.recordID), .text(dk), .text(did),
                          .integer(Int64(row.entry.depth)), .text(row.entry.explanation), .date(date)])
                if before { inserted += 1 } else { known += 1 }
            }
            try db.exec("""
                INSERT INTO case_change_checkpoints (case_id, reconciled_through, last_run_id, runs, updated_at) VALUES (?,?,?,1,?)
                ON CONFLICT(case_id) DO UPDATE SET reconciled_through = max(reconciled_through, excluded.reconciled_through), last_run_id = excluded.last_run_id,
                    runs = runs + 1, updated_at = excluded.updated_at;
                """, [.uuid(caseID), .date(through), .text(run), .date(date)])
            let cp = try db.query("SELECT runs, reconciled_through FROM case_change_checkpoints WHERE case_id = ?;", [.uuid(caseID)]).first
            return CaseReconcileReport(inserted: inserted, alreadyKnown: known, runs: Int(cp?.int(0) ?? 1), reconciledThrough: cp?.date(1) ?? through)
        }
    }

    public func impactNotifications(caseID: UUID) async throws -> [CaseImpactNotification] {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        return try await database.query("""
            SELECT id, change_id, changed_kind, changed_id, dependent_kind, dependent_id, depth, path_text, created_at, acknowledged_by
            FROM case_impact_notifications WHERE case_id = ? ORDER BY created_at, depth, id;
            """, [.uuid(caseID)]).compactMap { r in
            guard let id = r.string(0), let ch = r.string(1), let ck = r.string(2), let cid = r.string(3), let dk = r.string(4), let did = r.string(5),
                  let at = r.date(8) else { return nil }
            return CaseImpactNotification(id: id, changeID: ch, changed: "\(ck):\(cid)", dependent: "\(dk):\(did)", depth: Int(r.int(6) ?? 1),
                                          path: r.string(7) ?? "", createdAt: at, acknowledgedBy: r.string(9))
        }
    }

    /// Acknowledge one notification (once; it is never deleted).
    public func acknowledgeNotification(caseID: UUID, id: String, actor: String, at date: Date = Date()) async throws {
        let who = actor.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !who.isEmpty else { throw CaseChangeFeedError.blankActor }
        try await database.withSavepoint("ccnack_\(UUID().uuidString.prefix(8))") { db in
            try CaseAccessPolicy.require(db, caseID: caseID, actor: who, .read)
            guard try !db.query("SELECT 1 FROM case_impact_notifications WHERE id = ? AND case_id = ? AND acknowledged_at IS NULL;", [.text(id), .uuid(caseID)]).isEmpty else {
                throw CaseChangeWorkError.alreadyDecided
            }
            try db.exec("UPDATE case_impact_notifications SET acknowledged_by = ?, acknowledged_at = ? WHERE id = ?;", [.text(who), .date(date), .text(id)])
        }
    }
}
