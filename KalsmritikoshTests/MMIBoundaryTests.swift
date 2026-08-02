//
//  MMIBoundaryTests.swift
//  KalsmritikoshTests
//
//  MMI-FINAL architecture guards: no second parser / EvidenceBlock / readiness / SensitiveScope
//  authority; typed fields flow through the ACCEPTED EvidenceBlock model; a typed field is NOT
//  a Claim; the identity fast path is SensitiveScope-gated; media stays honest (no network
//  transcription shortcut); no MMI→TBJ / concrete-method leakage; schema at v90. Source
//  scanning — no data.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("MMI-FINAL — architecture guards")
struct MMIBoundaryTests {

    private var repoRoot: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent() }
    private func read(_ rel: String) throws -> String { try String(contentsOf: repoRoot.appendingPathComponent(rel), encoding: .utf8) }
    private func codeOnly(_ src: String) -> String {
        src.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("//") || t.hasPrefix("*") || t.hasPrefix("/*") { return "" }
            if let r = line.range(of: "//") { return String(line[line.startIndex..<r.lowerBound]) }
            return String(line)
        }.joined(separator: "\n")
    }
    private let mmiRels = [
        "Kalsmritikosh/Ingestion/TypedFields/TypedField.swift",
        "Kalsmritikosh/Ingestion/TypedFields/TypedFieldExtractor.swift",
        "Kalsmritikosh/Ingestion/TypedFields/IdentityFieldResolver.swift",
        "Kalsmritikosh/Storage/Repositories/TypedFieldRepository.swift"]
    private func mmiFiles() -> [(String, String)] { mmiRels.compactMap { rel in (try? read(rel)).map { (rel, $0) } } }

    @Test("The MMI typed-field subsystem is present")
    func present() {
        #expect(mmiFiles().count == 4)
    }

    @Test("MMI declares no second parser / EvidenceBlock / SourceLocator authority")
    func noParserFork() {
        let banned = ["struct EvidenceBlock", "class UniversalParserRegistry", "struct SourceLocator",
                      "protocol UniversalParserPlugin"]
        for (name, text) in mmiFiles() {
            let code = codeOnly(text)
            for t in banned { #expect(!code.contains(t), "\(name) redeclares \(t)") }
        }
    }

    @Test("MMI declares no second readiness / completion authority")
    func noReadinessFork() {
        let banned = ["enum SourceReadinessDimension", "enum SourceCompletionState", "struct SourceReadinessSnapshot"]
        for (name, text) in mmiFiles() {
            let code = codeOnly(text)
            for t in banned { #expect(!code.contains(t), "\(name) redeclares \(t)") }
        }
    }

    @Test("MMI declares no second SensitiveScope authority")
    func noSensitiveScopeFork() {
        let banned = ["struct SensitiveScope", "enum SensitivityLevel", "struct ProtectionLabel"]
        for (name, text) in mmiFiles() {
            let code = codeOnly(text)
            for t in banned { #expect(!code.contains(t), "\(name) redeclares \(t)") }
        }
    }

    @Test("Typed fields flow through the accepted EvidenceBlock model + FK, not a parallel store")
    func throughEvidenceBlocks() throws {
        #expect(codeOnly(try read("Kalsmritikosh/Ingestion/TypedFields/TypedFieldExtractor.swift")).contains("blocks: [EvidenceBlock]"))
        // The persistence FK ties a typed field to an exact evidence_block + source_version.
        let migrations = try read("Kalsmritikosh/Storage/Schema/SchemaMigrations.swift")
        #expect(migrations.contains("FOREIGN KEY(evidence_block_id) REFERENCES evidence_blocks(id)"))
        #expect(migrations.contains("FOREIGN KEY(source_version_id) REFERENCES source_versions(id)"))
    }

    @Test("A typed field is NOT a Claim — MMI promotes nothing to the claim ledger")
    func typedFieldIsNotAClaim() {
        for (name, text) in mmiFiles() {
            let code = codeOnly(text)
            #expect(!code.contains("INSERT INTO claims"), "\(name) must not write claims")
            #expect(!code.contains("ClaimRepository"), "\(name) must not promote claims")
        }
    }

    @Test("The identity fast path is gated by the existing SensitiveScope authority")
    func fastPathIsSensitiveScopeGated() throws {
        let brain = codeOnly(try read("Kalsmritikosh/Brain/MasterBrain.swift"))
        #expect(brain.contains("identityFieldFastPath"))
        #expect(brain.contains("effectiveLabel"))
        #expect(brain.contains("access.scope.permits"))
    }

    @Test("Media stays honest — MMI adds no network transcription shortcut")
    func mediaHonestyNoNetwork() {
        let banned = ["URLSession", "http://", "https://", "SFSpeechRecognizer", "WhisperKit", "transcribe("]
        for (name, text) in mmiFiles() {
            let code = codeOnly(text)
            for t in banned { #expect(!code.contains(t), "\(name) must not add a network/transcription shortcut (\(t))") }
        }
    }

    @Test("MMI introduces no TBJ / concrete professional method / DataLab")
    func noFutureStageWork() {
        let banned = ["TimeBoundedJob", "JobExecutionPlan", "struct FiveWhys", "struct Fishbone", "class CAPA", "DataLab"]
        for (name, text) in mmiFiles() {
            for t in banned { #expect(!text.contains(t), "\(name) must not implement \(t)") }
        }
    }

    @Test("No model names in MMI; schema is at v90 with typed_fields created once")
    func grepGuardAndSchema() throws {
        let models = ["qwen", "gemma", "deepseek", "llama", "mistral", "nomic", "gpt"]
        for (name, text) in mmiFiles() {
            let lower = text.lowercased()
            for t in models { #expect(!lower.contains(t), "\(name) names model \(t)") }
        }
        #expect(SchemaMigrations.latestVersion == 90)
        let migrations = try read("Kalsmritikosh/Storage/Schema/SchemaMigrations.swift")
        #expect(migrations.components(separatedBy: "CREATE TABLE typed_fields").count == 2)
    }
}
