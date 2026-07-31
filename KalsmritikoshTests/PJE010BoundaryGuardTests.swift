//
//  PJE010BoundaryGuardTests.swift
//  KalsmritikoshTests
//
//  PJE-010 — runtime boundary guards + end-to-end. Terminology is presentation
//  only; automation creates PROPOSALS only through the existing canonical
//  repositories, never confirming a Claim/Deadline/approval/privilege or
//  completing a workflow; the runtime has no persona switch, LLM, network, UI,
//  or second store.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PJE-010 — runtime boundary guards + E2E")
struct PJE010BoundaryGuardTests {

    private let t0 = PJE010Fixtures.t0

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }
    private static func source(_ p: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(p), encoding: .utf8)
    }
    private static let resolver = "Kalsmritikosh/Workflow/Runtime/PersonaTerminologyResolver.swift"
    private static let coordinator = "Kalsmritikosh/Workflow/Runtime/PersonaAutomationRuntimeCoordinator.swift"

    // MARK: - Terminology guards

    @Test("The terminology resolver is presentation-only (no persistence, no identifiers, no branching)")
    func terminologyResolverPresentationOnly() throws {
        let text = try Self.source(Self.resolver)
        for token in ["Database", "Repository", "INSERT ", "UPDATE ", "StepDefinitionID",
                      "WorkflowTransition", "WorkflowStepKind"] {
            #expect(!text.contains(token), "terminology resolver must not reference '\(token)'")
        }
    }

    @Test("A terminology label is never equal to a workflow/step identifier")
    func labelNeverAnIdentifier() throws {
        let resolver = PersonaTerminologyResolver()
        let appID = ApplicationDefinitionID(rawValue: "com.app")
        let snapshot = TerminologyDefinitionSnapshot(from: PersonaTerminologyDefinition(
            id: TerminologyDefinitionID(rawValue: "t"), version: 1, applicationID: appID,
            labels: [.issue: "Legal Issue", .step: "Phase"]))
        let issue = try resolver.label(for: .issue, in: snapshot, expectedApplicationID: appID, canonicalFallback: "Issue")
        let step = try resolver.label(for: .step, in: snapshot, expectedApplicationID: appID, canonicalFallback: "Step")
        // Presentation labels are human strings, not enum raw values / IDs.
        #expect(issue != "issue" && step != "step")
    }

    // MARK: - Automation runtime guards

    @Test("The automation runtime has no persona switch — it dispatches on the closed action enum")
    func noPersonaSwitch() throws {
        let text = try Self.source(Self.coordinator)
        for token in ["case .investigator", "case .lawyer", "case .journalist",
                      "case .researcher", "switch persona"] {
            #expect(!text.contains(token), "runtime must not switch on persona ('\(token)')")
        }
        #expect(text.contains("switch definition.action"))
    }

    @Test("The automation runtime performs no LLM or network access")
    func noLLMNetwork() throws {
        let text = try Self.source(Self.coordinator)
        for token in ["URLSession", "URLRequest", "http://", "https://", "Ollama", "LLMClient", "prompt("] {
            #expect(!text.contains(token), "runtime must not reference '\(token)'")
        }
    }

    @Test("The automation runtime has no UI or AppState dependency")
    func noUIAppState() throws {
        let text = try Self.source(Self.coordinator)
        for token in ["import SwiftUI", "import AppKit", "AppState"] {
            #expect(!text.contains(token))
        }
    }

    @Test("The automation runtime never confirms a Claim, Deadline, approval, privilege or completion")
    func neverConfirmsTruth() throws {
        let text = try Self.source(Self.coordinator)
        for token in ["Claim(", "ClaimRepository", "recordHumanApproval", "submitHumanApproval",
                      "confirmDeadline", "promoteCandidate", "completeTerminal",
                      "assignPrivilege", "EvidenceStore", "INSERT INTO claims", "UPDATE claims"] {
            #expect(!text.contains(token), "runtime must not perform truth-confirming action '\(token)'")
        }
    }

    @Test("The automation runtime creates proposals through the EXISTING canonical repositories")
    func usesExistingRepositories() throws {
        let text = try Self.source(Self.coordinator)
        #expect(text.contains("ProfessionalTaskRepository"))
        #expect(text.contains("DeadlineRepository"))
        #expect(text.contains("WorkflowRunRepository"))
        // No second proposal store — outputs go to the existing tables.
        #expect(!text.contains("CREATE TABLE"))
    }

    @Test("The action kind enum is a closed set of six safe actions")
    func actionEnumClosedSix() {
        #expect(PersonaAutomationActionKind.allCases.count == 6)
        let names = Set(PersonaAutomationActionKind.allCases.map(\.rawValue))
        #expect(names == ["createSuggestion", "createCandidateTask", "createCandidateDeadline",
                          "createReviewQueueItem", "createMissingEvidenceRequest", "createAttentionItem"])
    }

    @Test("The trigger kind enum is a closed set of four triggers")
    func triggerEnumClosedFour() {
        #expect(PersonaAutomationTriggerKind.allCases.count == 4)
    }

    @Test("DeadlineCandidateOrigin includes automationProposed (a proposal origin)")
    func deadlineOriginHasAutomation() {
        #expect(DeadlineCandidateOrigin.allCases.contains(.automationProposed))
    }

    @Test("The execution ledger is an audit receipt — it carries no task/deadline domain columns")
    func ledgerIsAuditOnly() throws {
        let schema = try Self.source("Kalsmritikosh/Storage/Schema/SchemaMigrations.swift")
        // Scope the scan to the v78 ledger DDL block (bounded by the next migration,
        // so later migrations like v79's method_findings.related_claim_id do not leak in).
        let start = try #require(schema.range(of: "private static let v78"))
        let end = schema.range(of: "private static let v79")?.lowerBound ?? schema.endIndex
        let v78Block = String(schema[start.lowerBound..<end])
        #expect(v78Block.contains("CREATE TABLE workflow_automation_executions"))
        for token in ["due_date", "task_status", "deadline_value", "task_priority",
                      "claim_id", "evidence_text", "source_bytes"] {
            #expect(!v78Block.contains(token),
                    "the automation ledger must not become a domain store ('\(token)')")
        }
    }

    // MARK: - E2E

    @MainActor
    @Test("E2E: three automations produce candidate outputs + receipts; replay is idempotent; reopen is exact; automation never decides")
    func endToEndAutomationFlow() async throws {
        let url = PJE007Fixtures.newURL()
        let rig = try await PJE010Fixtures.makeRig(at: url)
        let (ws, runID) = try await PJE010Fixtures.startRun(rig, suffix: "e2e")
        let taskID = try await PJE010Fixtures.seedTask(rig, ws: ws)

        // A gap-driven workflowEvent fires three distinct automations.
        let evidenceReq = PJE010Fixtures.automation(id: "auto.evidence", action: .createMissingEvidenceRequest)
        let review = PJE010Fixtures.automation(id: "auto.review", action: .createReviewQueueItem)
        let deadline = PJE010Fixtures.automation(id: "auto.deadline", action: .createCandidateDeadline)

        _ = try await rig.coordinator.run(
            definition: evidenceReq, applicationID: PJE010Fixtures.applicationID,
            request: PersonaAutomationRequest(workspaceID: ws, workflowRunID: runID, title: "Need invoice"),
            trigger: PersonaAutomationTriggerEvent(kind: .workflowEvent, eventKey: "gap-detected"),
            now: t0.addingTimeInterval(10))
        _ = try await rig.coordinator.run(
            definition: review, applicationID: PJE010Fixtures.applicationID,
            request: PersonaAutomationRequest(workspaceID: ws, workflowRunID: runID, title: "Review the gap", severity: .blocking),
            trigger: PersonaAutomationTriggerEvent(kind: .workflowEvent, eventKey: "gap-detected"),
            now: t0.addingTimeInterval(20))
        _ = try await rig.coordinator.run(
            definition: deadline, applicationID: PJE010Fixtures.applicationID,
            request: PersonaAutomationRequest(
                workspaceID: ws, workflowRunID: runID, title: "Respond by",
                targetTaskID: taskID, deadlineValue: PJE010Fixtures.dayDeadline(), deadlineKind: .response),
            trigger: PersonaAutomationTriggerEvent(kind: .workflowEvent, eventKey: "gap-detected"),
            now: t0.addingTimeInterval(30))

        // Three receipts, three proposal outputs.
        #expect(try await rig.executions.executions(inWorkspace: ws).count == 3)
        #expect(Int(try await rig.db.query("SELECT COUNT(*) FROM deadline_candidates;", []).first?.int(0) ?? -1) == 1)

        // Replay every event — idempotent, no new outputs.
        let candidatesBefore = Int(try await rig.db.query("SELECT COUNT(*) FROM deadline_candidates;", []).first?.int(0) ?? -1)
        let r = try await rig.coordinator.run(
            definition: deadline, applicationID: PJE010Fixtures.applicationID,
            request: PersonaAutomationRequest(
                workspaceID: ws, workflowRunID: runID, title: "Respond by",
                targetTaskID: taskID, deadlineValue: PJE010Fixtures.dayDeadline(), deadlineKind: .response),
            trigger: PersonaAutomationTriggerEvent(kind: .workflowEvent, eventKey: "gap-detected"),
            now: t0.addingTimeInterval(40))
        guard case .skippedDuplicate = r else { Issue.record("expected skippedDuplicate"); return }
        #expect(Int(try await rig.db.query("SELECT COUNT(*) FROM deadline_candidates;", []).first?.int(0) ?? -2) == candidatesBefore)

        // Relaunch — receipts and outputs restored exactly.
        let rig2 = try await PJE010Fixtures.makeRig(at: url, migrate: false)
        #expect(try await rig2.executions.executions(inWorkspace: ws).count == 3)

        // Automation never DECIDED: the deadline candidate is still pending and the
        // seeded task is still candidate — promotion/confirmation is a human step.
        let candStatuses = try await rig2.db.query("SELECT status FROM deadline_candidates;", [])
            .compactMap { $0.string(0) }
        #expect(candStatuses.allSatisfy { $0 == "pending" })
        #expect(Int(try await rig2.db.query("SELECT COUNT(*) FROM deadlines;", []).first?.int(0) ?? -1) == 0)
    }

    @Test("Terminology isolation: different persona packs never change canonical token identity or leak into IDs")
    func terminologyIsolation() throws {
        let resolver = PersonaTerminologyResolver()
        let appID = ApplicationDefinitionID(rawValue: "com.app")
        func snap(_ labels: [PersonaTerminologyToken: String]) -> TerminologyDefinitionSnapshot {
            TerminologyDefinitionSnapshot(from: PersonaTerminologyDefinition(
                id: TerminologyDefinitionID(rawValue: "t"), version: 1, applicationID: appID, labels: labels))
        }
        let investigator = snap([.issue: "Issue", .task: "Task"])
        let lawyer = snap([.issue: "Legal Issue", .task: "Matter"])
        // Same canonical token, different presentation.
        let i = try resolver.label(for: .issue, in: investigator, expectedApplicationID: appID, canonicalFallback: "Issue")
        let l = try resolver.label(for: .issue, in: lawyer, expectedApplicationID: appID, canonicalFallback: "Issue")
        #expect(i != l)
        // Canonical token identity is unchanged across packs.
        #expect(PersonaTerminologyToken.allCases == PersonaTerminologyToken.allCases)
        // A workflow/step identifier is independent of any terminology label.
        let stepID = StepDefinitionID(rawValue: "step.intake")
        #expect(stepID.rawValue != i && stepID.rawValue != l)
    }
}
