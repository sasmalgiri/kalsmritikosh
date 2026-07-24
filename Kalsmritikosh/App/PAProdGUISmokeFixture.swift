//
//  PAProdGUISmokeFixture.swift
//  Kalsmritikosh
//
//  PA-PROD B5 — a DEBUG-ONLY disposable fixture for the manual GUI checkpoint. It exists ONLY
//  under `#if DEBUG` and only runs when the app is launched with `--pa-prod-gui-smoke`, so it can
//  never appear in a release build or the shipping UI.
//
//  It boots AppState against a throwaway SQLite database (bookmarked-root reingest suppressed),
//  wipes any prior smoke db/WAL/SHM, and seeds two clearly-named workspaces that exercise the two
//  ends of the production export boundary:
//
//   • "PA-PROD GUI — VALID"   — a claim seeded through the REAL path (file → KnowledgeObject →
//     source version → exact EvidenceBlock → entity mention → GenericFact →
//     ClaimProjectionBackfill.projectSource → derived membership). The claim is assertive and its
//     citation is reopenable, so a sourced summary + receipt must export cleanly. The SAME subject
//     also carries an OUT-OF-SCOPE SENTINEL claim backed only by a file that is NOT a workspace
//     source — it must never appear, proving the B4 source-boundary correction in the running app.
//
//   • "PA-PROD GUI — BLOCKED" — a deliberately CORRUPTED canonical claim seeded directly (NOT via
//     the producer, which correctly drops unreopenable evidence): assertive assessment, a valid
//     workspace subject + KnowledgeObject, a non-nil block id (so policy renders it assertively),
//     and `sourceVersionID == nil`. The renderer treats that as unresolved and the fail-closed
//     production validator blocks the export — report and receipt alike, before any save panel.
//

#if DEBUG
import Foundation
import os

@MainActor
enum PAProdGUISmokeFixture {

    static let launchArgument = "--pa-prod-gui-smoke"

    static var isRequested: Bool { CommandLine.arguments.contains(launchArgument) }

    /// A disposable database under the temp directory — never the user's real archive.
    static var databaseURL: URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pa-prod-gui-smoke.sqlite")
    }

    /// Wipe any prior smoke database (+ WAL/SHM), boot AppState against the disposable file with
    /// bookmarked-root reingest suppressed, then seed the VALID and BLOCKED workspaces.
    static func bootAndSeed(_ appState: AppState) async {
        wipeDatabaseFiles()
        await appState.boot(databaseURL: databaseURL, suppressAutoReingest: true)
        guard case .ready = appState.phase,
              let db = appState.database,
              let store = appState.evidenceStore,
              let workspaces = appState.workspaces,
              let projection = appState.claimProjection else {
            KalsmritikoshLog.app.error("PA-PROD GUI smoke: AppState not ready — cannot seed fixture")
            return
        }
        let facts = GenericFactRepository(database: db)
        let claims = ClaimRepository(database: db)
        let deriver = WorkspaceMembershipDeriver(database: db, workspaces: workspaces)
        do {
            try await seedValidWorkspace(db: db, store: store, facts: facts,
                                         workspaces: workspaces, projection: projection)
            try await seedBlockedWorkspace(db: db, workspaces: workspaces, deriver: deriver, claims: claims)
            KalsmritikoshLog.app.info("PA-PROD GUI smoke: seeded VALID + BLOCKED workspaces at \(databaseURL.path, privacy: .public)")
        } catch {
            KalsmritikoshLog.app.error("PA-PROD GUI smoke: seeding failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - VALID workspace

    private static func seedValidWorkspace(db: Database, store: EvidenceStore, facts: GenericFactRepository,
                                           workspaces: WorkspaceRepository,
                                           projection: ClaimProjectionBackfill) async throws {
        let workspaceID = UUID()
        try await workspaces.upsert(Workspace(id: workspaceID, title: "PA-PROD GUI — VALID", template: .general))

        // In-scope source: file → KO (the workspace source), entity + mention anchored to it.
        let file = UUID(), ko = UUID(), subject = UUID()
        try await insertFileAndKO(db, file: file, ko: ko, filename: "valid-contract.txt",
                                  content: "Contract signed by Alex Rivera on 2025-03-01.")
        try await insertEntityWithMention(db, entity: subject, ko: ko, value: "Alex Rivera", normalized: "alex rivera")

        // A reopenable source persisted the SAME way production does: source version keyed at the
        // FILE (logical-source) level, plus an explicit block→KnowledgeObject ownership link (B6).
        // The block therefore resolves to its real KnowledgeObject (inside the workspace).
        let inScopeBlock = try await persistBlock(store, file: file, ko: ko, filename: "valid-contract.txt",
                                                  text: "Contract signed by Alex Rivera on 2025-03-01.")
        try await facts.upsert(GenericFact(
            subjectID: subject, subjectLabel: "Alex Rivera",
            field: "event", value: "signed the contract on 2025-03-01",
            assessment: EvidenceAssessment(basis: .directlyObserved, origin: .sourceExtraction),
            confidence: 0.95, sourceBlockIDs: [inScopeBlock]))

        // OUT-OF-SCOPE SENTINEL: same subject, a claim backed ONLY by a file that is NOT a workspace
        // source. It is produced into the ledger but must be excluded from this workspace's export.
        let outFile = UUID(), outKO = UUID()
        try await insertFileAndKO(db, file: outFile, ko: outKO, filename: "unrelated.txt",
                                  content: "Unrelated material.")
        let outBlock = try await persistBlock(store, file: outFile, ko: outKO, filename: "unrelated.txt",
                                              text: "OUT-OF-SCOPE SENTINEL — MUST NOT APPEAR")
        try await facts.upsert(GenericFact(
            subjectID: subject, subjectLabel: "Alex Rivera",
            field: "note", value: "OUT-OF-SCOPE SENTINEL — MUST NOT APPEAR",
            assessment: EvidenceAssessment(basis: .directlyObserved, origin: .sourceExtraction),
            confidence: 0.95, sourceBlockIDs: [outBlock]))

        // Drive the LIVE production path: add the in-scope file as a workspace source, then let the
        // shared projection actor produce claims for the subject and reconcile derived membership.
        try await workspaces.addSource(file, to: workspaceID)
        await projection.projectSource(fileID: file, at: Date())
    }

    // MARK: - BLOCKED workspace

    private static func seedBlockedWorkspace(db: Database, workspaces: WorkspaceRepository,
                                             deriver: WorkspaceMembershipDeriver,
                                             claims: ClaimRepository) async throws {
        let workspaceID = UUID()
        try await workspaces.upsert(Workspace(id: workspaceID, title: "PA-PROD GUI — BLOCKED", template: .general))

        let file = UUID(), ko = UUID(), subject = UUID()
        try await insertFileAndKO(db, file: file, ko: ko, filename: "blocked-source.txt",
                                  content: "Jordan Blake authorized the wire transfer.")
        try await insertEntityWithMention(db, entity: subject, ko: ko, value: "Jordan Blake", normalized: "jordan blake")
        try await workspaces.addSource(file, to: workspaceID)
        try await deriver.deriveMembership(for: workspaceID)   // subject becomes a derived member

        // A deliberately CORRUPTED canonical claim (seeded directly, never through the producer):
        // assertive + a valid in-workspace evidence object + a non-nil block id (so it renders
        // assertively) but sourceVersionID == nil, so its citation cannot be reopened. This is the
        // fail-closed export boundary's intended trigger — NOT a real, reopenable claim.
        let corrupt = Claim(
            subjectID: subject, subjectLabel: "Jordan Blake",
            statement: "authorized the wire transfer",
            assessment: EvidenceAssessment(basis: .directlyObserved, origin: .sourceExtraction),
            confidence: 0.9,
            evidence: [EvidenceReference(objectID: ko, blockID: UUID(), sourceVersionID: nil)],
            createdAt: Date())
        try await claims.save(corrupt)
    }

    // MARK: - Seeding primitives

    private static func insertFileAndKO(_ db: Database, file: UUID, ko: UUID,
                                        filename: String, content: String) async throws {
        try await db.exec("INSERT INTO files (id, url, source_type) VALUES (?,?,?);",
                          [.uuid(file), .text("file:///pa-prod-gui/\(filename)"), .text("txt")])
        try await db.exec("""
        INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at)
        VALUES (?,?,?,?,?,?);
        """, [.uuid(ko), .uuid(file), .text("txt"), .text(content), .real(0), .real(0)])
    }

    private static func insertEntityWithMention(_ db: Database, entity: UUID, ko: UUID,
                                                value: String, normalized: String) async throws {
        try await db.exec("INSERT INTO entities (id, kind, value, normalized, source_object_id) VALUES (?,?,?,?,?);",
                          [.uuid(entity), .text("person"), .text(value), .text(normalized), .uuid(ko)])
        try await db.exec("""
        INSERT INTO entity_mentions (id, entity_id, kind, surface, normalized, source_object_id, confidence)
        VALUES (?,?,?,?,?,?,?);
        """, [.uuid(UUID()), .uuid(entity), .text("person"), .text(value),
              .text(normalized), .uuid(ko), .real(1.0)])
    }

    /// Persist a one-block source version the SAME way production ingest does — the source version's
    /// `logical_source_id` is the FILE id — then record the canonical block→KnowledgeObject ownership
    /// link (B6). The block therefore resolves through the exact production path. Returns the block id.
    private static func persistBlock(_ store: EvidenceStore, file: UUID, ko: UUID,
                                     filename: String, text: String) async throws -> UUID {
        let docID = UUID(), versionID = UUID(), blockID = UUID()
        let block = EvidenceBlock(id: blockID, documentID: docID, ordinal: 0, kind: .paragraph, rawText: text)
        let doc = ParsedDocument(id: docID, logicalSourceID: file, sourceVersionID: versionID,
                                 filename: filename, detectedType: .txt, contentHash: "pa-prod-\(blockID.uuidString)",
                                 blocks: [block])
        try await store.persist(doc, parser: "pa-prod-gui-fixture", parserVersion: "1", startedAt: Date())
        try await store.linkBlocks([blockID], toObject: ko, at: Date())   // B6 canonical ownership
        return blockID
    }

    private static func wipeDatabaseFiles() {
        let fm = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let url = URL(fileURLWithPath: databaseURL.path + suffix)
            try? fm.removeItem(at: url)
        }
    }
}
#endif
