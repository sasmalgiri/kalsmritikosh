//
//  PersonaRegistrySafetyTests.swift
//  KalsmritikoshTests
//
//  PJE-002 — Safety invariants: reserved type names, blank terminology labels,
//  closed automation action enum, and PersonaRegistryError Equatable.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PJE-002 — PersonaRegistrySafetyTests")
struct PersonaRegistrySafetyTests {

    // MARK: - Shared minimal-catalog helpers

    private let appID  = ApplicationDefinitionID(rawValue: "com.safety.app")
    private let termID = TerminologyDefinitionID(rawValue: "com.safety.term")
    private let schID  = ObjectSchemaDefinitionID(rawValue: "com.safety.schema")

    /// Builds the smallest valid catalog that includes one object schema.
    /// Throws whichever error the builder or resolver raises.
    private func buildWithSchema(
        representedTypeName: String,
        ownership: PersonaObjectSchemaOwnership
    ) throws -> PersonaJobCatalog {
        var b = PersonaJobCatalogBuilder(composerRegistry: WorkProductComposerRegistry())
        let app = PersonaApplicationDefinition(id: appID, version: 1, label: "App")
        try b.registerApplication(app)
        try b.registerObjectSchema(PersonaObjectSchemaDefinition(
            id: schID, version: 1, label: "Schema",
            representedTypeName: representedTypeName,
            ownership: ownership))
        try b.registerTerminology(PersonaTerminologyDefinition(
            id: termID, version: 1, applicationID: appID))
        b.registerPackage(PersonaApplicationPackageDefinition(
            application: app,
            terminologyID: termID,
            objectSchemaIDs: [schID]))
        return try b.build()
    }

    // MARK: - Reserved canonical type names

    @Test("Canonical reserved name 'Claim' with workflowOwned ownership is rejected")
    func canonicalNameWorkflowOwnedRejected() {
        #expect(throws: PersonaRegistryError.illegalObjectSchemaOwnership(
            representedTypeName: "Claim", ownership: .workflowOwned
        )) {
            _ = try buildWithSchema(representedTypeName: "Claim", ownership: .workflowOwned)
        }
    }

    @Test("Canonical reserved name 'EvidenceBlock' with proposalLayer ownership is rejected")
    func canonicalNameProposalLayerRejected() {
        #expect(throws: PersonaRegistryError.illegalObjectSchemaOwnership(
            representedTypeName: "EvidenceBlock", ownership: .proposalLayer
        )) {
            _ = try buildWithSchema(representedTypeName: "EvidenceBlock", ownership: .proposalLayer)
        }
    }

    @Test("Canonical reserved name 'Entity' with canonicalReferenceOnly ownership is accepted")
    func canonicalNameCanonicalReferenceOnlyAccepted() throws {
        let catalog = try buildWithSchema(
            representedTypeName: "Entity", ownership: .canonicalReferenceOnly)
        #expect(catalog.latestObjectSchema(id: schID)?.representedTypeName == "Entity")
    }

    @Test("Canonical reserved name 'Event' with sharedProfessionalReferenceOnly is rejected")
    func canonicalNameSharedProfessionalReferenceOnlyRejected() {
        // canonicalReferenceOnly is the ONLY allowed ownership for canonical names
        #expect(throws: PersonaRegistryError.illegalObjectSchemaOwnership(
            representedTypeName: "Event", ownership: .sharedProfessionalReferenceOnly
        )) {
            _ = try buildWithSchema(
                representedTypeName: "Event", ownership: .sharedProfessionalReferenceOnly)
        }
    }

    // MARK: - Reserved shared professional type names

    @Test("Shared professional reserved name 'Issue' with workflowOwned is rejected")
    func sharedProfessionalNameWorkflowOwnedRejected() {
        #expect(throws: PersonaRegistryError.illegalObjectSchemaOwnership(
            representedTypeName: "Issue", ownership: .workflowOwned
        )) {
            _ = try buildWithSchema(representedTypeName: "Issue", ownership: .workflowOwned)
        }
    }

    @Test("Shared professional reserved name 'Deadline' with sharedProfessionalReferenceOnly is accepted")
    func sharedProfessionalNameAccepted() throws {
        let catalog = try buildWithSchema(
            representedTypeName: "Deadline", ownership: .sharedProfessionalReferenceOnly)
        #expect(catalog.latestObjectSchema(id: schID)?.representedTypeName == "Deadline")
    }

    @Test("Shared professional reserved name 'ProfessionalTask' with canonicalReferenceOnly is rejected")
    func sharedProfessionalNameCanonicalReferenceOnlyRejected() {
        #expect(throws: PersonaRegistryError.illegalObjectSchemaOwnership(
            representedTypeName: "ProfessionalTask", ownership: .canonicalReferenceOnly
        )) {
            _ = try buildWithSchema(
                representedTypeName: "ProfessionalTask", ownership: .canonicalReferenceOnly)
        }
    }

    @Test("A non-reserved type name with workflowOwned ownership is accepted")
    func nonReservedNameAccepted() throws {
        let catalog = try buildWithSchema(
            representedTypeName: "IntakeForm", ownership: .workflowOwned)
        #expect(catalog.latestObjectSchema(id: schID) != nil)
    }

    // MARK: - Blank terminology labels

    @Test("A blank terminology label is rejected with blankTerminologyLabel")
    func blankTerminologyLabelRejected() throws {
        var b = PersonaJobCatalogBuilder(composerRegistry: WorkProductComposerRegistry())
        let app = PersonaApplicationDefinition(id: appID, version: 1, label: "App")
        try b.registerApplication(app)
        try b.registerTerminology(PersonaTerminologyDefinition(
            id: termID, version: 1, applicationID: appID,
            labels: [.claim: ""]))  // blank label
        b.registerPackage(PersonaApplicationPackageDefinition(
            application: app, terminologyID: termID))
        #expect(throws: PersonaRegistryError.blankTerminologyLabel(
            terminologyID: termID, token: .claim
        )) {
            _ = try b.build()
        }
    }

    @Test("A whitespace-only terminology label is rejected with blankTerminologyLabel")
    func whitespaceOnlyTerminologyLabelRejected() throws {
        var b = PersonaJobCatalogBuilder(composerRegistry: WorkProductComposerRegistry())
        let app = PersonaApplicationDefinition(id: appID, version: 1, label: "App")
        try b.registerApplication(app)
        try b.registerTerminology(PersonaTerminologyDefinition(
            id: termID, version: 1, applicationID: appID,
            labels: [.workflow: "   "]))  // whitespace only
        b.registerPackage(PersonaApplicationPackageDefinition(
            application: app, terminologyID: termID))
        #expect(throws: PersonaRegistryError.blankTerminologyLabel(
            terminologyID: termID, token: .workflow
        )) {
            _ = try b.build()
        }
    }

    // MARK: - Closed automation action enum

    @Test("PersonaAutomationActionKind contains exactly the 6 safe candidate actions")
    func automationActionKindHasExactlySixCases() {
        // Only safe candidate-creation actions are representable.
        // Unsafe actions (confirm, approve, complete) are impossible at the type level.
        let expected: Set<PersonaAutomationActionKind> = [
            .createSuggestion,
            .createCandidateTask,
            .createCandidateDeadline,
            .createReviewQueueItem,
            .createMissingEvidenceRequest,
            .createAttentionItem
        ]
        #expect(Set(PersonaAutomationActionKind.allCases) == expected)
        #expect(PersonaAutomationActionKind.allCases.count == 6)
    }
}
