//
//  TBJBoundaryTests.swift
//  KalsmritikoshTests
//
//  TBJ-FINAL architecture guards. Prove the time-bounded Job layer COMPOSES over the existing
//  task / deadline / workflow authorities and never forks them: no second ProfessionalTask /
//  Deadline / WorkflowRun type; a Job's lifecycle vocabulary is DISTINCT from ProfessionalTaskStatus
//  and WorkflowRunStatus; priority is never a function of evidence confidence; the planner never
//  marks a job complete; no fabricated percentage; exactly one schema bump (v91); no model names in
//  the subsystem. Source scanning + value assertions — no data.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("TBJ-FINAL — architecture guards")
struct TBJBoundaryTests {

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
    private let tbjRels = [
        "Kalsmritikosh/Jobs/Domain/TimeBudget.swift",
        "Kalsmritikosh/Jobs/Domain/JobObjective.swift",
        "Kalsmritikosh/Jobs/Planning/JobPlanningTypes.swift",
        "Kalsmritikosh/Jobs/Planning/JobPlanningService.swift",
        "Kalsmritikosh/Jobs/Persistence/JobRepository.swift"]
    private func tbjFiles() -> [(String, String)] { tbjRels.compactMap { rel in (try? read(rel)).map { (rel, $0) } } }

    @Test("The TBJ subsystem is present")
    func present() {
        #expect(tbjFiles().count == 5)
    }

    @Test("TBJ declares no second task / deadline / workflow authority")
    func noEngineFork() {
        let banned = ["struct ProfessionalTask", "actor ProfessionalTaskRepository",
                      "struct Deadline ", "struct DeadlineCandidate", "actor DeadlineRepository",
                      "struct WorkflowRun ", "actor WorkflowRunRepository"]
        for (name, text) in tbjFiles() {
            let code = codeOnly(text)
            for t in banned { #expect(!code.contains(t), "\(name) redeclares \(t)") }
        }
    }

    @Test("No model names anywhere in the TBJ subsystem")
    func noModelNames() {
        let models = ["qwen", "gemma", "deepseek", "llama", "mistral", "nomic", "gpt"]
        for (name, text) in tbjFiles() {
            let lower = text.lowercased()
            for m in models { #expect(!lower.contains(m), "\(name) names model \(m)") }
        }
    }

    @Test("The job lifecycle vocabulary is DISTINCT from task and workflow statuses")
    func lifecycleVocabularyIsDistinct() {
        let jobCases = Set(JobLifecycle.allCases.map(\.rawValue))
        #expect(jobCases == ["active", "closed", "abandoned"])
        // A distinct vocabulary: none of the task/workflow-only states leak into the job lifecycle.
        let taskOnly = Set(ProfessionalTaskStatus.allCases.map(\.rawValue)).subtracting(jobCases)
        #expect(taskOnly.contains("inProgress") && taskOnly.contains("completed"))
        let runOnly = Set(WorkflowRunStatus.allCases.map(\.rawValue)).subtracting(jobCases)
        #expect(runOnly.contains("waitingForHuman") && runOnly.contains("superseded"))
        // The job lifecycle introduces its own term the others do not have.
        #expect(!Set(ProfessionalTaskStatus.allCases.map(\.rawValue)).contains("abandoned"))
        #expect(!Set(WorkflowRunStatus.allCases.map(\.rawValue)).contains("abandoned"))
    }

    @Test("Priority is never a function of evidence confidence")
    func priorityIgnoresConfidence() {
        // The rationale/priority code must not reference any confidence signal.
        let code = codeOnly((try? read("Kalsmritikosh/Jobs/Planning/JobPlanningService.swift")) ?? "")
        // Isolate the priority region for a precise check.
        #expect(!code.contains(".confidence"))
        #expect(!code.lowercased().contains("evidenceconfidence"))
    }

    @Test("The planner never marks a job complete and reports no percentage")
    func noAutoCompleteNoPercentage() {
        // TimeBoundedOutcome's completion contract is hard-false.
        let outcome = TimeBoundedOutcome(
            budget: .unbounded, progress: JobProgressSnapshot(items: []), minimumDeliverable: .undefined,
            prioritizedItems: [], completedNow: [], remainingWork: [], missingEvidence: [],
            blockedActions: [], deadlineRisk: .unknown, recommendedNextAction: nil)
        #expect(outcome.marksJobComplete == false)
        // No fabricated percentage in the CODE of the derived planning types (comments explaining the
        // "no percentage" contract are stripped first).
        for rel in ["Kalsmritikosh/Jobs/Planning/JobPlanningTypes.swift",
                    "Kalsmritikosh/Jobs/Planning/JobPlanningService.swift"] {
            let code = codeOnly((try? read(rel)) ?? "").lowercased()
            #expect(!code.contains("percent"))
        }
    }

    @Test("Time-budget integrity holds: only the column matching the basis is populated")
    func budgetWellFormedness() {
        #expect(TimeBudget.none.isWellFormed)
        #expect(TimeBudget.explicit(seconds: 60).isWellFormed)
        #expect(TimeBudget.confirmedDeadline(UUID()).isWellFormed)
        #expect(TimeBudget.workflowConstraint(UUID()).isWellFormed)
        // A malformed budget (basis says deadline but carries seconds) is caught.
        let bad = TimeBudget(basis: .confirmedDeadline, explicitDuration: 60, deadlineID: nil, workflowRunID: nil)
        #expect(!bad.isWellFormed)
    }

    @Test("TBJ adds exactly one schema bump: latest is v91 and the job tables are created once")
    func oneSchemaBump() throws {
        #expect(SchemaMigrations.latestVersion == 91)
        let migrations = try read("Kalsmritikosh/Storage/Schema/SchemaMigrations.swift")
        #expect(migrations.components(separatedBy: "CREATE TABLE job_objectives").count == 2)
        #expect(migrations.components(separatedBy: "CREATE TABLE job_plan_references").count == 2)
        #expect(migrations.components(separatedBy: "CREATE TABLE job_events").count == 2)
    }

    @Test("The v91 job migration suite is registered in the migration matrix")
    func migrationSuiteRegistered() throws {
        let matrix = try read("ci/test-groups/migration-matrix.json")
        #expect(matrix.contains("JobObjectiveMigrationTests"))
    }
}
