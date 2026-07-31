//
//  USF001UniversalSafeIntakeBoundaryTests.swift
//  KalsmritikoshTests
//
//  USF-001 — architecture boundaries: one source/version authority (no second identity
//  table), EvidenceStore never creates source identity, KnowledgeObject/Chunk stay
//  projections, unsupported inputs remain visible without a source document, and the
//  intake subsystem introduces no readiness model, parser-registry redesign, UI/LLM/
//  network dependency, Claim creation, or concrete method — and leaves PM-004 untouched.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("USF-001 — universal safe intake boundary guards", .serialized)
struct USF001UniversalSafeIntakeBoundaryTests {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }
    private static func source(_ rel: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(rel), encoding: .utf8)
    }
    private static func intakeFiles() throws -> [(name: String, text: String)] {
        let dir = repoRoot.appendingPathComponent("Kalsmritikosh/Ingestion/Intake")
        var out: [(String, String)] = []
        let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        while let url = e?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            out.append((url.lastPathComponent, try String(contentsOf: url, encoding: .utf8)))
        }
        return out
    }

    // MARK: - One authority

    @Test("The v82 migration creates no second logical-source or version authority table")
    func noSecondSourceAuthorityTable() throws {
        let schema = try Self.source("Kalsmritikosh/Storage/Schema/SchemaMigrations.swift")
        // grab just the v82 DDL
        let v82 = schema.range(of: "private static let v82").map { String(schema[$0.lowerBound...]) } ?? ""
        for forbidden in ["CREATE TABLE logical_sources", "CREATE TABLE source_identities",
                          "CREATE TABLE source_version_records", "CREATE TABLE canonical_sources"] {
            #expect(!v82.contains(forbidden), "v82 must not create a competing authority (\(forbidden))")
        }
    }

    @Test("A fresh v82 database has files + source_versions and no competing identity table")
    func oneVersionAuthorityAtRuntime() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 82)
        #expect(try await MigrationFixtureBuilder.tableExists(db, "source_versions"))
        #expect(try await MigrationFixtureBuilder.tableExists(db, "files"))
        for t in ["logical_sources", "source_identities", "canonical_sources"] {
            #expect(try await MigrationFixtureBuilder.tableExists(db, t) == false)
        }
    }

    @Test("EvidenceStore never writes the files table (it cannot create logical-source identity)")
    func evidenceStoreCreatesNoFileIdentity() throws {
        let store = try Self.source("Kalsmritikosh/Storage/Repositories/EvidenceStore.swift")
        #expect(!store.contains("INSERT INTO files"))
        #expect(!store.contains("INSERT OR REPLACE INTO files"))
    }

    @Test("The intake repository writes no KnowledgeObject or Chunk table (they stay projections)")
    func knowledgeObjectAndChunkStayProjections() throws {
        let repo = try Self.source("Kalsmritikosh/Ingestion/Intake/CanonicalSourceIntakeRepository.swift")
        for t in ["knowledge_objects", "chunks", "INSERT INTO evidence_blocks"] {
            #expect(!repo.contains(t), "intake must not write '\(t)'")
        }
    }

    // MARK: - Visibility without understanding

    @Test("An unsupported input receives a source version but no source document")
    func unsupportedInputHasNoSourceDocument() async throws {
        let rig = try await USF001Fixtures.makeRig()
        let url = try USF001Fixtures.writeFile(rig, name: "mystery.zzz", bytes: Data([0x01, 0x02, 0x03]))
        _ = try await USF001Fixtures.intake(rig, url: url)
        #expect(try await rig.db.query("SELECT COUNT(*) FROM source_versions;", []).first?.int(0) == 1)
        #expect(try await rig.db.query("SELECT COUNT(*) FROM source_documents;", []).first?.int(0) == 0)
    }

    // MARK: - No scope creep

    @Test("The intake subsystem introduces no readiness model and no parser-registry redesign")
    func noReadinessOrParserRegistry() throws {
        for (name, text) in try Self.intakeFiles() {
            for token in ["Readiness", "ParserRegistry", "ParserPlugin", "LoaderRegistry"] {
                #expect(!text.contains(token), "\(name) must not introduce '\(token)' (deferred to later USF units)")
            }
        }
    }

    @Test("The intake subsystem has no UI, LLM or network dependency")
    func intakeNoLLMUINetwork() throws {
        for (name, text) in try Self.intakeFiles() {
            for token in ["import SwiftUI", "import AppKit", "URLSession", "http://", "https://",
                          "Ollama", "LLMClient", "prompt("] {
                #expect(!text.contains(token), "\(name) must not reference '\(token)'")
            }
        }
    }

    @Test("The intake subsystem creates no Claim and no concrete professional method")
    func intakeNoClaimNoMethod() throws {
        for (name, text) in try Self.intakeFiles() {
            for token in ["Claim(", "ClaimRepository", "confirmFact", "GenericFact(",
                          "FiveWhys", "Fishbone", "CAPA"] {
                #expect(!text.contains(token), "\(name) must not reference '\(token)'")
            }
        }
    }

    @Test("PM-004 lifecycle boundaries are unchanged (method ledger intact at v82)")
    func pm004Untouched() async throws {
        #expect(SchemaMigrations.latestVersion == 82)
        let db = try await MigrationFixtureBuilder.database(atVersion: 82)
        for t in ["method_runs", "method_reviews", "method_validation_results", "method_run_events"] {
            #expect(try await MigrationFixtureBuilder.tableExists(db, t))
        }
    }
}
