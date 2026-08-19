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

    @Test("Auto-complete eligibility — engagement guard, required fields, gates")
    func autoCompleteEligibility() {
        let receive = WCCatalog.evidenceIntake.operations[0]   // has required fields + launches a tool
        let filled = ["caseNumber": "CASE-1", "custodian": "j.doe"]
        // A tool step needs its tool opened — touch alone is not engagement.
        #expect(!WCAutoComplete.eligible(receive, confirmed: [], lockedReasons: [],
                                         values: filled, touched: true, openedTool: false))
        #expect(WCAutoComplete.eligible(receive, confirmed: [], lockedReasons: [],
                                        values: filled, touched: false, openedTool: true))
        // Missing required fields never auto-complete.
        #expect(!WCAutoComplete.eligible(receive, confirmed: [], lockedReasons: [],
                                         values: ["caseNumber": "CASE-1"], touched: true, openedTool: true))
        // Confirmed or locked steps never auto-complete.
        #expect(!WCAutoComplete.eligible(receive, confirmed: [1], lockedReasons: [],
                                         values: filled, touched: true, openedTool: true))
        #expect(!WCAutoComplete.eligible(receive, confirmed: [], lockedReasons: ["locked"],
                                         values: filled, touched: true, openedTool: true))
        // A step with NO required fields never auto-completes (nothing to fill = no signal).
        let examine = WCCatalog.evidenceIntake.operations[2]
        #expect(!WCAutoComplete.eligible(examine, confirmed: [1, 2], lockedReasons: [],
                                         values: ["itemsOfInterest": "3"], touched: true, openedTool: true))
    }

    @Test("Reserved keys — attestation parses, prefix detection")
    func reservedKeys() {
        #expect(WCReservedKey.isReserved("__note"))
        #expect(!WCReservedKey.isReserved("caseNumber"))
        let values = [WCReservedKey.confirmedAt: "1700000000",
                      WCReservedKey.confirmedBy: "Tester"]
        let att = WCReservedKey.attestation(in: values)
        #expect(att?.by == "Tester")
        #expect(att?.at == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(WCReservedKey.attestation(in: ["caseNumber": "X"]) == nil)
    }

    @Test("Document filter — number, title, field value, reserved keys excluded")
    func documentFilter() {
        let doc = WCDocument(
            id: UUID(), docNumber: "WF-2026-0007", docType: "WF", runID: nil,
            defID: "builtin.investigator.intake", stepSeq: nil,
            title: "Estate matter", status: .released,
            fieldValues: [1: ["caseNumber": "CASE-42",
                              WCReservedKey.note: "call the custodian",
                              WCReservedKey.confirmedBy: "SecretActorKey"]],
            confirmedSeqs: [1], actor: "Tester",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(WCDocumentFilter.matches(doc, query: ""))
        #expect(WCDocumentFilter.matches(doc, query: "wf-2026"))
        #expect(WCDocumentFilter.matches(doc, query: "estate"))
        #expect(WCDocumentFilter.matches(doc, query: "case-42"))
        #expect(WCDocumentFilter.matches(doc, query: "custodian"), "notes are searchable")
        #expect(!WCDocumentFilter.matches(doc, query: "SecretActorKey"),
                "reserved attestation values are not search text")
        #expect(!WCDocumentFilter.matches(doc, query: "no-such-thing"))
        // Date range: inclusive of the creation day, exclusive outside it.
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(WCDocumentFilter.inRange(doc, from: day, to: day, calendar: .current))
        #expect(!WCDocumentFilter.inRange(doc, from: day.addingTimeInterval(2 * 86_400),
                                          to: day.addingTimeInterval(3 * 86_400), calendar: .current))
    }

    @Test("Technical report — steps, marks, values, attestations, doc echoes")
    func instanceReport() {
        let def = WCCatalog.evidenceIntake
        let runID = UUID()
        let run = WCDocument(
            id: runID, docNumber: "WF-2026-0001", docType: "WF", runID: nil,
            defID: def.defID, stepSeq: nil, title: "Estate intake", status: .released,
            fieldValues: [1: ["caseNumber": "CASE-42", "custodian": "j.doe",
                              WCReservedKey.confirmedAt: "1700000000",
                              WCReservedKey.confirmedBy: "Tester",
                              WCReservedKey.note: "receipt attached"]],
            confirmedSeqs: [1], actor: "Tester",
            createdAt: Date(timeIntervalSince1970: 1_699_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let intake = WCDocument(
            id: UUID(), docNumber: "IMP-2026-0001", docType: "IMP", runID: runID,
            defID: def.defID, stepSeq: 1, title: "Receive & Identify — Estate intake",
            status: .confirmed, fieldValues: [:], confirmedSeqs: [1], actor: "Tester",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let text = WCInstanceReport(run: run, definition: def, documents: [intake]).rendered()
        #expect(text.contains("WORKFLOW WF-2026-0001"))
        #expect(text.contains("[x] 1. Receive & Identify"))
        #expect(text.contains("[ ] 2. Preserve & Verify"))
        #expect(text.contains("Case / Matter number: CASE-42"))
        #expect(text.contains("by Tester"))
        #expect(text.contains("→ IMP-2026-0001"))
        #expect(text.contains("note: receipt attached"))
        #expect(!text.contains("__confirmed"), "reserved keys never leak as text")
    }

    @Test("Stakeholder summary — plain language, records produced, no jargon leaks")
    func stakeholderSummary() {
        let def = WCCatalog.production
        let runID = UUID()
        let run = WCDocument(
            id: runID, docNumber: "WF-2026-0002", docType: "WF", runID: nil,
            defID: def.defID, stepSeq: nil, title: "Acme v. Roe production", status: .released,
            fieldValues: [1: ["matter": "Acme v. Roe",
                              WCReservedKey.confirmedAt: "1700000000",
                              WCReservedKey.confirmedBy: "Counsel"]],
            confirmedSeqs: [1], actor: "Counsel",
            createdAt: Date(timeIntervalSince1970: 1_699_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let prod = WCDocument(
            id: UUID(), docNumber: "PRD-2026-0001", docType: "PRD", runID: runID,
            defID: def.defID, stepSeq: 5, title: "Produce — Acme", status: .confirmed,
            fieldValues: [:], confirmedSeqs: [5], actor: "Counsel",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let text = WCStakeholderSummary(run: run, definition: def, documents: [prod],
                                        preparedAt: Date(timeIntervalSince1970: 1_700_100_000)).rendered()
        #expect(text.contains("# Acme v. Roe production"))
        #expect(text.contains("**Reference:** WF-2026-0002"))
        #expect(text.contains("In progress — 1 of 5 steps done"))
        #expect(text.contains("**Assemble Set** — completed"))
        #expect(text.contains("by Counsel"))
        #expect(text.contains("**Review & Code** — not yet started."))
        #expect(text.contains("## Records produced"))
        #expect(text.contains("- PRD-2026-0001"))
        #expect(!text.contains("__confirmed"), "reserved keys never leak")
        #expect(!text.contains("seq"), "no engine jargon in the stakeholder summary")
    }

    @Test("Step refs — JSON codec round-trips, garbage decodes empty")
    func stepRefsCodec() {
        let refs = [WCStepRef(id: "a", title: "ledger.pdf", detail: "/Users/x/Documents"),
                    WCStepRef(id: "b", title: "receipt.jpg", detail: "")]
        let json = WCStepRef.encodeList(refs)
        #expect(WCStepRef.decodeList(json) == refs)
        #expect(WCStepRef.decodeList(nil) == [])
        #expect(WCStepRef.decodeList("not json") == [])
    }

    @Test("Attached evidence is searchable in the documents register")
    func refsSearchable() {
        let doc = WCDocument(
            id: UUID(), docNumber: "WF-2026-0009", docType: "WF", runID: nil,
            defID: "builtin.individual.records", stepSeq: nil,
            title: "Records", status: .released,
            fieldValues: [1: [WCReservedKey.refs: WCStepRef.encodeList(
                [WCStepRef(id: "a", title: "insurance-policy.pdf", detail: "/tmp")])]],
            confirmedSeqs: [1], actor: "Tester",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(WCDocumentFilter.matches(doc, query: "insurance-policy"))
    }

    @Test("Field derivation — examiner fills reviewer, matter identity carries over, never overwrites")
    func fieldDerivation() {
        let assemble = WCCatalog.production.operations[0]   // matter (carry-over) + reviewer (examiner)
        let prior = WCDocument(
            id: UUID(), docNumber: "WF-2026-0001", docType: "WF", runID: nil,
            defID: WCCatalog.production.defID, stepSeq: nil,
            title: "Earlier run", status: .confirmed,
            fieldValues: [1: ["matter": "Acme v. Roe"]],
            confirmedSeqs: [1], actor: "T",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let derived = WCFieldDerivation.derive(for: assemble, examiner: "R. Reviewer", priorRuns: [prior])
        #expect(derived["matter"] == "Acme v. Roe")
        #expect(derived["reviewer"] == "R. Reviewer")
        // Non-carry-over keys are never invented; findings never carry over.
        let report = WCCatalog.evidenceIntake.operations[4]
        #expect(WCFieldDerivation.derive(for: report, examiner: "X", priorRuns: [prior]).isEmpty)
        // Blank prior values don't count.
        let blankPrior = WCDocument(
            id: UUID(), docNumber: "WF-2026-0002", docType: "WF", runID: nil,
            defID: WCCatalog.production.defID, stepSeq: nil,
            title: "t", status: .open, fieldValues: [1: ["matter": "  "]],
            confirmedSeqs: [], actor: "T",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(WCFieldDerivation.derive(for: assemble, examiner: "", priorRuns: [blankPrior]).isEmpty)
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
            case .date: values[field.key] = "2026-08-17"
            case .dateRange: values[field.key] = "2026-07-18 → 2026-08-17"
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

    @Test("Variants — numbered VAR document, reserved keys stripped, listed per definition")
    func variants() async throws {
        let (repo, _, _) = try await makeRepo()
        let defID = WCCatalog.production.defID
        let values: [Int: [String: String]] = [
            1: ["matter": "Acme v. Roe", "reviewer": "R. Reviewer",
                WCReservedKey.confirmedAt: "1700000000", WCReservedKey.confirmedBy: "X"],
            3: [WCReservedKey.note: "internal only"],
        ]
        let variant = try await repo.createVariant(
            defID: defID, name: "Acme template", values: values, actor: "Tester", at: Date())
        #expect(variant.docType == "VAR")
        #expect(variant.docNumber.hasPrefix("VAR-"))
        #expect(variant.title == "Acme template")
        #expect(variant.fieldValues[1] == ["matter": "Acme v. Roe", "reviewer": "R. Reviewer"],
                "a variant is master data — attestations don't ride along")
        #expect(variant.fieldValues[3] == nil, "steps left with only reserved keys drop out")
        let listed = try await repo.variants(defID: defID)
        #expect(listed.map(\.id) == [variant.id])
        #expect(try await repo.variants(defID: WCCatalog.lifeRecords.defID).isEmpty)
        // Variants never appear in the runs list.
        #expect(try await repo.runs().isEmpty)
    }

    @Test("Number uniqueness under concurrent burst — 120 documents, three ranges, zero duplicates, zero gaps")
    func numbersUniqueUnderBurst() async throws {
        let (repo, _, _) = try await makeRepo()
        let when = Date(timeIntervalSince1970: 1_755_000_000)
        // Hammer the number ranges from many concurrent tasks: 40 EXP
        // captures, 40 RPT captures, and 40 WF runs, all racing into the
        // one repository actor. The actor serializes, the counter upsert is
        // atomic, and the schema's UNIQUE would reject any slip — this test
        // proves the composition holds end to end.
        let numbers = try await withThrowingTaskGroup(of: String.self) { group in
            for i in 0..<40 {
                group.addTask {
                    try await repo.capture(type: "EXP", title: "burst \(i)", values: [:],
                                           actor: "T", at: when).docNumber
                }
                group.addTask {
                    try await repo.capture(type: "RPT", title: "burst \(i)", values: [:],
                                           actor: "T", at: when).docNumber
                }
                group.addTask {
                    try await repo.createRun(defID: WCCatalog.lifeRecords.defID,
                                             title: "burst \(i)", actor: "T", at: when).docNumber
                }
            }
            var collected: [String] = []
            for try await number in group { collected.append(number) }
            return collected
        }
        #expect(numbers.count == 120)
        #expect(Set(numbers).count == 120, "every issued number must be globally unique")

        // Each type's range is gapless: exactly 1...40, no skips, no repeats.
        let year = Calendar(identifier: .gregorian).component(.year, from: when)
        for type in ["EXP", "RPT", "WF"] {
            let seqs = numbers.filter { $0.hasPrefix("\(type)-") }
                .compactMap { Int($0.split(separator: "-").last ?? "") }
                .sorted()
            #expect(seqs == Array(1...40), "\(type)-\(year) range must be gapless 1...40, got \(seqs.count) values")
        }

        // And the register agrees with itself.
        let all = try await repo.allDocuments(limit: 500)
        #expect(Set(all.map(\.docNumber)).count == all.count)
    }

    @Test("A failed issue rolls back its number — no gaps from errors")
    func failedIssueLeavesNoGap() async throws {
        let (repo, _, _) = try await makeRepo()
        let when = Date(timeIntervalSince1970: 1_755_000_000)
        let first = try await repo.capture(type: "EXP", title: "ok", values: [:], actor: "T", at: when)
        // A failing insert (blank title violates the CHECK) must roll back
        // the counter increment inside the same savepoint…
        await #expect(throws: (any Error).self) {
            _ = try await repo.capture(type: "EXP", title: "   ", values: [:], actor: "T", at: when)
        }
        // …so the NEXT number continues the sequence with no gap.
        let second = try await repo.capture(type: "EXP", title: "ok again", values: [:], actor: "T", at: when)
        let seq = { (n: String) in Int(n.split(separator: "-").last ?? "") ?? -1 }
        #expect(seq(second.docNumber) == seq(first.docNumber) + 1,
                "gapless after rollback: \(first.docNumber) then \(second.docNumber)")
    }

    @Test("Universal capture — a standalone EXP document with its own number and facts")
    func universalCapture() async throws {
        let (repo, _, _) = try await makeRepo()
        let doc = try await repo.capture(type: "EXP", title: "Premiums — XLSX export",
                                         values: ["Format": "XLSX", "Rows": "12"],
                                         actor: "Tester", at: Date())
        #expect(doc.docType == "EXP")
        #expect(doc.docNumber.hasPrefix("EXP-"))
        #expect(doc.status == .confirmed)
        #expect(doc.runID == nil && doc.defID == nil && doc.stepSeq == nil,
                "captures stand alone — no run, no recipe, no step")
        #expect(doc.fieldValues[1]?["Format"] == "XLSX")
        let second = try await repo.capture(type: "EXP", title: "again", values: [:],
                                            actor: "Tester", at: Date())
        #expect(second.docNumber != doc.docNumber, "the EXP number range advances")
        // Captures appear in the register but never in the runs list.
        #expect(try await repo.runs().isEmpty)
        #expect(try await repo.allDocuments().count == 2)
    }

    @Test("Rename — the client/matter name replaces the run title")
    func renameRun() async throws {
        let (repo, _, _) = try await makeRepo()
        let run = try await repo.createRun(defID: WCCatalog.storyBuild.defID,
                                           title: "Story Build", actor: "T", at: Date())
        try await repo.rename(runID: run.id, title: "Panama files", at: Date())
        #expect(try await repo.run(run.id)?.title == "Panama files")
        try await repo.rename(runID: run.id, title: "   ", at: Date())
        #expect(try await repo.run(run.id)?.title == "Panama files", "blank names are ignored")
    }

    @Test("confirmStep stamps the who/when attestation into the step's values")
    func attestationStamped() async throws {
        let (repo, _, _) = try await makeRepo()
        let def = WCCatalog.lifeRecords
        let run = try await repo.createRun(defID: def.defID, title: "t", actor: "Creator", at: Date())
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        try await repo.saveFields(runID: run.id, seq: 1,
                                  values: ["scope": "Insurance", WCReservedKey.note: "first pass"],
                                  at: when)
        _ = try await repo.confirmStep(runID: run.id, seq: 1, actor: "Attester", at: when)
        let after = try #require(try await repo.run(run.id))
        let vals = try #require(after.fieldValues[1])
        let att = try #require(WCReservedKey.attestation(in: vals))
        #expect(att.by == "Attester")
        #expect(att.at == when)
        #expect(vals["scope"] == "Insurance", "user values survive the stamp")
        #expect(vals[WCReservedKey.note] == "first pass", "the note rides with the record")
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
