//
//  AEEM2BoundaryTests.swift
//  KalsmritikoshTests
//
//  AEE-FINAL architecture guards (§29): ONE answer authority, no second AnswerState
//  vocabulary, new claims pinned to an exact revision, prior revisions never mutated during
//  a correction, corrected requires a prior revision + reason, verifiedFinal cannot precede
//  the durable commit, no raw synthesis tokens emitted as answer prose, and no MMI/TBJ/
//  concrete-method leakage. Source scanning — no data.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("AEE-FINAL — architecture guards")
struct AEEM2BoundaryTests {

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
    private let revisionsFile = "Kalsmritikosh/Storage/Repositories/AnswerLedgerRepository+Revisions.swift"
    private let masterBrainFile = "Kalsmritikosh/Brain/MasterBrain.swift"
    private let migrationsFile = "Kalsmritikosh/Storage/Schema/SchemaMigrations.swift"
    private func aeeM2Files() -> [(String, String)] {
        ["Kalsmritikosh/Brain/AEE/ProgressiveAnswer.swift",
         "Kalsmritikosh/Brain/AEE/ProgressiveAnswerContentHasher.swift",
         "Kalsmritikosh/Brain/AEE/ProgressiveAnswerStateMachine.swift",
         revisionsFile, "Kalsmritikosh/Brain/AnswerUpdate.swift"]
            .compactMap { rel in (try? read(rel)).map { (rel, $0) } }
    }

    @Test("Schema stays at v89; the revision ledger is the only answer-revision authority")
    func oneAuthoritySchema() async throws {
        #expect(SchemaMigrations.latestVersion == 89)
        // answer_revisions / answer_revision_events are created exactly once (in the migration).
        let migrations = try read(migrationsFile)
        #expect(migrations.components(separatedBy: "CREATE TABLE answer_revisions").count == 2)
        #expect(migrations.components(separatedBy: "CREATE TABLE answer_revision_events").count == 2)
    }

    @Test("AEE-M2 declares no second AnswerState vocabulary")
    func noSecondAnswerState() {
        for (name, text) in aeeM2Files() {
            #expect(!codeOnly(text).contains("enum AnswerState"), "\(name) must not redefine AnswerState")
        }
    }

    @Test("New answer claims are pinned to an exact revision")
    func claimsPinnedToRevision() throws {
        let code = codeOnly(try read(revisionsFile))
        #expect(code.contains("INSERT INTO answer_claims"))
        #expect(code.contains("revision_id"))
    }

    @Test("A correction never updates or deletes a prior revision")
    func priorRevisionImmutable() throws {
        let code = codeOnly(try read(revisionsFile))
        #expect(!code.contains("UPDATE answer_revisions"), "revisions must be immutable")
        #expect(!code.contains("DELETE FROM answer_revisions"), "revisions must never be deleted")
    }

    @Test("The schema enforces correction-requires-prior-revision-and-reason")
    func correctionCheckInSchema() throws {
        let migrations = try read(migrationsFile)
        #expect(migrations.contains("correction_of_revision_id IS NOT NULL AND length(trim(correction_reason)) > 0"))
        // Same-answer correction FK.
        #expect(migrations.contains("REFERENCES answer_revisions(id, answer_id)"))
    }

    @Test("verifiedFinal is emitted only after the durable commit; failure emits incomplete")
    func verifiedFinalAfterCommit() throws {
        let code = codeOnly(try read(masterBrainFile))
        #expect(code.contains("lockVerifiedFinal"))
        // The commit failure path returns incomplete, never a final.
        #expect(code.contains("return [.incomplete(verified)]"))
    }

    @Test("Production MasterBrain never yields a raw token / legacy answer state as answer prose")
    func noLegacyProductionEmission() throws {
        let code = codeOnly(try read(masterBrainFile))
        for token in ["yield(.instant", "yield(.synthesisToken", "yield(.expertFindingsArrived",
                      "yield(.verified(", "yield(.chapterReady"] {
            #expect(!code.contains(token), "production MasterBrain must not emit \(token)")
        }
    }

    @Test("The lifecycle vocabulary is exactly the seven AEE-M2 states")
    func sevenStateVocabulary() {
        #expect(Set(ProgressiveAnswerState.allCases.map(\.rawValue)) == [
            "immediateFinding", "groundedWorkingResult", "analysisProgress", "reviewReady",
            "verifiedFinal", "corrected", "incomplete"])
    }

    @Test("AEE-M2 introduces no MMI / TBJ / concrete professional method")
    func noFutureStageWork() {
        let forbidden = ["MultimodalInterpretation", "TimeBoundedJob", "struct FiveWhys",
                         "struct Fishbone", "class CAPA", "DataLab"]
        for (name, text) in aeeM2Files() {
            for token in forbidden { #expect(!text.contains(token), "\(name) must not implement \(token)") }
        }
    }

    @Test("Grep guard — no model names in the AEE-M2 subsystem")
    func grepGuardNoModelNames() {
        let models = ["qwen", "gemma", "deepseek", "llama", "mistral", "nomic", "gpt"]
        for (name, text) in aeeM2Files() {
            let lower = text.lowercased()
            for token in models { #expect(!lower.contains(token), "\(name) names model \(token)") }
        }
    }
}
