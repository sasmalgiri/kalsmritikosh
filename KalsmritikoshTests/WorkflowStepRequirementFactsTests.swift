//
//  WorkflowStepRequirementFactsTests.swift
//  KalsmritikoshTests
//
//  PJE-006A — Requirement facts, envelope header, generic envelope, and adapter.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PJE-006A — WorkflowStepRequirementFacts")
struct WorkflowStepRequirementFactsTests {

    // MARK: - WorkflowStepRequirementFact

    @Test("WorkflowStepRequirementFact preserves all fields")
    func factFields() {
        let fact = WorkflowStepRequirementFact(
            requirementID: "req.name",
            kind: .formFieldCompleted,
            isSatisfied: true,
            detail: "Name entered"
        )
        #expect(fact.requirementID == "req.name")
        #expect(fact.kind == .formFieldCompleted)
        #expect(fact.isSatisfied == true)
        #expect(fact.detail == "Name entered")
    }

    @Test("WorkflowStepRequirementFact codable roundtrip")
    func factCodableRoundtrip() throws {
        let fact = WorkflowStepRequirementFact(
            requirementID: "req.x", kind: .formFieldCompleted, isSatisfied: false)
        let json = try WorkflowStepPayloadCodec.encode(fact)
        let decoded = try WorkflowStepPayloadCodec.decode(WorkflowStepRequirementFact.self, from: json)
        #expect(decoded == fact)
    }

    // MARK: - WorkflowStepStateEnvelopeHeader

    @Test("WorkflowStepStateEnvelopeHeader decodes from envelope JSON")
    func envelopeHeaderDecode() throws {
        let fact = WorkflowStepRequirementFact(
            requirementID: "f1", kind: .formFieldCompleted, isSatisfied: true)
        let envelope = WorkflowStepStateEnvelope(
            stepKind: .form,
            executorID: "com.test.form",
            executorVersion: "1.0",
            state: ["hello": "world"],
            requirementFacts: [fact]
        )
        let json = try WorkflowStepPayloadCodec.encode(envelope)
        let header = try WorkflowStepPayloadCodec.decode(WorkflowStepStateEnvelopeHeader.self, from: json)
        #expect(header.stepKind == .form)
        #expect(header.executorID == "com.test.form")
        #expect(header.executorVersion == "1.0")
        #expect(header.envelopeSchemaVersion == 1)
        #expect(header.requirementFacts.count == 1)
        #expect(header.requirementFacts.first?.requirementID == "f1")
    }

    // MARK: - WorkflowStepStateEnvelope generic

    @Test("WorkflowStepStateEnvelope envelopeSchemaVersion is always 1")
    func envelopeSchemaVersionFixed() throws {
        let envelope = WorkflowStepStateEnvelope(
            stepKind: .intake,
            executorID: "com.test.intake",
            executorVersion: "1.0",
            state: 42
        )
        #expect(envelope.envelopeSchemaVersion == 1)
    }

    @Test("WorkflowStepStateEnvelope generic codable roundtrip preserves state")
    func envelopeGenericRoundtrip() throws {
        struct S: Codable, Sendable, Equatable { let x: String }
        let env = WorkflowStepStateEnvelope(
            stepKind: .scope,
            executorID: "com.test.scope",
            executorVersion: "1.0",
            state: S(x: "objective")
        )
        let json = try WorkflowStepPayloadCodec.encode(env)
        let decoded = try WorkflowStepPayloadCodec.decode(WorkflowStepStateEnvelope<S>.self, from: json)
        #expect(decoded.state == S(x: "objective"))
        #expect(decoded.stepKind == .scope)
    }

    // MARK: - WorkflowStepRequirementFactsAdapter

    @Test("adapter returns nil for empty stateJSON")
    func adapterNilForEmpty() async {
        let adapter = WorkflowStepRequirementFactsAdapter()
        let stepRun = makeStepRun(stateJSON: "{}")
        let fact = await adapter.factForRequirement("req.x", in: stepRun)
        #expect(fact == nil)
    }

    @Test("adapter finds specific fact by requirementID")
    func adapterFindsByID() async throws {
        let adapter = WorkflowStepRequirementFactsAdapter()
        let fact = WorkflowStepRequirementFact(
            requirementID: "req.name", kind: .formFieldCompleted, isSatisfied: true)
        let stateJSON = try makeStepRunStateJSON(facts: [fact])
        let stepRun = makeStepRun(stateJSON: stateJSON)
        let found = await adapter.factForRequirement("req.name", in: stepRun)
        #expect(found?.requirementID == "req.name")
        #expect(found?.isSatisfied == true)
    }

    @Test("adapter returns all facts")
    func adapterAllFacts() async throws {
        let adapter = WorkflowStepRequirementFactsAdapter()
        let facts = [
            WorkflowStepRequirementFact(requirementID: "r1", kind: .formFieldCompleted, isSatisfied: true),
            WorkflowStepRequirementFact(requirementID: "r2", kind: .formFieldCompleted, isSatisfied: false)
        ]
        let stateJSON = try makeStepRunStateJSON(facts: facts)
        let stepRun = makeStepRun(stateJSON: stateJSON)
        let all = await adapter.allFacts(in: stepRun)
        #expect(all.count == 2)
    }

    @Test("adapter returns nil for unknown requirementID")
    func adapterMissingID() async throws {
        let adapter = WorkflowStepRequirementFactsAdapter()
        let fact = WorkflowStepRequirementFact(
            requirementID: "req.known", kind: .formFieldCompleted, isSatisfied: false)
        let stateJSON = try makeStepRunStateJSON(facts: [fact])
        let stepRun = makeStepRun(stateJSON: stateJSON)
        let found = await adapter.factForRequirement("req.unknown", in: stepRun)
        #expect(found == nil)
    }

    // MARK: - Helpers

    private func makeStepRunStateJSON(facts: [WorkflowStepRequirementFact]) throws -> String {
        struct DummyState: Codable, Sendable {}
        let envelope = WorkflowStepStateEnvelope(
            stepKind: .form,
            executorID: "com.test",
            executorVersion: "1.0",
            state: DummyState(),
            requirementFacts: facts
        )
        return try WorkflowStepPayloadCodec.encode(envelope)
    }

    private func makeStepRun(stateJSON: String) -> WorkflowStepRun {
        let t0 = Date(timeIntervalSince1970: 1_753_000_000)
        return WorkflowStepRun(
            id: UUID(), workflowRunID: UUID(),
            stepDefinitionID: StepDefinitionID(rawValue: "step.test"),
            stepKind: .form,
            attempt: 1, sequence: 1, status: .active,
            executorID: "com.test", executorVersion: "1.0",
            inputJSON: "{}", stateJSON: stateJSON,
            outputJSON: nil, stateSHA256: "",
            enteredAt: t0, updatedAt: t0, completedAt: nil
        )
    }
}
