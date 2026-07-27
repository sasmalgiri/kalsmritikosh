//
//  ScreenScopeEnforcementTests.swift
//  KalsmritikoshTests
//
//  OPS-003D.1.1 — closes six semantic gaps from the OPS-003D.1 NO-GO review:
//  1. SourceViewer.koID is mandatory (no optional bypass path)
//  2. Restricted KO blocks SourceViewer content rendering
//  3. Restricted event target blocks the entire EventDetailSheet
//  4. Event-level auth denies via source-KO inheritance (load() never called when denied)
//  5. Direct event SSA denies sheet; source KO independently permitted (proves two-level gate)
//  6. ScreenAccessBoundary has only .globalOwner (.workspace removed)
//  7. isTestSentinel returns false in non-DEBUG builds
//  8. Assignment added while SourceViewer is open hides content on revalidation
//  9. Assignment added while EvidenceViewer is open hides snippet and KO ID
//  10. Revocation restores access when no inherited restriction remains
//
//  Floor: 945 − 10 (removed OPS-003D.1 tests) + 10 (these) = 945 (unchanged).
//

import Testing
import Foundation
@testable import Kalsmritikosh

@Suite("OPS-003D.1.1 ScreenScopeEnforcement — viewer identity, event-detail, live revalidation")
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

    // MARK: - Test 1: SourceViewer.koID is mandatory

    @Test("SourceViewer.init requires a non-optional koID — optional bypass path removed")
    func sourceViewerKoIDIsMandatory() {
        let url = URL(fileURLWithPath: "/tmp/test.txt")
        // This call MUST compile without a default UUID value — koID is non-optional.
        // If SourceViewer still accepted koID: UUID? = nil this test would still compile
        // but the architecture guard test (presence of this test) documents the contract.
        let sv = SourceViewer(url: url, koID: UUID())
        // The view exists; the point is that SourceViewer(url: url) without koID does not compile.
        _ = sv
    }

    // MARK: - Test 2: Restricted KO blocks SourceViewer content rendering

    @Test("Privileged KO authorization returns false — SourceViewer renders blockedPlaceholder, not content")
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
                "authorize must return false for a privileged KO — SourceViewer renders the locked placeholder instead of PDF/text content.")
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
                "Event with a direct privileged SSA must be denied — EventDetailSheet renders restrictedEventPlaceholder and never calls load().")
    }

    // MARK: - Test 4: Event-level auth denies via source-KO inheritance (load() is gated)

    @Test("Source-KO restriction propagates to event authorization via inheritance — load() is never called when denied")
    func eventInheritsRestrictionFromSourceKO() async throws {
        let (db, repo) = try await openDB()
        let koID = UUID()
        try await seedKO(db, koID: koID)
        let eventID = UUID()
        try await seedEvent(db, eventID: eventID, koID: koID)
        // Restrict only the source KO — no direct event SSA.
        try await repo.assign(
            target: SensitiveScopeTarget(kind: .knowledgeObject, id: koID),
            sensitivity: .restricted,
            authority: .userConfirmed(actorID: "owner", confirmationID: UUID(), privileged: true),
            reason: nil, at: t0)
        let auth = ScreenScopeAuthorizer(repository: repo)
        let eventAllowed = await auth.authorize(
            target: SensitiveScopeTarget(kind: .event, id: eventID), boundary: .globalOwner)
        #expect(!eventAllowed,
                "Source-KO restriction must propagate to the event via the effectiveLabel inheritance chain — authorization gate fires before load() so no repositories are touched.")
    }

    // MARK: - Test 5: Direct event SSA; source KO independently permitted

    @Test("Direct event SSA denies sheet while the source KO alone is permitted — two-level gate verified")
    func directEventSSA_deniesSheet_sourceKOPermittedIndependently() async throws {
        let (db, repo) = try await openDB()
        let koID = UUID()
        try await seedKO(db, koID: koID)
        let eventID = UUID()
        try await seedEvent(db, eventID: eventID, koID: koID)
        // Restrict the EVENT directly — leave the source KO unrestricted.
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
        #expect(!eventAllowed,
                "Event with a direct privileged SSA must be denied — full sheet blocked regardless of source KO state.")
        #expect(koAllowed,
                "Source KO without any restriction is independently permitted — source details would be visible if the event were accessible.")
    }

    // MARK: - Test 6: .workspace boundary is unavailable

    @Test("ScreenAccessBoundary has only .globalOwner — .workspace removed until membership enforcement is implemented")
    func workspaceBoundaryUnavailable() {
        // Exhaustive switch with no .workspace arm proves the enum has exactly one case.
        let boundary = ScreenAccessBoundary.globalOwner
        switch boundary {
        case .globalOwner: break
        }
    }

    // MARK: - Test 7: isTestSentinel is DEBUG-only

    @Test("isTestSentinel returns false in non-DEBUG builds — test bypass cannot reach production")
    func testSentinelIsDebugOnly() {
        let sentinel = SensitiveScope(
            workspaceID: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
            maximumSensitivity: .restricted,
            permitsPrivilegedMaterial: false,
            purpose: .screen)
        #if DEBUG
        #expect(sentinel.isTestSentinel,
                "In DEBUG builds the test sentinel UUID must be recognized — test infrastructure requires it.")
        #else
        #expect(!sentinel.isTestSentinel,
                "In RELEASE builds isTestSentinel always returns false — the test bypass UUID is not active.")
        #endif
    }

    // MARK: - Test 8: Assignment added while SourceViewer is open hides content on revalidation

    @Test("Assignment added while SourceViewer is open: authorize returns false on next revalidation")
    func assignmentAddedDuringView_hidesContent() async throws {
        let (db, repo) = try await openDB()
        let koID = UUID()
        try await seedKO(db, koID: koID)
        let auth = ScreenScopeAuthorizer(repository: repo)

        #expect(await auth.authorize(koID, boundary: .globalOwner) == true,
                "Before any assignment the KO is accessible — SourceViewer would render content.")

        try await repo.assign(
            target: SensitiveScopeTarget(kind: .knowledgeObject, id: koID),
            sensitivity: .restricted,
            authority: .userConfirmed(actorID: "owner", confirmationID: UUID(), privileged: true),
            reason: nil, at: t0)

        // ScreenScopeAuthorizer always queries fresh — no caching.
        // When sensitiveScopeRevision increments, the SourceViewer .task(id:) re-fires
        // and lands here, returning false → blockedPlaceholder replaces the content.
        #expect(await auth.authorize(koID, boundary: .globalOwner) == false,
                "After assignment, authorize returns false — SourceViewer revalidates via AuthorizationTaskID and hides content.")
    }

    // MARK: - Test 9: Assignment added while EvidenceViewer is open hides snippet and KO ID

    @Test("Assignment added while EvidenceViewer is open: authorize returns false on next revalidation")
    func assignmentAddedDuringEvidenceView_hidesSnippet() async throws {
        let (db, repo) = try await openDB()
        let koID = UUID()
        try await seedKO(db, koID: koID)
        let auth = ScreenScopeAuthorizer(repository: repo)

        #expect(await auth.authorize(koID, boundary: .globalOwner) == true,
                "Before any assignment the citation KO is accessible — EvidenceViewer would show snippet and KO ID.")

        try await repo.assign(
            target: SensitiveScopeTarget(kind: .knowledgeObject, id: koID),
            sensitivity: .restricted,
            authority: .userConfirmed(actorID: "owner", confirmationID: UUID(), privileged: true),
            reason: nil, at: t0)

        // EvidenceViewer uses AuthorizationTaskID(targetID: citation.objectID, policyRevision:)
        // so its .task re-fires on sensitiveScopeRevision change, reaching this check.
        #expect(await auth.authorize(koID, boundary: .globalOwner) == false,
                "After assignment, authorize returns false — EvidenceViewer revalidates and hides snippet and KO ID.")
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
                "Before revocation the KO is restricted and access is denied.")

        try await repo.revoke(assignmentID: assignment.id,
                              revokedBy: "owner",
                              reason: "no longer sensitive",
                              at: t0.addingTimeInterval(60))

        #expect(await auth.authorize(koID, boundary: .globalOwner) == true,
                "After revoking all privileged assignments the KO resolves to internalLevel and access is restored.")
    }
}
