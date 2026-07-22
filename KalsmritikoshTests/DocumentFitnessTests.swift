//
//  DocumentFitnessTests.swift
//  KalsmritikoshTests
//
//  RET-003 — verifies question-conditioned document fitness ranks the AUTHORITATIVE
//  source above a high-density incidental one, using the two real-corpus failures
//  from project_retrieval_authority as the gold cases. This is the general rule that
//  replaces the mention-density authority heuristic; it must hold by FIT, not by name.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("RET-003 DocumentFitness")
struct DocumentFitnessTests {

    private let qc = QueryPlanCompiler()
    private let scorer = DocumentFitnessScorer()

    private func signals(_ file: String, _ type: SourceType, fields: Set<RequestedField>, mentions: Int) -> DocumentSignals {
        DocumentSignals(
            objectID: UUID(),
            fileName: file,
            sourceType: type,
            roleHints: DocumentRoleInference.inferRoles(fileName: file, sourceType: type, presentFields: fields),
            presentFields: fields,
            subjectMentionCount: mentions
        )
    }

    @Test("Résumé outranks a patent email for 'where worked' despite 186 vs 15 mentions")
    func resumeBeatsDensePatentEmail() {
        let plan = qc.compile(
            intent: UserIntent(kind: .factualLookup, scope: .person("Shirshendu Sasmal"),
                               rawQuestion: "Where has Shirshendu Sasmal worked?"),
            category: .fact, queryClass: .ordinary)
        let resume = signals("Resume.doc", .doc, fields: [.employment], mentions: 15)
        let patentEmail = signals("Patent grant.eml", .eml, fields: [], mentions: 186)

        let ranked = scorer.rank(plan: plan, candidates: [patentEmail, resume])
        #expect(ranked.first?.objectID == resume.objectID)
        #expect(ranked.first!.score > ranked.last!.score)
    }

    @Test("Receipt image outranks the payment email for a payment question")
    func receiptBeatsPaymentEmail() {
        let plan = qc.compile(
            intent: UserIntent(kind: .factualLookup, scope: .global,
                               rawQuestion: "PhonePe payment — to whom and how much was paid?"),
            category: .fact, queryClass: .ordinary)
        let receipt = signals("TransactionReceipt.jpeg", .jpg, fields: [.monetaryAmount, .counterparty], mentions: 1)
        let payEmail = signals("Payment done.eml", .eml, fields: [.date], mentions: 8)

        let ranked = scorer.rank(plan: plan, candidates: [payEmail, receipt])
        #expect(ranked.first?.objectID == receipt.objectID)
    }

    @Test("Raw density cannot outrank a role+field match")
    func densityNeverOutranksFit() {
        let plan = qc.compile(
            intent: UserIntent(kind: .factualLookup, scope: .person("X"),
                               rawQuestion: "Where has X worked?"),
            category: .fact, queryClass: .ordinary)
        let fit = signals("cv.pdf", .pdf, fields: [.employment], mentions: 1)
        let dense = signals("thread.mbox", .mbox, fields: [], mentions: 10_000)
        let ranked = scorer.rank(plan: plan, candidates: [dense, fit])
        #expect(ranked.first?.objectID == fit.objectID)
    }

    @Test("Correspondence-only doc is penalized when a specific role is requested")
    func correspondencePenaltyApplies() {
        let plan = qc.compile(
            intent: UserIntent(kind: .factualLookup, scope: .global,
                               rawQuestion: "What were the terms of the agreement?"),
            category: .fact, queryClass: .ordinary)
        let email = signals("discussion.eml", .eml, fields: [], mentions: 50)
        let verdict = scorer.score(plan: plan, candidate: email)
        #expect(verdict.score < 0) // penalty dominates a no-fit correspondence doc
    }

    @Test("Role inference maps filenames to roles by reusable signal, not by example")
    func roleInferenceSignals() {
        #expect(DocumentRoleInference.inferRoles(fileName: "MyResume.pdf", sourceType: .pdf, presentFields: []).contains(.biographical))
        #expect(DocumentRoleInference.inferRoles(fileName: "invoice_2024.pdf", sourceType: .pdf, presentFields: []).contains(.transactional))
        #expect(DocumentRoleInference.inferRoles(fileName: "NDA_final.docx", sourceType: .docx, presentFields: []).contains(.contractual))
        #expect(DocumentRoleInference.inferRoles(fileName: "note.eml", sourceType: .eml, presentFields: []).contains(.correspondence))
    }
}
