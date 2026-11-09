//
//  SmartMapS9Tests.swift
//  KalsmritikoshTests
//
//  Smart-map S9 (docs/IME_Full_Smart_Map_Implementation_TODO_2026-11-08.md: SEC and the local parts of ACCESS and TEAM of
//  milestone M3; schema v185). Throwaway ledgers; expected results written by hand. Nothing here calls a model or the network.
//

import Foundation
import Testing
@testable import Kalsmritikosh

private func s9Count(_ db: Database, _ sql: String, _ binds: [SQLValue] = []) async throws -> Int {
    Int(try await db.query(sql, binds).first?.int(0) ?? -1)
}

private func s9Denied(_ e: Error) -> Bool {
    if case CaseAccessError.denied = e { return true }
    return false
}

/// A team case: Ada (this Mac's owner) gives Ben investigator, Rita reviewer, Vera viewer, Cal contributor.
@MainActor
private struct S9Team {
    let f: CaseFileTests.Fixture
    var file: CaseFileRepository { f.file }
    var caseID: UUID { f.caseID }
    var grants: [String: UUID] = [:]
    static func make() async throws -> S9Team {
        let f = try await CaseFileTests.fixture(title: "Supplier payments")
        var t = S9Team(f: f)
        for (n, r) in [("Ben", CaseAccessRole.investigator), ("Rita", .reviewer), ("Vera", .viewer), ("Cal", .contributor)] {
            t.grants[n] = try await f.file.grantAccess(caseID: f.caseID, to: n, role: r, reason: "Assigned by the lead", actor: "Ada")
        }
        return t
    }
}

@Suite("Smart map S9 — security, local access and team (M3)", .serialized)
@MainActor
struct SmartMapS9Tests {

    // MARK: ACCESS-02 / TEAM-12 solo stays simple

    @Test("A solo case needs no setup: this Mac's owner holds every role and any recorded name may act")
    func soloCase() async throws {
        let f = try await CaseFileTests.fixture()
        _ = try await f.file.addAllegation(caseID: f.caseID, text: "Was the supplier paid twice?", actor: "Ada")
        _ = try await f.file.addAllegation(caseID: f.caseID, text: "Who approved it?", actor: "Ben")
        #expect(try await !f.file.isTeamCase(caseID: f.caseID))
        let d = try await f.file.accessDecision(caseID: f.caseID, operation: .administer)
        #expect(d.allowed && d.soloCase && Set(d.roles) == Set(CaseAccessRole.allCases))
        #expect(try await s9Count(f.db, "SELECT COUNT(*) FROM case_access_grants;") == 0, "solo mode records nothing")
        // A named person acting in a solo case is not this Mac's owner: refused, with the remedy.
        await #expect(throws: CaseAccessError.self) {
            try await CaseAccessContext.$principal.withValue(.local("Zed")) {
                _ = try await f.file.addAllegation(caseID: f.caseID, text: "x", actor: "Zed")
            }
        }
    }

    // MARK: ACCESS-02 / 03 / 09 roles enforced in the services

    @Test("Roles are enforced inside the services: investigators work, reviewers decide, viewers read, contributors return material")
    func rolesEnforced() async throws {
        let t = try await S9Team.make()
        #expect(try await t.file.isTeamCase(caseID: t.caseID))
        // The first grant made Ada the owner (this Mac's owner).
        let history = try await t.file.accessGrants(caseID: t.caseID)
        #expect(history.first?.role == .owner && history.first?.actorName == "Ada")
        #expect(history.count == 5)
        let q = try await t.file.addAllegation(caseID: t.caseID, text: "Was the supplier paid twice?", actor: "Ben")
        // A viewer or a reviewer cannot change the work.
        for who in ["Vera", "Rita"] {
            do { _ = try await t.file.addAllegation(caseID: t.caseID, text: "x", actor: who); Issue.record("\(who) changed the work") } catch {
                #expect(s9Denied(error), "\(error)")
                #expect(error.localizedDescription.contains(who))
            }
        }
        // The reviewer decides; the investigator cannot.
        try await t.file.decide(allegationID: q, caseID: t.caseID, disposition: .inconclusive, rationale: "Two entries, one witness", actor: "Rita")
        await #expect(throws: CaseAccessError.self) {
            try await t.file.decide(allegationID: q, caseID: t.caseID, disposition: .unsubstantiated, rationale: "x", actor: "Ben")
        }
        // An unknown name is refused in a team case.
        await #expect(throws: CaseAccessError.self) { _ = try await t.file.addAllegation(caseID: t.caseID, text: "x", actor: "Zed") }
        // ACCESS-09 — only an owner manages roles; nobody elevates themselves by editing their own work.
        await #expect(throws: CaseAccessError.self) {
            _ = try await t.file.grantAccess(caseID: t.caseID, to: "Ben", role: .owner, reason: "I need it", actor: "Ben")
        }
        await #expect(throws: CaseAccessError.self) {
            _ = try await t.file.grantAccess(caseID: t.caseID, to: "Vera", role: .investigator, reason: "help", actor: "Ben")
        }
        await #expect(throws: CaseAccessError.self) {
            try await CaseAccessContext.$principal.withValue(.local("Ben")) {
                _ = try await t.file.grantAccess(caseID: t.caseID, to: "Ben", role: .reviewer, reason: "self", actor: "Ben")
            }
        }
        // Closing the case is administration: an investigator cannot.
        let viewerDecision = try await t.file.accessDecision(caseID: t.caseID, principal: .local("Vera"), operation: .work)
        #expect(!viewerDecision.allowed && viewerDecision.remedy?.contains("Investigator") == true)
        #expect(try await t.file.accessDecision(caseID: t.caseID, principal: .local("Ben"), operation: .administer).allowed == false)
        #expect(try await t.file.accessDecision(caseID: t.caseID, principal: .local("Ada"), operation: .administer).allowed)
        // Several roles per person: Vera also becomes a reviewer and may now decide.
        _ = try await t.file.grantAccess(caseID: t.caseID, to: "Vera", role: .reviewer, reason: "Second reviewer", actor: "Ada")
        let vera = try await t.file.accessDecision(caseID: t.caseID, principal: .local("Vera"), operation: .review)
        #expect(vera.allowed && vera.roles == [.reviewer, .viewer])
        // A contributor returns material but cannot open the case.
        #expect(try await t.file.accessDecision(caseID: t.caseID, principal: .local("Cal"), operation: .contribute).allowed)
        #expect(try await !t.file.accessDecision(caseID: t.caseID, principal: .local("Cal"), operation: .read).allowed)
        // Approving the case's findings is a review decision: an investigator or a contributor cannot record it
        // (Vera is a reviewer by now).
        let approvals = InvestigationFindingsApprovalRepository(database: t.f.db)
        for who in ["Ben", "Cal"] {
            await #expect(throws: CaseAccessError.self) {
                _ = try await approvals.approve(caseID: t.caseID, workProductRunID: UUID(), receiptSeal: "seal", scopeFingerprint: CaseScopeFingerprint(value: "fp"),
                                                rationale: "Looks right", actor: who, at: Date())
            }
        }
        #expect(try await approvals.approvals(caseID: t.caseID).isEmpty)
        // An authenticated identity cannot be trusted without the identity service (ARCH-08).
        let bound = try await t.file.accessDecision(caseID: t.caseID, principal: .bound(provider: "CloudKit", subject: "_abc"), operation: .read)
        #expect(!bound.allowed && bound.remedy?.contains("ARCH-08") == true)
    }

    @Test("Reads are checked in the services: a contributor sees no case content, list entry, title or count; a viewer reads")
    func readsAndDerivedViews() async throws {
        let t = try await S9Team.make()
        _ = try await t.file.addAllegation(caseID: t.caseID, text: "Was the supplier paid twice?", actor: "Ada")
        try await CaseAccessContext.$principal.withValue(.local("Cal")) {
            do { _ = try await t.file.allegations(caseID: t.caseID); Issue.record("a contributor read the questions") } catch { #expect(s9Denied(error)) }
            do { _ = try await t.f.svc.caseTasks(caseID: t.caseID); Issue.record("a contributor read the tasks") } catch { #expect(s9Denied(error)) }
            do { _ = try await t.f.cases.fetch(caseID: t.caseID); Issue.record("a contributor read the header") } catch { #expect(s9Denied(error)) }
            // ACCESS-06 — the case list leaves the case out entirely (no title, no counts).
            let listed = try await t.f.svc.caseload()
            #expect(listed.isEmpty)
        }
        try await CaseAccessContext.$principal.withValue(.local("Vera")) {
            let read = try await t.file.allegations(caseID: t.caseID)
            let listed = try await t.f.svc.caseload()
            #expect(read.count == 1)
            #expect(listed.map(\.caseID) == [t.caseID])
        }
        // A role never reaches another case: Ben has none in a second case of the same workspace.
        let other = try await t.f.cases.createCase(workspaceID: t.f.workspaceID, title: "Other matter", actor: "Ada", at: Date())
        _ = try await t.file.grantAccess(caseID: other.id, to: "Rita", role: .viewer, reason: "Only Rita", actor: "Ada")
        try await CaseAccessContext.$principal.withValue(.local("Ben")) {
            await #expect(throws: CaseAccessError.self) { _ = try await t.file.allegations(caseID: other.id) }
            let listed = try await t.f.svc.caseload()
            #expect(listed.map(\.caseID) == [t.caseID])
        }
    }

    @Test("A change cannot be recorded in another person's name (forged actor)")
    func forgedActor() async throws {
        let t = try await S9Team.make()
        do {
            try await CaseAccessContext.$principal.withValue(.local("Vera")) {
                _ = try await t.file.addAllegation(caseID: t.caseID, text: "x", actor: "Ada")
            }
            Issue.record("a viewer recorded a change as the owner")
        } catch let e as CaseAccessError {
            #expect(e == .forgedActor(recorded: "Ada", acting: "Vera"))
        }
        #expect(try await s9Count(t.f.db, "SELECT COUNT(*) FROM case_allegations WHERE case_id = ?;", [.uuid(t.caseID)]) == 0)
    }

    // MARK: TEAM-09 / ACCESS-07 (local) / ACCESS-11 revocation, departure, history

    @Test("Removing a role: open work needs a taker, the last owner stays, the person is refused at once, history keeps who and why")
    func revocationAndDeparture() async throws {
        let t = try await S9Team.make()
        let task = UUID()
        try await t.f.db.exec("INSERT INTO case_work_assignments (id, case_id, work_kind, work_id, assignee, assigned_by, assigned_at) VALUES (?,?,?,?,?,?,?);",
                              [.uuid(UUID()), .uuid(t.caseID), .text("task"), .text(task.uuidString.lowercased()), .text("Ben"), .text("Ada"), .date(Date())])
        let ben = try #require(t.grants["Ben"])
        do { try await t.file.revokeAccess(caseID: t.caseID, grantID: ben, reason: "Left the unit", actor: "Ada"); Issue.record("orphaned work") } catch let e as CaseAccessError {
            if case .pendingWorkNeedsTransfer(let items) = e { #expect(items.count == 1) } else { Issue.record("\(e)") }
        }
        await #expect(throws: CaseAccessError.transferTargetCannotWork("Vera")) {
            try await t.file.revokeAccess(caseID: t.caseID, grantID: ben, reason: "Left the unit", transferTo: "Vera", actor: "Ada")
        }
        // Nobody but an owner removes roles.
        await #expect(throws: CaseAccessError.self) {
            try await t.file.revokeAccess(caseID: t.caseID, grantID: ben, reason: "x", transferTo: "Ada", actor: "Rita")
        }
        try await t.file.revokeAccess(caseID: t.caseID, grantID: ben, reason: "Left the unit", transferTo: "Ada", actor: "Ada")
        #expect(try await s9Count(t.f.db, "SELECT COUNT(*) FROM case_work_assignments WHERE case_id = ? AND assignee = 'Ada' AND ended_at IS NULL;", [.uuid(t.caseID)]) == 1)
        #expect(try await s9Count(t.f.db, "SELECT COUNT(*) FROM case_work_assignments WHERE case_id = ? AND assignee = 'Ben' AND end_reason = 'transferred';", [.uuid(t.caseID)]) == 1)
        // Refused at once, for changes and reads.
        await #expect(throws: CaseAccessError.self) { _ = try await t.file.addAllegation(caseID: t.caseID, text: "late", actor: "Ben") }
        try await CaseAccessContext.$principal.withValue(.local("Ben")) {
            await #expect(throws: CaseAccessError.self) { _ = try await t.file.allegations(caseID: t.caseID) }
        }
        // The last owner cannot be removed.
        let owner = try #require(try await t.file.accessGrants(caseID: t.caseID).first { $0.role == .owner }?.id)
        await #expect(throws: CaseAccessError.lastOwner) { try await t.file.revokeAccess(caseID: t.caseID, grantID: owner, reason: "x", actor: "Ada") }
        // A grant is never edited; the history says who removed what, when and why.
        await #expect(throws: (any Error).self) { try await t.f.db.exec("UPDATE case_access_grants SET role = 'owner' WHERE id = ?;", [.uuid(ben)]) }
        let lines = try await t.file.accessHistory(caseID: t.caseID)
        #expect(lines.contains { $0.hasPrefix("Ben: Investigator") && $0.contains("removed by Ada") && $0.contains("Left the unit") && $0.contains("open work to Ada") })
        #expect(try await s9Count(t.f.db, "SELECT COUNT(*) FROM case_actions WHERE case_id = ? AND action IN ('accessGranted','accessRevoked');", [.uuid(t.caseID)]) == 5)
        // Roles never touch the case's people (ACCESS-04).
        #expect(try await s9Count(t.f.db, "SELECT COUNT(*) FROM case_people WHERE case_id = ?;", [.uuid(t.caseID)]) == 0)
    }

    // MARK: SEC-12 / ACCESS-08 races and queued work

    @Test("A role removed after an export was prepared refuses the release; a ticket taken before a revocation or erasure is stale")
    func revocationRaces() async throws {
        let t = try await S9Team.make()
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("s9-out-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let outputs = CaseOutputService(database: t.f.db, caseFiles: t.f.svc, custody: { _ in [] }, pendingDirectory: temp.appendingPathComponent("pending"))
        let pkg = try await outputs.prepareText(caseID: t.caseID, kind: .achReport, route: .file, actor: "Ben", citations: [], text: "Reconciliation notes")
        // A viewer cannot even prepare one.
        await #expect(throws: CaseAccessError.self) {
            _ = try await outputs.prepareText(caseID: t.caseID, kind: .achReport, route: .file, actor: "Vera", citations: [], text: "x")
        }
        try await t.file.revokeAccess(caseID: t.caseID, grantID: try #require(t.grants["Ben"]), reason: "Removed during export", actor: "Ada")
        let url = temp.appendingPathComponent("out.txt")
        let receipt = await outputs.write(pkg, to: url)
        #expect(receipt.status == .refused)
        #expect(!FileManager.default.fileExists(atPath: url.path), "nothing left")
        // Queued work (ACCESS-08, local part): a ticket taken by Rita is rechecked before its effect.
        let cid = t.caseID
        let ticket = try await t.f.db.withSavepoint("t") { db in try CaseAccessTicket.take(db, caseID: cid, actor: "Rita", .review) }
        try await t.f.db.withSavepoint("ok") { db in try ticket.revalidate(db) }   // nothing changed: still valid
        try await t.file.revokeAccess(caseID: t.caseID, grantID: try #require(t.grants["Rita"]), reason: "Conflict of interest", actor: "Ada")
        do { try await t.f.db.withSavepoint("v") { db in try ticket.revalidate(db) }; Issue.record("stale ticket used") } catch let e as CaseAccessError {
            if case .stale(let why) = e { #expect(why.contains("role")) } else { Issue.record("\(e)") }
        }
        // Erased meanwhile: an owner's ticket is stale too.
        let adaTicket = try await t.f.db.withSavepoint("a") { db in try CaseAccessTicket.take(db, caseID: cid, actor: "Ada", .export) }
        let report = try await CaseEraser(database: t.f.db).erase(caseID: t.caseID, sourceVersionIDs: [], eraseExclusiveSources: false, reason: "Closed matter",
                                                                  legalBasis: nil, actor: "Ada")
        #expect(report.refused == nil, "\(report.refused ?? "")")
        await #expect(throws: CaseAccessError.self) { try await t.f.db.withSavepoint("e") { db in try adaTicket.revalidate(db) } }
        // Erasure removed the case's grants (case data) but keeps the content-free erasure generation.
        #expect(try await s9Count(t.f.db, "SELECT COUNT(*) FROM case_access_grants WHERE case_id = ?;", [.uuid(t.caseID)]) == 0)
        #expect(try await s9Count(t.f.db, "SELECT COUNT(*) FROM erasure_generations WHERE kind = 'case' AND state = 'done' AND scope_hash = ?;",
                                  [.text(ErasureGenerations.scopeHash(t.caseID))]) == 1)
    }

    // MARK: SEC-08 no resurrection

    @Test("A late writer cannot re-create an erased case; a replica's batch cannot re-create an erased synchronised row")
    func noResurrection() async throws {
        let f = try await CaseFileTests.fixture()
        _ = try await f.file.addAllegation(caseID: f.caseID, text: "Before erasure", actor: "Ada")
        try await f.db.exec("CREATE TEMP TABLE s9_keep AS SELECT * FROM investigation_cases WHERE id = ?;", [.uuid(f.caseID)])
        let report = try await CaseEraser(database: f.db).erase(caseID: f.caseID, sourceVersionIDs: [], eraseExclusiveSources: false, reason: "Request",
                                                                legalBasis: nil, actor: "Ada")
        #expect(report.refused == nil)
        // The case row comes back (an old replica, a restore of one table): the erasure generation still refuses writes.
        try await f.db.exec("INSERT INTO investigation_cases SELECT * FROM s9_keep;")
        do { _ = try await f.file.addAllegation(caseID: f.caseID, text: "Resurrected", actor: "Ada"); Issue.record("an erased case took a change") } catch let e as CaseAccessError {
            if case .stale = e {} else { Issue.record("\(e)") }
        }
        // Synchronised user-layer rows removed during an erasure leave a tombstone (identifiers only).
        let erased = UUID().uuidString, kept = UUID().uuidString
        let now = Date().timeIntervalSince1970
        for id in [erased, kept] {
            try await f.db.exec("INSERT INTO pinned_questions (id, question, created_at) VALUES (?,?,?);", [.text(id), .text("Who signed off?"), .real(now)])
        }
        let erasure = UUID()
        try await f.db.withSavepoint("s9_er") { db in
            try ErasureGenerations.begin(db, kind: "person", scopeHash: ErasureGenerations.scopeHash(UUID()), erasureID: erasure, at: Date())
            try db.exec("DELETE FROM pinned_questions WHERE id = ?;", [.text(erased)])
            try ErasureGenerations.finish(db, erasureID: erasure)
        }
        // An ordinary delete outside an erasure leaves no tombstone.
        try await f.db.exec("DELETE FROM pinned_questions WHERE id = ?;", [.text(kept)])
        #expect(try await s9Count(f.db, "SELECT COUNT(*) FROM erasure_tombstones WHERE tbl = 'pinned_questions';") == 1)
        let tomb = try await f.db.query("SELECT row_key FROM erasure_tombstones WHERE tbl = 'pinned_questions';", []).first?.string(0)
        #expect(tomb == erased, "only the identifier is kept")
        func op(_ id: String) -> SyncOp {
            SyncOp(table: "pinned_questions", key: id, fields: ["id": .text(id), "question": .text("Who signed off?"), "created_at": .real(now), "retired_at": .null],
                   lamport: 9, device: "phone")
        }
        let ops = [op(erased), op(kept)]
        let outcomes = try await f.db.withSavepoint("s9_sync") { db in try ops.map { try SyncEngine.applyOp($0, db) } }
        #expect(outcomes[0] == .ignored)
        #expect(outcomes[1] == .applied(conflicts: 0), "a row that was never erased is restored normally")
        #expect(try await s9Count(f.db, "SELECT COUNT(*) FROM pinned_questions WHERE id = ?;", [.text(erased)]) == 0)
        // Ready for a sync service: the generations not yet passed on, with their tombstone counts.
        let pending = try await ErasureGenerations.pendingPropagation(f.db)
        #expect(pending.count == 2 && pending.last?.tombstones == 1 && pending.allSatisfy { $0.scopeHash.count == 64 })
        // Tombstones are kept and never edited (only a full erase removes them).
        await #expect(throws: (any Error).self) { try await f.db.exec("DELETE FROM erasure_tombstones;") }
    }

    // MARK: Mutation and read coverage (enumerated from the source)

    static let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    /// Entry points the enumeration finds that are intentionally not guarded themselves, with the reason.
    static let exempt: [String: String] = [
        "CaseAccessModel.accessDecision": "explains a decision (roles and remedy) and returns no case content, so a refused person can be told why",
        "CaseActionWork.bulkActions": "delegates to one checked entry point per action and reports each refusal",
        "CaseActionWork.soloBinding": "a read (its actor names whose solo roles to show); guarded by requireRead",
        "CaseChangeFeed.load": "non-throwing: the read check runs inside and a refusal is the load's failed state",
        "CasePeopleModel.declareCapability": "an investigator's own declared capabilities: not case data (kept across cases)",
        "CasePeopleModel.withdrawCapability": "an investigator's own declared capabilities: not case data",
        "CasePeopleModel.declareUnavailable": "an investigator's own availability: not case data",
        "CasePeopleModel.removeInvestigatorProfile": "an investigator's own profile: not case data",
        "InvestigationCaseRepository.createCase": "creates a new (solo) case: there is no case to check yet",
    ]

    struct EntryPoint { let file: String; let name: String; let line: Int; let mutates: Bool; let covered: Bool; let asyncThrows: Bool; let touchesDB: Bool }

    static func entryPoints() throws -> [EntryPoint] {
        let caseDir = repoRoot.appendingPathComponent("Kalsmritikosh/Investigate/CaseFile")
        var urls = try FileManager.default.contentsOfDirectory(at: caseDir, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        urls.append(repoRoot.appendingPathComponent("Kalsmritikosh/Personas/Investigator/InvestigationCaseRepository.swift"))
        let funcRE = try NSRegularExpression(pattern: #"(?m)^[ \t]*((?:@\w+(?:\([^)]*\))?\s+)*)((?:\w+\s+)*)func (\w+)\s*(?:<[^>]*>)?\("#)
        let mutRE = try NSRegularExpression(pattern: #"\bwrite\("|\.exec\(|\bINSERT\b|\bUPDATE\b|DELETE FROM"#)
        let mcovRE = try NSRegularExpression(pattern: #"\bwrite\("|CaseAccessPolicy\.require\(|CaseAccessPolicy\.requireChange\(|requireExport\(|CaseAccessTicket\.take\("#)
        let rcovRE = try NSRegularExpression(pattern: #"CaseAccessPolicy\.requireRead\(|CaseAccessPolicy\.mayRead\("#)
        func has(_ re: NSRegularExpression, _ s: String) -> Bool { re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }
        var out: [EntryPoint] = []
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let text = try String(contentsOf: url, encoding: .utf8)
            let chars = Array(text.utf16)
            let ns = text as NSString
            for m in funcRE.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let mods = ns.substring(with: m.range(at: 2))
                if mods.contains("private") || mods.contains("static") { continue }
                // The parameter list, then the body.
                var p = m.range.location + m.range.length, depth = 1
                while depth > 0, p < chars.count { if chars[p] == 40 { depth += 1 } else if chars[p] == 41 { depth -= 1 }; p += 1 }
                var b = p
                while b < chars.count, chars[b] != 123 { b += 1 }
                guard b < chars.count else { continue }
                var q = b, d = 0
                repeat { if chars[q] == 123 { d += 1 } else if chars[q] == 125 { d -= 1 }; q += 1 } while d > 0 && q < chars.count
                let sig = ns.substring(with: NSRange(location: m.range.location, length: b - m.range.location))
                let body = ns.substring(with: NSRange(location: b, length: q - b))
                let hasCase = sig.range(of: #"\bcaseID: UUID\b"#, options: .regularExpression) != nil
                let hasActor = sig.range(of: #"\bactor: String\b"#, options: .regularExpression) != nil
                let mutates = has(mutRE, body) || (hasActor && hasCase)
                guard hasCase || mutates else { continue }
                let asyncThrows = sig.contains("async") && sig.contains("throws")
                let covered = mutates ? has(mcovRE, body) : (has(rcovRE, body) || has(mcovRE, body))
                let line = ns.substring(to: m.range.location).components(separatedBy: "\n").count
                out.append(EntryPoint(file: url.deletingPathExtension().lastPathComponent, name: ns.substring(with: m.range(at: 3)), line: line,
                                      mutates: mutates, covered: covered, asyncThrows: asyncThrows,
                                      touchesDB: body.contains("database.") || body.contains("db.query")))
            }
        }
        return out
    }

    @Test("Every mutating case-service entry point calls the policy check; every read of case content calls the read check")
    func everyEntryPointIsGuarded() throws {
        let points = try Self.entryPoints()
        let mutating = points.filter(\.mutates)
        let reads = points.filter { !$0.mutates && $0.asyncThrows }
        // The enumeration really sees the services (a broken scan must not pass by finding nothing).
        #expect(mutating.count > 200, "\(mutating.count) mutating entry points")
        #expect(reads.count > 100, "\(reads.count) read entry points")
        for e in points {
            let key = "\(e.file).\(e.name)"
            if Self.exempt[key] != nil { continue }
            if e.mutates {
                #expect(e.covered, "UNGUARDED change: \(key) (\(e.file).swift:\(e.line)) — call CaseAccessPolicy.require / requireChange or go through write()")
            } else if e.asyncThrows {
                #expect(e.covered, "UNGUARDED read: \(key) (\(e.file).swift:\(e.line)) — call CaseAccessPolicy.requireRead")
            } else if e.touchesDB {
                Issue.record("A non-throwing entry point reads the ledger without a stated exemption: \(key) (\(e.file).swift:\(e.line))")
            }
        }
        // Every exemption still names a real entry point (a stale list fails).
        let names = Set(points.map { "\($0.file).\($0.name)" })
        for k in Self.exempt.keys { #expect(names.contains(k), "stale exemption \(k)") }
        // The central write path runs the check with the operation of its action.
        let repo = try String(contentsOf: Self.repoRoot.appendingPathComponent("Kalsmritikosh/Investigate/CaseFile/CaseFileRepository.swift"), encoding: .utf8)
        #expect(repo.contains("try CaseAccessPolicy.require(db, caseID: caseID, actor: actor, operation)"))
    }

    @Test("Every recorded action maps to an operation; unknown actions need work, never just read")
    func actionClassification() {
        #expect(CaseAccessPolicy.operation(forAction: "accessGranted") == .administer)
        #expect(CaseAccessPolicy.operation(forAction: "stage") == .administer)
        #expect(CaseAccessPolicy.operation(forAction: "allegationDecided") == .review)
        #expect(CaseAccessPolicy.operation(forAction: "actionAccepted") == .review)
        #expect(CaseAccessPolicy.operation(forAction: "exported") == .export)
        #expect(CaseAccessPolicy.operation(forAction: "lateContributionQueued") == .contribute)
        #expect(CaseAccessPolicy.operation(forAction: "layoutSaved") == .read)
        #expect(CaseAccessPolicy.operation(forAction: "somethingNew") == .work)
        #expect(CaseAccessPolicy.operation(forAction: "exportRefused") == nil, "a refusal is recorded whoever attempted it")
    }

    // MARK: SEC-05 / SEC-11 secrets

    @Test("Credentials never reach the unified log as public text, the action log or an export")
    func secretsNeverLeak() async throws {
        // 1. No log statement interpolates a credential-named value as public, anywhere in the app's sources.
        let interp = try NSRegularExpression(pattern: #"\\\(([^()]*(?:\([^()]*\))*[^()]*),\s*privacy:\s*\.public\)"#)
        let secret = try NSRegularExpression(pattern: #"(?i)(api_?key|password|passphrase|secret|bearer|private_?key|signedTransaction|jws\b|ledgerKey|\btoken\b|credential|authorization)"#)
        var scanned = 0, offenders: [String] = []
        for dir in ["Kalsmritikosh", "SyncCore", "KalsmritikoshShare"] {
            guard let en = FileManager.default.enumerator(at: Self.repoRoot.appendingPathComponent(dir), includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in en where url.pathExtension == "swift" {
                let text = try String(contentsOf: url, encoding: .utf8)
                scanned += 1
                for line in text.components(separatedBy: "\n") where line.contains(".public") {
                    let ns = line as NSString
                    for m in interp.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                        let expr = ns.substring(with: m.range(at: 1))
                        if secret.firstMatch(in: expr, range: NSRange(location: 0, length: (expr as NSString).length)) != nil {
                            offenders.append("\(url.lastPathComponent): \(expr.prefix(80))")
                        }
                    }
                }
            }
        }
        #expect(scanned > 500, "\(scanned) source files scanned")
        #expect(offenders.isEmpty, "\(offenders)")
        // 2. The redactor masks credential shapes and leaves ordinary text alone.
        let key = "sk-ant-api03-" + String(repeating: "Ab9_", count: 12)
        let jws = "eyJhbGciOiJFUzI1NiJ9.eyJidW5kbGVJZCI6ImNvbSJ9.c2lnbmF0dXJlLXZhbHVl"
        #expect(SecretRedactor.redact("key \(key) end") == "key [credential removed] end")
        #expect(SecretRedactor.containsCredential("Authorization: Bearer abcdefghijklmnopqrstuvwx"))
        #expect(SecretRedactor.containsCredential(jws))
        #expect(!SecretRedactor.containsCredential("Invoice INV-104 for ₹1,00,000 paid on 5 March; account 0012345678"))
        // 3. A key pasted into a case note: the action log keeps no copy, and an export carries none.
        let f = try await CaseFileTests.fixture()
        _ = try await f.file.addJournal(caseID: f.caseID, kind: .note, text: "Pasted by mistake: \(key)", eventDate: nil, evidenceRef: nil, actor: "Ada")
        let details = try await f.db.query("SELECT COALESCE(detail,'') FROM case_actions WHERE case_id = ?;", [.uuid(f.caseID)]).compactMap { $0.string(0) }
        #expect(!details.joined().contains("sk-ant-"), "action log")
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("s9-sec-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let outputs = CaseOutputService(database: f.db, caseFiles: f.svc, custody: { _ in [] }, pendingDirectory: temp.appendingPathComponent("pending"))
        let pkg = try await outputs.prepareText(caseID: f.caseID, kind: .caseLog, route: .file, actor: "Ada", citations: [],
                                                text: "Notes\nPasted by mistake: \(key)\nToken: \(jws)")
        #expect(!pkg.text.contains("sk-ant-") && !pkg.text.contains(jws) && pkg.text.contains(SecretRedactor.marker))
        #expect(!String(decoding: pkg.data, as: UTF8.self).contains("sk-ant-"))
    }

    // MARK: SEC-10 hostile input on the new tables

    @Test("Hostile names and shares are refused or stored inertly; look-alike names cannot become a second person")
    func hostileInput() async throws {
        for bad in ["", "   ", "Ada\u{202E}nimdA", "Ben\u{200B}", "Rita\u{0007}", String(repeating: "x", count: 201), "Vera\u{2066}x\u{2069}"] {
            #expect(throws: CaseAccessError.self) { _ = try CaseAccessPolicy.nameKey(bad) }
        }
        #expect(try CaseAccessPolicy.nameKey("  Ａｄａ   Lovelace ") == "ada lovelace", "full-width and spacing fold to one key")
        let f = try await CaseFileTests.fixture()
        let sql = "Robert'); DROP TABLE case_access_grants;--"
        _ = try await f.file.grantAccess(caseID: f.caseID, to: sql, role: .viewer, reason: "x'); DELETE FROM local_actors;--", actor: "Ada")
        #expect(try await f.file.accessGrants(caseID: f.caseID).contains { $0.actorName == sql })
        #expect(try await s9Count(f.db, "SELECT COUNT(*) FROM local_actors;") == 2)
        // The same person under a look-alike spelling is the same local actor, so they cannot be given a second identity.
        await #expect(throws: CaseAccessError.alreadyHeld("Viewer")) {
            _ = try await f.file.grantAccess(caseID: f.caseID, to: "ROBERT'); DROP TABLE CASE_ACCESS_GRANTS;--", role: .viewer, reason: "dup", actor: "Ada")
        }
        await #expect(throws: CaseAccessError.self) {
            _ = try await f.file.grantAccess(caseID: f.caseID, to: "Ada\u{202E}", role: .owner, reason: "x", actor: "Ada")
        }
        // Shares: only a contributor's, only requests of this case, only identifiers.
        await #expect(throws: CaseAccessError.self) {
            _ = try await f.file.grantAccess(caseID: f.caseID, to: "Cal", role: .contributor, scope: ["../../etc/passwd"], reason: "x", actor: "Ada")
        }
        await #expect(throws: CaseAccessError.self) {
            _ = try await f.file.grantAccess(caseID: f.caseID, to: "Cal", role: .contributor, scope: [UUID().uuidString], reason: "x", actor: "Ada")
        }
        await #expect(throws: CaseAccessError.self) {
            _ = try await f.file.grantAccess(caseID: f.caseID, to: "Vera", role: .viewer, scope: [UUID().uuidString], reason: "x", actor: "Ada")
        }
        // The database refuses an unknown role and a malformed tombstone generation hash outright.
        await #expect(throws: (any Error).self) {
            try await f.db.exec("INSERT INTO case_access_grants (id, case_id, actor_id, role, reason, granted_by, granted_at, generation) VALUES (?,?,?,'admin','x','Ada',0,1);",
                                [.uuid(UUID()), .uuid(f.caseID), .uuid(UUID())])
        }
        await #expect(throws: (any Error).self) {
            try await f.db.exec("INSERT INTO erasure_generations (kind, scope_hash, erasure_id, state, erased_at) VALUES ('case','short','x','done',0);")
        }
    }

    // MARK: TEAM-08 notifications

    @Test("Notifications carry no case content on a locked screen or in the notification store")
    func notificationsAreContentFree() {
        let p = MaturationNotifier.preview(kind: "person", identifier: "Meera Iyer")
        #expect(!p.title.contains("Meera") && !p.body.contains("Meera") && !p.requestID.contains("Meera"))
        #expect(!p.userInfo.values.contains { $0.contains("Meera") })
    }

    // MARK: TEAM-12 both modes

    @Test("The same work runs solo (no setup) and as a team (lead, examiner, contributor), with the same records")
    func bothModes() async throws {
        let solo = try await CaseFileTests.fixture(title: "Solo")
        let q1 = try await solo.file.addAllegation(caseID: solo.caseID, text: "Paid twice?", actor: "Ada")
        try await solo.file.decide(allegationID: q1, caseID: solo.caseID, disposition: .inconclusive, rationale: "Self-review in a solo case", actor: "Ada")
        let team = try await CaseFileTests.fixture(title: "Team")
        _ = try await team.file.grantAccess(caseID: team.caseID, to: "Eli", role: .investigator, reason: "Examiner", actor: "Ada")
        _ = try await team.file.grantAccess(caseID: team.caseID, to: "Cal", role: .contributor, reason: "Bank liaison", actor: "Ada")
        let q2 = try await team.file.addAllegation(caseID: team.caseID, text: "Paid twice?", actor: "Eli")
        await #expect(throws: CaseAccessError.self) {
            try await team.file.decide(allegationID: q2, caseID: team.caseID, disposition: .inconclusive, rationale: "x", actor: "Cal")
        }
        try await team.file.decide(allegationID: q2, caseID: team.caseID, disposition: .inconclusive, rationale: "Reviewed by the lead", actor: "Ada")
        for f in [solo, team] {
            #expect(try await s9Count(f.db, "SELECT COUNT(*) FROM case_allegations WHERE case_id = ? AND disposition = 'inconclusive';", [.uuid(f.caseID)]) == 1)
        }
        #expect(try await !solo.file.isTeamCase(caseID: solo.caseID))
        #expect(try await team.file.isTeamCase(caseID: team.caseID))
    }
}
