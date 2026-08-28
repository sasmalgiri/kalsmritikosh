//
//  ConversationalRefusalTests.swift
//  KalsmritikoshTests
//
//  v1.0-rc5 owner-acceptance finding — a conversational utterance ("how are
//  you online?") was forced into `.ordinary`, retrieval keyword-matched
//  unrelated ledger facts, and the engine shipped a 37%-confidence fact dump.
//  The evidence contract requires an HONEST REFUSAL for input that is not a
//  question about the archive; the detector must stay conservative so real
//  archival questions containing similar phrases are never refused.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Conversational refusal (§8.4 unsupported)", .serialized)
struct ConversationalRefusalTests {

    @Test("Clear conversational/meta utterances classify as unsupported")
    func conversationalDetected() {
        for q in ["how are you online?", "How are you?", "hello", "Hi there!",
                  "are you online", "who are you?", "thanks", "what can you do"] {
            #expect(LLMQueryClassifier.isConversational(q), "should refuse: \(q)")
        }
    }

    @Test("Archival questions are NEVER classified conversational")
    func archivalNotDetected() {
        for q in ["how are you calculating totals per invoice",
                  "who are you referring to in the contract?",
                  "Why was Project Delta delayed?",
                  "when did maria lopez reply about invoice 401",
                  "are you online is what the email from Bill said — find it",
                  "help me find the amendment about penalties"] {
            #expect(!LLMQueryClassifier.isConversational(q), "must answer: \(q)")
        }
    }

    @Test("The brain refuses a conversational question before any retrieval")
    @MainActor
    func brainRefusesConversational() async {
        // No collaborators wired: if the gate did NOT fire first, the pipeline
        // would fall through to retrieval/synthesis paths. The refused answer
        // flows out through the standard incomplete terminal.
        let brain = MasterBrain()
        let answer = await brain.answer(question: "how are you online?",
                                        access: SensitiveAccessContext(
                                            scope: SensitiveScope.globalOwnerRetrieval()))
        #expect(answer.refused)
        #expect(answer.citations.isEmpty)
        #expect(answer.refusalReason?.contains("ingested documents") == true)
    }
}
