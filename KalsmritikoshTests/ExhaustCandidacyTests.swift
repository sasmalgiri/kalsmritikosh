//
//  ExhaustCandidacyTests.swift
//  KalsmritikoshTests
//
//  UNIT C-i — the provenance-class law at its enforcement point: artifacts
//  derived from the answer path's own output (exhaust: distilled memories,
//  answer commits, any future self-writer) never enter the answer path's
//  candidate set. The measured defect: a memory distilled from ask N's
//  answer hydrated its keyEventIDs into ask N+1's evidence (+1 distinct
//  source, the 0.002 confidence lattice); at a top-K boundary a candidacy
//  leak can displace a real chunk and flip TEXT. The canary below is an
//  event reachable ONLY through memory hydration — red (canary retrieved)
//  pre-fix, green (exhaust contributes nothing evidentiary) post-fix.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Unit C-i — exhaust never enters the candidate set", .serialized)
@MainActor
struct ExhaustCandidacyTests {

    @Test("A distilled memory's summary and hydrated events stay out of retrieval")
    func memoryExhaustExcludedFromCandidacy() async throws {
        let gen = NoiseFixtureGenerator()
        let rig = try await FixtureRig.make(document: gen.noisyGrantLetter, name: "grant-letter.md")
        defer { try? FileManager.default.removeItem(at: rig.dir) }

        // A canary event no layer can reach for this question. First-run
        // lesson (recorded): parenting the canary on the grant letter's KO
        // let the OBJECT/timeline layer hydrate it legitimately — the canary
        // must live under a SECOND document the question never retrieves,
        // so memory hydration is the only path to it.
        let decoyDir = rig.dir.appendingPathComponent("decoy", isDirectory: true)
        try FileManager.default.createDirectory(at: decoyDir, withIntermediateDirectories: true)
        try "Unrelated gardening notes about tulip bulbs and soil acidity."
            .write(to: decoyDir.appendingPathComponent("gardening.md"), atomically: true, encoding: .utf8)
        _ = try await rig.ingest(fileAt: decoyDir.appendingPathComponent("gardening.md"))
        let koID = try #require(
            (try await rig.db.query(
                "SELECT id FROM knowledge_objects WHERE content LIKE '%tulip%' LIMIT 1", []))
                .first?.string(0).flatMap(UUID.init(uuidString:)))
        // Second lesson (recorded): the timeline layer's recent(limit:100)
        // scoops EVERY event in a tiny rig — bury the canary behind 120
        // newer fillers so memory hydration is the only remaining path.
        let canary = Event(
            kind: .other, date: Date(timeIntervalSince1970: 400_000_000),
            title: "canary unrelated marker zzqx", sourceObjectID: koID)
        let fillers = (0..<120).map { i in
            Event(kind: .other,
                  date: Date(timeIntervalSince1970: 500_000_000 + TimeInterval(i) * 86_400),
                  title: "filler gardening note \(i)", sourceObjectID: koID)
        }
        try await EventsRepository(database: rig.db).insertBatch([canary] + fillers)

        // The exhaust: a distilled memory whose narrative matches the rung-1
        // question (so the memory layer's search finds it) and whose
        // keyEventIDs carry the canary.
        let memory = MemoryObject(
            subjectKind: .project,
            subjectIdentifier: "granted patent number",
            keyEventIDs: [canary.id],
            narrative: "The granted patent number was discussed; exhaust echo 999999.",
            sourceObjectIDs: [koID])
        try await MemoryRepository(database: rig.db).upsert(memory)

        let intent = (try? await RuleIntentDetector().detect(question: "what is the granted patent number"))
            ?? UserIntent(kind: .factualLookup, scope: .global, rawQuestion: "what is the granted patent number")
        let result = try await rig.retriever.retrieve(for: intent, layers: [])

        let canaryRetrieved = result.events.contains { $0.id == canary.id }
        let exhaustSummary = result.summaries.contains { $0.body.contains("999999") || $0.body.contains("exhaust echo") }
        print("C-i fixture: canaryEvent=\(canaryRetrieved ? "LEAKED" : "excluded") exhaustSummary=\(exhaustSummary ? "LEAKED" : "excluded")")
        #expect(!canaryRetrieved, "a memory-hydrated event entered the candidate set")
        #expect(!exhaustSummary, "a distilled memory became a Summary candidate")
    }
}
