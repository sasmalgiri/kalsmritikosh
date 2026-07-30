//
//  PJE009WorkProductBoundaryGuardTests.swift
//  KalsmritikoshTests
//
//  PJE-009 — architecture guards + integration E2E. The workflow work-product
//  layer uses ONE accepted assembly path and ONE persistence writer, derives
//  provenance from the manifest/citations (never from rendered prose), performs
//  no approval/LLM/network/UI, and copies no source bytes into workflow
//  artifacts. Plus a full build → close → reopen → verify end-to-end.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PJE-009 — work-product boundary guards + E2E")
struct PJE009WorkProductBoundaryGuardTests {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }
    private static func source(_ p: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(p), encoding: .utf8)
    }
    private static func swiftFiles(under dir: String) throws -> [(String, String)] {
        var out: [(String, String)] = []
        let e = FileManager.default.enumerator(at: repoRoot.appendingPathComponent(dir), includingPropertiesForKeys: nil)
        while let url = e?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            out.append((url.lastPathComponent, try String(contentsOf: url, encoding: .utf8)))
        }
        return out
    }

    private static let coordinator = "Kalsmritikosh/Workflow/Execution/Bridges/WorkflowWorkProductBuildCoordinator.swift"
    private static let buildExecutor = "Kalsmritikosh/Workflow/Execution/Executors/WorkProductBuildStepExecutor.swift"
    private static let bridgesDir = "Kalsmritikosh/Workflow/Execution/Bridges"

    // MARK: - 1: The workflow WP bridge layer has no LLM/network/UI/AppState

    @Test("The workflow work-product bridge layer has no LLM, network, UI or AppState dependency")
    func bridgeLayerNoLLMNetworkUI() throws {
        let banned = ["URLSession", "URLRequest", "http://", "https://", "Ollama",
                      "import SwiftUI", "import AppKit", "AppState", "LLMClient"]
        for (name, text) in try Self.swiftFiles(under: Self.bridgesDir) {
            for token in banned {
                #expect(!text.contains(token), "\(name) must not reference '\(token)'")
            }
        }
    }

    // MARK: - 2: The coordinator uses ONE accepted assembly path

    @Test("The build coordinator composes through the accepted assembly service only")
    func coordinatorUsesOneAssemblyPath() throws {
        let text = try Self.source(Self.coordinator)
        #expect(text.contains("assembly.compose"))
        #expect(text.contains("applyWorkProductBuild"))
        // No second renderer/exporter route inside the workflow coordinator.
        for token in ["WorkProductExporter", "RuleBasedNarrativeComposer", "LLMNarrativeComposer"] {
            #expect(!text.contains(token), "coordinator must not use a second route '\(token)'")
        }
    }

    // MARK: - 3: The coordinator never persists work-product rows directly

    @Test("The build coordinator writes no work-product SQL directly (one persistence writer)")
    func coordinatorNoDirectPersistence() throws {
        let text = try Self.source(Self.coordinator)
        #expect(!text.contains("INSERT INTO work_product"))
        #expect(!text.contains("INSERT INTO workflow_artifacts"))
    }

    // MARK: - 4: Provenance is manifest/citation-derived, not parsed from prose

    @Test("The coordinator derives provenance from claims and the manifest, never by parsing prose")
    func coordinatorProvenanceNotFromProse() throws {
        let text = try Self.source(Self.coordinator)
        #expect(text.contains("sourceClaimID"))
        #expect(text.contains("manifest.sourceVersionIDs"))
        #expect(text.contains("citation.sourceVersionID"))
        // No text parsing of rendered output to invent references.
        for token in ["NSRegularExpression", "regularExpression", "components(separatedBy:"] {
            #expect(!text.contains(token), "coordinator must not parse prose ('\(token)')")
        }
    }

    // MARK: - 5: The build executor performs no approval and no canonical writes

    @Test("The work-product build executor records no approval and creates no Claim")
    func buildExecutorNoApprovalNoClaim() throws {
        let text = try Self.source(Self.buildExecutor)
        for token in ["submitHumanApproval", "recordHumanApproval", "Claim(", "ClaimRepository",
                      "URLSession", "Ollama"] {
            #expect(!text.contains(token), "build executor must not reference '\(token)'")
        }
    }

    // MARK: - 6: The build executor is repository-free

    @Test("The work-product build executor references no Database or Repository")
    func buildExecutorRepositoryFree() throws {
        let text = try Self.source(Self.buildExecutor)
        for token in ["Database", "Repository"] {
            #expect(!text.contains(token), "build executor must be repository-free ('\(token)')")
        }
    }

    // MARK: - 7: No receipt implementation lives in the workflow bridge layer

    @Test("The workflow bridge layer contains no receipt implementation (one receipt authority)")
    func noDuplicateReceiptInBridges() throws {
        for (name, text) in try Self.swiftFiles(under: Self.bridgesDir) {
            #expect(!text.contains("enum VerifiableReceipt"),
                    "\(name) must not re-implement the receipt")
            #expect(!text.contains("struct SealedReceipt"),
                    "\(name) must not re-implement the receipt")
        }
    }

    // MARK: - 8: Workflow artifacts store no source bytes

    @Test("The workflow_artifacts table stores references/hashes, never source bytes")
    func workflowArtifactsHaveNoByteColumns() throws {
        let schema = try Self.source("Kalsmritikosh/Storage/Schema/SchemaMigrations.swift")
        for token in ["content_blob", "file_bytes", "raw_bytes", "artifact_bytes", "source_blob"] {
            #expect(!schema.contains(token), "workflow artifacts must not store bytes ('\(token)')")
        }
    }

    // MARK: - 9: No second work-product route in the executors dir

    @Test("No workflow executor bypasses the coordinator to persist a work product")
    func noExecutorPersistsWorkProduct() throws {
        for (name, text) in try Self.swiftFiles(under: "Kalsmritikosh/Workflow/Execution/Executors") {
            #expect(!text.contains("WorkProductRunPersistenceWriter"),
                    "\(name): only the coordinator/repository may invoke the persistence writer")
            #expect(!text.contains("INSERT INTO work_product"),
                    "\(name): executors must not persist work-product rows directly")
        }
    }

    // MARK: - E2E-1: Full build → close → reopen → verify everything

    @MainActor
    @Test("E2E: build a cited work product, close, reopen, verify run/artifact/citations/provenance/receipt/validation")
    func endToEndBuildReopenVerify() async throws {
        let b = try await PJE009Fixtures.buildWorkProduct(suffix: "e2e")

        // Relaunch — reopen the workflow run (verifies provenance) over the same file.
        let rig2 = try await PJE006CFixtures.makeRig(at: b.rig.dbURL, migrate: false)
        let run = try await rig2.repo.fetchRun(b.runID)
        #expect(run.artifacts.contains { $0.id == b.artifactID && $0.kind == .workProductRun })

        // Work-product run reopens with cited findings + a verifying receipt + clean validation.
        let repo = WorkProductRunRepository(database: rig2.db)
        let wp = try await repo.reopen(b.wpRunID)
        #expect(wp.manifest.selectedFindingCount >= 1)
        #expect(wp.workProduct.allCitations.contains { $0.isResolved })
        let receipt = try WorkProductReceiptBuilder().build(from: wp)
        #expect(VerifiableReceipt.verify(receipt))
        #expect(WorkProductValidator().validateProductionExport(wp.workProduct).isValid)

        // Artifact provenance is citation-derived and reopens snapshotV1.
        #expect(try await rig2.repo.provenanceSemantics(owner: .artifact(b.artifactID)) == .snapshotV1)
        let snap = try #require(try await rig2.repo.provenanceSnapshots(owner: .artifact(b.artifactID)).last)
        let refs = try WorkflowProvenanceCodec.decodeAndVerify(
            json: snap.snapshotJSON, expectedSHA256: snap.snapshotSHA256).references
        #expect(refs.contains { $0.kind == .sourceVersion })
    }

    // MARK: - E2E-2: All 17 step kinds still resolve (integration sanity)

    @MainActor
    @Test("The full executor registry still resolves all 17 step kinds including workProductBuild")
    func allStepKindsStillResolve() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 77)
        let gate = CanonicalWorkflowEvidenceReferenceGate(
            database: db, scopeRepository: SensitiveScopeRepository(database: db), scope: nil)
        let registry = try PJE006CFixtures.makeFullRegistry(gate: gate)
        for kind in WorkflowStepKind.allCases {
            #expect(registry.resolveExecutor(workflowSchemaVersion: 1, stepKind: kind) != nil,
                    "step kind \(kind) must resolve to an executor")
        }
    }
}
