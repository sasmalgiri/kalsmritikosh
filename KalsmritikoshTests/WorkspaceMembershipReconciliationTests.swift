//
//  WorkspaceMembershipReconciliationTests.swift
//  KalsmritikoshTests
//
//  PA-PROD Commit B2 — derived workspace membership reconciliation. Derived membership follows
//  the workspace's current sources (add on include, drop on remove) and NEVER deletes a
//  manually-curated member. Occurrence-based via entity_mentions; scoped, no leakage.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PA-PROD B2 — workspace membership reconciliation")
struct WorkspaceMembershipReconciliationTests {

    private struct Rig {
        let db: Database
        let workspaces: WorkspaceRepository
        let deriver: WorkspaceMembershipDeriver
    }
    private func rig() async throws -> Rig {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("wsm-\(UUID().uuidString).sqlite")
        let db = try Database(url: tmp)
        try await SchemaMigrations.migrate(db)
        let ws = WorkspaceRepository(database: db)
        return Rig(db: db, workspaces: ws, deriver: WorkspaceMembershipDeriver(database: db, workspaces: ws))
    }

    /// A file + KO + entity mentioned in that file. Returns the file id.
    @discardableResult
    private func seedMentionedEntity(_ r: Rig, entity: UUID) async throws -> UUID {
        let file = UUID(), ko = UUID()
        try await r.db.exec("INSERT INTO files (id, url, source_type) VALUES (?,?,?);",
                            [.uuid(file), .text("file://\(file)"), .text("txt")])
        try await r.db.exec("""
        INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at) VALUES (?,?,?,?,?,?);
        """, [.uuid(ko), .uuid(file), .text("txt"), .text("c"), .real(0), .real(0)])
        try await r.db.exec("INSERT INTO entities (id, kind, value, normalized, source_object_id) VALUES (?,?,?,?,?);",
                            [.uuid(entity), .text("person"), .text("S"), .text(entity.uuidString.lowercased()), .uuid(ko)])
        try await r.db.exec("""
        INSERT INTO entity_mentions (id, entity_id, kind, surface, normalized, source_object_id, confidence)
        VALUES (?,?,?,?,?,?,?);
        """, [.uuid(UUID()), .uuid(entity), .text("person"), .text("S"),
              .text(entity.uuidString.lowercased() + "-m"), .uuid(ko), .real(1.0)])
        return file
    }

    /// A bare entity (its own file/KO, no mention) — exists for the FK but is not occurrence-
    /// linked to any workspace, so it can only be a MANUAL member.
    private func seedBareEntity(_ r: Rig, entity: UUID) async throws {
        let file = UUID(), ko = UUID()
        try await r.db.exec("INSERT INTO files (id, url, source_type) VALUES (?,?,?);",
                            [.uuid(file), .text("file://\(file)"), .text("txt")])
        try await r.db.exec("""
        INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at) VALUES (?,?,?,?,?,?);
        """, [.uuid(ko), .uuid(file), .text("txt"), .text("c"), .real(0), .real(0)])
        try await r.db.exec("INSERT INTO entities (id, kind, value, normalized, source_object_id) VALUES (?,?,?,?,?);",
                            [.uuid(entity), .text("person"), .text("M"), .text(entity.uuidString.lowercased()), .uuid(ko)])
    }

    private func workspace(_ r: Rig) async throws -> Workspace.ID {
        let id = UUID()
        try await r.workspaces.upsert(Workspace(id: id, title: "WS", template: .general))
        return id
    }

    @Test("Adding a source adds its occurrence-linked entity to derived membership")
    func addingSourceAddsEntity() async throws {
        let r = try await rig()
        let entity = UUID()
        let file = try await seedMentionedEntity(r, entity: entity)
        let ws = try await workspace(r)
        try await r.workspaces.addSource(file, to: ws)
        try await r.deriver.deriveMembership(for: ws)
        #expect(try await r.workspaces.entityIDs(in: ws) == [entity])
    }

    @Test("Removing the source removes its derived membership")
    func removingSourceRemovesDerived() async throws {
        let r = try await rig()
        let entity = UUID()
        let file = try await seedMentionedEntity(r, entity: entity)
        let ws = try await workspace(r)
        try await r.workspaces.addSource(file, to: ws)
        try await r.deriver.deriveMembership(for: ws)
        #expect(try await r.workspaces.entityIDs(in: ws) == [entity])
        // Remove the source and re-reconcile → the derived member drops.
        try await r.workspaces.removeSource(file, from: ws)
        try await r.deriver.deriveMembership(for: ws)
        #expect(try await r.workspaces.entityIDs(in: ws).isEmpty)
    }

    @Test("A manually-added member survives reconciliation")
    func manualMemberSurvives() async throws {
        let r = try await rig()
        let manual = UUID(), derived = UUID()
        try await seedBareEntity(r, entity: manual)              // exists for the FK; not occurrence-linked
        let file = try await seedMentionedEntity(r, entity: derived)
        let ws = try await workspace(r)
        try await r.workspaces.addEntity(manual, to: ws)         // manual (workspace_entities)
        try await r.workspaces.addSource(file, to: ws)
        try await r.deriver.deriveMembership(for: ws)            // replaces DERIVED set only
        let members = Set(try await r.workspaces.entityIDs(in: ws))
        #expect(members == [manual, derived])
        // Even after the source (and its derived member) is removed, manual persists.
        try await r.workspaces.removeSource(file, from: ws)
        try await r.deriver.deriveMembership(for: ws)
        #expect(try await r.workspaces.entityIDs(in: ws) == [manual])
    }

    @Test("An entity in another workspace's source does not leak")
    func noCrossWorkspaceLeak() async throws {
        let r = try await rig()
        let entity = UUID()
        let file = try await seedMentionedEntity(r, entity: entity)
        let wsA = try await workspace(r)
        let wsB = try await workspace(r)
        try await r.workspaces.addSource(file, to: wsA)          // only A has the file
        try await r.deriver.deriveMembership(for: wsA)
        try await r.deriver.deriveMembership(for: wsB)
        #expect(try await r.workspaces.entityIDs(in: wsA) == [entity])
        #expect(try await r.workspaces.entityIDs(in: wsB).isEmpty)
    }
}
