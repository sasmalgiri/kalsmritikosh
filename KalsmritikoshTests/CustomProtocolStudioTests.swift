//
//  CustomProtocolStudioTests.swift
//  KalsmritikoshTests
//
//  Conformance roadmap 2.0 — the Custom Protocol Studio (shipped OFF). The
//  testable core: structure → deterministic build → the SAME activation gate
//  as any pack (compile check = export → verify) → signed pack → registry.
//  The feature flag defaults OFF so a vanilla install shows no authoring UI.
//

import Foundation
import Testing
import CryptoKit
@testable import Kalsmritikosh

@MainActor
@Suite("Custom Protocol Studio — build, compile, sign, register")
struct CustomProtocolStudioTests {

    private let now = Date(timeIntervalSince1970: 1_756_000_000)

    @Test("The studio ships OFF")
    func flagDefaultsOff() {
        UserDefaults.standard.removeObject(forKey: FeatureFlags.customProtocolStudioKey)
        #expect(FeatureFlags.customProtocolStudioValue() == false)
    }

    @Test("Structure builds a custom constitution; empty structure refuses")
    func buildRequiresStructure() {
        let model = CustomProtocolStudioModel()
        #expect(model.buildSutra() == nil, "no title/identifier yet")
        model.title = "ACME HR Investigations"
        model.identifier = "sutra.acme.hr"
        model.globalRequirementsText = "Every claim in the deliverable carries its evidence\n"
        let sutra = model.buildSutra()
        #expect(sutra != nil)
        #expect(sutra?.citation == "ACME HR Investigations v1 · sutra.acme.hr")
        #expect(sutra?.globalRequirements == ["Every claim in the deliverable carries its evidence"])
        // The seeded skeleton carries the standard phases; excluding all refuses.
        for i in model.phaseEdits.indices { model.phaseEdits[i].include = false }
        #expect(model.buildSutra() == nil)
    }

    @Test("Compile check runs the same gate that guards activation")
    func compileCheck() {
        let model = CustomProtocolStudioModel()
        model.title = "ACME HR Investigations"
        model.identifier = "sutra.acme.hr"
        switch model.compileCheck(at: now) {
        case .success(let rules): #expect(rules > 0)
        case .failure(let error): Issue.record("compile check refused: \(error)")
        }
    }

    @Test("Signed pack round-trips through verify and the registry")
    func signRegisterActivate() async throws {
        let model = CustomProtocolStudioModel()
        model.title = "ACME HR Investigations"
        model.identifier = "sutra.acme.hr"
        model.publisher = "ACME Corp"
        model.assurance = "organization-approved"
        let data = try model.signedPack(at: now)
        let (pack, sutra) = try ProtocolPacks.verify(data)
        #expect(pack.envelope.publisher == "ACME Corp")
        #expect(pack.envelope.assurance == "organization-approved")
        #expect(sutra.id == "sutra.acme.hr")

        // Register + activate: the custom constitution now governs new runs for
        // ITS id — the built-in doctrine is untouched.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("studio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try Database(url: dir.appendingPathComponent("db.sqlite"))
        try await SchemaMigrations.migrate(db)
        let repo = ProtocolRegistryRepository(database: db)
        let row = try await repo.importPack(pack, at: now)
        try await repo.activate(id: row.id, at: now)
        let active = try await repo.activeSutra(id: "sutra.acme.hr")
        #expect(active?.citation == sutra.citation)
        #expect(try await repo.activeSutra(id: SutraCompiler.shared().id) == nil,
                "the built-in doctrine's id must remain ungoverned")

        // And the custom constitution assesses like any other — fail-closed.
        let facts = ConformanceFacts(completedPhaseKinds: [.findings],
                                     standardOfProofDeclared: true,
                                     openItemsAcknowledged: true,
                                     humanDecisionsMade: [.findings])
        let a = SutraConformance.assess(facts: facts, against: sutra, at: now)
        #expect(a.status == .indeterminate, "unattested custom rules block conformance too")
    }
}
