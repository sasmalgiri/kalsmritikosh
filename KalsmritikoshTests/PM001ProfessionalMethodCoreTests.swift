//
//  PM001ProfessionalMethodCoreTests.swift
//  KalsmritikoshTests
//
//  PM-001 — invariant + architecture-guard tests for the Professional Method
//  Core Contract (Stage 4). Proves the shared domain contract preserves the
//  Stage-4 truth boundaries WITHOUT any schema change, persistence, concrete
//  method, Claim promotion, or Stage-3 redesign.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PM-001 — Professional Method Core Contract")
struct PM001ProfessionalMethodCoreTests {

    private let t0 = Date(timeIntervalSince1970: 1_753_900_000)

    // MARK: - Source access (repo-relative from this file's compile-time path)

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func methodSource(_ relative: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent("Kalsmritikosh/Method/\(relative)"),
                   encoding: .utf8)
    }

    private static func methodSwiftFiles() throws -> [(name: String, text: String)] {
        // The MODELS layer only — the PM-002 persistence layer under Method/Persistence
        // legitimately depends on Database.
        let dir = repoRoot.appendingPathComponent("Kalsmritikosh/Method/Models")
        var out: [(String, String)] = []
        let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        while let url = e?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            out.append((url.lastPathComponent, try String(contentsOf: url, encoding: .utf8)))
        }
        return out
    }

    private func sampleDefinition(
        id: String = "com.kalsmritikosh.method.test", version: Int = 1, label: String = "Test method"
    ) -> ProfessionalMethodDefinition {
        ProfessionalMethodDefinition(
            id: ProfessionalMethodDefinitionID(rawValue: id), version: version, label: label,
            category: .analysis,
            requiredInputRoles: [MethodInputRole(rawValue: "problemStatement")],
            allowedNodeKinds: [MethodNodeKind(rawValue: "cause")],
            allowedEdgeKinds: [MethodEdgeKind(rawValue: "contributesTo")],
            requiredReviews: [MethodRequiredReview(reviewKey: "final", label: "Final review")],
            validationIdentifiers: ["v.structure"],
            outputContract: MethodOutputContract(
                allowedFindingKinds: [MethodFindingKind(rawValue: "candidateCause")]))
    }

    private func sampleRun() -> MethodRun {
        MethodRun(
            workspaceID: UUID(),
            methodDefinitionID: ProfessionalMethodDefinitionID(rawValue: "com.kalsmritikosh.method.test"),
            methodDefinitionVersion: 1, status: .draft, revision: 0,
            createdBy: "analyst-1", createdAt: t0, updatedAt: t0)
    }

    // MARK: - 1. Stable IDs + versions enforced

    @Test("Stable method-definition IDs round-trip and reject blank/invalid structure")
    func definitionStructureValidated() throws {
        try sampleDefinition().validateStructure()   // valid → no throw
        #expect(ProfessionalMethodDefinitionID(rawValue: "x").rawValue == "x")
        #expect(throws: MethodContractError.blankDefinitionID) {
            try self.sampleDefinition(id: "   ").validateStructure()
        }
        #expect(throws: MethodContractError.blankDefinitionLabel) {
            try self.sampleDefinition(label: " ").validateStructure()
        }
        #expect(throws: MethodContractError.invalidDefinitionVersion) {
            try self.sampleDefinition(version: 0).validateStructure()
        }
    }

    @Test("A definition carries its own version and holds NO run state")
    func definitionHoldsNoRunState() {
        let labels = Mirror(reflecting: sampleDefinition()).children.compactMap { $0.label }
        for runOnly in ["status", "revision", "supersededByRunID", "nodes", "findings", "completedAt"] {
            #expect(!labels.contains(runOnly),
                    "ProfessionalMethodDefinition must not carry run-state field '\(runOnly)'")
        }
        #expect(labels.contains("version"))
    }

    // MARK: - 2. Working state cannot masquerade as an evidence status

    @Test("Method working-state vocabulary is the closed proposal-layer set")
    func workingStateVocabularyIsClosed() {
        #expect(Set(MethodWorkingState.allCases.map(\.rawValue)) ==
                ["proposal", "ruleSupported", "disputed", "gap", "humanRejected", "humanAcceptedForWorkflow"])
    }

    @Test("Method working state is a distinct type from every evidence-status vocabulary")
    func workingStateDistinctFromEvidenceStatuses() {
        // Even a concept-sharing case ('humanRejected') encodes differently, so the
        // two can never be confused at the persistence layer.
        #expect(MethodWorkingState.humanRejected.rawValue == "humanRejected")
        #expect(EvidenceStatus.humanRejected.rawValue == "HUMAN_REJECTED")
        #expect("\(MethodWorkingState.self)" != "\(EvidenceStatus.self)")
        #expect("\(MethodWorkingState.self)" != "\(FactStatus.self)")
        #expect("\(MethodWorkingState.self)" != "\(ReviewDisposition.self)")
        #expect("\(MethodWorkingState.self)" != "\(EvidenceBasis.self)")
    }

    @Test("Method models declare no evidence-status-typed property (no second evidence system)")
    func methodModelsDeclareNoEvidenceStatusField() throws {
        let text = try Self.methodSource("Models/ProfessionalMethodCore.swift")
        for evidenceType in ["EvidenceStatus", "FactStatus", "EvidenceAssessment",
                             "ReviewDisposition", "EvidenceBasis", "ConflictStatus", "AvailabilityStatus"] {
            #expect(!text.contains(": \(evidenceType)"),
                    "Method core must not store a property of evidence-status type '\(evidenceType)'")
        }
        // The node's working state is the method vocabulary.
        #expect(text.contains("workingState: MethodWorkingState"))
    }

    // MARK: - 3. Canonical references are IDs only, reusing PJE-007 vocabulary

    @Test("Method evidence links reuse the PJE-007 canonical reference vocabulary as IDs only")
    func evidenceLinkReusesCanonicalVocabularyAsIDsOnly() throws {
        let link = MethodEvidenceLink(
            methodRunID: UUID(), nodeID: UUID(),
            targetKind: .claim, targetID: UUID(), role: .supporting,
            ordinal: 0, addedBy: "analyst-1", addedAt: t0)
        // targetKind is the SAME type as PJE-007 provenance references.
        #expect(type(of: link.targetKind) == WorkflowProvenanceReferenceKind.self)
        // The link carries no evidence CONTENT — only a kind + canonical ID.
        let labels = Mirror(reflecting: link).children.compactMap { $0.label }
        for contentField in ["text", "body", "content", "bytes", "snippet", "label", "quote"] {
            #expect(!labels.contains(contentField),
                    "MethodEvidenceLink must not carry evidence content ('\(contentField)')")
        }
        #expect(labels.contains("targetKind") && labels.contains("targetID"))
        // Codable round-trip preserves the exact IDs.
        let data = try JSONEncoder().encode(link)
        let back = try JSONDecoder().decode(MethodEvidenceLink.self, from: data)
        #expect(back == link)
    }

    // MARK: - 4. Human review requires a human actor

    @Test("A method review requires a human actor with a non-blank identifier")
    func reviewRequiresHumanActor() throws {
        let human = MethodReview(
            methodRunID: UUID(), action: .acceptForWorkflow,
            actorKind: .human, actorIdentifier: "reviewer-1", reviewedAt: t0)
        try human.validate()   // valid → no throw

        let system = MethodReview(
            methodRunID: UUID(), action: .acceptForWorkflow,
            actorKind: .system, actorIdentifier: "system", reviewedAt: t0)
        #expect(throws: MethodContractError.reviewRequiresHumanActor) { try system.validate() }

        let rule = MethodReview(
            methodRunID: UUID(), action: .reject,
            actorKind: .deterministicRule, actorIdentifier: "rule-7", reviewedAt: t0)
        #expect(throws: MethodContractError.reviewRequiresHumanActor) { try rule.validate() }

        let blank = MethodReview(
            methodRunID: UUID(), action: .comment,
            actorKind: .human, actorIdentifier: "   ", reviewedAt: t0)
        #expect(throws: MethodContractError.blankReviewActorIdentifier) { try blank.validate() }
    }

    // MARK: - 5. Findings never become Claims automatically

    @Test("A method finding references a Claim without becoming one or being confirmed by it")
    func findingReferencesClaimWithoutPromotion() {
        let claimID = UUID()
        let finding = MethodFinding(
            methodRunID: UUID(), statement: "Carrier handoff is a candidate cause",
            findingKind: MethodFindingKind(rawValue: "candidateCause"),
            relatedClaimID: claimID, createdAt: t0)
        #expect(finding.relatedClaimID == claimID)
        // Carrying a related Claim ID does not confirm the finding.
        #expect(finding.supportStatus == .unsupported)
        #expect(finding.reviewStatus == .unreviewed)
    }

    @Test("The method core constructs or persists no canonical fact type")
    func methodCoreCreatesNoCanonicalFacts() throws {
        let text = try Self.methodSource("Models/ProfessionalMethodCore.swift")
        for token in ["Claim(", "ClaimRepository", "insertClaim", "confirmFact",
                      "GenericFact(", "Assertion(", "EvidenceBlock("] {
            #expect(!text.contains(token),
                    "Method core must not create a canonical fact ('\(token)')")
        }
    }

    // MARK: - 6. Assumptions are proposal-layer, not facts

    @Test("An assumption is proposal-layer and defaults to open, never a fact")
    func assumptionIsProposalLayer() {
        let a = MethodAssumption(
            methodRunID: UUID(), statement: "The carrier record is complete", createdBy: "analyst-1")
        #expect(a.status == .open)
        #expect(Set(MethodAssumptionStatus.allCases.map(\.rawValue)) ==
                ["open", "accepted", "rejected", "needsEvidence"])
    }

    // MARK: - 7. Validation may block but never confirms

    @Test("A blocking validation blocks completion; validation confirms no conclusion")
    func validationBlocksButNeverConfirms() throws {
        let blocking = MethodValidationResult(
            methodRunID: UUID(), validatorID: "v.structure", validatorVersion: "1",
            severity: .blocking, code: "MISSING_ROOT", message: "No terminal cause",
            subjectKind: .run, createdAt: t0)
        #expect(blocking.blocksCompletion)
        let info = MethodValidationResult(
            methodRunID: UUID(), validatorID: "v.structure", validatorVersion: "1",
            severity: .info, code: "OK", message: "ok", subjectKind: .run, createdAt: t0)
        #expect(!info.blocksCompletion)
        // No confirm/Claim capability exists on the validation vocabulary.
        let text = try Self.methodSource("Models/ProfessionalMethodCore.swift")
        #expect(!text.contains("confirmClaim"))
    }

    // MARK: - 8. Run mirrors the Stage-3 run idiom (revision + supersession)

    @Test("A method run carries revision + supersession and completion is not confirmation")
    func runCarriesRevisionAndSupersession() {
        let labels = Mirror(reflecting: sampleRun()).children.compactMap { $0.label }
        #expect(labels.contains("revision"))
        #expect(labels.contains("supersededByRunID"))
        #expect(labels.contains("workflowRunID") && labels.contains("workflowStepRunID"))
        #expect(Set(MethodRunStatus.allCases.map(\.rawValue)) ==
                ["draft", "active", "paused", "waitingForHuman", "blocked", "completed", "cancelled", "superseded"])
    }

    // MARK: - 9. Architecture closure: models only — no persistence / UI / network / LLM

    @Test("The Method subsystem contains models only — no persistence, UI, network or LLM")
    func methodSubsystemIsModelsOnly() throws {
        for (name, text) in try Self.methodSwiftFiles() {
            for token in ["import SwiftUI", "import AppKit", "URLSession", "http://", "https://",
                          "Ollama", "LLMClient", "prompt(", "AppState",
                          "CREATE TABLE", "SchemaMigrations", "sqlite3_", ": Database"] {
                #expect(!text.contains(token),
                        "\(name) (Stage 4 core) must not reference '\(token)' — PM-001 is models only")
            }
        }
    }

    @Test("Method definitions stay code-registry-backed — no method-definition table exists")
    func noMethodDefinitionTable() throws {
        // PM-001 added no schema; PM-002 added the RUN-state ledger (v79) but never a
        // definition table — definitions are immutable, code-registry-backed (PM-003),
        // so there is exactly one definition authority.
        let schema = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("Kalsmritikosh/Storage/Schema/SchemaMigrations.swift"),
            encoding: .utf8)
        for token in ["CREATE TABLE professional_method_definitions",
                      "CREATE TABLE method_definition_registry",
                      "CREATE TABLE method_templates"] {
            #expect(!schema.contains(token), "no method-definition table may exist ('\(token)')")
        }
    }

    // MARK: - 10. Stage-3 adapter stays generic (boundary intact)

    @Test("The Stage-3 MethodStepExecutor remains generic and references no Stage-4 method type")
    func stage3MethodExecutorStaysGeneric() throws {
        let executor = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "Kalsmritikosh/Workflow/Execution/Executors/MethodStepExecutor.swift"),
            encoding: .utf8)
        for stage4Type in ["ProfessionalMethodDefinition", "MethodRun", "MethodNode", "MethodEdge",
                           "MethodFinding", "MethodAssumption", "MethodReview"] {
            #expect(!executor.contains(stage4Type),
                    "MethodStepExecutor must stay a generic adapter (no '\(stage4Type)')")
        }
    }
}
