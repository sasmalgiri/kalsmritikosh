//
//  CrossEncoderLifecycleTests.swift
//  KalsmritikoshTests
//
//  Pre-V2 unit B — the tier is constructed fresh per verify
//  (EvidenceVerifier builds the ladder per call), and pre-fix each
//  score() call re-compiled the mlpackage and re-loaded the 250k-token
//  vocab: a full model lifecycle per answer. Red: ten sequential
//  score() calls blow the one-minute limit pre-fix; green: the
//  process-scoped runtime cache pays compile+vocab once.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Unit B — cross-encoder lifecycle is per-process, not per-call")
struct CrossEncoderLifecycleTests {

    @Test("Ten sequential score() calls on fresh tiers complete within the limit",
          .timeLimit(.minutes(1)))
    func repeatedScoringIsCheap() async {
        // Warmup pays the one legitimate compile+vocab cost.
        guard await CoreMLCrossEncoderTier().score(question: "q", candidates: ["warmup passage"]) != nil else {
            print("UNITB: model not bundled — nothing to measure")
            return
        }
        let t0 = Date()
        for i in 0..<10 {
            let tier = CoreMLCrossEncoderTier()   // fresh per verify, as production does
            let s = await tier.score(question: "what is the granted patent number",
                                     candidates: ["Patent No. 700321 was granted on 17 June 2025. Passage \(i)"])
            #expect(s?.count == 1)
        }
        let secs = Date().timeIntervalSince(t0)
        print("UNITB: 10 fresh-tier score() calls in \(String(format: "%.2f", secs))s post-warmup")
        #expect(secs < 30, "per-call lifecycle cost has crept back: \(secs)s for 10 calls")
    }
}
