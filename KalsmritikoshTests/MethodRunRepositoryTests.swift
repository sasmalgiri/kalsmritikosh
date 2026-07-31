//
//  MethodRunRepositoryTests.swift
//  KalsmritikoshTests
//
//  PM-002 — MethodRunRepository aggregate persistence: exact round-trip + reopen,
//  optimistic revision CAS, same-run ownership fail-closed, canonical evidence
//  validation (existence / workspace / scope), human-only append-only reviews,
//  finding-references-Claim-without-promotion, atomic rollback, and canonical
//  ledger isolation.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PM-002 — MethodRunRepository", .serialized)
struct MethodRunRepositoryTests {

    private let t0 = Date(timeIntervalSince1970: 1_753_900_000)

    private struct Rig {
        let db: Database
        let url: URL
        let repo: MethodRunRepository
        let gate: CanonicalWorkflowEvidenceReferenceGate
        let ws: UUID
        let otherWS: UUID
        let entityInWS: UUID
        let entityOtherWS: UUID
        let claimID: UUID
    }

    private func makeRig() async throws -> Rig {
        let url = PJE006CFixtures.newDatabaseURL()
        let db = try await MigrationFixtureBuilder.database(atVersion: 80, at: url)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let ws = UUID(); try await PJE007Fixtures.seedWorkspace(db, id: ws)
        let otherWS = UUID(); try await PJE007Fixtures.seedWorkspace(db, id: otherWS)
        let entityInWS = try await PJE007Fixtures.seedEntity(db, in: ws)
        let entityOtherWS = try await PJE007Fixtures.seedEntity(db, in: otherWS)
        let claimID = try await seedClaim(db)
        return Rig(db: db, url: url, repo: MethodRunRepository(database: db),
                   gate: CanonicalWorkflowEvidenceReferenceGate(
                       database: db, scopeRepository: SensitiveScopeRepository(database: db), scope: nil),
                   ws: ws, otherWS: otherWS, entityInWS: entityInWS,
                   entityOtherWS: entityOtherWS, claimID: claimID)
    }

    private func seedClaim(_ db: Database) async throws -> UUID {
        let id = UUID()
        try await db.exec("""
            INSERT INTO claims (id, subject_label, statement, confidence, created_at, evidence_basis,
                                review_disposition, proposal_origin, availability_status, conflict_status)
            VALUES (?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(id), .text("S"), .text("stmt"), .real(0.5), .real(0), .text("sourceAsserted"),
                  .text("unreviewed"), .text("sourceExtraction"), .text("present"), .text("none")])
        return id
    }

    private func count(_ db: Database, _ table: String) async throws -> Int {
        Int(try await db.query("SELECT COUNT(*) FROM \(table);", []).first?.int(0) ?? -1)
    }

    private func makeRun(_ rig: Rig) async throws -> MethodRun {
        try await rig.repo.createRun(
            workspaceID: rig.ws, methodDefinitionID: ProfessionalMethodDefinitionID(rawValue: "com.k.method.test"),
            methodDefinitionVersion: 1, createdBy: "analyst-1", now: t0)
    }

    // MARK: - Full round trip + reopen

    @Test("A complete method aggregate persists and reopens exactly, in deterministic order")
    func fullAggregateRoundTrip() async throws {
        let rig = try await makeRig()
        let repo = rig.repo
        let run = try await repo.createRun(
            workspaceID: rig.ws, methodDefinitionID: ProfessionalMethodDefinitionID(rawValue: "com.k.method.fivewhys"),
            methodDefinitionVersion: 2, title: "Why did it fail?", createdBy: "analyst-1", now: t0)
        #expect(run.revision == 1 && run.status == .draft)

        let parent = MethodNode(methodRunID: run.id, nodeDefinitionKey: "problem",
            nodeKind: MethodNodeKind(rawValue: "problem"), label: "Shipment late",
            workingState: .ruleSupported, ordinal: 0, createdAt: t0, updatedAt: t0)
        #expect(try await repo.addNode(parent, expectedRevision: 1, now: t0.addingTimeInterval(1)).revision == 2)
        let child = MethodNode(methodRunID: run.id, nodeDefinitionKey: "cause",
            nodeKind: MethodNodeKind(rawValue: "cause"), label: "Carrier handoff",
            ordinal: 1, parentNodeID: parent.id, createdAt: t0, updatedAt: t0)
        #expect(try await repo.addNode(child, expectedRevision: 2, now: t0.addingTimeInterval(2)).revision == 3)
        let edge = MethodEdge(methodRunID: run.id, fromNodeID: parent.id, toNodeID: child.id,
            edgeKind: MethodEdgeKind(rawValue: "leadsTo"), ordinal: 0)
        #expect(try await repo.addEdge(edge, expectedRevision: 3, now: t0.addingTimeInterval(3)).revision == 4)
        let link = MethodEvidenceLink(methodRunID: run.id, nodeID: child.id, targetKind: .entity,
            targetID: rig.entityInWS, role: .supporting, ordinal: 0, addedBy: "analyst-1", addedAt: t0)
        #expect(try await repo.addEvidenceLink(link, expectedRevision: 4, gate: rig.gate, now: t0.addingTimeInterval(4)).revision == 5)
        let assume = MethodAssumption(methodRunID: run.id, nodeID: child.id,
            statement: "Carrier logs complete", status: .needsEvidence, createdBy: "analyst-1")
        #expect(try await repo.addAssumption(assume, expectedRevision: 5, now: t0.addingTimeInterval(5)).revision == 6)
        let finding = MethodFinding(methodRunID: run.id, nodeID: child.id,
            statement: "Handoff is a candidate cause", findingKind: MethodFindingKind(rawValue: "candidateCause"),
            supportStatus: .partiallySupported, relatedClaimID: rig.claimID, createdAt: t0)
        #expect(try await repo.addFinding(finding, expectedRevision: 6, now: t0.addingTimeInterval(6)).revision == 7)
        let review = MethodReview(methodRunID: run.id, findingID: finding.id, action: .acceptForWorkflow,
            actorIdentifier: "reviewer-1", comment: "ok", reviewedAt: t0.addingTimeInterval(7))
        #expect(try await repo.appendReview(review, expectedRevision: 7, now: t0.addingTimeInterval(7)).revision == 8)
        let validation = MethodValidationResult(methodRunID: run.id, validatorID: "v.structure",
            validatorVersion: "1", severity: .blocking, code: "NO_ROOT", message: "no terminal cause",
            subjectKind: .node, subjectID: child.id, createdAt: t0)
        #expect(try await repo.appendValidationResult(validation, expectedRevision: 8, now: t0.addingTimeInterval(8)).revision == 9)

        // Reopen with a fresh connection.
        let db2 = try MigrationFixtureBuilder.reopen(at: rig.url)
        let agg = try #require(try await MethodRunRepository(database: db2).aggregate(runID: run.id))
        #expect(agg.run.revision == 9)
        #expect(agg.run.methodDefinitionID.rawValue == "com.k.method.fivewhys")
        #expect(agg.run.methodDefinitionVersion == 2)
        #expect(agg.run.title == "Why did it fail?")
        #expect(agg.nodes.map(\.id) == [parent.id, child.id])
        #expect(agg.nodes[0].workingState == .ruleSupported)
        #expect(agg.nodes[1].parentNodeID == parent.id)
        #expect(agg.edges.map(\.id) == [edge.id])
        #expect(agg.evidenceLinks.count == 1)
        #expect(agg.evidenceLinks[0].targetKind == .entity && agg.evidenceLinks[0].targetID == rig.entityInWS)
        #expect(agg.evidenceLinks[0].role == .supporting)
        #expect(agg.assumptions.map(\.id) == [assume.id] && agg.assumptions[0].status == .needsEvidence)
        #expect(agg.findings.map(\.id) == [finding.id])
        #expect(agg.findings[0].relatedClaimID == rig.claimID)
        #expect(agg.findings[0].supportStatus == .partiallySupported)
        #expect(agg.findings[0].reviewStatus == .unreviewed)
        #expect(agg.reviews.map(\.id) == [review.id])
        #expect(agg.reviews[0].actorKind == .human && agg.reviews[0].action == .acceptForWorkflow)
        #expect(agg.validationResults.map(\.id) == [validation.id])
        #expect(agg.validationResults[0].blocksCompletion)
    }

    // MARK: - Optimistic concurrency

    @Test("A stale expected revision fails without writing anything")
    func staleRevisionWritesNothing() async throws {
        let rig = try await makeRig()
        let run = try await makeRun(rig)
        let node = MethodNode(methodRunID: run.id, nodeDefinitionKey: "k",
            nodeKind: MethodNodeKind(rawValue: "cause"), label: "L", ordinal: 0, createdAt: t0, updatedAt: t0)
        await #expect(throws: MethodPersistenceError.revisionConflict(runID: run.id, expected: 99)) {
            _ = try await rig.repo.addNode(node, expectedRevision: 99, now: self.t0)
        }
        #expect(try await rig.repo.nodes(runID: run.id).isEmpty)
        #expect(try await rig.repo.run(id: run.id)?.revision == 1)
    }

    @Test("Each successful aggregate mutation increases the run revision by exactly one")
    func oneMutationOneRevision() async throws {
        let rig = try await makeRig()
        let run = try await makeRun(rig)
        let n1 = MethodNode(methodRunID: run.id, nodeDefinitionKey: "k", nodeKind: MethodNodeKind(rawValue: "cause"),
            label: "A", ordinal: 0, createdAt: t0, updatedAt: t0)
        let after1 = try await rig.repo.addNode(n1, expectedRevision: 1, now: t0)
        #expect(after1.revision == 2)
        let a = MethodAssumption(methodRunID: run.id, statement: "x", createdBy: "analyst-1")
        let after2 = try await rig.repo.addAssumption(a, expectedRevision: 2, now: t0)
        #expect(after2.revision == 3)
        // One node + one assumption, three revision states total.
        #expect(try await rig.repo.nodes(runID: run.id).count == 1)
        #expect(try await rig.repo.assumptions(runID: run.id).count == 1)
    }

    // MARK: - Ownership fail-closed + atomic rollback

    @Test("An edge cannot reference a node from another run, and the failed mutation rolls back atomically")
    func ownershipViolationRollsBack() async throws {
        let rig = try await makeRig()
        let runA = try await makeRun(rig)
        let runB = try await makeRun(rig)
        let nodeA = MethodNode(methodRunID: runA.id, nodeDefinitionKey: "k", nodeKind: MethodNodeKind(rawValue: "cause"),
            label: "A", ordinal: 0, createdAt: t0, updatedAt: t0)
        _ = try await rig.repo.addNode(nodeA, expectedRevision: 1, now: t0)   // runA → rev 2
        let nodeB = MethodNode(methodRunID: runB.id, nodeDefinitionKey: "k", nodeKind: MethodNodeKind(rawValue: "cause"),
            label: "B", ordinal: 0, createdAt: t0, updatedAt: t0)
        _ = try await rig.repo.addNode(nodeB, expectedRevision: 1, now: t0)   // runB → rev 2
        // Edge in runA whose to-node belongs to runB → ownership violation.
        let edge = MethodEdge(methodRunID: runA.id, fromNodeID: nodeA.id, toNodeID: nodeB.id,
            edgeKind: MethodEdgeKind(rawValue: "leadsTo"), ordinal: 0)
        await #expect(throws: MethodPersistenceError.self) {
            _ = try await rig.repo.addEdge(edge, expectedRevision: 2, now: self.t0)
        }
        // The failed mutation left NO edge and did NOT advance runA's revision.
        #expect(try await rig.repo.edges(runID: runA.id).isEmpty)
        #expect(try await rig.repo.run(id: runA.id)?.revision == 2)
    }

    // MARK: - Canonical evidence validation

    @Test("A same-workspace canonical reference is permitted; missing and cross-workspace are denied")
    func evidenceReferenceValidation() async throws {
        let rig = try await makeRig()
        let run = try await makeRun(rig)
        // Same-workspace entity → permitted.
        let ok = MethodEvidenceLink(methodRunID: run.id, targetKind: .entity, targetID: rig.entityInWS,
            role: .supporting, ordinal: 0, addedBy: "a", addedAt: t0)
        #expect(try await rig.repo.addEvidenceLink(ok, expectedRevision: 1, gate: rig.gate, now: t0).revision == 2)
        // Missing target → denied, no write.
        let missing = MethodEvidenceLink(methodRunID: run.id, targetKind: .entity, targetID: UUID(),
            role: .contextual, ordinal: 1, addedBy: "a", addedAt: t0)
        await #expect(throws: MethodPersistenceError.self) {
            _ = try await rig.repo.addEvidenceLink(missing, expectedRevision: 2, gate: rig.gate, now: self.t0)
        }
        // Cross-workspace target → denied.
        let cross = MethodEvidenceLink(methodRunID: run.id, targetKind: .entity, targetID: rig.entityOtherWS,
            role: .contextual, ordinal: 2, addedBy: "a", addedAt: t0)
        await #expect(throws: MethodPersistenceError.self) {
            _ = try await rig.repo.addEvidenceLink(cross, expectedRevision: 2, gate: rig.gate, now: self.t0)
        }
        #expect(try await rig.repo.evidenceLinks(runID: run.id).count == 1)
        #expect(try await rig.repo.run(id: run.id)?.revision == 2)
    }

    @Test("A workflow-output kind is not a canonical evidence target")
    func evidenceLinkRejectsWorkflowOutputKind() async throws {
        let rig = try await makeRig()
        let run = try await makeRun(rig)
        let bad = MethodEvidenceLink(methodRunID: run.id, targetKind: .workflowArtifact, targetID: UUID(),
            role: .supporting, ordinal: 0, addedBy: "a", addedAt: t0)
        await #expect(throws: MethodPersistenceError.unsupportedEvidenceTargetKind("workflowArtifact")) {
            _ = try await rig.repo.addEvidenceLink(bad, expectedRevision: 1, gate: rig.gate, now: self.t0)
        }
    }

    // MARK: - Human-only reviews

    @Test("Only a human actor may record a review")
    func reviewsAreHumanOnly() async throws {
        let rig = try await makeRig()
        let run = try await makeRun(rig)
        let human = MethodReview(methodRunID: run.id, action: .comment,
            actorKind: .human, actorIdentifier: "reviewer-1", reviewedAt: t0)
        #expect(try await rig.repo.appendReview(human, expectedRevision: 1, now: t0).revision == 2)
        let system = MethodReview(methodRunID: run.id, action: .acceptForWorkflow,
            actorKind: .system, actorIdentifier: "system", reviewedAt: t0)
        await #expect(throws: MethodContractError.reviewRequiresHumanActor) {
            _ = try await rig.repo.appendReview(system, expectedRevision: 2, now: self.t0)
        }
        #expect(try await rig.repo.reviews(runID: run.id).count == 1)
    }

    @Test("A run-level review with neither node nor finding is allowed")
    func runLevelReviewAllowed() async throws {
        let rig = try await makeRig()
        let run = try await makeRun(rig)
        let r = MethodReview(methodRunID: run.id, action: .reopen, actorIdentifier: "boss", reviewedAt: t0)
        #expect(try await rig.repo.appendReview(r, expectedRevision: 1, now: t0).revision == 2)
    }

    // MARK: - Findings never promote a Claim

    @Test("A finding may reference an existing Claim; an unknown Claim is rejected and the Claim is never mutated")
    func findingReferencesClaimWithoutPromotion() async throws {
        let rig = try await makeRig()
        let run = try await makeRun(rig)
        let claimBefore = try await rig.db.query("SELECT statement, review_disposition FROM claims WHERE id = ?;", [.uuid(rig.claimID)])
        // Valid related claim → accepted.
        let ok = MethodFinding(methodRunID: run.id, statement: "candidate", findingKind: MethodFindingKind(rawValue: "cause"),
            relatedClaimID: rig.claimID, createdAt: t0)
        _ = try await rig.repo.addFinding(ok, expectedRevision: 1, now: t0)
        // Unknown related claim → rejected.
        let bad = MethodFinding(methodRunID: run.id, statement: "candidate2", findingKind: MethodFindingKind(rawValue: "cause"),
            relatedClaimID: UUID(), createdAt: t0)
        await #expect(throws: MethodPersistenceError.self) {
            _ = try await rig.repo.addFinding(bad, expectedRevision: 2, now: self.t0)
        }
        // The referenced Claim is unchanged — carrying a finding never confirms it.
        let claimAfter = try await rig.db.query("SELECT statement, review_disposition FROM claims WHERE id = ?;", [.uuid(rig.claimID)])
        #expect(claimBefore.first?.string(0) == claimAfter.first?.string(0))
        #expect(claimBefore.first?.string(1) == claimAfter.first?.string(1))
        #expect(try await rig.repo.findings(runID: run.id).count == 1)
    }

    // MARK: - Evidence-link identity

    @Test("An evidence link carries a stable id that reopens and can be a validation subject")
    func evidenceLinkIdentityRoundTrips() async throws {
        let rig = try await makeRig()
        let run = try await makeRun(rig)
        let link = MethodEvidenceLink(methodRunID: run.id, targetKind: .entity, targetID: rig.entityInWS,
            role: .supporting, ordinal: 0, addedBy: "a", addedAt: t0)
        _ = try await rig.repo.addEvidenceLink(link, expectedRevision: 1, gate: rig.gate, now: t0)   // rev 2
        // The persisted id is the model's id (no hidden repository UUID); it reopens.
        let db2 = try MigrationFixtureBuilder.reopen(at: rig.url)
        let reopened = try await MethodRunRepository(database: db2).evidenceLinks(runID: run.id)
        #expect(reopened.count == 1 && reopened[0].id == link.id)
        // A validation result can now target that evidence link by its public id.
        let v = MethodValidationResult(methodRunID: run.id, validatorID: "v", validatorVersion: "1",
            severity: .warning, code: "C", message: "m", subjectKind: .evidenceLink, subjectID: link.id, createdAt: t0)
        #expect(try await rig.repo.appendValidationResult(v, expectedRevision: 2, now: t0).revision == 3)
    }

    // MARK: - Validation subject ownership + mandatory subject

    @Test("A non-run validation subject is mandatory and its absence fails atomically")
    func validationSubjectMandatoryForNonRun() async throws {
        let rig = try await makeRig()
        let run = try await makeRun(rig)
        let missing = MethodValidationResult(methodRunID: run.id, validatorID: "v", validatorVersion: "1",
            severity: .error, code: "C", message: "m", subjectKind: .node, subjectID: nil, createdAt: t0)
        await #expect(throws: MethodPersistenceError.self) {
            _ = try await rig.repo.appendValidationResult(missing, expectedRevision: 1, now: self.t0)
        }
        #expect(try await rig.repo.validationResults(runID: run.id).isEmpty)
        #expect(try await rig.repo.run(id: run.id)?.revision == 1)   // atomic: no revision bump
        // A run-level validation with no subject id is allowed.
        let ok = MethodValidationResult(methodRunID: run.id, validatorID: "v", validatorVersion: "1",
            severity: .info, code: "OK", message: "m", subjectKind: .run, subjectID: nil, createdAt: t0)
        #expect(try await rig.repo.appendValidationResult(ok, expectedRevision: 1, now: t0).revision == 2)
    }

    @Test("A validation result cannot name a subject from another run")
    func validationSubjectOwnership() async throws {
        let rig = try await makeRig()
        let runA = try await makeRun(rig)
        let runB = try await makeRun(rig)
        let nodeB = MethodNode(methodRunID: runB.id, nodeDefinitionKey: "k", nodeKind: MethodNodeKind(rawValue: "cause"),
            label: "B", ordinal: 0, createdAt: t0, updatedAt: t0)
        _ = try await rig.repo.addNode(nodeB, expectedRevision: 1, now: t0)
        let v = MethodValidationResult(methodRunID: runA.id, validatorID: "v", validatorVersion: "1",
            severity: .warning, code: "C", message: "m", subjectKind: .node, subjectID: nodeB.id, createdAt: t0)
        await #expect(throws: MethodPersistenceError.self) {
            _ = try await rig.repo.appendValidationResult(v, expectedRevision: 1, now: self.t0)
        }
        #expect(try await rig.repo.validationResults(runID: runA.id).isEmpty)
    }

    // MARK: - Creation validation

    @Test("Run creation validates the workspace and workflow invocation references")
    func createRunValidatesReferences() async throws {
        let rig = try await makeRig()
        // An unknown workspace fails closed.
        await #expect(throws: MethodPersistenceError.self) {
            _ = try await rig.repo.createRun(workspaceID: UUID(),
                methodDefinitionID: ProfessionalMethodDefinitionID(rawValue: "m"),
                methodDefinitionVersion: 1, createdBy: "a", now: self.t0)
        }
        // A blank creator fails closed.
        await #expect(throws: MethodPersistenceError.invalidRun("createdBy is blank")) {
            _ = try await rig.repo.createRun(workspaceID: rig.ws,
                methodDefinitionID: ProfessionalMethodDefinitionID(rawValue: "m"),
                methodDefinitionVersion: 1, createdBy: "  ", now: self.t0)
        }
        // A bogus workflow-run reference is unresolved at creation.
        await #expect(throws: MethodPersistenceError.self) {
            _ = try await rig.repo.createRun(workspaceID: rig.ws,
                methodDefinitionID: ProfessionalMethodDefinitionID(rawValue: "m"),
                methodDefinitionVersion: 1, workflowRunID: UUID(), createdBy: "a", now: self.t0)
        }
    }

    // MARK: - Reads

    @Test("Runs are queryable by workspace and by definition id/version")
    func runReads() async throws {
        let rig = try await makeRig()
        let r1 = try await rig.repo.createRun(workspaceID: rig.ws,
            methodDefinitionID: ProfessionalMethodDefinitionID(rawValue: "com.k.m.a"), methodDefinitionVersion: 1,
            createdBy: "a", now: t0)
        _ = try await rig.repo.createRun(workspaceID: rig.ws,
            methodDefinitionID: ProfessionalMethodDefinitionID(rawValue: "com.k.m.b"), methodDefinitionVersion: 3,
            createdBy: "a", now: t0.addingTimeInterval(1))
        #expect(try await rig.repo.runs(inWorkspace: rig.ws).count == 2)
        #expect(try await rig.repo.runs(inWorkspace: rig.otherWS).isEmpty)
        let byDef = try await rig.repo.runs(definitionID: ProfessionalMethodDefinitionID(rawValue: "com.k.m.a"), version: 1)
        #expect(byDef.map(\.id) == [r1.id])
    }

    // MARK: - Canonical isolation

    @Test("Building a method aggregate never mutates any canonical ledger table")
    func canonicalIsolation() async throws {
        let rig = try await makeRig()
        let canonical = ["claims", "evidence_blocks", "source_versions", "events",
                         "entities", "relationships", "contradictions", "gap_nodes"]
        var before: [String: Int] = [:]
        for t in canonical { before[t] = try await count(rig.db, t) }

        let run = try await makeRun(rig)
        let node = MethodNode(methodRunID: run.id, nodeDefinitionKey: "k", nodeKind: MethodNodeKind(rawValue: "cause"),
            label: "L", ordinal: 0, createdAt: t0, updatedAt: t0)
        _ = try await rig.repo.addNode(node, expectedRevision: 1, now: t0)
        let link = MethodEvidenceLink(methodRunID: run.id, nodeID: node.id, targetKind: .entity, targetID: rig.entityInWS,
            role: .supporting, ordinal: 0, addedBy: "a", addedAt: t0)
        _ = try await rig.repo.addEvidenceLink(link, expectedRevision: 2, gate: rig.gate, now: t0)
        let finding = MethodFinding(methodRunID: run.id, statement: "s", findingKind: MethodFindingKind(rawValue: "cause"),
            relatedClaimID: rig.claimID, createdAt: t0)
        _ = try await rig.repo.addFinding(finding, expectedRevision: 3, now: t0)
        let review = MethodReview(methodRunID: run.id, action: .acceptForWorkflow, actorIdentifier: "r", reviewedAt: t0)
        _ = try await rig.repo.appendReview(review, expectedRevision: 4, now: t0)

        for t in canonical {
            #expect(try await count(rig.db, t) == before[t], "canonical table \(t) changed")
        }
    }
}
