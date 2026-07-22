//
//  ReconstructCitationRefinerTests.swift
//  KalsmritikoshTests
//
//  P5.2 — the reconstruct-path citation refiner. The narrative composer can
//  only cite documents that produced a dated event, so an authoritative
//  structural doc (a contract/amendment) is otherwise uncitable; and because
//  every candidate shares the SUBJECT term, plain keyword filtering can't drop
//  the incidental email pile. These tests lock in the pure, deterministic
//  behavior — the end-to-end gold eval is intentionally NOT the validation here
//  because its narrative is composed by a non-deterministic LLM (run-to-run
//  swings), whereas this logic must be stable given fixed inputs.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("P5.2 ReconstructCitationRefiner")
struct ReconstructCitationRefinerTests {

    private func chunk(_ oid: UUID, _ text: String) -> RetrievedChunk {
        let c = Chunk(
            id: UUID(), objectID: oid, ordinal: 0, text: text,
            characterRange: 0..<max(1, text.count), createdAt: .distantPast
        )
        return RetrievedChunk(chunk: c, score: 1.0, viaLayer: .entity)
    }
    private func cite(_ oid: UUID, _ snippet: String) -> VerifiedAnswer.Citation {
        VerifiedAnswer.Citation(objectID: oid, snippet: snippet)
    }

    @Test("Discriminative terms drop the subject and stopwords")
    func discriminativeTerms() {
        let terms = MasterBrain.discriminativeTerms(
            question: "How did the contract status evolve over time for Project Delta?",
            entityHints: ["Project Delta"]
        )
        #expect(terms.contains("contract"))
        #expect(terms.contains("status"))
        #expect(!terms.contains("project"))   // subject
        #expect(!terms.contains("delta"))     // subject
        #expect(!terms.contains("the"))       // stopword
        #expect(!terms.contains("how"))       // question word
    }

    @Test("Light stemming folds verb inflection so 'delayed' matches 'delay'")
    func stemming() {
        let terms = MasterBrain.discriminativeTerms(
            question: "Why was Project Delta delayed?", entityHints: ["Project Delta"]
        )
        #expect(terms.contains("delay"))       // "delayed" → "delay"
        #expect(!terms.contains("delayed"))
    }

    @Test("Folds an authoritative doc the narrative could not cite, drops subject-only noise")
    func foldsAuthorityDropsNoise() {
        let contract = UUID(), amendment = UUID(), invoice = UUID(), supplier = UUID()
        let chunks = [
            chunk(contract, "Master Supply Agreement Project Delta. Total contract value USD 1,800,000."),
            chunk(amendment, "Amendment No. 7 Project Delta. this amendment is a contract modified record."),
            chunk(invoice, "Invoice No. 401 Project Delta milestone 1. Amount due USD 540,000."),
            chunk(supplier, "Re: Project Delta review amendment. Approval delayed. weekly status note."),
        ]
        // Narrative could only cite the event-sourced emails; authority ranking
        // (RET-009) surfaced the contract + amendment.
        let refined = MasterBrain.refineReconstructCitations(
            question: "How did the contract status evolve over time for Project Delta?",
            entityHints: ["Project Delta"],
            narrativeCitations: [cite(invoice, "invoice"), cite(supplier, "supplier")],
            chunks: chunks,
            authorityObjectIDs: [contract, amendment],
            cap: 6
        )
        let ids = Set(refined.map(\.objectID))
        #expect(ids.contains(contract))       // authoritative doc folded in
        #expect(ids.contains(amendment))       // authoritative doc folded in
        #expect(!ids.contains(invoice))        // subject-only noise ("Project Delta") dropped
    }

    @Test("No discriminative terms (subject-only question) → narrative citations pass through unchanged")
    func noOpWithoutDiscriminativeTerms() {
        let a = UUID(), b = UUID()
        let original = [cite(a, "a"), cite(b, "b")]
        let refined = MasterBrain.refineReconstructCitations(
            question: "Project Delta",
            entityHints: ["Project Delta"],
            narrativeCitations: original,
            chunks: [chunk(a, "Project Delta doc")],
            authorityObjectIDs: [a],
            cap: 6
        )
        #expect(refined.map(\.objectID) == original.map(\.objectID))
    }

    @Test("Nothing matches the discriminative terms → do not empty a grounded answer")
    func neverEmpties() {
        let a = UUID(), b = UUID()
        let original = [cite(a, "unrelated text"), cite(b, "more unrelated text")]
        let refined = MasterBrain.refineReconstructCitations(
            question: "What were the payment terms of the contract?",
            entityHints: ["Project Delta"],
            narrativeCitations: original,
            chunks: [chunk(a, "unrelated text"), chunk(b, "more unrelated text")],
            authorityObjectIDs: [],
            cap: 6
        )
        // No candidate carries "payment"/"terms"/"contract" → passthrough, not empty.
        #expect(!refined.isEmpty)
        #expect(refined.map(\.objectID) == original.map(\.objectID))
    }
}
