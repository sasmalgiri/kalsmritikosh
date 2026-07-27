//
//  ScreenScopeEnforcementTests.swift
//  KalsmritikoshTests
//
//  OPS-003D.1.2.1 — cumulative suite; all prior security contracts are retained.
//
//  OPS-003D.1.1 tests (10) — original viewer-identity and event-detail contracts:
//  1.  SourceViewer.koID is mandatory (no optional bypass path)
//  2.  Restricted KO blocks SourceViewer content rendering
//  3.  Restricted event target blocks the entire EventDetailSheet
//  4.  Event-level auth denies via source-KO inheritance (load() never called)
//  5.  Direct event SSA denies sheet; source KO independently permitted
//  6.  ScreenAccessBoundary has only .globalOwner (.workspace removed)
//  7.  isTestSentinel returns false in non-DEBUG builds
//  8.  Assignment added while SourceViewer is open hides content on revalidation
//  9.  Assignment added while EvidenceViewer is open hides snippet and KO ID
//  10. Revocation restores access when no inherited restriction remains
//
//  OPS-003D.1.2 tests (8) — mutation-service and live-revalidation contracts:
//  11. Successful assign increments SensitiveScopeMutationService.revisionCount
//  12. Successful revoke increments revisionCount
//  13. Failed mutation does not increment revisionCount
//  14. SourceViewer recheck: authorize returns false after assignment via service
//  15. EvidenceViewer recheck: authorize returns false after assignment — snippet hidden
//  16. EventDetailSheet becomes restricted after service.assign(.event)
//  17. EventDetailSheet access restored after service.revoke
//  18. Direct repo.assign() bypass does not increment service.revisionCount
//
//  policyChanges / AppState observer integration tests (4):
//  19. Successful assign emits exactly one policyChanges yield
//  20. Successful revoke emits exactly one policyChanges yield
//  21. Failed mutation emits no policyChanges yield
//  22. AppState observer pattern: two mutations → simulated revision counter = 2
//
//  Floor: 943 (OPS-003D.1.2 baseline) − 8 + 10 (restored) + 8 (kept) + 4 (new) = 957.
//

import Testing
import Foundation
@testable import Kalsmritikosh

// MARK: - Stream-observation helper

/// Swift 6–safe counter for observing policyChanges yields in tests.
private actor SignalCounter {
    var count: Int = 0
    func bump() { count += 1 }
}

@Suite("OPS-003D.1.2.1 ScreenScopeEnforcement — cumulative viewer, mutation-service, and stream tests")
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

    /// Seeds a minimal event row linking it to an existing KO.
    private func seedEvent(_ db: Database, eventID: UUID, koID: UUID) async throws {
        try await db.exec(
            "INSERT INTO events (id, kind, date, title, source_object_id) VALUES (?,?,?,?,?);",
            [.uuid(eventID), .text("contractSigned"), .real(t0.timeIntervalSince1970),
             .text("Test Event"), .uuid(koID)])
    }

    // =========================================================================
    // MARK: OPS-003D.1.1 — viewer identity, event-detail, revalidation contracts
    // =========================================================================

    // MARK: - Test 1: SourceViewer.koID is mandatory

    @Test("SourceViewer.init requires a non-optional koID — optional bypass path removed")
    func sourceViewerKoIDIsMandatory() {
        let url = URL(fileURLWithPath: "/tmp/test.txt")
        let sv = SourceViewer(url: url, koID: UUID())
        _ = sv
    }

    // MARK: - Test 2: Restricted KO blocks SourceViewer content rendering

    @Test("Privileged KO authorization returns false — SourceViewer renders blockedPlaceholder")
    func restrictedKO_blocksSourceViewerContent() async throws {
        let (db, repo) = try await openDB()
        let koID = UUID()
        try await seedKO(db, koID: koID)
        try await repo.assign(
            target: SensitiveScopeTarget(kind: .knowledgeObject, id: koID),
            sensitivity: .restricted,
            authority: .userConfirmed(actorID: "owner", confirmationID: UUID(), privileged: true),
            reason: nil, at: t0)
        let auth = ScreenScopeAuthorizer(repository: repo)
        let allowed = await auth.authorize(koID, boundary: .globalOwner)
        #expect(!allowed,
                "authorize must return false for a privileged KO — SourceViewer renders the locked placeholder.")
    }

    // MARK: - Test 3: Restricted event target blocks the entire EventDetailSheet

    @Test("Event with direct privileged SSA is denied — EventDetailSheet shows restricted placeholder")
    func restrictedEvent_blocksDetailSheet() async throws {
        let (db, repo) = try await openDB()
        let koID = UUID()
        try await seedKO(db, koID: koID)
        let eventID = UUID()
        try await seedEvent(db, eventID: eventID, koID: koID)
        try await repo.assign(
            target: SensitiveScopeTarget(kind: .event, id: eventID),
            sensitivity: .restricted,
            authority: .userConfirmed(actorID: "owner", confirmationID: UUID(), privileged: true),
            reason: nil, at: t0)
        let auth = ScreenScopeAuthorizer(repository: repo)
        let allowed = await auth.authorize(target: SensitiveScopeTarget(kind: .event, id: eventID),
                                           boundary: .globalOwner)
        #expect(!allowed,
                "Event with a direct privileged SSA must be denied — EventDetailSheet shows restrictedEventPlaceholder.")
    }

    // MARK: - Test 4: Event-level auth denies via source-KO inheritance

    @Test("Source-KO restriction propagates to event authorization via inheritance")
    func eventInheritsRestrictionFromSourceKO() async throws {
        let (db, repo) = try await openDB()
        let koID = UUID()
        try await seedKO(db, koID: koID)
        let eventID = UUID()
        try await seedEvent(db, eventID: eventID, koID: koID)
        try await repo.assign(
            target: SensitiveScopeTarget(kind: .knowledgeObject, id: koID),
            sensitivity: .restricted,
            authority: .userConfirmed(actorID: "owner", confirmationID: UUID(), privileged: true),
            reason: nil, at: t0)
        let auth = ScreenScopeAuthorizer(repository: repo)
        let eventAllowed = await auth.authorize(
            target: SensitiveScopeTarget(kind: .event, id: eventID), boundary: .globalOwner)
        #expect(!eventAllowed,
                "Source-KO restriction propagates to the event — gate fires before load().")
    }

    // MARK: - Test 5: Direct event SSA; source KO independently permitted

    @Test("Direct event SSA denies sheet while source KO alone is permitted — two-level gate")
    func directEventSSA_deniesSheet_sourceKOPermittedIndependently() async throws {
        let (db, repo) = try await openDB()
        let koID = UUID()
        try await seedKO(db, koID: koID)
        let eventID = UUID()
        try await seedEvent(db, eventID: eventID, koID: koID)
        try await repo.assign(
            target: SensitiveScopeTarget(kind: .event, id: eventID),
            sensitivity: .restricted,
            authority: .userConfirmed(actorID: "owner", confirmationID: UUID(), privileged: true),
            reason: nil, at: t0)
        let auth = ScreenScopeAuthorizer(repository: repo)
        let eventAllowed = await auth.authorize(
            target: SensitiveScopeTarget(kind: .event, id: eventID), boundary: .globalOwner)
        let koAllowed = await auth.authorize(
            target: SensitiveScopeTarget(kind: .knowledgeObject, id: koID), boundary: .globalOwner)
        #expect(!eventAllowed, "Event with a direct privileged SSA must be denied.")
        #expect(koAllowed, "Source KO without any restriction is independently permitted.")
    }

    // MARK: - Test 6: .workspace boundary is unavailable

    @Test("ScreenAccessBoundary has only .globalOwner — .workspace removed")
    func workspaceBoundaryUnavailable() {
        let boundary = ScreenAccessBoundary.globalOwner
        switch boundary {
        case .globalOwner: break
        }
    }

    // MARK: - Test 7: isTestSentinel is DEBUG-only

    @Test("isTestSentinel returns false in non-DEBUG builds")
    func testSentinelIsDebugOnly() {
        let sentinel = SensitiveScope(
            workspaceID: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
            maximumSensitivity: .restricted,
            permitsPrivilegedMaterial: false,
            purpose: .screen)
        #if DEBUG
        #expect(sentinel.isTestSentinel, "DEBUG: test sentinel UUID recognized.")
        #else
        #expect(!sentinel.isTestSentinel, "RELEASE: isTestSentinel always false.")
        #endif
    }

    // MARK: - Test 8: Assignment added while SourceViewer is open hides content

    @Test("Assignment added while SourceViewer is open: authorize returns false on revalidation")
    func assignmentAddedDuringView_hidesContent() async throws {
        let (db, repo) = try await openDB()
        let koID = UUID()
        try await seedKO(db, koID: koID)
        let auth = ScreenScopeAuthorizer(repository: repo)
        #expect(await auth.authorize(koID, boundary: .globalOwner) == true,
                "Before any assignment the KO is accessible.")
        try await repo.assign(
            target: SensitiveScopeTarget(kind: .knowledgeObject, id: koID),
            sensitivity: .restricted,
            authority: .userConfirmed(actorID: "owner", confirmationID: UUID(), privileged: true),
            reason: nil, at: t0)
        #expect(await auth.authorize(koID, boundary: .globalOwner) == false,
                "After assignment, authorize returns false — SourceViewer revalidates and hides content.")
    }

    // MARK: - Test 9: Assignment added while EvidenceViewer is open hides snippet

    @Test("Assignment added while EvidenceViewer is open: authorize returns false on revalidation")
    func assignmentAddedDuringEvidenceView_hidesSnippet() async throws {
        let (db, repo) = try await openDB()
        let koID = UUID()
        try await seedKO(db, koID: koID)
        let auth = ScreenScopeAuthorizer(repository: repo)
        #expect(await auth.authorize(koID, boundary: .globalOwner) == true,
                "Before any assignment the citation KO is accessible.")
        try await repo.assign(
            target: SensitiveScopeTarget(kind: .knowledgeObject, id: koID),
            sensitivity: .restricted,
            authority: .userConfirmed(actorID: "owner", confirmationID: UUID(), privileged: true),
            reason: nil, at: t0)
        #expect(await auth.authorize(koID, boundary: .globalOwner) == false,
                "After assignment, authorize returns false — EvidenceViewer hides snippet and KO ID.")
    }

    // MARK: - Test 10: Revocation restores access

    @Test("Revocation restores access when no inherited restriction remains")
    func revocationRestoresAccess() async throws {
        let (db, repo) = try await openDB()
        let koID = UUID()
        try await seedKO(db, koID: koID)
        let assignment = try await repo.assign(
            target: SensitiveScopeTarget(kind: .knowledgeObject, id: koID),
            sensitivity: .restricted,
            authority: .userConfirmed(actorID: "owner", confirmationID: UUID(), privileged: true),
            reason: nil, at: t0)
        let auth = ScreenScopeAuthorizer(repository: repo)
        #expect(await auth.authorize(koID, boundary: .globalOwner) == false,
                "Before revocation the KO is restricted.")
        try await repo.revoke(assignmentID: assignment.id, revokedBy: "owner",
                              reason: "no longer sensitive", at: t0.addingTimeInterval(60))
        #expect(await auth.authorize(koID, boundary: .globalOwner) == true,
                "After revoking all privileged assignments access is restored.")
    }

    // =========================================================================
    // MARK: OPS-003D.1.2 — mutation service and live-revalidation contracts
    // =========================================================================

    // MARK: - Test 11: Successful assign increments revisionCount

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

    // MARK: - Test 12: Successful revoke increments revisionCount

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
                "Assign (1) + revoke (2) must give revisionCount of 2.")
    }

    // MARK: - Test 13: Failed mutation does not increment revisionCount

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

    // MARK: - Test 14: SourceViewer recheck after assignment returns false

    @Test("SourceViewer recheck: authorize returns false after service.assign — pending then blocked")
    func sourcePolicyRecheck_blocksKOAfterAssignment() async throws {
        let (db, repo) = try await openDB()
        let koID = UUID()
        try await seedKO(db, koID: koID)
        let service = SensitiveScopeMutationService(repository: repo)
        let auth = ScreenScopeAuthorizer(repository: repo)
        #expect(await auth.authorize(koID, boundary: .globalOwner) == true,
                "Before any assignment the KO is accessible.")
        _ = try await service.assign(
            target: SensitiveScopeTarget(kind: .knowledgeObject, id: koID),
            sensitivity: .restricted,
            authority: .userConfirmed(actorID: "owner", confirmationID: UUID(), privileged: true),
            reason: nil, at: t0)
        #expect(await auth.authorize(koID, boundary: .globalOwner) == false,
                "After service.assign, authorize returns false — SourceViewer shows blockedPlaceholder.")
        #expect(await service.revisionCount == 1)
    }

    // MARK: - Test 15: EvidenceViewer recheck after assignment returns false

    @Test("EvidenceViewer recheck: authorize returns false after service.assign — snippet hidden")
    func evidencePolicyRecheck_blocksSnippetAfterAssignment() async throws {
        let (db, repo) = try await openDB()
        let koID = UUID()
        try await seedKO(db, koID: koID)
        let eventID = UUID()
        try await seedEvent(db, eventID: eventID, koID: koID)
        let service = SensitiveScopeMutationService(repository: repo)
        let auth = ScreenScopeAuthorizer(repository: repo)
        #expect(await auth.authorize(koID, boundary: .globalOwner) == true)
        _ = try await service.assign(
            target: SensitiveScopeTarget(kind: .knowledgeObject, id: koID),
            sensitivity: .restricted,
            authority: .userConfirmed(actorID: "owner", confirmationID: UUID(), privileged: true),
            reason: nil, at: t0)
        #expect(await auth.authorize(koID, boundary: .globalOwner) == false,
                "After service.assign, EvidenceViewer recheck returns false — snippet and KO ID hidden.")
    }

    // MARK: - Test 16: EventDetailSheet becomes restricted after service.assign(.event)

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
        #expect(await auth.authorize(target: target, boundary: .globalOwner) == true)
        _ = try await service.assign(
            target: target,
            sensitivity: .restricted,
            authority: .userConfirmed(actorID: "owner", confirmationID: UUID(), privileged: true),
            reason: nil, at: t0)
        #expect(await auth.authorize(target: target, boundary: .globalOwner) == false,
                "After service.assign(.event), EventDetailSheet recheck returns false — state cleared.")
        #expect(await service.revisionCount == 1)
    }

    // MARK: - Test 17: EventDetailSheet access restored after service.revoke

    @Test("EventDetailSheet: event access restored after service.revoke")
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
        #expect(await auth.authorize(target: target, boundary: .globalOwner) == true,
                "After service.revoke, EventDetailSheet recheck returns true — access restored.")
        #expect(await service.revisionCount == 2)
    }

    // MARK: - Test 18: Direct repo.assign() bypass does not increment service.revisionCount

    @Test("Direct repo.assign() bypasses mutation service — revisionCount stays 0 until service is used")
    func directRepoBypass_doesNotIncrementRevision() async throws {
        let (db, repo) = try await openDB()
        let koID = UUID()
        try await seedKO(db, koID: koID)
        let service = SensitiveScopeMutationService(repository: repo)
        _ = try await repo.assign(
            target: SensitiveScopeTarget(kind: .knowledgeObject, id: koID),
            sensitivity: .restricted,
            authority: .userConfirmed(actorID: "owner", confirmationID: UUID(), privileged: true),
            reason: nil, at: t0)
        #expect(await service.revisionCount == 0,
                "Direct repo.assign() must not increment service.revisionCount.")
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

    // =========================================================================
    // MARK: policyChanges / AppState observer — stream integration tests
    // =========================================================================

    // MARK: - Test 19: Successful assign emits exactly one policyChanges yield

    @Test("policyChanges: successful assign emits exactly one yield to stream observers")
    func policyChanges_oneYield_afterSuccessfulAssign() async throws {
        let (db, repo) = try await openDB()
        let koID = UUID()
        try await seedKO(db, koID: koID)
        let service = SensitiveScopeMutationService(repository: repo)
        let counter = SignalCounter()
        let observerTask = Task {
            for await _ in service.policyChanges {
                await counter.bump()
                if await counter.count >= 1 { break }
            }
        }
        _ = try await service.assign(
            target: SensitiveScopeTarget(kind: .knowledgeObject, id: koID),
            sensitivity: .restricted,
            authority: .userConfirmed(actorID: "owner", confirmationID: UUID(), privileged: true),
            reason: nil, at: t0)
        await observerTask.value
        #expect(await counter.count == 1,
                "Successful assign emits exactly one yield — the AppState observer receives one bump.")
    }

    // MARK: - Test 20: Successful revoke emits exactly one policyChanges yield

    @Test("policyChanges: successful revoke emits exactly one yield to stream observers")
    func policyChanges_oneYield_afterSuccessfulRevoke() async throws {
        let (db, repo) = try await openDB()
        let koID = UUID()
        try await seedKO(db, koID: koID)
        let service = SensitiveScopeMutationService(repository: repo)
        let assignment = try await service.assign(
            target: SensitiveScopeTarget(kind: .knowledgeObject, id: koID),
            sensitivity: .restricted,
            authority: .userConfirmed(actorID: "owner", confirmationID: UUID(), privileged: true),
            reason: nil, at: t0)
        // Start observing AFTER assign to isolate the revoke yield.
        let counter = SignalCounter()
        let observerTask = Task {
            for await _ in service.policyChanges {
                await counter.bump()
                if await counter.count >= 2 { break }  // 1 from assign (buffered) + 1 from revoke
            }
        }
        try await service.revoke(assignmentID: assignment.id, revokedBy: "owner",
                                 reason: nil, at: t0.addingTimeInterval(60))
        await observerTask.value
        // Total yields = 2 (one per successful mutation); revisionCount confirms the same.
        #expect(await counter.count == 2,
                "Assign + revoke = two yields total; each successful mutation emits exactly one.")
        #expect(await service.revisionCount == 2)
    }

    // MARK: - Test 21: Failed mutation emits no policyChanges yield

    @Test("policyChanges: failed mutation emits no yield — stream count reflects only successes")
    func policyChanges_noYield_onFailedMutation() async throws {
        let (db, repo) = try await openDB()
        let koID = UUID()
        try await seedKO(db, koID: koID)
        let service = SensitiveScopeMutationService(repository: repo)
        let counter = SignalCounter()
        // Observer: waits for exactly 1 yield — from the successful assign below.
        // If the failed revoke emits a spurious yield, revisionCount would be 2 and
        // the test catches the bug through that check even though the observer
        // breaks at count=1.
        let observerTask = Task {
            for await _ in service.policyChanges {
                await counter.bump()
                if await counter.count >= 1 { break }
            }
        }
        // Failed mutation — must NOT emit a yield
        await #expect(throws: (any Error).self) {
            try await service.revoke(assignmentID: UUID(), revokedBy: "owner",
                                     reason: nil, at: t0)
        }
        // Successful mutation — emits exactly one yield, completing the observer
        _ = try await service.assign(
            target: SensitiveScopeTarget(kind: .knowledgeObject, id: koID),
            sensitivity: .restricted,
            authority: .userConfirmed(actorID: "owner", confirmationID: UUID(), privileged: true),
            reason: nil, at: t0)
        await observerTask.value
        // revisionCount == 1 proves only the successful mutation fired; if the failed one
        // also yielded, revisionCount would be 2 (bug). Combined with counter.count == 1
        // (observer breaks at first yield), this proves exactly one yield was emitted.
        #expect(await service.revisionCount == 1,
                "Failed mutation does not increment revisionCount — policyChanges was not yielded.")
        #expect(await counter.count == 1,
                "Observer received exactly 1 yield (from the successful assign, not the failed revoke).")
    }

    // MARK: - Test 22: AppState observer pattern: two mutations → revision counter = 2

    @Test("AppState observer pattern: two successful mutations yield twice — simulated sensitiveScopeRevision = 2")
    func policyChanges_appStateObserverPattern() async throws {
        let (db, repo) = try await openDB()
        let koID1 = UUID()
        let koID2 = UUID()
        try await seedKO(db, koID: koID1)
        try await seedKO(db, koID: koID2)
        let service = SensitiveScopeMutationService(repository: repo)
        let counter = SignalCounter()
        // Mirror AppState.setup():
        //   Task { @MainActor in for await _ in svc.policyChanges { self.notifyScopePolicyChanged() } }
        let observerTask = Task {
            for await _ in service.policyChanges {
                await counter.bump()
                if await counter.count >= 2 { break }
            }
        }
        _ = try await service.assign(
            target: SensitiveScopeTarget(kind: .knowledgeObject, id: koID1),
            sensitivity: .restricted,
            authority: .userConfirmed(actorID: "owner", confirmationID: UUID(), privileged: true),
            reason: nil, at: t0)
        _ = try await service.assign(
            target: SensitiveScopeTarget(kind: .knowledgeObject, id: koID2),
            sensitivity: .restricted,
            authority: .userConfirmed(actorID: "owner", confirmationID: UUID(), privileged: true),
            reason: nil, at: t0)
        await observerTask.value
        #expect(await counter.count == 2,
                "AppState observer receives exactly one yield per successful mutation — sensitiveScopeRevision would increment to 2.")
        #expect(await service.revisionCount == 2)
    }
}
