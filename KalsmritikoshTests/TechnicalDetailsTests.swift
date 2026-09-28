//
//  TechnicalDetailsTests.swift
//  Kalsmritikosh Tests
//
//  §1.3 — the "Technical details" disclosure carries the raw identifiers an
//  audit or support request needs: state, answer id, build, and one line per
//  citation naming its document (and chunk/event when known).
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("§1.3 — Technical details disclosure")
struct TechnicalDetailsTests {

    @Test("Every citation gets a line naming its document, chunk and event ids")
    func citationLines() {
        let doc = UUID(), chunk = UUID(), event = UUID(), answerID = UUID()
        let answer = VerifiedAnswer(
            body: "The patent was granted.", citations: [
                VerifiedAnswer.Citation(objectID: doc, chunkID: chunk, snippet: "granted"),
                VerifiedAnswer.Citation(objectID: doc, eventID: event, snippet: "grant event"),
            ],
            confidence: Confidence(0.9), answerState: .supported, ledgerAnswerID: answerID)
        let lines = QualityStrip.technicalLines(answer)
        let byLabel = Dictionary(lines.map { ($0.label, $0.value) }, uniquingKeysWith: { a, _ in a })
        #expect(byLabel["State"] == AnswerState.supported.displayName)
        #expect(byLabel["Answer ID"] == answerID.uuidString)
        #expect(byLabel["Build"] == BuildIdentity.gitSHA)
        #expect(byLabel["Confidence"] == "0.90")
        #expect(byLabel["Source 1"] == "doc \(doc.uuidString.prefix(8)) · chunk \(chunk.uuidString.prefix(8))")
        #expect(byLabel["Source 2"] == "doc \(doc.uuidString.prefix(8)) · event \(event.uuidString.prefix(8))")
    }

    @Test("A not-found answer with no ledger link still discloses state, confidence and build — no invented ids")
    func minimalAnswer() {
        let answer = VerifiedAnswer(body: "Not found.", citations: [], confidence: Confidence(0.1),
                                    refused: true, answerState: .notFound)
        let labels = QualityStrip.technicalLines(answer).map(\.label)
        #expect(labels == ["State", "Confidence", "Build"])
    }
}
