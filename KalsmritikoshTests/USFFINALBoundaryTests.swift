//
//  USFFINALBoundaryTests.swift
//  KalsmritikoshTests
//
//  USF-FINAL §35 — architecture guards proving the completion + upgrade + reprocessing subsystems stay
//  within their lanes: completion state is not duplicated and is derived only from readiness (not ingest
//  attempts); production ingest writes no new .queryable; upgrade jobs target the EXACT SourceVersion and
//  never key by URL; upgrade parsing routes through the ONE UniversalParserRegistry and upgrade bytes
//  through SourceVersionByteResolver; a changed source cannot mutate the old version; job done requires a
//  readiness postcondition; background work yields to QueryPriorityGate; no second readiness table, no
//  Claim promotion, no AEE/MMI/TBJ/concrete-method implementation. Source scanning — no data.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("USF-FINAL — completion + upgrade architecture guards")
struct USFFINALBoundaryTests {

    private var repoRoot: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent() }
    private func read(_ rel: String) throws -> String { try String(contentsOf: repoRoot.appendingPathComponent(rel), encoding: .utf8) }
    private func swiftFiles(_ relDir: String) -> [(name: String, text: String)] {
        let dir = repoRoot.appendingPathComponent(relDir)
        return ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "swift" }
            .compactMap { u in (try? String(contentsOf: u, encoding: .utf8)).map { (u.lastPathComponent, $0) } }
    }
    private func codeOnly(_ src: String) -> String {
        src.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("//") || t.hasPrefix("*") || t.hasPrefix("/*") { return "" }
            if let r = line.range(of: "//") { return String(line[line.startIndex..<r.lowerBound]) }
            return String(line)
        }.joined(separator: "\n")
    }
    private var completion: [(name: String, text: String)] { swiftFiles("Kalsmritikosh/Ingestion/Completion") }
    private var upgrade: [(name: String, text: String)] { swiftFiles("Kalsmritikosh/Ingestion/Upgrade") }

    @Test("The completion + upgrade subsystems were found")
    func subsystemsPresent() {
        #expect(completion.count >= 4)
        #expect(upgrade.count >= 8)
    }

    @Test("Completion reuses SourceCompletionState — it declares no second completion vocabulary")
    func noDuplicateCompletionState() {
        for (name, text) in completion {
            #expect(!text.contains("enum SourceCompletionState"), "\(name) must not redefine completion state")
            #expect(!text.lowercased().contains("case fullyprocessed"))
            #expect(!text.contains("PercentReady"))
        }
        #expect(try! read("Kalsmritikosh/Ingestion/Completion/IngestionCompletionEvaluator.swift").contains("completionState: readiness.completionState"))
    }

    @Test("Completion is derived from readiness, not from ingest-attempt status")
    func completionNotFromAttempts() throws {
        let service = try read("Kalsmritikosh/Ingestion/Completion/IngestionCompletionService.swift")
        #expect(service.contains("readiness.snapshot"))
        #expect(!codeOnly(service).contains("ingest_file_attempts"))   // completion never reads attempt history
    }

    @Test("Production ingest writes no new .queryable status")
    func noNewQueryableWrites() throws {
        let src = codeOnly(try read("Kalsmritikosh/Ingestion/Pipeline/IngestCoordinator.swift"))
        #expect(!src.contains(".queryable"))
        #expect(src.contains(".passCompleted"))
    }

    @Test("Upgrade jobs target the EXACT SourceVersion and never key execution by URL")
    func upgradeTargetsExactVersion() {
        for (name, text) in upgrade {
            let code = codeOnly(text)
            #expect(code.contains("source_version_id") || code.contains("sourceVersionID") || !code.contains("enrichment_jobs"),
                    "\(name) upgrade work must be exact-version keyed")
            // No URL-keyed job execution (the resolver reads original_url only to reopen bytes).
            #expect(!code.contains("WHERE url ="), "\(name) must not execute by URL")
        }
    }

    @Test("Upgrade parser work routes through the ONE registry; bytes through the byte resolver")
    func upgradeRoutesThroughRegistryAndResolver() throws {
        let src = try read("Kalsmritikosh/Ingestion/Pipeline/IngestCoordinator.swift")
        // The structural upgrade handler reopens exact bytes + parses via the universal executor.
        #expect(src.contains("byteResolver.resolve"))
        #expect(src.contains("universalExecutor.execute"))
        #expect(src.contains("intent: .evidenceStructure"))
    }

    @Test("A changed source cannot mutate the old version (exact-byte guard)")
    func changedSourceGuard() throws {
        let resolver = try read("Kalsmritikosh/Ingestion/Upgrade/SourceVersionByteResolver.swift")
        #expect(resolver.contains("sourceBytesChanged"))
        #expect(resolver.contains("captured.contentHash.lowercased() == hash.lowercased()"))
    }

    @Test("A job is done only when the readiness postcondition is met (terminal fail otherwise)")
    func jobDoneRequiresPostcondition() throws {
        let coord = try read("Kalsmritikosh/Ingestion/Upgrade/SourceUpgradeCoordinator.swift")
        #expect(coord.contains("postconditionMet"))
        #expect(coord.contains("failTerminal"))
        #expect(coord.contains("jobs.succeed"))
    }

    @Test("Background upgrade work yields to interactive queries via QueryPriorityGate")
    func backgroundYields() throws {
        let coord = try read("Kalsmritikosh/Ingestion/Upgrade/SourceUpgradeCoordinator.swift")
        #expect(coord.contains("priorityGate?.awaitClearance()"))
    }

    @Test("The subsystems add no second readiness table and no Claim promotion")
    func noReadinessTableOrClaimPromotion() {
        for (name, text) in completion + upgrade {
            let code = codeOnly(text)
            #expect(!code.contains("CREATE TABLE"), "\(name) must not create a table")
            #expect(!code.contains("ClaimRepository"), "\(name) must not promote claims")
            #expect(!code.contains("INSERT INTO claims"), "\(name) must not write claims")
        }
    }

    @Test("No AEE / MMI / TBJ / concrete professional method is introduced")
    func noFutureStageWork() {
        let forbidden = ["AdaptiveEvidenceEngine", "MultimodalInterpretation", "TimeBoundedJob", "FiveWhys", "Fishbone", "class CAPA"]
        for (name, text) in completion + upgrade {
            for token in forbidden { #expect(!text.contains(token), "\(name) must not implement \(token)") }
        }
    }

    @Test("Grep guard — no model names in the completion or upgrade subsystems")
    func grepGuardNoModelNames() {
        let forbidden = ["qwen", "gemma", "deepseek", "llama", "mistral", "nomic", "gpt"]
        for (name, text) in completion + upgrade {
            let lower = text.lowercased()
            for token in forbidden { #expect(!lower.contains(token), "\(name) names model '\(token)'") }
        }
    }
}
