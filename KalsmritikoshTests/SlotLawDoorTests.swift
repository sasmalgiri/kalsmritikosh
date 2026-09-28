//
//  SlotLawDoorTests.swift
//  KalsmritikoshTests
//
//  P2.3 — a role question with one canonical, structured value is answered by
//  the slot law before any model; anything less goes to the experts.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("P2.3 — the slot law answers clean role questions before the model")
struct SlotLawDoorTests {

    private func fact(_ field: String, _ value: String) -> GenericFact {
        GenericFact(subjectLabel: "Patent No. 555489", field: field, value: value,
                    status: .sourceAsserted, confidence: 0.8, sourceBlockIDs: [UUID()])
    }

    private func evalFor(_ f: GenericFact, objectID: UUID) -> ClaimEvaluation {
        let ev = [AssertabilityEvidence(objectID: objectID, blockID: f.sourceBlockIDs.first,
                                        independenceKey: objectID.uuidString)]
        let ctx = AssertabilityContextBuilder().build(assessment: f.assessment, evidence: ev)
        return ClaimEvaluation(id: f.id, claimKind: .genericFact, assessment: ctx.assessment,
                               evidence: ev, context: ctx, decision: AssertabilityPolicy.evaluate(ctx))
    }

    private func intent(_ q: String) -> UserIntent { UserIntent(kind: .factualLookup, scope: .global, rawQuestion: q) }

    @Test("One structured applicant → slot law; two applicants, no applicant, or a non-role question → experts")
    func door() {
        let form = UUID(), letter = UUID()
        let a1 = fact("applicant", "Shirshendu Sasmal"), a2 = fact("applicant", "Shirshendu Sasmal")
        let clean = RetrievalResult(genericFacts: [a1, a2],
                                    claimEvaluations: [evalFor(a1, objectID: form), evalFor(a2, objectID: letter)],
                                    authorityObjectIDs: [form])
        #expect(MasterBrain.isSlotLawQuestion(intent: intent("Who is the applicant of the patent?"), retrieval: clean))

        let b = fact("applicant", "Tarun Khurana")
        let conflict = RetrievalResult(genericFacts: [a1, b],
                                       claimEvaluations: [evalFor(a1, objectID: form), evalFor(b, objectID: letter)],
                                       authorityObjectIDs: [form, letter])
        #expect(!MasterBrain.isSlotLawQuestion(intent: intent("Who is the applicant of the patent?"), retrieval: conflict),
                "a conflict is shown with both sources by the full path")

        let none = RetrievalResult(genericFacts: [fact("patentnumber", "555489")])
        #expect(!MasterBrain.isSlotLawQuestion(intent: intent("Who is the applicant of the patent?"), retrieval: none))
        #expect(!MasterBrain.isSlotLawQuestion(intent: intent("Tell me about the applicant"), retrieval: clean),
                "only the role shape takes the door")
    }

    @Test("With no expert claims the verifier answers a clean slot, cited to the value as written; a conflict still refuses")
    func verifierSlotLaw() async throws {
        let form = UUID(), letter = UUID()
        let a1 = GenericFact(subjectLabel: "Patent No. 555489", field: "applicant", value: "shirshendu sasmal",
                             status: .sourceAsserted, confidence: 0.8, sourceBlockIDs: [UUID()],
                             rawMatch: "SHIRSHENDU SASMAL")
        let clean = RetrievalResult(genericFacts: [a1], claimEvaluations: [evalFor(a1, objectID: form)],
                                    authorityObjectIDs: [form])
        let verifier = EvidenceVerifier(answerabilityMinRetrievalScore: 0.0)
        let answered = try await verifier.verify(intent: intent("Who is the applicant of the patent?"), findings: [], retrieval: clean)
        #expect(!answered.refused)
        #expect(answered.citations.map(\.objectID) == [form])
        #expect(answered.citations.first?.snippet == "shirshendu sasmal", "the stored value, never rawMatch")
        #expect(answered.answerText?.contains("SHIRSHENDU SASMAL") == true || answered.body.contains("SHIRSHENDU SASMAL")
                || answered.body.lowercased().contains("shirshendu sasmal"))

        let b = fact("applicant", "Tarun Khurana")
        let conflict = RetrievalResult(genericFacts: [a1, b],
                                       claimEvaluations: [evalFor(a1, objectID: form), evalFor(b, objectID: letter)],
                                       authorityObjectIDs: [form, letter])
        let refused = try await verifier.verify(intent: intent("Who is the applicant of the patent?"), findings: [], retrieval: conflict)
        #expect(refused.refused, "two values need the full path, which shows both sources")
    }
}

@Suite("P4.2 — fact lookups by block are complete and deterministic", .serialized)
struct FactBlockLookupTests {
    @Test("A document with more than 64 blocks finds its fact whichever block carries it; a stray row's blocks survive the merge")
    func lookupAndStrays() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("fbl-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try Database(url: dir.appendingPathComponent("db.sqlite"))
        try await SchemaMigrations.migrate(db)
        let repo = GenericFactRepository(database: db)

        let blocks = (0..<300).map { _ in UUID() }
        let carrier = blocks.sorted { $0.uuidString < $1.uuidString }.last!   // the block a 64-prefix would skip
        let f = GenericFact(subjectLabel: "Whole Stock", field: "date", value: "1918",
                            status: .sourceAsserted, confidence: 0.8, sourceBlockIDs: [carrier])
        try await repo.upsert(f)
        for _ in 0..<3 {
            let found = try await repo.facts(forBlockIDs: blocks.shuffled())
            #expect(found.map(\.id) == [f.id], "found on every run, not on a random subset")
        }

        // A stray duplicate row (pre-merge write) carrying another document's block.
        let other = UUID()
        let stray = GenericFact(subjectLabel: "Whole Stock", field: "date", value: "1918",
                                status: .sourceAsserted, confidence: 0.8, sourceBlockIDs: [other])
        try await repo.upsert(stray)
        try await repo.mergeUpsert(GenericFact(subjectLabel: "Whole Stock", field: "date", value: "1918",
                                               status: .sourceAsserted, confidence: 0.8, sourceBlockIDs: [carrier]))
        let survivors = try await repo.facts(forBlockIDs: [other])
        #expect(survivors.count == 1, "the stray's document still finds the fact after the collapse")
        #expect(Set(survivors.first?.sourceBlockIDs ?? []) == [carrier, other])
    }
}
