//
//  SpeechTranscriberMessageTests.swift
//  KalsmritikoshTests
//
//  D-1 (completion instructions) — the capability-unavailable messages a
//  buyer sees when transcription cannot run must name the REAL remedy
//  (System Settings / Dictation) and must never reference controls or
//  technologies the Release product does not use for Speech: there is no
//  cloud path, and Apple Speech does not depend on Apple Intelligence.
//

import Testing
@testable import Kalsmritikosh

@Suite("Speech transcriber messages (D-1)")
struct SpeechTranscriberMessageTests {

    @Test("Both unavailable-messages point at System Settings")
    func messagesNameTheRealRemedy() {
        #expect(SpeechTranscriber.recognizerUnavailableMessage.contains("System Settings"))
        #expect(SpeechTranscriber.languageAssetsMissingMessage.contains("System Settings"))
        #expect(SpeechTranscriber.languageAssetsMissingMessage.contains("Dictation"))
    }

    @Test("Neither message references cloud routing or Apple Intelligence")
    func messagesNeverAdvertiseUnavailablePaths() {
        for message in [SpeechTranscriber.recognizerUnavailableMessage,
                        SpeechTranscriber.languageAssetsMissingMessage] {
            #expect(!message.lowercased().contains("cloud"))
            #expect(!message.lowercased().contains("apple intelligence"))
        }
    }
}
