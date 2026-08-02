//
//  ProgressiveAnswerStateMachineTests.swift
//  KalsmritikoshTests
//
//  AEE-M2 — the progressive answer lifecycle: legal transition ORDER, terminality,
//  content-bearing classification, correction-reason rules, and the deterministic content
//  fingerprint (identical/reflowed content → identical hash; a real change → a new hash).
//  Synthetic only.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("AEE-M2 — progressive answer state machine + content hasher")
struct ProgressiveAnswerStateMachineTests {

    private let sm = ProgressiveAnswerStateMachine()

    @Test("The initial states are exactly the four openers")
    func initialStates() {
        for s in [ProgressiveAnswerState.immediateFinding, .groundedWorkingResult, .analysisProgress, .incomplete] {
            #expect(sm.isInitial(s))
            #expect(sm.canTransition(from: nil, to: s))
        }
        for s in [ProgressiveAnswerState.reviewReady, .verifiedFinal, .corrected] {
            #expect(!sm.isInitial(s))
            #expect(!sm.canTransition(from: nil, to: s))
        }
    }

    @Test("Terminal states have no outgoing transitions")
    func terminalHasNoOutgoing() {
        for terminal in [ProgressiveAnswerState.verifiedFinal, .incomplete] {
            for to in ProgressiveAnswerState.allCases {
                #expect(!sm.canTransition(from: terminal, to: to), "\(terminal)→\(to) must be illegal")
            }
        }
    }

    @Test("An immediate finding may go straight to review-ready (deterministic fast path)")
    func immediateToReviewReady() {
        #expect(sm.canTransition(from: .immediateFinding, to: .reviewReady))
    }

    @Test("A working result cannot repeat itself; a material change is a correction")
    func workingResultRepeatIllegal() {
        #expect(!sm.canTransition(from: .groundedWorkingResult, to: .groundedWorkingResult))
        #expect(sm.canTransition(from: .groundedWorkingResult, to: .corrected))
    }

    @Test("Review-ready may finalise or be corrected or fall to incomplete")
    func reviewReadyOutgoing() {
        #expect(sm.canTransition(from: .reviewReady, to: .verifiedFinal))
        #expect(sm.canTransition(from: .reviewReady, to: .corrected))
        #expect(sm.canTransition(from: .reviewReady, to: .incomplete))
    }

    @Test("Progress may repeat and may precede a working result")
    func progressChaining() {
        #expect(sm.canTransition(from: .analysisProgress, to: .analysisProgress))
        #expect(sm.canTransition(from: .analysisProgress, to: .groundedWorkingResult))
    }

    @Test("A correction must return through review-ready before final — never straight to verifiedFinal")
    func correctedNotDirectlyFinal() {
        #expect(sm.canTransition(from: .corrected, to: .reviewReady))
        #expect(!sm.canTransition(from: .corrected, to: .verifiedFinal))
    }

    @Test("validate throws the specific illegal-transition error")
    func validateThrows() {
        #expect(throws: ProgressiveAnswerError.self) {
            try sm.validate(from: .groundedWorkingResult, to: .verifiedFinal)
        }
        #expect(throws: Never.self) {
            try sm.validate(from: .reviewReady, to: .verifiedFinal)
        }
    }

    @Test("Only analysisProgress is non-content-bearing")
    func contentBearing() {
        #expect(!ProgressiveAnswerState.analysisProgress.isContentBearing)
        for s in ProgressiveAnswerState.allCases where s != .analysisProgress {
            #expect(s.isContentBearing, "\(s) should be content-bearing")
        }
    }

    @Test("Only verifiedFinal and incomplete are terminal")
    func terminalClassification() {
        #expect(ProgressiveAnswerState.verifiedFinal.isTerminal)
        #expect(ProgressiveAnswerState.incomplete.isTerminal)
        for s in ProgressiveAnswerState.allCases where s != .verifiedFinal && s != .incomplete {
            #expect(!s.isTerminal, "\(s) should not be terminal")
        }
    }

    @Test("Correction reason rules: only .other needs detail; only .userCorrection is user-attributed")
    func correctionReasonRules() {
        for k in CorrectionReasonKind.allCases {
            #expect(k.requiresDetail == (k == .other))
            #expect(k.isUserAttributed == (k == .userCorrection))
        }
    }

    // MARK: - Content hasher

    private func citation(_ obj: UUID, chunk: UUID? = nil, event: UUID? = nil, snippet: String = "s") -> VerifiedAnswer.Citation {
        VerifiedAnswer.Citation(objectID: obj, chunkID: chunk, eventID: event, snippet: snippet)
    }

    @Test("Identical content and reflowed whitespace hash the same")
    func hashStableUnderReflow() {
        let h = ProgressiveAnswerContentHasher()
        let obj = UUID()
        let a = h.hash(answerText: "The amount was 500.", citations: [citation(obj)], answerState: .supported)
        let b = h.hash(answerText: "The   amount\n was    500.", citations: [citation(obj)], answerState: .supported)
        #expect(a == b)
        #expect(a.count == 64)
        #expect(a.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    @Test("A material change to text, state, or cited evidence changes the hash")
    func hashChangesOnMaterialChange() {
        let h = ProgressiveAnswerContentHasher()
        let obj = UUID(), other = UUID()
        let base = h.hash(answerText: "Paid 500.", citations: [citation(obj)], answerState: .supported)
        #expect(base != h.hash(answerText: "Paid 600.", citations: [citation(obj)], answerState: .supported))          // text
        #expect(base != h.hash(answerText: "Paid 500.", citations: [citation(obj)], answerState: .contradicted))       // state
        #expect(base != h.hash(answerText: "Paid 500.", citations: [citation(other)], answerState: .supported))        // evidence identity
    }

    @Test("Citation ORDER and snippet wording do not perturb the fingerprint")
    func hashIgnoresOrderAndSnippet() {
        let h = ProgressiveAnswerContentHasher()
        let a = UUID(), b = UUID()
        let one = h.hash(answerText: "x", citations: [citation(a, snippet: "alpha"), citation(b, snippet: "beta")], answerState: .supported)
        let two = h.hash(answerText: "x", citations: [citation(b, snippet: "DIFFERENT"), citation(a, snippet: "words")], answerState: .supported)
        #expect(one == two)
    }
}
