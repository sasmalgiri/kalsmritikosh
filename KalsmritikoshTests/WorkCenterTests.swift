//
//  WorkCenterTests.swift
//  KalsmritikoshTests
//
//  WORK-CENTER — engine (pure gates/validation/numbering/catalog integrity)
//  and repository (numbered documents over migration v105: create, save,
//  gate-enforced confirm, posted step documents, transactional number
//  ranges, status lifecycle, durability across reopen).
//

import Foundation
import Testing
@testable import Kalsmritikosh

// MARK: - Pure engine

@Suite("WORK-CENTER — engine (pure)")
struct WorkCenterEngineTests {

    @Test("Document numbers format SAP-style TYPE-YEAR-####")
    func numberFormat() {
        #expect(WCDocumentNumber.format(type: "WF", year: 2026, sequence: 1) == "WF-2026-0001")
        #expect(WCDocumentNumber.format(type: "imp", year: 2026, sequence: 42) == "IMP-2026-0042")
        #expect(WCDocumentNumber.format(type: "RPT", year: 2027, sequence: 12345) == "RPT-2027-12345")
    }

    @Test("Sequential gates lock each step until the previous is confirmed")
    func sequentialGates() {
        let def = WCCatalog.evidenceIntake
        let fresh = WCGatePolicy.RunState(confirmed: [], fieldValues: [:])
        #expect(WCGatePolicy.lockedReasons(def.operations[0], state: fresh).isEmpty,
                "step 1 must start open")
        #expect(!WCGatePolicy.lockedReasons(def.operations[1], state: fresh).isEmpty,
                "step 2 must be locked before step 1 confirms")
        let after1 = WCGatePolicy.RunState(confirmed: [1], fieldValues: [:])
        #expect(WCGatePolicy.lockedReasons(def.operations[1], state: after1).isEmpty)
    }

    @Test("fieldEquals gate — production blocks until the privilege log reads Yes")
    func privilegeGate() {
        let produce = WCCatalog.production.operations[4]
        let state = WCGatePolicy.RunState(
            confirmed: [1, 2, 3, 4],
            fieldValues: [3: ["logComplete": "No"]])
        let reasons = WCGatePolicy.lockedReasons(produce, state: state)
        #expect(reasons.count == 1)
        #expect(reasons[0].contains("privilege log"))
        let done = WCGatePolicy.RunState(
            confirmed: [1, 2, 3, 4],
            fieldValues: [3: ["logComplete": "Yes"]])
        #expect(WCGatePolicy.lockedReasons(produce, state: done).isEmpty)
    }

    @Test("fieldPresent gate treats whitespace-only values as absent")
    func fieldPresentGate() {
        let edition = WCCatalog.systematicReview.operations[4]
        let blank = WCGatePolicy.RunState(
            confirmed: [1, 2, 3, 4],
            fieldValues: [1: ["question": "   \n"]])
        #expect(!WCGatePolicy.lockedReasons(edition, state: blank).isEmpty)
        let filled = WCGatePolicy.RunState(
            confirmed: [1, 2, 3, 4],
            fieldValues: [1: ["question": "What happened to the estate?"]])
        #expect(WCGatePolicy.lockedReasons(edition, state: filled).isEmpty)
    }

    @Test("Required-field validation returns the missing labels")
    func requiredValidation() {
        let receive = WCCatalog.evidenceIntake.operations[0]
        let missing = WCFieldValidation.missingRequired(receive.fields, values: [:])
        #expect(missing == ["Case / Matter number", "Custodian / owner"])
        let partial = WCFieldValidation.missingRequired(
            receive.fields, values: ["caseNumber": "CASE-1", "custodian": "  "])
        #expect(partial == ["Custodian / owner"])
        let full = WCFieldValidation.missingRequired(
            receive.fields, values: ["caseNumber": "CASE-1", "custodian": "j.doe"])
        #expect(full.isEmpty)
    }

    @Test("Catalog integrity — unique defIDs, contiguous steps, gates point backward, surfaces resolve")
    func catalogIntegrity() {
        let defs = WCCatalog.all
        #expect(Set(defs.map(\.defID)).count == defs.count, "defIDs must be unique")
        for def in defs {
            #expect(def.operations.map(\.seq) == Array(1...def.operations.count),
                    "\(def.defID): steps must be 1...N in order")
            #expect(def.operations.contains { $0.postsDocType != nil },
                    "\(def.defID): a workflow that posts nothing leaves no record")
            for op in def.operations {
                for gate in op.gates {
                    let ref: Int
                    switch gate.rule {
                    case .operationConfirmed(let seq),
                         .fieldPresent(let seq, _),
                         .fieldEquals(let seq, _, _):
                        ref = seq
                    }
                    #expect(ref < op.seq,
                            "\(def.defID) step \(op.seq): gates may only reference earlier steps")
                    #expect(!gate.reason.isEmpty, "every gate carries a plain-language reason")
                }
                if let surface = op.launchesSurface {
                    #expect(Destination(rawValue: surface) != nil,
                            "\(def.defID) step \(op.seq): launchesSurface '\(surface)' is not a Destination")
                }
                for field in op.fields {
                    #expect(!field.help.isEmpty,
                            "\(def.defID) step \(op.seq) field \(field.key): help text is the contract")
                    if field.kind == .choice {
                        #expect(!field.options.isEmpty, "choice fields need options")
                    }
                }
            }
        }
    }

    @Test("Field-map JSON encoding round-trips")
    func fieldsRoundTrip() {
        let values: [Int: [String: String]] = [
            1: ["caseNumber": "CASE-2026-0001", "custodian": "j.doe"],
            3: ["itemsOfInterest": "7"],
        ]
        let json = WorkCenterRepository.encodeFields(values)
        #expect(WorkCenterRepository.decodeFields(json) == values)
        #expect(WorkCenterRepository.decodeFields("not json") == [:])
        #expect(WorkCenterRepository.decodeFields("{}") == [:])
    }
}

// MARK: - Repository (over migration v105)

@Suite("WORK-CENTER — repository")
struct WorkCenterRepositoryTests {

    private func makeRepo() async throws -> (WorkCenterRepository, Database, URL) {
        let url = MigrationFixtureBuilder.newTemporaryURL()
        let db = try await MigrationFixtureBuilder.database(atVersion: 0, at: url)
        try await SchemaMigrations.migrate(db)
        return (WorkCenterRepository(database: db), db, url)
    }

    /// Values that satisfy every required field AND every field-based gate of
    /// an operation set — drives any recipe to completion generically.
    private func passingValues(for op: WCOperation) -> [String: String] {
        var values: [String: String] = [:]
        for field in op.fields where field.required {
            switch field.kind {
            case .choice: values[field.key] = field.options.first ?? "X"
            case .bool:   values[field.key] = "Yes"
            case .number: values[field.key] = "1"
            case .text, .longText: values[field.key] = "test value"
            }
        }
        return values
    }

    /// Extra values later gates demand from EARLIER steps (fieldEquals/fieldPresent).
    private func gateDemands(of def: WCWorkflowDefinition, on seq: Int) -> [String: String] {
        var demands: [String: String] = [:]
        for op in def.operations {
            for gate in op.gates {
                switch gate.rule {
                case .fieldEquals(let s, let key, let value) where s == seq:
                    demands[key] = value
                case .fieldPresent(let s, let key) where s == seq:
                    if demands[key] == nil { demands[key] = "present" }
                default: break
                }
            }
        }
        return demands
    }

    @Test("createRun posts a numbered WF document, open, with transactional numbering")
    func createRunNumbers() async throws {
        let (repo, _, _) = try await makeRepo()
        let now = Date()
        let year = Calendar(identifier: .gregorian).component(.year, from: now)
        let first = try await repo.createRun(
            defID: WCCatalog.evidenceIntake.defID, title: "Estate intake", actor: "Tester", at: now)
        #expect(first.docNumber == WCDocumentNumber.format(type: "WF", year: year, sequence: 1))
        #expect(first.docType == "WF")
        #expect(first.status == .open)
        #expect(first.confirmedSeqs.isEmpty)
        let second = try await repo.createRun(
            defID: WCCatalog.production.defID, title: "Acme production", actor: "Tester", at: now)
        #expect(second.docNumber == WCDocumentNumber.format(type: "WF", year: year, sequence: 2),
                "the WF number range must advance, never repeat")
        let runs = try await repo.runs()
        #expect(runs.count == 2)
        #expect(runs.first?.id == second.id, "runs list newest first")
    }

    @Test("createRun rejects an unknown definition")
    func createRunUnknownDef() async throws {
        let (repo, _, _) = try await makeRepo()
        await #expect(throws: WorkCenterError.unknownDefinition("nope")) {
            _ = try await repo.createRun(defID: "nope", title: "x", actor: "T", at: Date())
        }
    }

    @Test("confirmStep is fail-closed — missing required fields and locked gates throw")
    func confirmFailClosed() async throws {
        let (repo, _, _) = try await makeRepo()
        let def = WCCatalog.evidenceIntake
        let run = try await repo.createRun(defID: def.defID, title: "t", actor: "T", at: Date())

        // Step 1 without its required fields.
        await #expect(throws: WorkCenterError.self) {
            _ = try await repo.confirmStep(runID: run.id, seq: 1, actor: "T", at: Date())
        }
        // Step 2 before step 1 (sequential gate), even with fields filled.
        try await repo.saveFields(runID: run.id, seq: 2,
                                  values: passingValues(for: def.operations[1]), at: Date())
        await #expect(throws: WorkCenterError.self) {
            _ = try await repo.confirmStep(runID: run.id, seq: 2, actor: "T", at: Date())
        }
        // Nothing was recorded by the failed attempts.
        let after = try await repo.run(run.id)
        #expect(after?.confirmedSeqs.isEmpty == true)
        #expect(after?.status == .open)
        #expect(try await repo.documents(inRun: run.id).isEmpty)
    }

    @Test("Every catalog recipe runs to completion — statuses advance, posting steps issue documents",
          arguments: WCCatalog.all.map(\.defID))
    func recipeRunsToCompletion(defID: String) async throws {
        let (repo, _, _) = try await makeRepo()
        let def = try #require(WCCatalog.definition(defID))
        var run = try await repo.createRun(defID: defID, title: def.name, actor: "Tester", at: Date())
        #expect(run.status == .open)

        for op in def.operations {
            var values = passingValues(for: op)
            gateDemands(of: def, on: op.seq).forEach { values[$0] = $1 }
            try await repo.saveFields(runID: run.id, seq: op.seq, values: values, at: Date())
            let (posted, updated) = try await repo.confirmStep(
                runID: run.id, seq: op.seq, actor: "Tester", at: Date())
            run = updated
            #expect(run.confirmedSeqs.contains(op.seq))
            if let type = op.postsDocType {
                let doc = try #require(posted, "\(defID) step \(op.seq) must post a document")
                #expect(doc.docType == type)
                #expect(doc.runID == run.id)
                #expect(doc.stepSeq == op.seq)
                #expect(doc.status == .confirmed)
            } else {
                #expect(posted == nil)
            }
            // Lifecycle only moves forward: released after the first confirm,
            // confirmed only when every step is done.
            let expected: WCRunStatus =
                run.confirmedSeqs.count == def.operations.count ? .confirmed : .released
            #expect(run.status == expected)
        }

        // Double-confirm is rejected.
        await #expect(throws: WorkCenterError.stepAlreadyConfirmed(1)) {
            _ = try await repo.confirmStep(runID: run.id, seq: 1, actor: "Tester", at: Date())
        }

        // The register holds the run + every posted step doc, numbers unique.
        let docs = try await repo.documents(inRun: run.id)
        #expect(docs.count == def.operations.compactMap(\.postsDocType).count)
        let all = try await repo.allDocuments()
        #expect(Set(all.map(\.docNumber)).count == all.count, "document numbers must be unique")
    }

    @Test("Runs and their documents survive a reopen (durability)")
    func durabilityAcrossReopen() async throws {
        let url = MigrationFixtureBuilder.newTemporaryURL()
        let db = try await MigrationFixtureBuilder.database(atVersion: 0, at: url)
        try await SchemaMigrations.migrate(db)
        let repo = WorkCenterRepository(database: db)
        let def = WCCatalog.lifeRecords
        let run = try await repo.createRun(defID: def.defID, title: "Insurance", actor: "T", at: Date())
        try await repo.saveFields(runID: run.id, seq: 1,
                                  values: ["scope": "Insurance & property papers"], at: Date())
        _ = try await repo.confirmStep(runID: run.id, seq: 1, actor: "T", at: Date())

        let reopened = try MigrationFixtureBuilder.reopen(at: url)
        let repo2 = WorkCenterRepository(database: reopened)
        let restored = try #require(try await repo2.run(run.id))
        #expect(restored.docNumber == run.docNumber)
        #expect(restored.confirmedSeqs == [1])
        #expect(restored.status == .released)
        #expect(restored.fieldValues[1]?["scope"] == "Insurance & property papers")
    }

    @Test("Migration v105 reaches the new tables from a v104 database")
    func migrationReach() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 104)
        #expect(try await !MigrationFixtureBuilder.tableExists(db, "work_center_documents"))
        try await SchemaMigrations.migrate(db)
        #expect(try await db.currentUserVersion() == 105)
        #expect(try await MigrationFixtureBuilder.tableExists(db, "work_center_documents"))
        #expect(try await MigrationFixtureBuilder.tableExists(db, "work_center_counters"))
    }
}
