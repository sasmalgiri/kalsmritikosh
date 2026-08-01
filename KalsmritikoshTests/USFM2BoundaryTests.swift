//
//  USFM2BoundaryTests.swift
//  KalsmritikoshTests
//
//  USF-M2 §31 — architecture guards proving the container + coverage subsystems stay within their lanes:
//  container child ingestion/parsing always go through universal intake + the UniversalParserRegistry
//  (never a bypass), no direct SourceVersion / Claim mutation from container/coverage code, coverage is a
//  read-only projection that never writes membership or copies evidence, no second readiness system,
//  RAR/7z use no shell/network, temporary extraction paths never become durable identity, and archive
//  members use managed custody. Source scanning over the committed repo — no data.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("USF-M2 — container + coverage architecture guards")
struct USFM2BoundaryTests {

    private var repoRoot: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent() }
    private func read(_ rel: String) throws -> String { try String(contentsOf: repoRoot.appendingPathComponent(rel), encoding: .utf8) }
    private func swiftFiles(_ relDir: String) throws -> [(name: String, text: String)] {
        let dir = repoRoot.appendingPathComponent(relDir)
        return try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
    }
    /// Drop full-line + trailing comments so a guard proves absence of CODE, not documentation.
    private func codeOnly(_ src: String) -> String {
        src.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("//") || t.hasPrefix("*") || t.hasPrefix("/*") { return "" }
            if let r = line.range(of: "//") { return String(line[line.startIndex..<r.lowerBound]) }
            return String(line)
        }.joined(separator: "\n")
    }
    private var container: [(name: String, text: String)] { (try? swiftFiles("Kalsmritikosh/Ingestion/Container")) ?? [] }
    private var coverage: [(name: String, text: String)] { (try? swiftFiles("Kalsmritikosh/Ingestion/Coverage")) ?? [] }

    @Test("The container subsystem was found (guards are scanning real files)")
    func subsystemPresent() {
        #expect(container.count >= 6)
        #expect(coverage.count >= 4)
    }

    @Test("Container code never inserts a SourceVersion or mutates Claims directly")
    func containerNoDirectLedgerMutation() {
        for (name, text) in container {
            let code = codeOnly(text)
            #expect(!code.contains("INSERT INTO source_versions"), "\(name) must not create source versions")
            #expect(!code.contains("INSERT INTO claims"), "\(name) must not create claims")
            #expect(!code.contains("ClaimRepository"), "\(name) must not touch claims")
        }
    }

    @Test("The container coordinator delegates ingestion — it holds no intake/parser/loader itself")
    func coordinatorDelegatesIngestion() throws {
        let src = codeOnly(try read("Kalsmritikosh/Ingestion/Container/ContainerProcessingCoordinator.swift"))
        #expect(!src.contains("UniversalSourceIntakeCoordinator"))
        #expect(!src.contains("universalExecutor"))
        #expect(!src.contains(".ingestMany("))
        #expect(src.contains("ingestMember"))   // the pipeline is reached only through the injected closure
    }

    @Test("IngestCoordinator ingests container members through universal intake with MANAGED custody + a stable origin")
    func memberIngestGoesThroughIntakeManaged() throws {
        let src = codeOnly(try read("Kalsmritikosh/Ingestion/Pipeline/IngestCoordinator.swift"))
        #expect(src.contains("originIdentity:"))
        #expect(src.contains("custodyMode: .managed"))
        #expect(src.contains("containerCoordinator"))
        // Members re-enter the SAME pipeline (runIngest), not a bypass parser.
        #expect(src.contains("runIngest(fileAt: origin"))
    }

    @Test("The stable virtual origin (not a temp path) is what members are identified by")
    func stableOriginNotTempPath() throws {
        let src = try read("Kalsmritikosh/Ingestion/Container/ContainerProcessingCoordinator.swift")
        #expect(src.contains("kalsmritikosh-container://"))
    }

    @Test("Coverage code is read-only — it never writes membership or copies evidence")
    func coverageIsReadOnly() {
        for (name, text) in coverage {
            let code = codeOnly(text)
            #expect(!code.contains("INSERT INTO"), "\(name) must not write")
            #expect(!code.contains("DELETE FROM"), "\(name) must not delete")
            #expect(!code.contains("UPDATE "), "\(name) must not update")
        }
    }

    @Test("Coverage reuses the durable readiness snapshot — it is not a second readiness system")
    func coverageReusesReadiness() throws {
        let builder = try read("Kalsmritikosh/Ingestion/Coverage/CaseCoverageManifestBuilder.swift")
        #expect(builder.contains("SourceReadinessRepository") || builder.contains(".snapshot(sourceVersionID"))
        #expect(builder.contains("SourceCompletionState") || builder.contains("completionState"))
        // Container code must not declare durable readiness booleans (its status is inspection, not readiness).
        for (name, text) in container {
            #expect(!text.contains("isEvidenceReady"), "\(name) must not declare readiness")
            #expect(!text.contains("isSearchReady"), "\(name) must not declare readiness")
        }
    }

    @Test("RAR/7z (and all container code) invoke no shell, Homebrew, or network")
    func noShellOrNetwork() {
        for (name, text) in container {
            let code = codeOnly(text)
            #expect(!code.contains("Process("), "\(name) must not launch a subprocess")
            #expect(!code.contains("URLSession"), "\(name) must not open a network session")
            #expect(!code.contains("/usr/bin"), "\(name) must not shell out")
            #expect(!code.contains("https://"), "\(name) must not reach the network")
            #expect(!code.lowercased().contains("homebrew"), "\(name) must not depend on Homebrew")
        }
    }

    @Test("Grep guard — no model names anywhere in the container or coverage subsystems")
    func grepGuardNoModelNames() {
        let forbidden = ["qwen", "gemma", "deepseek", "llama", "mistral", "nomic", "gpt"]
        for (name, text) in container + coverage {
            let lower = text.lowercased()
            for token in forbidden { #expect(!lower.contains(token), "\(name) names model '\(token)'") }
        }
    }

    @Test("derivedConversion is excluded from the coverage closure (not an independent source)")
    func derivedConversionExcluded() throws {
        let resolver = try read("Kalsmritikosh/Ingestion/Coverage/CaseCoverageScopeResolver.swift")
        #expect(resolver.contains("archiveMember"))
        #expect(resolver.contains("attachment"))
        // The closure relations list must NOT contain derivedConversion.
        let code = codeOnly(resolver)
        #expect(!code.contains("derivedConversion"))
    }
}
