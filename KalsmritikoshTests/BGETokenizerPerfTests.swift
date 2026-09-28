//
//  BGETokenizerPerfTests.swift
//  KalsmritikoshTests
//
//  I-6 perf fixture — the greedy scan's `remaining.count` guard was O(N) per
//  bucket comparison at every position: O(N²·bucket) over the passage. On the
//  owner's real ledger (37 SVG chunks, 141 oversized chunks) the reranker fed
//  those passages uncapped, costing minutes per answer — measured in the
//  sealed baseline artifact (rung-1: 775.9 s).
//
//  UPDATE (2026-09-24, first observed full-suite run). `capNeutrality` was
//  failing on its one-minute limit, and NOT because of suite contention: it
//  fails the same way in a two-test run. Measured on this machine:
//
//      English text, 22 800 chars   20.2 s      (~2.3 ms/char)
//      English text,  8 192 chars   18.6 s
//      SVG-shaped,   294 000 chars  14.2 s      (~0.05 ms/char)
//
//  The test did TWO English encodes, so ~39 s of work plus overhead — over the
//  limit. The cost is driven by CONTENT, not length: an English letter's
//  first-character bucket holds thousands of vocab pieces and the scan probes
//  them in descending length order at every position, whereas digit and
//  punctuation buckets are tiny. That is why the 294 KB SVG case passes while
//  the 23 KB prose case does not.
//
//  What was NOT wrong: the neutrality property itself. The measurement confirmed
//  `full.inputIDs == capped.inputIDs`, so the cap IS output-neutral. The failure
//  was wall-clock only.
//
//  So the two concerns are now separated. Neutrality is a property of the CAP,
//  independent of content, so it is proven on cheap content and runs fast. The
//  prose cost is recorded below as an explicit, measured characterization rather
//  than hidden behind a loosened limit — the bound would have had to triple to
//  pass, which would have retired the cliff this file exists to catch.
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

    @Test("The input cap is neutral: text beyond the bound never changes tokens",
          .timeLimit(.minutes(1)))
    func capNeutrality() throws {
        guard let tok = BGETokenizer() else { return }
        // The REAL bound, read from the tokenizer. The previous version derived
        // it from an assumed 16-char longest piece; asserting against the
        // tokenizer's own value means this cannot pass for the wrong reason if
        // the bundled vocab changes.
        let bound = tok.inputCharacterBound
        // Digit/punctuation-shaped content: the same neutrality property, ~46×
        // cheaper per character than prose (see the file header), so this runs
        // in well under a second instead of ~39 s.
        let unit = "M413.4 87.9c-6.3 12.7-19.2 21.4-34.2 21.4 "
        let text = String(repeating: unit, count: (bound * 3 / unit.count) + 2)
        #expect(text.count > bound, "the fixture must exceed the bound to test the cap at all")
        let full = tok.encode(text: text)
        let capped = tok.encode(text: String(text.prefix(bound)))
        #expect(full.inputIDs == capped.inputIDs)
        #expect(full.attentionMask == capped.attentionMask)
    }

    @Test("Neutrality also holds for prose, where the per-character cost is highest",
          .timeLimit(.minutes(3)))
    func capNeutralityOnProse() throws {
        guard let tok = BGETokenizer() else { return }
        // The original fixture, kept because prose is the content class that
        // exercises the large first-character buckets — the case most likely to
        // expose a cap that is not actually neutral. Its limit is set from the
        // MEASURED cost (~39 s for two encodes) with headroom, and is
        // deliberately NOT the one-minute bound the cheap test uses: a slow
        // known-slow path is recorded as slow, not quietly normalised.
        let bound = tok.inputCharacterBound
        let text = String(repeating: "patent application granted number 555489 hearing invoice ", count: 400)
        #expect(text.count > bound)
        let full = tok.encode(text: text)
        let capped = tok.encode(text: String(text.prefix(bound)))
        #expect(full.inputIDs == capped.inputIDs)
        #expect(full.attentionMask == capped.attentionMask)
    }

    @Test("Prose tokenization cost is characterized, not assumed", .timeLimit(.minutes(3)))
    func proseTokenizationCostIsRecorded() throws {
        guard let tok = BGETokenizer() else { return }
        // A characterization test: it pins the ORDER OF MAGNITUDE so a further
        // regression is caught, while stating plainly that this path is slow.
        // An ordinary 1 000-character chunk costs roughly 2 s here, which is the
        // embedding path's real per-chunk cost — tracked for repair, not
        // accepted as good.
        let prose = String(repeating: "patent application granted number 555489 hearing invoice ", count: 18)
        let started = Date()
        _ = tok.encode(text: prose)
        let elapsed = Date().timeIntervalSince(started)
        print("BGETokenizer prose cost: \(prose.count) chars in \(elapsed)s "
              + "(\(elapsed / Double(prose.count) * 1000) ms/char)")
        #expect(elapsed < 30.0, "a ~1KB prose chunk took \(elapsed)s — worse than the recorded baseline")
    }
}
