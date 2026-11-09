//
//  CaseRecordContracts.swift
//  Kalsmritikosh
//
//  Smart-map M0 (docs/IME_Full_Smart_Map_Implementation_TODO_2026-11-08.md: ARCH-02, ARCH-06, ARCH-07, DATA-01–DATA-05;
//  schema v177): the record and relationship contracts the recursive map rests on.
//
//  • Frame membership (ARCH-02). The investigator places a record of the case in a branch (a frame anchored on another
//    record). The membership is its own record: it copies neither record and holds no position (positions stay per
//    frame in case_map_layout), so one record is a member of several branches while it is stored — and edited — once.
//    Withdrawn with a reason, never edited; a second active placement of the same record in the same frame is refused.
//  • Action dependencies (ARCH-07). "This action waits for that one", stored in the ONE task engine's own
//    professional_task_dependencies (kind 'waitsFor'): both ends must be tasks of the case (case_task_links), and a
//    dependency that would close a cycle is refused. Removing one deletes the row; its before copy, who removed it and
//    why stay in the case's revisions and action log. The case_actions activity log is not an action and never becomes one.
//  • Actors (ARCH-06, DATA-05). Every name in a case's action log has a stable actor id. A name typed on this Mac is a
//    LEGACY name — "a name as recorded, not a signed-in account" — and the database refuses to turn it into an
//    authenticated user. Case participants, reported external performers and software are recorded as such.
//  • Times (ARCH-06). Event (the record's own date), receipt (when it reached the case or the result was handed in),
//    entry (when it was recorded here) and review are kept apart; a time not recorded is shown as not recorded, never
//    filled from another kind of time.
//  Every write goes through CaseFileRepository's one savepoint with its case_actions row and a before/after copy.
//  Nothing here calls a model or the network.
//

import Foundation
import os

// MARK: - Records

/// One investigator-placed membership of a record in a frame (v177 case_frame_members).
public nonisolated struct CaseFrameMembership: Identifiable, Sendable, Equatable, Hashable {
    public let id: UUID
    public let caseID: UUID
    public let frameKind: String
    public let frameID: String
    public let memberKind: String
    public let memberID: String
    public let purpose: String?
    public let addedBy: String
    public let addedAt: Date
    public let withdrawnBy: String?
    public let withdrawnAt: Date?
    public let withdrawnReason: String?
    public var isActive: Bool { withdrawnAt == nil }
    public var frame: CaseMapNodeID? { CaseMapRecordKind(rawValue: frameKind).map { CaseMapNodeID(caseID: caseID, kind: $0, recordID: frameID) } }
    public var member: CaseMapNodeID? { CaseMapRecordKind(rawValue: memberKind).map { CaseMapNodeID(caseID: caseID, kind: $0, recordID: memberID) } }
}

/// One action waiting for another (the task engine's professional_task_dependencies, read for one case).
public nonisolated struct CaseActionDependency: Identifiable, Sendable, Equatable, Hashable {
    public static let waitsFor = "waitsFor"
    public let id: UUID
    public let caseID: UUID
    public let taskID: UUID
    public let dependsOnTaskID: UUID
    public let kind: String
    public let createdAt: Date
}

/// What kind of actor a stable actor id stands for.
public nonisolated enum CaseActorKind: String, Codable, Sendable, CaseIterable {
    /// A name typed on this Mac (every name already in the case's history is one). Not an account.
    case localUser
    /// A signed-in account of an identity service (none exists yet: refused until one does).
    case authenticatedUser
    /// A person of the case (a witness, a subject…) — the case-person record it stands for is kept with it.
    case caseParticipant
    /// Someone outside the case who reportedly did the work (an external laboratory, an examiner) — reported, not verified.
    case reportedExternal
    /// A rule or a program of this app.
    case software
    public var label: String {
        switch self {
        case .localUser: return "Name recorded on this Mac (not a signed-in account)"
        case .authenticatedUser: return "Signed-in account"
        case .caseParticipant: return "Person in the case"
        case .reportedExternal: return "Reported external performer (as reported, not verified)"
        case .software: return "Software"
        }
    }
}

/// A stable actor identity of a case (v177 case_actors).
public nonisolated struct CaseActor: Identifiable, Sendable, Equatable, Hashable {
    public let id: UUID
    public let caseID: UUID
    public let kind: CaseActorKind
    public let displayName: String
    /// True for a name carried from free-text history (or typed on this Mac): never presented as an account.
    public let isLegacyName: Bool
    public let isAuthenticated: Bool
    public let identityRef: String?
    public let casePersonID: UUID?
    public let createdAt: Date
    /// "Ada — Name recorded on this Mac (not a signed-in account)".
    public var attribution: String { "\(displayName) — \(kind.label)" }
}

/// The kinds of time a record can carry, kept apart (ARCH-06).
public nonisolated enum CaseTimeKind: String, Sendable, CaseIterable {
    case event, receipt, entry, review
    public var label: String {
        switch self {
        case .event: return "Date of the record itself"
        case .receipt: return "Received"
        case .entry: return "Recorded in the case"
        case .review: return "Reviewed"
        }
    }
}

/// One time statement about a record: a date, the source's own wording, or neither (explicitly not recorded).
public nonisolated struct CaseTimeAssertion: Sendable, Equatable {
    public let kind: CaseTimeKind
    public let date: Date?
    public let text: String?
    public var isRecorded: Bool { date != nil || !(text ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
    /// "Received: 16 March 2026" / "Received: not recorded".
    public var display: String {
        if let text, !text.trimmingCharacters(in: .whitespaces).isEmpty { return "\(kind.label): \(text)" }
        if let date { return "\(kind.label): \(date.formatted(date: .abbreviated, time: .shortened))" }
        return "\(kind.label): not recorded"
    }
}

nonisolated extension CaseReport {
    /// The report's own date, when it reached the case, and when it was entered — never one filled from another.
    public var times: [CaseTimeAssertion] {
        [CaseTimeAssertion(kind: .event, date: reportDate, text: reportDateText),
         CaseTimeAssertion(kind: .receipt, date: receivedAt, text: receivedText),
         CaseTimeAssertion(kind: .entry, date: recordedAt, text: nil)]
    }
}

nonisolated extension CaseActionContract {
    /// When the action was recorded, when its result was handed in, and when it was reviewed.
    public var times: [CaseTimeAssertion] {
        [CaseTimeAssertion(kind: .entry, date: createdAt, text: nil),
         CaseTimeAssertion(kind: .receipt, date: submittedAt, text: nil),
         CaseTimeAssertion(kind: .review, date: reviewedAt, text: nil)]
    }
}

nonisolated extension CaseReportLedger {
    public func frameMembers(of frame: CaseMapNodeID) -> [CaseFrameMembership] {
        frameMembers.filter { $0.isActive && $0.frame == frame }
    }
    public func frames(containing member: CaseMapNodeID) -> [CaseFrameMembership] {
        frameMembers.filter { $0.isActive && $0.member == member }
    }
    public func dependencies(of task: UUID) -> [CaseActionDependency] { dependencies.filter { $0.taskID == task } }
    public func actor(named name: String) -> CaseActor? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return actors.first { $0.displayName == n }
    }
}

nonisolated extension CaseRecordCapture {
    public static func frameMember(_ id: UUID) -> CaseRecordCapture { CaseRecordCapture(kind: "frameMember", table: "case_frame_members", recordID: id) }
    public static func actionDependency(_ id: UUID) -> CaseRecordCapture { CaseRecordCapture(kind: "actionDependency", table: "professional_task_dependencies", recordID: id) }
    public static func actor(_ id: UUID) -> CaseRecordCapture { CaseRecordCapture(kind: "actor", table: "case_actors", recordID: id) }
}

public nonisolated enum CaseContractError: Error, Equatable, LocalizedError {
    case notPlaceable(String)
    case alreadyPlaced
    case sameRecord
    case dependencyCycle
    case alreadyDepends
    case notFound(String)
    case alreadyWithdrawn
    case identityServiceUnavailable
    /// S3 (GRAPH-05): the branch would contain itself through other placements.
    case containmentCycle

    public var errorDescription: String? {
        switch self {
        case .notPlaceable(let what): return "A \(what) can't be placed in a branch; place the record it belongs to instead."
        case .alreadyPlaced: return "That item is already in this branch."
        case .sameRecord: return "An item can't be placed inside its own branch."
        case .dependencyCycle: return "That would make the action wait for itself through other actions. Choose another action."
        case .alreadyDepends: return "The action already waits for that one."
        case .notFound(let what): return "The \(what) was not found in this case."
        case .alreadyWithdrawn: return "It is already withdrawn."
        case .containmentCycle: return "That branch is already inside this item (through other placements), so placing it here would make a branch contain itself. Link the two items instead."
        case .identityServiceUnavailable: return "Signed-in accounts need the team service, which this version does not have. Record the name instead; it is shown as a name, not an account."
        }
    }
}

// MARK: - Persistence

extension CaseFileRepository {

    /// The v177 records of the case, read into the ledger the map and the work flows share.
    func readContracts(caseID: UUID, into ledger: inout CaseReportLedger) async throws {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        let c: [SQLValue] = [.uuid(caseID)]
        ledger.frameMembers = try await database.query("""
            SELECT id, case_id, frame_kind, frame_id, member_kind, member_id, purpose, added_by, added_at, withdrawn_by, withdrawn_at, withdrawn_reason
            FROM case_frame_members WHERE case_id = ? ORDER BY added_at ASC, rowid ASC;
            """, c).compactMap { r in
            guard let id = r.uuid(0), let cid = r.uuid(1), let fk = r.string(2), let fid = r.string(3), let mk = r.string(4), let mid = r.string(5),
                  let by = r.string(7), let at = r.date(8) else { return nil }
            return CaseFrameMembership(id: id, caseID: cid, frameKind: fk, frameID: fid.lowercased(), memberKind: mk, memberID: mid.lowercased(),
                                       purpose: r.string(6), addedBy: by, addedAt: at, withdrawnBy: r.string(9), withdrawnAt: r.date(10), withdrawnReason: r.string(11))
        }
        // Both ends are tasks of this case (an index lookup per end, not a scan of the workspace's tasks).
        ledger.dependencies = try await database.query("""
            SELECT d.id, d.task_id, d.depends_on_task_id, d.dependency_kind, d.created_at FROM professional_task_dependencies d
            WHERE EXISTS (SELECT 1 FROM case_task_links l WHERE l.case_id = ? AND l.task_id IN (d.task_id, lower(d.task_id), upper(d.task_id)))
              AND EXISTS (SELECT 1 FROM case_task_links l WHERE l.case_id = ? AND l.task_id IN (d.depends_on_task_id, lower(d.depends_on_task_id), upper(d.depends_on_task_id)))
            ORDER BY d.created_at ASC, d.rowid ASC;
            """, c + c).compactMap { r in
            guard let id = r.uuid(0), let t = r.uuid(1), let d = r.uuid(2), let kind = r.string(3), let at = r.date(4) else { return nil }
            return CaseActionDependency(id: id, caseID: caseID, taskID: t, dependsOnTaskID: d, kind: kind, createdAt: at)
        }
        ledger.actors = try await database.query("""
            SELECT id, case_id, actor_kind, display_name, origin, authentication, identity_ref, case_person_id, created_at
            FROM case_actors WHERE case_id = ? ORDER BY created_at ASC, rowid ASC;
            """, c).compactMap { r in
            guard let id = r.uuid(0), let cid = r.uuid(1), let kind = r.string(2).flatMap(CaseActorKind.init(rawValue:)), let name = r.string(3),
                  let origin = r.string(4), let at = r.date(8) else { return nil }
            return CaseActor(id: id, caseID: cid, kind: kind, displayName: name, isLegacyName: origin == "legacyName",
                             isAuthenticated: r.string(5) == "authenticated", identityRef: r.string(6), casePersonID: r.uuid(7), createdAt: at)
        }
        ledger.identityDecisions = try await readIdentityDecisions(caseID: caseID)
        ledger.personRoles = try await personRoles(caseID: caseID)
    }

    // MARK: Frame membership

    /// Place a record of the case in the frame anchored on another record of the case. Both ends are checked inside the
    /// write (target existence and case membership); the case must be open; the same record is placed once per frame.
    @discardableResult
    public func placeInFrame(caseID: UUID, frame: CaseMapNodeID, member: CaseMapNodeID, purpose: String?, actor: String,
                             at date: Date = Date()) async throws -> UUID {
        let who = try Self.clean(actor, "Actor")
        guard frame != member else { throw CaseContractError.sameRecord }
        for end in [frame, member] {
            guard end.caseID == caseID else { throw CaseWorkError.notInCase("item") }
            guard CaseMapRecordKind.linkable.contains(end.kind) else { throw CaseContractError.notPlaceable(end.kind.rawValue) }
        }
        let id = UUID()
        try await write("cf_fm", caseID: caseID, actor: who, action: "placedInFrame", detail: "\(member.key) in \(frame.key)", at: date,
                        capture: .frameMember(id)) { db in
            for end in [frame, member] {
                guard try CaseMapRepository.belongs(db, end, caseID: caseID) else { throw CaseWorkError.notInCase(end.kind.rawValue) }
            }
            guard try db.query("""
                SELECT 1 FROM case_frame_members WHERE case_id = ? AND frame_kind = ? AND frame_id = ? AND member_kind = ? AND member_id = ? AND withdrawn_at IS NULL;
                """, [.uuid(caseID), .text(frame.kind.rawValue), .text(frame.recordID), .text(member.kind.rawValue), .text(member.recordID)]).isEmpty else {
                throw CaseContractError.alreadyPlaced
            }
            // GRAPH-05 — containment may not cycle (investigative links may; they are not containment).
            let placed = try db.query("SELECT frame_kind, frame_id, member_kind, member_id FROM case_frame_members WHERE case_id = ? AND withdrawn_at IS NULL;",
                                      [.uuid(caseID)]).compactMap { r -> (frame: CaseMapNodeID, member: CaseMapNodeID)? in
                guard let fk = r.string(0).flatMap(CaseMapRecordKind.init(rawValue:)), let fid = r.string(1),
                      let mk = r.string(2).flatMap(CaseMapRecordKind.init(rawValue:)), let mid = r.string(3) else { return nil }
                return (CaseMapNodeID(caseID: caseID, kind: fk, recordID: fid), CaseMapNodeID(caseID: caseID, kind: mk, recordID: mid))
            }
            if CaseMapContainment.wouldCycle(frame: frame, member: member, placements: placed) { throw CaseContractError.containmentCycle }
            try db.exec("""
                INSERT INTO case_frame_members (id, case_id, frame_kind, frame_id, member_kind, member_id, purpose, added_by, added_at)
                VALUES (?,?,?,?,?,?,?,?,?);
                """, [.uuid(id), .uuid(caseID), .text(frame.kind.rawValue), .text(frame.recordID), .text(member.kind.rawValue), .text(member.recordID),
                      .optionalText(Self.blankToNil(purpose)), .text(who), .date(date)])
        }
        return id
    }

    /// Take a record out of a branch, with the reason. The membership stays in the ledger, marked withdrawn; the record
    /// itself and its other branches are untouched.
    public func withdrawFromFrame(caseID: UUID, membershipID: UUID, reason: String, actor: String, at date: Date = Date()) async throws {
        let why = try Self.clean(reason, "The reason")
        let who = try Self.clean(actor, "Actor")
        try await write("cf_fmw", caseID: caseID, actor: who, action: "removedFromFrame", detail: why, at: date, capture: .frameMember(membershipID)) { db in
            guard let r = try db.query("SELECT withdrawn_at FROM case_frame_members WHERE id = ? AND case_id = ?;", [.uuid(membershipID), .uuid(caseID)]).first else {
                throw CaseContractError.notFound("placement")
            }
            guard r.isNull(0) else { throw CaseContractError.alreadyWithdrawn }
            try db.exec("UPDATE case_frame_members SET withdrawn_by = ?, withdrawn_at = ?, withdrawn_reason = ? WHERE id = ?;",
                        [.text(who), .date(date), .text(why), .uuid(membershipID)])
        }
    }

    // MARK: Action dependencies

    /// Record that `taskID` waits for `dependsOn`. Both are tasks of this case; a dependency closing a cycle is refused.
    @discardableResult
    public func addDependency(caseID: UUID, taskID: UUID, dependsOn: UUID, reason: String?, actor: String, at date: Date = Date()) async throws -> UUID {
        let who = try Self.clean(actor, "Actor")
        guard taskID != dependsOn else { throw CaseContractError.dependencyCycle }
        let id = UUID()
        try await write("cf_dep", caseID: caseID, actor: who, action: "dependencyAdded", detail: Self.blankToNil(reason), at: date,
                        capture: .actionDependency(id)) { db in
            guard try Self.taskInCase(db, taskID, caseID: caseID) else { throw CaseWorkError.notInCase("action") }
            guard try Self.taskInCase(db, dependsOn, caseID: caseID) else { throw CaseWorkError.notInCase("action it waits for") }
            guard try db.query("""
                SELECT 1 FROM professional_task_dependencies WHERE upper(task_id) = ? AND upper(depends_on_task_id) = ? AND dependency_kind = ?;
                """, [.text(taskID.uuidString), .text(dependsOn.uuidString), .text(CaseActionDependency.waitsFor)]).isEmpty else {
                throw CaseContractError.alreadyDepends
            }
            if try Self.dependencyWouldCycle(db, taskID: taskID, dependsOn: dependsOn) { throw CaseContractError.dependencyCycle }
            try db.exec("""
                INSERT INTO professional_task_dependencies (id, task_id, depends_on_task_id, dependency_kind, created_at) VALUES (?,?,?,?,?);
                """, [.uuid(id), .uuid(taskID), .uuid(dependsOn), .text(CaseActionDependency.waitsFor), .date(date)])
        }
        return id
    }

    /// Remove a dependency with the reason. The row goes from the task engine; its before copy, the reason and who
    /// removed it stay in the case's revisions and action log.
    public func removeDependency(caseID: UUID, dependencyID: UUID, reason: String, actor: String, at date: Date = Date()) async throws {
        let why = try Self.clean(reason, "The reason")
        let who = try Self.clean(actor, "Actor")
        try await write("cf_depw", caseID: caseID, actor: who, action: "dependencyRemoved", detail: why, at: date, capture: .actionDependency(dependencyID)) { db in
            guard let t = try db.query("SELECT task_id FROM professional_task_dependencies WHERE id IN (?, ?);",
                                       [.text(dependencyID.uuidString), .text(dependencyID.uuidString.lowercased())]).first?.uuid(0),
                  try Self.taskInCase(db, t, caseID: caseID) else {
                throw CaseContractError.notFound("dependency")
            }
            try db.exec("DELETE FROM professional_task_dependencies WHERE id IN (?, ?);", [.text(dependencyID.uuidString), .text(dependencyID.uuidString.lowercased())])
        }
    }

    /// Would `taskID` → `dependsOn` close a cycle? Walks what `dependsOn` already waits for (each action once).
    static func dependencyWouldCycle(_ db: isolated Database, taskID: UUID, dependsOn: UUID) throws -> Bool {
        var seen = Set<UUID>()
        var queue: [UUID] = [dependsOn]
        while let next = queue.popLast() {
            if next == taskID { return true }
            guard seen.insert(next).inserted else { continue }
            queue += try db.query("SELECT depends_on_task_id FROM professional_task_dependencies WHERE task_id IN (?, ?);",
                                  [.text(next.uuidString), .text(next.uuidString.lowercased())]).compactMap { $0.uuid(0) }
        }
        return false
    }

    // MARK: Actors

    /// Record an actor that is not a name typed on this Mac: a person of the case, a reported external performer, or
    /// software. A signed-in account is refused — there is no identity service to vouch for it.
    @discardableResult
    public func recordActor(caseID: UUID, kind: CaseActorKind, displayName: String, casePersonID: UUID? = nil, actor: String,
                            at date: Date = Date()) async throws -> UUID {
        let name = try Self.clean(displayName, "The name")
        let who = try Self.clean(actor, "Actor")
        guard kind != .authenticatedUser else { throw CaseContractError.identityServiceUnavailable }
        let id = UUID()
        try await write("cf_actor", caseID: caseID, actor: who, action: "actorRecorded", detail: "\(kind.rawValue): \(name)", at: date, capture: .actor(id)) { db in
            if let p = casePersonID {
                guard try !db.query("SELECT 1 FROM case_people WHERE id = ? AND case_id = ? AND removed_at IS NULL;", [.uuid(p), .uuid(caseID)]).isEmpty else {
                    throw CaseWorkError.notInCase("person")
                }
            }
            try db.exec("""
                INSERT INTO case_actors (id, case_id, actor_kind, display_name, origin, authentication, case_person_id, created_at)
                VALUES (?,?,?,?, 'recorded', 'notAuthenticated', ?, ?);
                """, [.uuid(id), .uuid(caseID), .text(kind.rawValue), .text(name), casePersonID.map { .uuid($0) } ?? .null, .date(date)])
        }
        return id
    }

    /// Inside every case write: the acting name gets its stable actor id the first time it acts in the case (a legacy
    /// name — never an account). Idempotent.
    static func registerActingName(_ db: isolated Database, caseID: UUID, name: String, at date: Date) throws {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        try db.exec("""
            INSERT OR IGNORE INTO case_actors (id, case_id, actor_kind, display_name, origin, legacy_name, authentication, created_at)
            VALUES (?,?, 'localUser', ?, 'legacyName', ?, 'notAuthenticated', ?);
            """, [.uuid(UUID()), .uuid(caseID), .text(n), .text(n), .date(date)])
    }
}
