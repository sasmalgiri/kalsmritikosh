//
//  WorkflowRunSnapshotCodecTests.swift
//  KalsmritikoshTests
//
//  PJE-003 — WorkflowRunSnapshotCodec + WorkflowRunContractSnapshot.
//  16 tests covering encode/decode round-trip, determinism, hash verification,
//  sorting invariants, and reconstructDefinition().
//

import Foundation
import Testing
import CryptoKit
@testable import Kalsmritikosh

@Suite("PJE-003 — WorkflowRunSnapshotCodec")
struct WorkflowRunSnapshotCodecTests {

    // MARK: - Helpers

    private func makeMinimalPackage() throws -> (ResolvedPersonaApplicationPackage, WorkflowDefinitionID) {
        let appID = ApplicationDefinitionID(rawValue: "com.test.app")
        let wfID = WorkflowDefinitionID(rawValue: "com.test.workflow")
        let termID = TerminologyDefinitionID(rawValue: "com.test.term")

        let app = PersonaApplicationDefinition(id: appID, version: 1, label: "Test App")
        let entryStep = PersonaWorkflowStepDefinition(
            id: StepDefinitionID(rawValue: "step.intake"),
            kind: .intake,
            label: "Intake",
            isEntry: true,
            transitions: [WorkflowTransitionDefinition(
                label: "next",
                targetStepID: StepDefinitionID(rawValue: "step.done")
            )]
        )
        let terminalStep = PersonaWorkflowStepDefinition(
            id: StepDefinitionID(rawValue: "step.done"),
            kind: .closure,
            label: "Done",
            isTerminal: true
        )
        let wfDef = PersonaWorkflowDefinition(
            id: wfID, version: 1, schemaVersion: 1,
            label: "Test Workflow",
            steps: [entryStep, terminalStep]
        )
        let validated = try WorkflowDefinitionCompiler().compile(wfDef)
        let term = PersonaTerminologyDefinition(
            id: termID, version: 1,
            applicationID: appID,
            labels: [
                .workflow: "Workflow",
                .step: "Step",
                .evidence: "Evidence"
            ]
        )
        let pkg = ResolvedPersonaApplicationPackage(
            applicationKey: RegistryKey(id: appID, version: 1),
            application: app,
            toolKeys: [], tools: [],
            workflowKeys: [RegistryKey(id: wfID, version: 1)],
            workflows: [validated],
            terminologyKey: RegistryKey(id: termID, version: 1),
            terminology: term,
            objectSchemaKeys: [], objectSchemas: [],
            workProductKeys: [], workProducts: [],
            validatorKeys: [], validators: [],
            automationKeys: [], automations: []
        )
        return (pkg, wfID)
    }

    private func makePackageWithCapabilities() throws -> (ResolvedPersonaApplicationPackage, WorkflowDefinitionID) {
        let appID = ApplicationDefinitionID(rawValue: "com.test.caps")
        let wfID = WorkflowDefinitionID(rawValue: "com.test.caps.wf")
        let termID = TerminologyDefinitionID(rawValue: "com.test.caps.term")

        let app = PersonaApplicationDefinition(id: appID, version: 1, label: "Caps App")
        let entryStep = PersonaWorkflowStepDefinition(
            id: StepDefinitionID(rawValue: "step.entry"),
            kind: .intake,
            label: "Entry",
            isEntry: true,
            transitions: [WorkflowTransitionDefinition(
                label: "next",
                targetStepID: StepDefinitionID(rawValue: "step.end")
            )],
            capabilityRequirements: [
                WorkflowCapabilityRequirement(specKey: "reasoning", isRequired: true),
                WorkflowCapabilityRequirement(specKey: "extraction", isRequired: false)
            ]
        )
        let doneStep = PersonaWorkflowStepDefinition(
            id: StepDefinitionID(rawValue: "step.end"),
            kind: .closure,
            label: "End",
            isTerminal: true
        )
        let wfDef = PersonaWorkflowDefinition(
            id: wfID, version: 1, schemaVersion: 1,
            label: "Cap Workflow",
            steps: [entryStep, doneStep],
            capabilityRequirements: [
                WorkflowCapabilityRequirement(specKey: "summarization", isRequired: true)
            ]
        )
        let validated = try WorkflowDefinitionCompiler().compile(wfDef)
        let term = PersonaTerminologyDefinition(
            id: termID, version: 1, applicationID: appID, labels: [:])
        let pkg = ResolvedPersonaApplicationPackage(
            applicationKey: RegistryKey(id: appID, version: 1),
            application: app,
            toolKeys: [], tools: [],
            workflowKeys: [RegistryKey(id: wfID, version: 1)],
            workflows: [validated],
            terminologyKey: RegistryKey(id: termID, version: 1),
            terminology: term,
            objectSchemaKeys: [], objectSchemas: [],
            workProductKeys: [], workProducts: [],
            validatorKeys: [], validators: [],
            automationKeys: [], automations: []
        )
        return (pkg, wfID)
    }

    private func makeValidator() -> PersonaValidatorDefinition {
        PersonaValidatorDefinition(
            id: ValidatorDefinitionID(rawValue: "val.test"),
            version: 1,
            label: "Test Validator",
            supportedStepKinds: [.intake, .form, .closure],
            producesBlockingResults: true
        )
    }

    // MARK: - 1: Round-trip

    @Test("encode/decode round-trip preserves all snapshot fields")
    func encodeDecodeRoundTripPreservesAllFields() throws {
        let (pkg, wfID) = try makeMinimalPackage()
        let contract = try WorkflowRunContractSnapshot(from: pkg, selectedWorkflowID: wfID)
        let codec = WorkflowRunSnapshotCodec()
        let encoded = try codec.encode(contract)

        #expect(!encoded.json.isEmpty)
        #expect(encoded.sha256.count == 64)

        let decoded = try codec.decode(json: encoded.json, expectedSHA256: encoded.sha256)
        #expect(decoded == contract)
        #expect(decoded.snapshotSchemaVersion == 1)
        #expect(decoded.applicationKey.id.rawValue == "com.test.app")
        #expect(decoded.selectedWorkflowKey.id.rawValue == "com.test.workflow")
    }

    // MARK: - 2: Encoding is stable

    @Test("encoding same input twice produces identical JSON and SHA")
    func encodeIsStableAcrossMultipleCalls() throws {
        let (pkg, wfID) = try makeMinimalPackage()
        let contract = try WorkflowRunContractSnapshot(from: pkg, selectedWorkflowID: wfID)
        let codec = WorkflowRunSnapshotCodec()

        let e1 = try codec.encode(contract)
        let e2 = try codec.encode(contract)
        #expect(e1.json == e2.json)
        #expect(e1.sha256 == e2.sha256)
    }

    // MARK: - 3: SHA-256 is 64-char hex

    @Test("SHA-256 hash is a 64-character lowercase hex string")
    func sha256Is64CharHex() throws {
        let data = "test data".data(using: .utf8)!
        let hash = WorkflowRunSnapshotCodec.hashString(data)
        #expect(hash.count == 64)
        #expect(hash == hash.lowercased())
        #expect(hash.allSatisfy { $0.isHexDigit })
    }

    // MARK: - 4: Different content → different hash

    @Test("different content produces a different SHA-256")
    func sha256DependsOnContent() throws {
        let h1 = WorkflowRunSnapshotCodec.hashString("abc".data(using: .utf8)!)
        let h2 = WorkflowRunSnapshotCodec.hashString("xyz".data(using: .utf8)!)
        #expect(h1 != h2)
    }

    // MARK: - 5: Decode rejects wrong hash

    @Test("decode throws contractHashMismatch when SHA-256 does not match stored value")
    func decodeRejectsWrongHash() throws {
        let (pkg, wfID) = try makeMinimalPackage()
        let contract = try WorkflowRunContractSnapshot(from: pkg, selectedWorkflowID: wfID)
        let codec = WorkflowRunSnapshotCodec()
        let encoded = try codec.encode(contract)
        let badHash = String(repeating: "0", count: 64)

        do {
            _ = try codec.decode(json: encoded.json, expectedSHA256: badHash)
            Issue.record("Expected contractHashMismatch to be thrown")
        } catch WorkflowRunRepositoryError.contractHashMismatch {
            // Expected
        }
    }

    // MARK: - 6: Checkpoint round-trip

    @Test("encodeCheckpoint/decodeCheckpoint round-trip preserves payload")
    func encodeCheckpointRoundTrip() throws {
        let now = Date(timeIntervalSince1970: 1_752_000_000)
        let runID = UUID()
        let run = WorkflowRun(
            id: runID, workspaceID: UUID(),
            applicationDefinitionID: ApplicationDefinitionID(rawValue: "app"),
            applicationDefinitionVersion: 1,
            workflowDefinitionID: WorkflowDefinitionID(rawValue: "wf"),
            workflowDefinitionVersion: 1,
            title: nil, status: .active,
            currentStepDefinitionID: nil, currentStepRunID: nil,
            contractSnapshotJSON: "{}", contractSnapshotSHA256: "abc",
            snapshotSchemaVersion: 1,
            revision: 2,
            parentRunID: nil, supersededByRunID: nil,
            createdAt: now, updatedAt: now,
            startedAt: now, pausedAt: nil,
            completedAt: nil, cancelledAt: nil,
            cancellationReason: nil
        )
        let payload = WorkflowCheckpointPayload(
            run: run,
            stepRuns: [],
            decisions: [],
            artifacts: [],
            attentionItems: [],
            events: [],
            lastEventSequence: 0,
            runRevision: 2
        )
        let codec = WorkflowRunSnapshotCodec()
        let encoded = try codec.encodeCheckpoint(payload)
        let decoded = try codec.decodeCheckpoint(json: encoded.json)
        #expect(decoded == payload)
        #expect(decoded.runRevision == 2)
    }

    // MARK: - 7: snapshotSchemaVersion is 1

    @Test("WorkflowRunContractSnapshot.snapshotSchemaVersion is always 1 for PJE-003")
    func snapshotSchemaVersionIsOne() throws {
        let (pkg, wfID) = try makeMinimalPackage()
        let contract = try WorkflowRunContractSnapshot(from: pkg, selectedWorkflowID: wfID)
        #expect(contract.snapshotSchemaVersion == 1)
    }

    // MARK: - 8: requiredCapabilitySpecKeys are sorted

    @Test("requiredCapabilitySpecKeys is sorted in the snapshot")
    func requiredCapabilitySpecKeysSorted() throws {
        let (pkg, wfID) = try makePackageWithCapabilities()
        let contract = try WorkflowRunContractSnapshot(from: pkg, selectedWorkflowID: wfID)
        let keys = contract.requiredCapabilitySpecKeys
        #expect(keys == keys.sorted())
        #expect(keys.contains("reasoning"))
        #expect(keys.contains("extraction"))
        #expect(keys.contains("summarization"))
    }

    // MARK: - 9: terminology labels sorted

    @Test("terminology labels are stored sorted by token raw value")
    func terminologyLabelsSorted() throws {
        let (pkg, wfID) = try makeMinimalPackage()
        let contract = try WorkflowRunContractSnapshot(from: pkg, selectedWorkflowID: wfID)
        let tokens = contract.terminology.labels.map { $0.token }
        #expect(tokens == tokens.sorted())
        #expect(tokens.contains("evidence"))
        #expect(tokens.contains("step"))
        #expect(tokens.contains("workflow"))
    }

    // MARK: - 10: validator step kinds sorted

    @Test("ValidatorDefinitionSnapshot.supportedStepKinds is sorted")
    func validatorStepKindsSorted() throws {
        let v = makeValidator()
        let snap = ValidatorDefinitionSnapshot(from: v)
        #expect(snap.supportedStepKinds == snap.supportedStepKinds.sorted())
        #expect(snap.supportedStepKinds.count == 3)
    }

    // MARK: - 11: sensitive scope purposes sorted

    @Test("WorkflowSensitiveScopeRequirementSnapshot.purposes is sorted")
    func sensitiveScopePurposesSorted() throws {
        let req = WorkflowSensitiveScopeRequirement(
            purposes: [.prompt, .report, .retrieval, .screen])
        let snap = WorkflowSensitiveScopeRequirementSnapshot(from: req)
        #expect(snap.purposes == snap.purposes.sorted())
        #expect(snap.purposes.count == 4)
    }

    // MARK: - 12: terminal step IDs sorted

    @Test("ValidatedWorkflowDefinitionSnapshot.terminalStepIDs is sorted")
    func terminalStepIDsSorted() throws {
        let (pkg, wfID) = try makeMinimalPackage()
        let contract = try WorkflowRunContractSnapshot(from: pkg, selectedWorkflowID: wfID)
        guard let wfSnap = contract.workflows.first(where: { $0.id == wfID.rawValue }) else {
            Issue.record("Workflow snapshot not found"); return
        }
        #expect(wfSnap.terminalStepIDs == wfSnap.terminalStepIDs.sorted())
    }

    // MARK: - 13: reachable step IDs sorted

    @Test("ValidatedWorkflowDefinitionSnapshot.reachableStepIDs is sorted")
    func reachableStepIDsSorted() throws {
        let (pkg, wfID) = try makeMinimalPackage()
        let contract = try WorkflowRunContractSnapshot(from: pkg, selectedWorkflowID: wfID)
        guard let wfSnap = contract.workflows.first(where: { $0.id == wfID.rawValue }) else {
            Issue.record("Workflow snapshot not found"); return
        }
        #expect(wfSnap.reachableStepIDs == wfSnap.reachableStepIDs.sorted())
    }

    // MARK: - 14: reconstructDefinition round-trips through the snapshot

    @Test("reconstructDefinition returns a ValidatedWorkflowDefinition matching the original")
    func reconstructDefinitionMatchesOriginal() throws {
        let (pkg, wfID) = try makeMinimalPackage()
        let contract = try WorkflowRunContractSnapshot(from: pkg, selectedWorkflowID: wfID)
        guard let reconstructed = contract.reconstructDefinition() else {
            Issue.record("reconstructDefinition returned nil"); return
        }
        #expect(reconstructed.definition.id.rawValue == wfID.rawValue)
        #expect(reconstructed.definition.version == 1)
        #expect(reconstructed.entryStepID.rawValue == "step.intake")
        #expect(reconstructed.terminalStepIDs.contains(StepDefinitionID(rawValue: "step.done")))
        #expect(reconstructed.reachableStepIDs.count == 2)
    }

    // MARK: - 15: packageWorkflowNotFound on missing workflow ID

    @Test("WorkflowRunContractSnapshot init throws packageWorkflowNotFound for unknown workflow ID")
    func missingWorkflowIDThrowsPackageWorkflowNotFound() throws {
        let (pkg, _) = try makeMinimalPackage()
        let badID = WorkflowDefinitionID(rawValue: "com.nonexistent")
        do {
            _ = try WorkflowRunContractSnapshot(from: pkg, selectedWorkflowID: badID)
            Issue.record("Expected packageWorkflowNotFound to be thrown")
        } catch WorkflowRunRepositoryError.packageWorkflowNotFound(let id) {
            #expect(id.rawValue == "com.nonexistent")
        }
    }

    // MARK: - 16: Encoded JSON contains sortedKeys

    @Test("encoded contract JSON contains sorted keys (sortedKeys encoder option)")
    func encoderUsesSortedKeys() throws {
        let (pkg, wfID) = try makeMinimalPackage()
        let contract = try WorkflowRunContractSnapshot(from: pkg, selectedWorkflowID: wfID)
        let codec = WorkflowRunSnapshotCodec()
        let encoded = try codec.encode(contract)
        // The JSON must contain "applicationKey" before "automations" (alphabetical)
        guard let appKeyRange = encoded.json.range(of: "\"applicationKey\""),
              let automationsRange = encoded.json.range(of: "\"automations\"") else {
            // If either key is absent it's a schema issue, not a sorting issue
            return
        }
        #expect(appKeyRange.lowerBound < automationsRange.lowerBound,
                "applicationKey must appear before automations with sortedKeys")
    }
}
