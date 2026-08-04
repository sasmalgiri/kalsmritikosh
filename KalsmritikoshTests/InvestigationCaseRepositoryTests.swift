//
//  InvestigationCaseRepositoryTests.swift
//  KalsmritikoshTests
//
//  INV-01-A — the durable case-intake & scope authority over a real ledger. Proves a case is created,
//  scoped, and confirmed with append-only audit; that the in-scope source set is the HARD evidence
//  boundary (authorizedSourceRefs excludes out-of-scope and unlisted sources); that every mutation
//  advances the revision under optimistic CAS (a stale revision is rejected); that a case resumes
//  byte-for-byte after relaunch; and — the possible ≠ confirmed boundary — that only an id present in the
//  canonical confirmed `deadlines` table can bind, while a candidate id is refused. Synthetic only.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("INV-01-A — case intake & scope repository")
struct InvestigationCaseRepositoryTests {

    private let t0 = Date(timeIntervalSinceReferenceDate: 0)

    /// A repo over a fresh latest-schema ledger, with one workspace seeded. FK enforcement is left off so
    /// a bare confirmed-`deadlines` row can be seeded without standing up the whole task chain (the
    /// repository's own reference check, not FK, is what these tests exercise).
    private func makeRepoAndWorkspace() async throws -> (InvestigationCaseRepository, Database, UUID) {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let ws = UUID()
        try await db.exec("INSERT INTO workspaces (id, title, created_at, updated_at) VALUES (?,?,?,?);",
                          [.uuid(ws), .text("Matter"), .real(1), .real(1)])
        return (InvestigationCaseRepository(database: db), db, ws)
    }

    /// Seed a professional_task parent (the FK anchor deadlines / candidates require).
    private func seedTask(_ db: Database, workspace: UUID) async throws -> UUID {
        let id = UUID()
        try await db.exec("""
            INSERT INTO professional_tasks (id, workspace_id, title, task_type, status, priority, origin, created_at, updated_at)
            VALUES (?,?,?,?,?,?,?,?,?);
            """, [.uuid(id), .uuid(workspace), .text("t"), .text("investigate"), .text("open"), .text("normal"), .text("system"), .real(1), .real(1)])
        return id
    }

    /// Seed a bare CONFIRMED deadline row and return its id (used to prove binding accepts it).
    private func seedConfirmedDeadline(_ db: Database, task: UUID) async throws -> UUID {
        let id = UUID()
        try await db.exec("""
            INSERT INTO deadlines (id, task_id, due_date, precision, time_zone, deadline_kind, status,
                confirmation_kind, confirmed_by, confirmed_at, created_at, updated_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(id), .uuid(task), .real(1000), .integer(0), .text("UTC"), .text("hard"),
                  .text("confirmed"), .text("human"), .text("u"), .real(1), .real(1), .real(1)])
        return id
    }

    // MARK: - Intake

    @Test("A created case starts open at revision 1 with a `created` event and no authorized sources")
    func createCase() async throws {
        let (repo, _, ws) = try await makeRepoAndWorkspace()
        let c = try await repo.createCase(workspaceID: ws, title: "Payment discrepancy", purpose: "Find the cause", actor: "analyst", at: t0)
        #expect(c.status == .open)
        #expect(c.revision == 1)
        let record = try await repo.fetch(caseID: c.id)
        #expect(record?.authorizedSourceRefs.isEmpty == true)
        #expect(record?.events.map(\.action) == [.created])
    }

    @Test("Creating a case rejects a blank title/actor and an unknown workspace")
    func createGuards() async throws {
        let (repo, _, ws) = try await makeRepoAndWorkspace()
        await #expect(throws: InvestigationCaseError.self) { _ = try await repo.createCase(workspaceID: ws, title: "  ", actor: "u", at: t0) }
        await #expect(throws: InvestigationCaseError.self) { _ = try await repo.createCase(workspaceID: ws, title: "T", actor: "  ", at: t0) }
        await #expect(throws: InvestigationCaseError.self) { _ = try await repo.createCase(workspaceID: UUID(), title: "T", actor: "u", at: t0) }
    }

    // MARK: - Scope boundary

    @Test("The in-scope source set is the hard boundary: authorizedSourceRefs excludes excluded and unlisted sources")
    func authorizedBoundary() async throws {
        let (repo, _, ws) = try await makeRepoAndWorkspace()
        var c = try await repo.createCase(workspaceID: ws, title: "T", actor: "u", at: t0)
        c = try await repo.includeSource(caseID: c.id, expectedRevision: c.revision, sourceRef: "src-A", sourceKind: .logicalSource, actor: "u", at: t0)
        c = try await repo.includeSource(caseID: c.id, expectedRevision: c.revision, sourceRef: "src-B", sourceKind: .sourceVersion, actor: "u", at: t0)
        c = try await repo.excludeSource(caseID: c.id, expectedRevision: c.revision, sourceRef: "src-C", sourceKind: .workspaceSource, actor: "u", at: t0)
        let record = try await repo.fetch(caseID: c.id)
        #expect(record?.authorizedSourceRefs == ["src-A", "src-B"])   // src-C excluded, src-D never listed
        #expect(record?.excludedSourceRefs == ["src-C"])
        #expect(record?.isAuthorized("src-A") == true)
        #expect(record?.isAuthorized("src-C") == false)
        #expect(record?.isAuthorized("src-D") == false)
        #expect(try await repo.authorizedSourceRefs(caseID: c.id) == ["src-A", "src-B"])
    }

    @Test("Re-including a previously excluded source flips it back in-scope (one disposition per source)")
    func reincludeFlips() async throws {
        let (repo, _, ws) = try await makeRepoAndWorkspace()
        var c = try await repo.createCase(workspaceID: ws, title: "T", actor: "u", at: t0)
        c = try await repo.excludeSource(caseID: c.id, expectedRevision: c.revision, sourceRef: "src-A", sourceKind: .logicalSource, actor: "u", at: t0)
        #expect(try await repo.authorizedSourceRefs(caseID: c.id) == [])
        c = try await repo.includeSource(caseID: c.id, expectedRevision: c.revision, sourceRef: "src-A", sourceKind: .logicalSource, actor: "u", at: t0)
        #expect(try await repo.authorizedSourceRefs(caseID: c.id) == ["src-A"])
        // Still exactly one disposition row for the source.
        let record = try await repo.fetch(caseID: c.id)
        #expect(record?.sources.filter { $0.sourceRef == "src-A" }.count == 1)
    }

    @Test("A blank source reference is rejected")
    func blankSourceRejected() async throws {
        let (repo, _, ws) = try await makeRepoAndWorkspace()
        let c = try await repo.createCase(workspaceID: ws, title: "T", actor: "u", at: t0)
        await #expect(throws: InvestigationCaseError.self) {
            _ = try await repo.includeSource(caseID: c.id, expectedRevision: c.revision, sourceRef: "   ", sourceKind: .logicalSource, actor: "u", at: t0)
        }
    }

    @Test("updateScope revises the framing and records a scopeSet event")
    func updateScope() async throws {
        let (repo, _, ws) = try await makeRepoAndWorkspace()
        let c = try await repo.createCase(workspaceID: ws, title: "T", actor: "u", at: t0)
        let updated = try await repo.updateScope(caseID: c.id, expectedRevision: c.revision, scopeStatement: "In: Q1 payments",
                                                 outOfScopeStatement: "Out: HR files", timeWindowStart: t0, timeWindowEnd: t0.addingTimeInterval(86_400),
                                                 possibleDeadlineNote: "audit maybe due end of month", actor: "u", at: t0)
        #expect(updated.scopeStatement == "In: Q1 payments")
        #expect(updated.outOfScopeStatement == "Out: HR files")
        #expect(updated.possibleDeadlineNote == "audit maybe due end of month")
        #expect(updated.revision == 2)
        let record = try await repo.fetch(caseID: c.id)
        #expect(record?.events.map(\.action) == [.created, .scopeSet])
    }

    // MARK: - Status

    @Test("Confirming scope moves open→scopeConfirmed; reopening moves it back, both audited")
    func confirmAndReopen() async throws {
        let (repo, _, ws) = try await makeRepoAndWorkspace()
        var c = try await repo.createCase(workspaceID: ws, title: "T", actor: "u", at: t0)
        c = try await repo.confirmScope(caseID: c.id, expectedRevision: c.revision, actor: "human", at: t0)
        #expect(c.status == .scopeConfirmed)
        c = try await repo.reopenScope(caseID: c.id, expectedRevision: c.revision, actor: "human", at: t0)
        #expect(c.status == .open)
        let record = try await repo.fetch(caseID: c.id)
        #expect(record?.events.map(\.action) == [.created, .scopeConfirmed, .reopened])
    }

    // MARK: - CAS

    @Test("A stale expected revision is rejected as a conflict and mutates nothing")
    func revisionConflict() async throws {
        let (repo, _, ws) = try await makeRepoAndWorkspace()
        let c = try await repo.createCase(workspaceID: ws, title: "T", actor: "u", at: t0)   // revision 1
        _ = try await repo.includeSource(caseID: c.id, expectedRevision: 1, sourceRef: "src-A", sourceKind: .logicalSource, actor: "u", at: t0)   // now 2
        await #expect(throws: InvestigationCaseError.self) {
            _ = try await repo.includeSource(caseID: c.id, expectedRevision: 1, sourceRef: "src-B", sourceKind: .logicalSource, actor: "u", at: t0)   // stale
        }
        #expect(try await repo.authorizedSourceRefs(caseID: c.id) == ["src-A"])   // src-B never added
    }

    // MARK: - Resume

    @Test("A case resumes byte-for-byte from disk: header, sorted sources, and ordered audit")
    func resumeRoundTrip() async throws {
        let (repo, db, ws) = try await makeRepoAndWorkspace()
        var c = try await repo.createCase(workspaceID: ws, title: "Vendor review", purpose: "p", actor: "u", at: t0)
        c = try await repo.includeSource(caseID: c.id, expectedRevision: c.revision, sourceRef: "src-B", sourceKind: .logicalSource, actor: "u", at: t0)
        c = try await repo.includeSource(caseID: c.id, expectedRevision: c.revision, sourceRef: "src-A", sourceKind: .logicalSource, actor: "u", at: t0)
        c = try await repo.confirmScope(caseID: c.id, expectedRevision: c.revision, actor: "u", at: t0)

        // Reopen the ledger with a brand-new repository over the same database.
        let resumed = try await InvestigationCaseRepository(database: db).fetch(caseID: c.id)
        #expect(resumed?.caseHeader.status == .scopeConfirmed)
        #expect(resumed?.caseHeader.revision == c.revision)
        #expect(resumed?.authorizedSourceRefs == ["src-A", "src-B"])
        #expect(resumed?.events.map(\.sequence) == [1, 2, 3, 4])
        #expect(resumed?.events.map(\.action) == [.created, .sourceIncluded, .sourceIncluded, .scopeConfirmed])
    }

    @Test("Fetching an unknown case is nil; listCases returns a workspace's cases oldest-first")
    func fetchUnknownAndList() async throws {
        let (repo, _, ws) = try await makeRepoAndWorkspace()
        #expect(try await repo.fetch(caseID: UUID()) == nil)
        let a = try await repo.createCase(workspaceID: ws, title: "A", actor: "u", at: t0)
        let b = try await repo.createCase(workspaceID: ws, title: "B", actor: "u", at: t0.addingTimeInterval(10))
        #expect(try await repo.listCases(workspaceID: ws).map(\.id) == [a.id, b.id])
    }

    // MARK: - possible ≠ confirmed

    @Test("Binding accepts an id present in the canonical confirmed deadlines table")
    func bindConfirmedAccepted() async throws {
        let (repo, db, ws) = try await makeRepoAndWorkspace()
        let c = try await repo.createCase(workspaceID: ws, title: "T", actor: "u", at: t0)
        let deadlineID = try await seedConfirmedDeadline(db, task: try await seedTask(db, workspace: ws))
        let bound = try await repo.bindConfirmedDeadline(caseID: c.id, expectedRevision: c.revision, deadlineID: deadlineID, actor: "human", at: t0)
        #expect(bound.confirmedDeadlineID == deadlineID)
        let record = try await repo.fetch(caseID: c.id)
        #expect(record?.events.last?.action == .deadlineBound)
    }

    @Test("Binding refuses a candidate id (possible ≠ confirmed) — and any id absent from confirmed deadlines")
    func bindCandidateRefused() async throws {
        let (repo, db, ws) = try await makeRepoAndWorkspace()
        let c = try await repo.createCase(workspaceID: ws, title: "T", actor: "u", at: t0)
        // A DeadlineCandidate lives in a different table (deadline_candidates); its id must never bind as
        // the authoritative deadline, even though it is a perfectly valid candidate.
        let candidateID = UUID()
        let taskID = try await seedTask(db, workspace: ws)
        try await db.exec("""
            INSERT INTO deadline_candidates (id, task_id, due_date, precision, time_zone, deadline_kind, origin, proposed_by, status, created_at)
            VALUES (?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(candidateID), .uuid(taskID), .real(1000), .integer(0), .text("UTC"), .text("hard"),
                  .text("ruleProposed"), .text("rule"), .text("proposed"), .real(1)])
        await #expect(throws: InvestigationCaseError.self) {
            _ = try await repo.bindConfirmedDeadline(caseID: c.id, expectedRevision: c.revision, deadlineID: candidateID, actor: "human", at: t0)
        }
        await #expect(throws: InvestigationCaseError.self) {
            _ = try await repo.bindConfirmedDeadline(caseID: c.id, expectedRevision: c.revision, deadlineID: UUID(), actor: "human", at: t0)
        }
        // The failed bind mutated nothing.
        #expect(try await repo.fetch(caseID: c.id)?.caseHeader.confirmedDeadlineID == nil)
        #expect(try await repo.fetch(caseID: c.id)?.caseHeader.revision == 1)
    }

    // MARK: - Mutation guard on a missing case

    @Test("Mutating an unknown case throws caseNotFound")
    func mutateUnknownCase() async throws {
        let (repo, _, _) = try await makeRepoAndWorkspace()
        await #expect(throws: InvestigationCaseError.self) {
            _ = try await repo.confirmScope(caseID: UUID(), expectedRevision: 1, actor: "u", at: t0)
        }
    }
}
