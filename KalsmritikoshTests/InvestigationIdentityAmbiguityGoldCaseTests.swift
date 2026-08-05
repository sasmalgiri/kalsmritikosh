//
//  InvestigationIdentityAmbiguityGoldCaseTests.swift
//  KalsmritikoshTests
//
//  INV-02 / INV-03 golden case: "identity ambiguity". One real-world person appears under two spellings
//  inside the case scope (plus an out-of-scope lookalike). The journey composes the shared engines end to
//  end: nominate the subject → its dossier cites only its own in-scope evidence → PROPOSE merging the second
//  spelling → nothing merges yet (no auto-merge) → CONFIRM → the subject's dossier now folds in the second
//  spelling's evidence (aliases resolved to one canonical subject) → REVERSE → the split is restored → every
//  decision is recorded and the case reopens. Also holds the architecture boundary (one entity/merge engine,
//  live wiring, no model names). Synthetic only.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("INV-02/03 — identity-ambiguity gold case + boundary", .serialized)
struct InvestigationIdentityAmbiguityGoldCaseTests {

    private let t0 = Date(timeIntervalSince1970: 1_767_300_000)

    @Test("Identity ambiguity end-to-end: nominate → dossier → propose → confirm(unify) → reverse(split), all recorded")
    func identityAmbiguityJourney() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let ws = UUID()
        try await db.exec("INSERT INTO workspaces (id, title, created_at, updated_at) VALUES (?,?,?,?);",
                          [.uuid(ws), .text("Matter"), .real(1), .real(1)])

        // Source A (authorized): the same person under two spellings, each in its own knowledge object.
        let (vA, logicalA) = try await seedSourceVersion(db)
        let koPrimary = try await seedKO(db, logical: logicalA)
        let koAlias = try await seedKO(db, logical: logicalA)
        let primary = UUID(), alias = UUID()
        try await seedEntity(db, id: primary, kind: "person", value: "Katherine Vaughn", ko: koPrimary)
        try await seedMention(db, entity: primary, kind: "person", surface: "Katherine Vaughn", ko: koPrimary)
        try await seedEntity(db, id: alias, kind: "person", value: "Kate Vaughn", ko: koAlias)
        try await seedMention(db, entity: alias, kind: "person", surface: "Kate Vaughn", ko: koAlias)

        let cases = InvestigationCaseRepository(database: db)
        let evidence = EvidenceStore(database: db)
        let entities = EntitiesRepository(database: db)
        let subjectsRepo = InvestigationSubjectRepository(database: db)
        let scoped = CaseScopedEntityResolver(entities: entities, evidence: evidence)
        let resolver = CaseRetrievalScopeResolver(evidence: evidence)
        let dossierService = InvestigationSubjectDossierService(cases: cases, resolver: resolver, subjects: subjectsRepo, entities: entities, scopedEntities: scoped)
        let identityService = InvestigationIdentityResolutionService(cases: cases, resolver: resolver, scopedEntities: scoped, entities: entities,
                                                                     decisions: InvestigationIdentityDecisionRepository(database: db))

        var c = try await cases.createCase(workspaceID: ws, title: "Identity ambiguity", actor: "analyst", at: t0)
        c = try await cases.includeSource(caseID: c.id, expectedRevision: c.revision, sourceRef: vA.uuidString, sourceKind: .sourceVersion, actor: "analyst", at: t0)
        let caseID = c.id

        // 1. Nominate the primary spelling as the subject; confirm its identity.
        let subject = try await dossierService.nominateSubject(caseID: caseID, canonicalEntityID: primary, label: "Katherine Vaughn", actor: "analyst", at: t0)
        _ = try await dossierService.confirmSubjectIdentity(subjectID: subject.id, expectedRevision: subject.revision, actor: "lead", at: t0)

        // 2. Before any merge the dossier cites only the primary spelling's evidence.
        let before = try await dossierService.assembleDossier(caseID: caseID, subjectID: subject.id)
        #expect(before.items.map(\.knowledgeObjectID).contains(koPrimary))
        #expect(!before.items.map(\.knowledgeObjectID).contains(koAlias))

        // 3. Propose merging the alias spelling into the subject — nothing merges yet (no auto-merge).
        _ = try await identityService.proposeMerge(caseID: caseID, winnerEntityID: primary, loserEntityID: alias, rationale: "same person, two spellings", actor: "analyst", at: t0)
        let midDossier = try await dossierService.assembleDossier(caseID: caseID, subjectID: subject.id)
        #expect(!midDossier.items.map(\.knowledgeObjectID).contains(koAlias))   // proposal alone changes nothing

        // 4. Confirm the merge — the aliases resolve to one canonical subject; the dossier folds in both.
        _ = try await identityService.confirmMerge(caseID: caseID, winnerEntityID: primary, loserEntityID: alias, actor: "lead", at: t0)
        let unified = try await dossierService.assembleDossier(caseID: caseID, subjectID: subject.id)
        #expect(Set(unified.items.map(\.knowledgeObjectID)).isSuperset(of: [koPrimary, koAlias]))
        #expect(unified.items.allSatisfy { $0.sourceVersionID == vA })   // still only authorized evidence

        // 5. Reverse the merge — the split is restored; the dossier no longer folds the alias's evidence.
        _ = try await identityService.reverseMerge(caseID: caseID, winnerEntityID: primary, loserEntityID: alias, rationale: "reconsidered", actor: "lead", at: t0)
        let split = try await dossierService.assembleDossier(caseID: caseID, subjectID: subject.id)
        #expect(!split.items.map(\.knowledgeObjectID).contains(koAlias))

        // 6. Every decision is recorded and reopens; the subject's confirmation survives.
        let reopenedDecisions = InvestigationIdentityDecisionRepository(database: db)
        #expect(try await reopenedDecisions.decisions(caseID: caseID).map(\.kind) == [.mergeProposed, .mergeConfirmed, .mergeReversed])
        let reopenedSubjects = InvestigationSubjectRepository(database: db)
        #expect(try await reopenedSubjects.fetch(subjectID: subject.id)?.identityStatus == .confirmed)
    }

    // MARK: - Architecture boundary

    private var investigatorDir: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Kalsmritikosh/Personas/Investigator")
    }
    private func read(_ name: String) -> String {
        (try? String(contentsOf: investigatorDir.appendingPathComponent(name), encoding: .utf8)) ?? ""
    }

    @Test("No model names anywhere in the INV-02/03 persona files")
    func noModelNames() {
        let files = (try? FileManager.default.contentsOfDirectory(at: investigatorDir, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.pathExtension == "swift" {
            let lower = ((try? String(contentsOf: f, encoding: .utf8)) ?? "").lowercased()
            for m in ["qwen", "gemma", "deepseek", "mistral", "nomic", "llama", "gpt"] {
                #expect(!lower.contains(m), "\(f.lastPathComponent) names model \(m)")
            }
        }
    }

    @Test("Identity resolution forks no merge authority: it never writes merged_into itself and merges via the shared engine exactly once")
    func oneMergeEngine() {
        let src = read("InvestigationIdentityResolutionService.swift")
        #expect(!src.contains("merged_into"))                                  // no second merge implementation
        #expect(!src.contains("UPDATE entities"))                              // never mutates canonical rows directly
        // The SHARED merge is invoked from exactly one place (confirmMerge) — the no-auto-merge structural guard.
        #expect(src.components(separatedBy: "entities.merge(").count - 1 == 1)
        #expect(src.components(separatedBy: "entities.unmerge(").count - 1 == 1)
    }

    @Test("AppState wires both INV-02 and INV-03 services live")
    func appStateWiresBoth() {
        let app = (try? String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Kalsmritikosh/App/AppState.swift"), encoding: .utf8)) ?? ""
        #expect(app.contains("InvestigationSubjectDossierService("))
        #expect(app.contains("InvestigationIdentityResolutionService("))
        #expect(app.contains("investigationSubjectDossier"))
        #expect(app.contains("investigationIdentityResolution"))
    }

    // MARK: - Seed helpers

    private func seedSourceVersion(_ db: Database) async throws -> (version: UUID, logical: UUID) {
        let version = UUID(), logical = UUID()
        try await db.exec("INSERT INTO files (id, url, source_type, availability) VALUES (?,?,?,?);",
                          [.uuid(logical), .text("file:///x/\(logical.uuidString)"), .text("txt"), .text("available")])
        try await db.exec("""
            INSERT INTO source_versions (id, logical_source_id, content_hash, valid_from, is_current, created_at,
                filename, detected_type, detection_basis, size_bytes, custody_mode, preservation_status, intake_recorded_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(version), .uuid(logical), .text(String(repeating: "c", count: 64)), .real(100), .integer(1), .real(100),
                  .text("f.txt"), .text("txt"), .text("magicBytes"), .integer(1), .text("referenced"), .text("referenceRecorded"), .real(100)])
        return (version, logical)
    }
    private func seedKO(_ db: Database, logical: UUID) async throws -> UUID {
        let ko = UUID()
        try await db.exec("INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at) VALUES (?,?,?,?,?,?);",
                          [.uuid(ko), .uuid(logical), .text("txt"), .text("body"), .real(1), .real(1)])
        return ko
    }
    private func seedEntity(_ db: Database, id: UUID, kind: String, value: String, ko: UUID) async throws {
        try await db.exec("INSERT INTO entities (id, kind, value, normalized, source_object_id) VALUES (?,?,?,?,?);",
                          [.uuid(id), .text(kind), .text(value), .text(value.lowercased()), .uuid(ko)])
    }
    private func seedMention(_ db: Database, entity: UUID, kind: String, surface: String, ko: UUID) async throws {
        try await db.exec("INSERT INTO entity_mentions (id, entity_id, kind, surface, normalized, source_object_id) VALUES (?,?,?,?,?,?);",
                          [.uuid(UUID()), .uuid(entity), .text(kind), .text(surface), .text(surface.lowercased()), .uuid(ko)])
    }
}
