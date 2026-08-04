//
//  InvestigationScopeFingerprintTests.swift
//  KalsmritikoshTests
//
//  INV-01-C4 — the canonical case-scope fingerprint + staleness ledger. Proves the fingerprint is
//  deterministic, order-independent, and changes exactly when the authorized scope or case revision
//  changes; that the ledger records the fingerprint an artifact was produced under immutably and detects
//  staleness when the case's current fingerprint differs; that a historical artifact is never rewritten;
//  and — the ONE-system guarantee — that the Ask scope context's fingerprint is exactly what the shared
//  CaseScopeFingerprinter produces for the same case scope (no per-engine fingerprint). Synthetic only.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("INV-01-C4 — case-scope fingerprint + staleness")
struct InvestigationScopeFingerprintTests {

    private let t0 = Date(timeIntervalSinceReferenceDate: 0)
    private let vA = UUID(); private let vB = UUID()

    // MARK: - Fingerprint

    @Test("The fingerprint is a deterministic 64-hex value, identical for identical scope")
    func deterministic() {
        let caseID = UUID()
        let a = CaseScopeFingerprinter.fingerprint(caseID: caseID, caseRevision: 3, scope: .authorizing([vA, vB]))
        let b = CaseScopeFingerprinter.fingerprint(caseID: caseID, caseRevision: 3, scope: .authorizing([vB, vA]))  // order-independent
        #expect(a == b)
        #expect(a.value.count == 64 && a.value.allSatisfy(\.isHexDigit))
    }

    @Test("The fingerprint changes when the authorized set or the case revision changes")
    func sensitivity() {
        let caseID = UUID()
        let base = CaseScopeFingerprinter.fingerprint(caseID: caseID, caseRevision: 1, scope: .authorizing([vA]))
        #expect(base != CaseScopeFingerprinter.fingerprint(caseID: caseID, caseRevision: 1, scope: .authorizing([vA, vB])))
        #expect(base != CaseScopeFingerprinter.fingerprint(caseID: caseID, caseRevision: 2, scope: .authorizing([vA])))
        #expect(base != CaseScopeFingerprinter.fingerprint(caseID: caseID, caseRevision: 1, scope: .unscoped))
        #expect(base != CaseScopeFingerprinter.fingerprint(caseID: UUID(), caseRevision: 1, scope: .authorizing([vA])))
    }

    // MARK: - Ledger

    private func ledgerDB() async throws -> Database {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let ws = UUID()
        try await db.exec("INSERT INTO workspaces (id, title, created_at, updated_at) VALUES (?,?,?,?);", [.uuid(ws), .text("W"), .real(1), .real(1)])
        try await db.exec("""
            INSERT INTO investigation_cases (id, workspace_id, title, status, revision, actor, created_at, updated_at)
            VALUES (?,?,?,?,?,?,?,?);
            """, [.uuid(caseID), .uuid(ws), .text("C"), .text("open"), .integer(1), .text("u"), .real(1), .real(1)])
        return db
    }
    private let caseID = UUID()

    @Test("The ledger records a fingerprint, detects staleness on scope change, and never rewrites history")
    func recordAndStaleness() async throws {
        let ledger = InvestigationScopeLedger(database: try await ledgerDB())
        let fp1 = CaseScopeFingerprinter.fingerprint(caseID: caseID, caseRevision: 1, scope: .authorizing([vA]))
        _ = try await ledger.record(caseID: caseID, kind: .ask, artifactID: "answer-1", fingerprint: fp1, caseRevision: 1, at: t0)

        // Same scope → not stale.
        #expect(try await ledger.isStale(caseID: caseID, kind: .ask, artifactID: "answer-1", currentFingerprint: fp1) == false)
        // Scope changed (a source added → new fingerprint) → stale, but the recorded row is unchanged.
        let fp2 = CaseScopeFingerprinter.fingerprint(caseID: caseID, caseRevision: 2, scope: .authorizing([vA, vB]))
        #expect(try await ledger.isStale(caseID: caseID, kind: .ask, artifactID: "answer-1", currentFingerprint: fp2) == true)
        let recorded = try await ledger.artifact(caseID: caseID, kind: .ask, artifactID: "answer-1")
        #expect(recorded?.fingerprint == fp1)   // historical artifact retains its original fingerprint

        // Re-recording the same artifact is refused; an unrecorded artifact's staleness throws.
        await #expect(throws: InvestigationScopeLedgerError.self) {
            _ = try await ledger.record(caseID: caseID, kind: .ask, artifactID: "answer-1", fingerprint: fp2, caseRevision: 2, at: t0)
        }
        await #expect(throws: InvestigationScopeLedgerError.self) {
            _ = try await ledger.isStale(caseID: caseID, kind: .methodRun, artifactID: "never", currentFingerprint: fp1)
        }
    }

    @Test("Different artifact kinds share the ledger; reopen returns the recorded rows")
    func kindsAndReopen() async throws {
        let db = try await ledgerDB()
        let ledger = InvestigationScopeLedger(database: db)
        let fp = CaseScopeFingerprinter.fingerprint(caseID: caseID, caseRevision: 1, scope: .authorizing([vA]))
        for kind in InvestigationScopeArtifactKind.allCases {
            _ = try await ledger.record(caseID: caseID, kind: kind, artifactID: "x", fingerprint: fp, caseRevision: 1, at: t0)
        }
        let reopened = InvestigationScopeLedger(database: db)
        #expect(try await reopened.artifacts(caseID: caseID).count == InvestigationScopeArtifactKind.allCases.count)
    }

    // MARK: - One fingerprint system (Ask carries the shared fingerprint)

    private struct StubRetriever: Retriever {
        func retrieve(for intent: UserIntent, layers: [RetrievalLayer]) async throws -> RetrievalResult { RetrievalResult() }
    }

    @Test("The Ask scope context carries exactly the shared CaseScopeFingerprinter output for the same scope")
    func oneFingerprintSystem() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let ws = UUID()
        try await db.exec("INSERT INTO workspaces (id, title, created_at, updated_at) VALUES (?,?,?,?);", [.uuid(ws), .text("W"), .real(1), .real(1)])
        let cases = InvestigationCaseRepository(database: db)
        let evidence = EvidenceStore(database: db)
        var c = try await cases.createCase(workspaceID: ws, title: "C", actor: "u", at: t0)
        c = try await cases.includeSource(caseID: c.id, expectedRevision: c.revision, sourceRef: vA.uuidString, sourceKind: .sourceVersion, actor: "u", at: t0)
        let service = InvestigationAnswerService(cases: cases, resolver: CaseRetrievalScopeResolver(evidence: evidence),
                                                 baseRetriever: StubRetriever(), evidence: evidence, makeBrain: { MasterBrain(retriever: $0) })
        let ctx = try await service.scopeContext(caseID: c.id)
        let expected = CaseScopeFingerprinter.fingerprint(caseID: c.id, caseRevision: ctx.caseRevision, scope: ctx.scope)
        #expect(ctx.fingerprint == expected)
        #expect(ctx.scope.authorizedSourceVersionIDs == [vA])
    }

    // MARK: - Architecture guard

    @Test("Only CaseScopeFingerprinter computes the scope fingerprint (one system, no per-engine variant)")
    func oneSystemGuard() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Kalsmritikosh/Personas/Investigator")
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.pathExtension == "swift" {
            let src = (try? String(contentsOf: f, encoding: .utf8)) ?? ""
            if f.lastPathComponent == "CaseScopeFingerprint.swift" {
                #expect(src.contains("SHA256"))
            } else {
                #expect(!src.contains("SHA256"), "\(f.lastPathComponent) computes its own hash — use CaseScopeFingerprinter")
            }
        }
    }
}
