//
//  GeneralKnowledgeLaneTests.swift
//  Kalsmritikosh Tests
//
//  GK gold — the labeling law: the banner leads 100% of unsourced renderings;
//  eligibility follows only an archive-lane refusal (never a grounded answer,
//  never a conversational brush-off); the lane's type carries nothing
//  evidence-shaped; and the archive lane is untouched (the sealed seven keep
//  their shapes — the lane lives above the brain, in the Ask surface).
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("GK — the general-knowledge lane (banner-first, refusal-only, evidence-free)")
struct GeneralKnowledgeLaneTests {

    @Test("Eligibility: only an archive refusal opens the lane")
    func eligibility() {
        // Out-of-scope refusal → eligible (the lane's whole purpose).
        #expect(GeneralKnowledgeLane.eligible(
            refused: true, refusalReason: QuestionShapeRouter.outOfScopeRefusal))
        // Can't-ground refusal → eligible ("about the world, not in the docs").
        #expect(GeneralKnowledgeLane.eligible(
            refused: true, refusalReason: "The question asks for a specific value that no extracted field or quotable sentence carries."))
        // A grounded answer NEVER opens it — the archive lane won.
        #expect(!GeneralKnowledgeLane.eligible(refused: false, refusalReason: nil))
        // A conversational brush-off never opens it.
        #expect(!GeneralKnowledgeLane.eligible(
            refused: true,
            refusalReason: "That looks like a message to the app, not a question about your archive."))
    }

    @Test("The banner leads every rendering — 100%, no exceptions")
    func bannerFirst() {
        let rendered = GeneralKnowledgeLane.render("Paris is the capital of France.")
        #expect(rendered.hasPrefix(GeneralKnowledgeLane.banner),
                "an unsourced sentence may never appear above its banner")
        // RS-U6 — the block closes with the model stamp: author named, always.
        #expect(rendered.contains("AI text by"), "the AI-authored block names its author")
        #expect(LegalNotice.modelStamp().contains("FoundationModels"))
        #expect(LegalNotice.modelStamp().contains("macOS"))
        #expect(GeneralKnowledgeLane.banner.contains("Not from your documents"))
        #expect(GeneralKnowledgeLane.banner.contains("may be wrong") ||
                GeneralKnowledgeLane.banner.contains("It may be wrong"))
        #expect(GeneralKnowledgeLane.banner.contains("No sources"))
        // The deterministic-Mac note is a state, not an error, and points back
        // to the archive lane that DID run.
        #expect(GeneralKnowledgeLane.unavailableNote.contains("unavailable"))
        #expect(GeneralKnowledgeLane.unavailableNote.contains("still searched"))
    }

    @Test("Separation by construction: the lane returns bare text — nothing evidence-shaped exists to leak")
    func separationByConstruction() {
        // The lane's answer type is String? — no citations, no confidence, no
        // evidence IDs, no VerifiedAnswer. The compiler enforces the law; this
        // test documents it and pins the render shape.
        let block = GeneralKnowledgeLane.render("Some general fact.")
        #expect(!block.contains("Citation"))
        #expect(!block.contains("Confidence"))
        // And the sealed seven keep their shapes — the lane lives ABOVE the
        // brain, so the router's world is unchanged.
        #expect(QuestionShapeRouter.route("what is the capital of France").shape == .outOfScope)
        #expect(QuestionShapeRouter.route("what is the granted patent number").shape == .unresolved)
    }
}
