//
//  WorkflowDefinitionRegistryTests.swift
//  KalsmritikoshTests
//
//  PJE-002 — WorkflowDefinitionRegistry: compiles at registration,
//  stores validated definitions, rejects invalid workflows.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PJE-002 — WorkflowDefinitionRegistry")
struct WorkflowDefinitionRegistryTests {

    // MARK: Helpers

    private let wfID = WorkflowDefinitionID(rawValue: "com.test.workflow")

    private func simpleWorkflow(
        id: String = "com.test.workflow",
        version: Int = 1
    ) -> PersonaWorkflowDefinition {
        PersonaWorkflowDefinition(
            id: WorkflowDefinitionID(rawValue: id),
            version: version,
            schemaVersion: 1,
            label: id,
            steps: [
                PersonaWorkflowStepDefinition(
                    id: StepDefinitionID(rawValue: "start"),
                    kind: .intake, label: "Start",
                    isEntry: true, isTerminal: true)
            ]
        )
    }

    private func invalidWorkflow(id: String = "com.test.bad", version: Int = 1) -> PersonaWorkflowDefinition {
        PersonaWorkflowDefinition(
            id: WorkflowDefinitionID(rawValue: id),
            version: version,
            schemaVersion: 1,
            label: id,
            steps: []  // No entry step → compilation error
        )
    }

    // MARK: - Case 1: Valid workflow compiles and registers

    @Test("A valid workflow compiles at registration and is retrievable")
    func validWorkflowCompilesAndRegisters() throws {
        var b = WorkflowDefinitionRegistryBuilder()
        try b.register(simpleWorkflow())
        let reg = b.freeze()
        let result = reg.validatedDefinition(id: wfID, version: 1)
        #expect(result != nil)
        #expect(result?.definition.id == wfID)
    }

    // MARK: - Case 2: Invalid workflow cannot register

    @Test("An invalid workflow definition is rejected at registration")
    func invalidWorkflowCannotRegister() throws {
        var b = WorkflowDefinitionRegistryBuilder()
        #expect(throws: (any Error).self) {
            try b.register(invalidWorkflow())
        }
    }

    // MARK: - Case 3: Compiler error preserved in typed diagnostic

    @Test("Compilation failure is wrapped in workflowCompilationFailed with original error")
    func compilerErrorPreserved() throws {
        var b = WorkflowDefinitionRegistryBuilder()
        let badWF = invalidWorkflow(id: "com.test.bad2")
        let badID = WorkflowDefinitionID(rawValue: "com.test.bad2")
        let expectedError = PersonaRegistryError.workflowCompilationFailed(
            id: badID, version: 1,
            error: .missingEntryStep(badID)
        )
        #expect(throws: expectedError) {
            try b.register(badWF)
        }
    }

    // MARK: - Case 4: Duplicate workflow version rejected

    @Test("Registering the same workflow ID + version twice throws duplicateRegistration")
    func duplicateWorkflowVersionRejected() throws {
        var b = WorkflowDefinitionRegistryBuilder()
        try b.register(simpleWorkflow())
        #expect(throws: PersonaRegistryError.duplicateRegistration(
            registry: "WorkflowDefinitionRegistry",
            id: "com.test.workflow",
            version: 1
        )) {
            try b.register(simpleWorkflow())
        }
    }

    // MARK: - Case 5: Two valid versions coexist

    @Test("Two different versions of the same workflow ID coexist")
    func twoValidVersionsCoexist() throws {
        var b = WorkflowDefinitionRegistryBuilder()
        try b.register(simpleWorkflow(version: 1))
        try b.register(simpleWorkflow(version: 2))
        let reg = b.freeze()
        #expect(reg.validatedDefinition(id: wfID, version: 1) != nil)
        #expect(reg.validatedDefinition(id: wfID, version: 2) != nil)
        #expect(reg.latest(id: wfID)?.definition.version == 2)
    }

    // MARK: - Case 6: Lookup does not recompile

    @Test("Multiple lookups return the same pre-compiled ValidatedWorkflowDefinition")
    func lookupDoesNotRecompile() throws {
        var b = WorkflowDefinitionRegistryBuilder()
        try b.register(simpleWorkflow())
        let reg = b.freeze()
        let r1 = reg.validatedDefinition(id: wfID, version: 1)
        let r2 = reg.validatedDefinition(id: wfID, version: 1)
        #expect(r1 != nil)
        #expect(r2 != nil)
        // Same entry step ID proves the same pre-compiled result is returned.
        #expect(r1?.entryStepID == r2?.entryStepID)
        #expect(r1?.terminalStepIDs == r2?.terminalStepIDs)
    }

    // MARK: - Case 7: Enumeration is deterministic

    @Test("all returns workflows sorted by (id.rawValue, version)")
    func enumerationIsDeterministic() throws {
        var b = WorkflowDefinitionRegistryBuilder()
        try b.register(simpleWorkflow(id: "com.z", version: 1))
        try b.register(simpleWorkflow(id: "com.a", version: 2))
        try b.register(simpleWorkflow(id: "com.a", version: 1))
        let reg = b.freeze()
        let pairs = reg.all.map { ($0.definition.id.rawValue, $0.definition.version) }
        #expect(pairs.map { $0.0 } == ["com.a", "com.a", "com.z"])
        #expect(pairs.map { $0.1 } == [1, 2, 1])
    }
}
