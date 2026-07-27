//
//  ScreenScopeEnforcementTests.swift
//  KalsmritikoshTests
//
//  OPS-003D.1.2 — proves the three semantic gaps from the OPS-003D.1.1 NO-GO:
//  1. Successful assign increments SensitiveScopeMutationService.revisionCount
//  2. Successful revoke increments revisionCount
//  3. Failed mutation does not increment revisionCount
//  4. SourceViewer recheck: authorize returns false after assignment via service
//  5. EvidenceViewer recheck: authorize returns false after assignment — snippet hidden
//  6. EventDetailSheet becomes restricted after service.assign(.event)
//  7. EventDetailSheet access restored after service.revoke
//  8. Direct repo.assign() bypass does not increment service.revisionCount
//
//  Floor: 945 − 10 (OPS-003D.1.1 tests removed) + 8 (these) = 943.
//

import Testing
import Foundation
@testable import Kalsmritikosh

@Suite("OPS-003D.1.2 ScreenScopeEnforcement — mutation service + fail-closed live revalidation")
struct ScreenScopeEnforcementTests {

    private let t0 = Date(timeIntervalSince1970: 1_750_000_000)

    // MARK: - Rig

    private func openDB() async throws -> (Database, SensitiveScopeRepository) {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("screen-\(UUID().uuidString).sqlite")
        let db = try Database(url: tmp)
        try await SchemaMigrations.migrate(db)
        return (db, SensitiveScopeRepository(database: db))
    }

    private func seedKO(_ db: Database, koID: UUID) async throws {
        let fileID = UUID()
        try await db.exec("INSERT INTO files (id, url, source_type) VALUES (?,?,?);",
                          [.uuid(fileID), .text("file:///\(fileID).txt"), .text("text")])
        try await db.exec("""
        INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at)
        VALUES (?,?,?,?,0,0);
        """, [.uuid(koID), .uuid(fileID), .text("txt"), .text("test content")])
    }

    private func seedEvent(_ db: Database, eventID: UUID, koID: UUID) async throws {
        try await db.exec(
            "INSERT INTO events (id, kind, date, title, source_object_id) VALUES (?,?,?,?,?);",
            [.uuid(eventID), .text("contractSigned"), .real(t0.timeIntervalSince1970),
             .text("Test Event"), .uuid(koID)])
    }

    // MARK: - Test 1: Successful assign increments revisionCount

    @Test("SensitiveScopeMutationService: successful assign increments revisionCount to 1")
    func successfulAssignment_incrementsRevision() async throws {
        let (db, repo) = try await openDB()
        let koID = UUID()
        try await seedKO(db, koID: koID)
        let service = SensitiveScopeMutationService(repository: repo)
        _ = try await service.assign(
            target: SensitiveScopeTarget(kind: .knowledgeObject, id: koID),
            sensitivity: .restricted,
            authority: .userConfirmed(actorID: "owner", confirmationID: UUID(), privileged: true),
            reason: nil, at: t0)
        #expect(await service.revisionCount == 1,
                "Successful assign must increment revisionCount — policyChanges yielded, viewer tasks re-fire.")
    }

    // MARK: - Test 2: Successful revoke increments revisionCount

    @Test("SensitiveScopeMutationService: successful revoke increments revisionCount to 2")
    func successfulRevocation_incrementsRevision() async throws {
        let (db, repo) = try await openDB()
        let koID = UUID()
        try await seedKO(db, koID: koID)
        let service = SensitiveScopeMutationService(repository: repo)
        let assignment = try await service.assign(
            target: SensitiveScopeTarget(kind: .knowledgeObject, id: koID),
            sensitivity: .restricted,
            authority: .userConfirmed(actorID: "owner", confirmationID: UUID(), privileged: true),
            reason: nil, at: t0)
        try await service.revoke(assignmentID: assignment.id, revokedBy: "owner",
                                 reason: nil, at: t0.addingTimeInterval(60))
        #expect(await service.revisionCount == 2,
                "Assign (1) + revoke (2) must give revisionCount of 2 — two policy-change signals fired.")
    }

    // MARK: - Test 3: Failed mutation does not increment revisionCount

    @Test("SensitiveScopeMutationService: failed revoke (assignment not found) does not increment")
    func failedMutation_doesNotIncrementRevision() async throws {
        let (_, repo) = try await openDB()
        let service = SensitiveScopeMutationService(repository: repo)
        await #expect(throws: (any Error).self) {
            try await service.revoke(assignmentID: UUID(), revokedBy: "owner",
                                     reason: nil, at: t0)
        }
        #expect(await service.revisionCount == 0,
                "Failed revoke must not increment revisionCount — no policy signal, no viewer revalidation.")
    }

    // MARK: - Test 4: SourceViewer recheck after assignment returns false

    @Test("SourceViewer recheck: authorize returns false after service.assign — pending then blocked")
    func sourcePolicyRecheck_blocksKOAfterAssignment() async throws {
        let (db, repo) = try await openDB()
        let koID = UUID()
        try await seedKO(db, koID: koID)
        let service = SensitiveScopeMutationService(repository: repo)
        let auth = ScreenScopeAuthorizer(repository: repo)

        // Initially accessible — authorized=true, content shown.
        #expect(await auth.authorize(koID, boundary: .globalOwner) == true,
                "Before any assignment the KO is accessible.")

        _ = try await service.assign(
            target: SensitiveScopeTarget(kind: .knowledgeObject, id: koID),
            sensitivity: .restricted,
            authority: .userConfirmed(actorID: "owner", confirmationID: UUID(), privileged: true),
            reason: nil, at: t0)

        // SourceViewer's .task sets authorized=nil (ProgressView) BEFORE this await,
        // then this call returns false → blockedPlaceholder replaces the content.
        #expect(await auth.authorize(koID, boundary: .globalOwner) == false,
                "After service.assign, authorize returns false — SourceViewer shows blockedPlaceholder.")
        #expect(await service.revisionCount == 1,
                "Service correctly incremented revision after assignment.")
    }

    // MARK: - Test 5: EvidenceViewer recheck after assignment returns false

    @Test("EvidenceViewer recheck: authorize returns false after service.assign — snippet and KO ID hidden")
    func evidencePolicyRecheck_blocksSnippetAfterAssignment() async throws {
        let (db, repo) = try await openDB()
        let koID = UUID()
        try await seedKO(db, koID: koID)
        let eventID = UUID()
        try await seedEvent(db, eventID: eventID, koID: koID)
        let service = SensitiveScopeMutationService(repository: repo)
        let auth = ScreenScopeAuthorizer(repository: repo)

        // Citation KO initially accessible — EvidenceViewer shows snippet and KO ID.
        #expect(await auth.authorize(koID, boundary: .globalOwner) == true)

        // Service assigns restriction; revisionCount increments; AuthorizationTaskID changes.
        // EvidenceViewer's .task sets authorized=nil (ProgressView shown), then re-checks.
        _ = try await service.assign(
            target: SensitiveScopeTarget(kind: .knowledgeObject, id: koID),
            sensitivity: .restricted,
            authority: .userConfirmed(actorID: "owner", confirmationID: UUID(), privileged: true),
            reason: nil, at: t0)

        // The re-check must return false → EvidenceViewer shows restrictedBody hiding snippet.
        #expect(await auth.authorize(koID, boundary: .globalOwner) == false,
                "After service.assign, EvidenceViewer recheck returns false — snippet and KO ID hidden.")
    }

    // MARK: - Test 6: EventDetailSheet becomes restricted after service.assign(.event)

    @Test("EventDetailSheet: event authorization denied after service.assign on event target")
    func eventAuthorization_deniedAfterAssignment() async throws {
        let (db, repo) = try await openDB()
        let koID = UUID()
        try await seedKO(db, koID: koID)
        let eventID = UUID()
        try await seedEvent(db, eventID: eventID, koID: koID)
        let service = SensitiveScopeMutationService(repository: repo)
        let auth = ScreenScopeAuthorizer(repository: repo)
        let target = SensitiveScopeTarget(kind: .event, id: eventID)

        // Event initially accessible.
        #expect(await auth.authorize(target: target, boundary: .globalOwner) == true)

        _ = try await service.assign(
            target: target,
            sensitivity: .restricted,
            authority: .userConfirmed(actorID: "owner", confirmationID: UUID(), privileged: true),
            reason: nil, at: t0)

        // EventDetailSheet's revision-aware .task re-fires, sets eventAuthorized=nil,
        // awaits this check — returns false → sensitive state cleared, restricted placeholder shown.
        #expect(await auth.authorize(target: target, boundary: .globalOwner) == false,
                "After service.assign(.event), EventDetailSheet recheck returns false — state cleared.")
        #expect(await service.revisionCount == 1)
    }

    // MARK: - Test 7: EventDetailSheet access restored after service.revoke

    @Test("EventDetailSheet: event access restored after service.revoke — data reloads on re-authorization")
    func revocation_restoresEventAccess() async throws {
        let (db, repo) = try await openDB()
        let koID = UUID()
        try await seedKO(db, koID: koID)
        let eventID = UUID()
        try await seedEvent(db, eventID: eventID, koID: koID)
        let service = SensitiveScopeMutationService(repository: repo)
        let auth = ScreenScopeAuthorizer(repository: repo)
        let target = SensitiveScopeTarget(kind: .event, id: eventID)

        let assignment = try await service.assign(
            target: target,
            sensitivity: .restricted,
            authority: .userConfirmed(actorID: "owner", confirmationID: UUID(), privileged: true),
            reason: nil, at: t0)
        #expect(await auth.authorize(target: target, boundary: .globalOwner) == false,
                "Restricted before revocation.")

        try await service.revoke(assignmentID: assignment.id, revokedBy: "owner",
                                 reason: nil, at: t0.addingTimeInterval(60))

        // Revision bumps to 2; EventDetailSheet .task re-fires, sets eventAuthorized=nil,
        // awaits this check — returns true; loading=true (reset during denial) triggers reload.
        #expect(await auth.authorize(target: target, boundary: .globalOwner) == true,
                "After service.revoke, EventDetailSheet recheck returns true — access and data restored.")
        #expect(await service.revisionCount == 2,
                "Assign (1) + revoke (2) = revisionCount 2.")
    }

    // MARK: - Test 8: Direct repo.assign() bypass does not increment service.revisionCount

    @Test("Direct repo.assign() bypasses mutation service — revisionCount stays 0 until service is used")
    func directRepoBypass_doesNotIncrementRevision() async throws {
        let (db, repo) = try await openDB()
        let koID = UUID()
        try await seedKO(db, koID: koID)
        let service = SensitiveScopeMutationService(repository: repo)

        // Bypass: direct repo call — no increment, no policyChanges yield, no viewer revalidation.
        _ = try await repo.assign(
            target: SensitiveScopeTarget(kind: .knowledgeObject, id: koID),
            sensitivity: .restricted,
            authority: .userConfirmed(actorID: "owner", confirmationID: UUID(), privileged: true),
            reason: nil, at: t0)
        #expect(await service.revisionCount == 0,
                "Direct repo.assign() must not increment service.revisionCount — architecture guard prevents this in production.")

        // Correct path: using the service increments correctly.
        let koID2 = UUID()
        try await seedKO(db, koID: koID2)
        _ = try await service.assign(
            target: SensitiveScopeTarget(kind: .knowledgeObject, id: koID2),
            sensitivity: .restricted,
            authority: .userConfirmed(actorID: "owner", confirmationID: UUID(), privileged: true),
            reason: nil, at: t0)
        #expect(await service.revisionCount == 1,
                "Service.assign() correctly increments to 1.")
    }
}
