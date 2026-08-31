//
//  BGETokenizerPerfTests.swift
//  KalsmritikoshTests
//
//  I-6 perf fixture — the greedy scan's `remaining.count` guard was O(N) per
//  bucket comparison at every position: O(N²·bucket) over the passage. On the
//  owner's real ledger (37 SVG chunks, 141 oversized chunks) the reranker fed
//  those passages uncapped, costing minutes per answer — measured in the
//  sealed baseline artifact (rung-1: 775.9 s). Red before the fix (both tests
//  blow the 1-minute limit on a 300KB/23KB input); green after.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("BGETokenizer perf — giant-passage bound + provably neutral cap")
struct BGETokenizerPerfTests {

    @Test("A ~300KB SVG-shaped passage tokenizes within the time limit",
          .timeLimit(.minutes(1)))
    func giantPassageBoundedTime() throws {
        guard let tok = BGETokenizer() else { return }  // tokenizer.json not bundled → nothing to measure
        // Path-data noise, the exact shape of the ledger's SVG chunks.
        let svgish = String(repeating: "M413.4 87.9c-6.3 12.7-19.2 21.4-34.2 21.4 ", count: 7_000)
        let out = tok.encode(question: "what is the granted patent number", passage: svgish)
        #expect(out.inputIDs.count == tok.maxLength)
        #expect(out.inputIDs.first == BGETokenizer.clsID)
    }

    @Test("The input cap is neutral: text beyond maxLength × maxPieceLength never changes tokens",
          .timeLimit(.minutes(1)))
    func capNeutrality() throws {
        guard let tok = BGETokenizer() else { return }
        // Bundled vocab's longest piece is 16 chars → bound = 512 × 16 = 8192.
        // The scan emits ≤ maxLength−2 tokens and each consumes ≥1, ≤16 chars,
        // so only the first 8192 chars can ever influence the output.
        let bound = tok.maxLength * 16
        let text = String(repeating: "patent application granted number 555489 hearing invoice ", count: 400)
        #expect(text.count > bound)
        let full = tok.encode(text: text)
        let capped = tok.encode(text: String(text.prefix(bound)))
        #expect(full.inputIDs == capped.inputIDs)
        #expect(full.attentionMask == capped.attentionMask)
    }
}
