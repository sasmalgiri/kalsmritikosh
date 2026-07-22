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

    @Test("A résumé outranks a whole-mailbox super-KO that quotes the same CV text")
    func resumeBeatsMboxSuperDocument() {
        // Real-corpus failure: the whole Sent.mbox is one giant KO whose content
        // quotes everyone's CVs/receipts, so it reads as 'employment' too and has
        // MORE subject mentions than the focused résumé. It must still lose:
        // a source's role is its document type (correspondence), not quoted text.
        let plan = qc.compile(
            intent: UserIntent(kind: .factualLookup, scope: .person("Shirshendu Sasmal"),
                               rawQuestion: "Where has Shirshendu Sasmal worked?"),
            category: .fact, queryClass: .ordinary)
        let resume = signals("Resume.doc", .doc, fields: [.employment], mentions: 2)      // low mentions
        let mbox = signals("Sent.mbox", .mbox, fields: [.employment], mentions: 40)       // quotes CV, high mentions
        let ranked = scorer.rank(plan: plan, candidates: [mbox, resume])
        #expect(ranked.first?.objectID == resume.objectID)
    }

    @Test("Email family is correspondence regardless of quoted content")
    func emailAlwaysCorrespondence() {
        // Even a file named 'Resume.eml' with employment content is correspondence,
        // never biographical — the attachment .doc is the biographical source.
        let roles = DocumentRoleInference.inferRoles(fileName: "Resume forwarded.eml", sourceType: .eml, presentFields: [.employment])
        #expect(roles == [.correspondence])
    }

    @Test("RET-008: duplicate copies collapse to one independent source")
    func duplicatesAreNotCorroboration() {
        let cvA = "Curriculum Vitae Shirshendu Sasmal — worked at Orchid Chemicals."
        let cvB = "Curriculum   Vitae, Shirshendu Sasmal — worked at Orchid Chemicals!"  // same content, different whitespace/punct
        let other = "Completely different document about a patent filing."
        func s(_ file: String, _ text: String) -> DocumentSignals {
            DocumentSignals(objectID: UUID(), fileName: file, sourceType: .doc,
                roleHints: [.biographical], presentFields: [.employment], subjectMentionCount: 2,
                contentSignature: DocumentRoleInference.contentSignature(text))
        }
        let cands = [s("cv1.doc", cvA), s("cv2.doc", cvB), s("cv3.doc", cvA), s("patent.doc", other)]
        #expect(scorer.independentSourceCount(cands) == 2) // the CV (any spelling) + the other
        let (reps, collapsed) = scorer.rankDeduped(plan:
            qc.compile(intent: UserIntent(kind: .factualLookup, scope: .person("Sasmal"), rawQuestion: "Where has Sasmal worked?"),
                       category: .fact, queryClass: .ordinary),
            candidates: cands)
        #expect(collapsed == 2)          // two extra CV copies collapsed
        #expect(reps.count == 2)
    }

    @Test("Role inference maps filenames to roles by reusable signal, not by example")
    func roleInferenceSignals() {
        #expect(DocumentRoleInference.inferRoles(fileName: "MyResume.pdf", sourceType: .pdf, presentFields: []).contains(.biographical))
        #expect(DocumentRoleInference.inferRoles(fileName: "invoice_2024.pdf", sourceType: .pdf, presentFields: []).contains(.transactional))
        #expect(DocumentRoleInference.inferRoles(fileName: "NDA_final.docx", sourceType: .docx, presentFields: []).contains(.contractual))
        #expect(DocumentRoleInference.inferRoles(fileName: "note.eml", sourceType: .eml, presentFields: []).contains(.correspondence))
    }
}
