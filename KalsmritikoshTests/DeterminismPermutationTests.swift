//
//  DeterminismPermutationTests.swift
//  KalsmritikoshTests
//
//  Pre-V2 unit A — the answer envelope must not depend on the ORDER in
//  which equally-ranked evidence arrives. The quiesced steady-state parity
//  runs proved the wobble is product-level and semantic (the third citation
//  slot cites a DIFFERENT object run-to-run; the Q7 fallback list swaps one
//  item; confidence follows the changed evidence). Per-process hash seeds
//  can't be varied in-process, but the SAME tie-break sites are exercised
//  by permuting the INPUT order of tied items: pre-fix, unstable score-only
//  sorts leak input order into the envelope (red); post-fix, the total
//  order (score → tier → stable content key, applied at every sort AND
//  every top-K cut) makes the envelope input-order-invariant (green).
//  The multi-process proof is the capture-vs-parity pair on the resealed
//  baseline — separate processes by construction.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Unit A — envelope is invariant under permutation of tied evidence")
@MainActor
struct DeterminismPermutationTests {

    private func chunk(_ obj: UUID, text: String) -> RetrievedChunk {
        RetrievedChunk(
            chunk: Chunk(objectID: obj, ordinal: 0, text: text,
                         characterRange: 0..<text.count, evidenceBlockID: nil),
            score: 1.0, viaLayer: .metadata)
    }

    private func verifier() -> EvidenceVerifier {
        EvidenceVerifier(minimumConfidence: Confidence(0.0),
                         answerabilityMinRetrievalScore: 0,
                         citationResolver: CitationResolver())
    }

    private let intent = UserIntent(kind: .factualLookup, scope: .global, rawQuestion: "q")

    /// The full comparable envelope: primary text, body, and the citation
    /// list in its SHIPPED order (receipt order is part of the answer).
    private func envelope(_ a: VerifiedAnswer) -> String {
        (a.answerText ?? "nil") + "␟" + a.body + "␟"
            + a.citations.map { "\($0.objectID.uuidString)|\($0.snippet)" }.joined(separator: ",")
    }

    @Test("Citations: one claim citing 4 equally-scored objects → same envelope forward and reversed")
    func permutedCitationTies() async throws {
        // Fixed UUIDs so both permutations share content identity.
        let objs = (1...4).map { UUID(uuidString: "00000000-0000-0000-0000-00000000000\($0)")! }
        let retrieval = RetrievalResult(chunks: objs.map { chunk($0, text: "passage \($0.uuidString.suffix(1))") })
        func findings(_ ids: [UUID]) -> [ExpertFindings] {
            [ExpertFindings(expertID: "test", claims: [ExpertFindings.Claim(
                statement: "claim statement", supportingObjectIDs: ids,
                supportingEventIDs: [], confidence: .high)], confidence: .high)]
        }
        let forward = try await verifier().verify(
            intent: intent, findings: findings(objs), retrieval: retrieval)
        let reversed = try await verifier().verify(
            intent: intent, findings: findings(objs.reversed()), retrieval: retrieval)
        #expect(envelope(forward) == envelope(reversed),
                "citation envelope depends on the input order of tied evidence")
    }

    @Test("Doc-claims: equally-scored claims → same answer text forward and reversed")
    func permutedClaimTies() async throws {
        let objs = (1...3).map { UUID(uuidString: "00000000-0000-0000-0000-0000000000\($0)0")! }
        let retrieval = RetrievalResult(chunks: objs.map { chunk($0, text: "passage \($0.uuidString.suffix(2))") })
        func findings(_ order: [Int]) -> [ExpertFindings] {
            [ExpertFindings(expertID: "test", claims: order.map { i in
                ExpertFindings.Claim(
                    statement: "statement \(i)", supportingObjectIDs: [objs[i]],
                    supportingEventIDs: [], confidence: .high)
            }, confidence: .high)]
        }
        let forward = try await verifier().verify(
            intent: intent, findings: findings([0, 1, 2]), retrieval: retrieval)
        let reversed = try await verifier().verify(
            intent: intent, findings: findings([2, 1, 0]), retrieval: retrieval)
        #expect(envelope(forward) == envelope(reversed),
                "answer text depends on the input order of equally-scored claims")
    }
}
