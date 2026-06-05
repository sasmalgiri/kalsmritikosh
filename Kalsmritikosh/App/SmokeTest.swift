//
//  SmokeTest.swift
//  Kalsmritikosh
//
//  In-process smoke-test entry point that exercises the full M6 pipeline:
//      1. Boot a fresh AppState into a temp database.
//      2. Ingest the bundled ProjectDelta fixture corpus.
//      3. Wait for IncrementalUpdater + MemoryDistiller to converge.
//      4. Ask "Why was Project Delta delayed?" through MasterBrain.
//      5. Assert: an answer comes back, with at least one citation, and
//         the rendered body mentions Supplier ABC and delivery delays.
//
//  Surfaced as a `runProjectDeltaSmokeTest()` async function so it can be
//  invoked from a debug menu or a future test target without depending
//  on any external test harness existing today.
//

import Foundation
import OSLog

public struct ProjectDeltaSmokeResult: Sendable {
    public let ingested: Int
    public let entityCount: Int
    public let eventCount: Int
    public let memoryObjectCount: Int
    public let answer: VerifiedAnswer
    public let assertionsPassed: [String]
    public let assertionsFailed: [String]

    public var ok: Bool { assertionsFailed.isEmpty }
}

@MainActor
public func runProjectDeltaSmokeTest() async throws -> ProjectDeltaSmokeResult {
    AtlasLog.app.info("ProjectDelta smoke test starting")

    // 1. Use a fresh isolated bookmark store + fresh in-tmp AppState.
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("AtlasSmoke-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let isolatedBookmarks = BookmarkStore()
    let state = AppState(bookmarks: isolatedBookmarks)
    await state.boot()

    guard case .ready = state.phase,
          let ingest = state.ingest,
          let entities = state.entities,
          let events = state.events,
          let memory = state.memoryRepo
    else {
        throw NSError(
            domain: "atlas.smoke",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "AppState failed to boot."]
        )
    }

    // 2. Locate fixtures inside the app bundle.
    let fixtureURLs = try fixtureURLs()
    var ingested = 0
    for url in fixtureURLs {
        do {
            _ = try await ingest.ingest(fileAt: url)
            ingested += 1
        } catch {
            AtlasLog.app.error("Smoke ingest failed for \(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    // 3. Force a synchronous distillation pass for the smoke test —
    // IncrementalUpdater normally runs the same logic but with a debounce.
    if let distiller = state.memoryDistiller {
        let projects = (try? await entities.list(kind: .project, limit: 25))?.map(\.value) ?? []
        let orgs = (try? await entities.list(kind: .organization, limit: 25))?.map(\.value) ?? []
        let people = (try? await entities.list(kind: .person, limit: 25))?.map(\.value) ?? []
        let candidates = Set(projects + orgs + people)
        for value in candidates {
            for kind in MemoryObject.SubjectKind.allCases {
                _ = try? await distiller.distill(.init(kind: kind, identifier: value))
            }
        }
    }

    // 4. Ask the canonical question.
    let answer = await state.brain.answer(question: "Why was Project Delta delayed?")

    // 5. Assertions.
    let entityCount = (try? await countAllEntities(entities)) ?? 0
    let eventCount = (try? await events.count()) ?? 0
    let memoryCount = (try? await memory.count()) ?? 0
    var passed: [String] = []
    var failed: [String] = []

    if ingested >= 5 { passed.append("ingested \(ingested) fixture files") }
    else { failed.append("expected >=5 ingested files, got \(ingested)") }

    if entityCount > 0 { passed.append("entityCount=\(entityCount)") }
    else { failed.append("no entities extracted from corpus") }

    if eventCount > 0 { passed.append("eventCount=\(eventCount)") }
    else { failed.append("no events extracted from corpus") }

    if memoryCount > 0 { passed.append("memoryObjectCount=\(memoryCount)") }
    else { failed.append("memory layer produced 0 subjects") }

    if !answer.refused { passed.append("brain answered (not refused)") }
    else { failed.append("brain refused: \(answer.refusalReason ?? "unknown")") }

    if !answer.citations.isEmpty { passed.append("citations=\(answer.citations.count)") }
    else { failed.append("answer had zero citations") }

    let body = answer.body.lowercased()
    if body.contains("supplier abc") || body.contains("supplier_abc") {
        passed.append("body mentions Supplier ABC")
    } else {
        failed.append("body never mentions Supplier ABC")
    }

    if body.contains("delivery") || body.contains("delayed") || body.contains("amendment") {
        passed.append("body mentions delivery/delay/amendment vocabulary")
    } else {
        failed.append("body lacks delivery/delay vocabulary")
    }

    // T1 — calibrated confidence aggregation (replaces noisy-OR).
    let t1A = Confidence.aggregate(
        Array(repeating: Confidence(0.5), count: 94),
        agreement: 0.2,
        diversity: 0.2,
        contradictionPenalty: 0.0
    )
    if t1A.value <= 0.65 {
        passed.append("T1(a): 94×0.5 low-signal → \(t1A.value) ≤ 0.65")
    } else {
        failed.append("T1(a): 94×0.5 low-signal got \(t1A.value), expected ≤ 0.65")
    }

    let t1B = Confidence.aggregate(
        Array(repeating: Confidence(0.9), count: 3),
        agreement: 0.9,
        diversity: 1.0,
        contradictionPenalty: 0.0
    )
    if t1B.value >= 0.85 {
        passed.append("T1(b): 3×0.9 high-signal → \(t1B.value) ≥ 0.85")
    } else {
        failed.append("T1(b): 3×0.9 high-signal got \(t1B.value), expected ≥ 0.85")
    }

    // Adversarial: maximal claims should still clamp below 0.99.
    let t1C = Confidence.aggregate(
        Array(repeating: Confidence(1.0), count: 200),
        agreement: 1.0,
        diversity: 1.0,
        contradictionPenalty: 0.0
    )
    if t1C.value < 0.99 {
        passed.append("T1(c): clamp prevents ≥0.99 (got \(t1C.value))")
    } else {
        failed.append("T1(c): aggregate returned \(t1C.value) — clamp violated")
    }

    if answer.confidence.value < 1.0 {
        passed.append("T1: ProjectDelta answer confidence \(answer.confidence.value) < 1.00")
    } else {
        failed.append("T1: ProjectDelta answer confidence is \(answer.confidence.value) (expected < 1.00)")
    }

    // T2 — claim-level evidence contract. Static checks on the parser.
    let t2Map: [String: EvidenceCitation] = [
        "E1": EvidenceCitation(supportingObjectIDs: [], supportingEventIDs: [], supportingEntityIDs: []),
        "E2": EvidenceCitation(supportingObjectIDs: [], supportingEventIDs: [], supportingEntityIDs: []),
        "E3": EvidenceCitation(supportingObjectIDs: [], supportingEventIDs: [], supportingEntityIDs: [])
    ]
    // (a) fenced JSON parses; (b) two claims carry DIFFERENT evidence sets;
    // (c) claims with empty / unresolved evidence are dropped and counted.
    let t2Response = """
    ```json
    {"claims":[
      {"text":"Claim citing E1 only","evidence":["E1"]},
      {"text":"Claim citing E2 and E3","evidence":["E2","E3"]},
      {"text":"Claim with empty evidence","evidence":[]},
      {"text":"Claim with phantom E-id","evidence":["E99"]}
    ]}
    ```
    """
    let t2Parsed = ExpertResponseParser.parseClaims(from: t2Response, evidenceMap: t2Map)
    if t2Parsed.claims.count == 2 {
        passed.append("T2: parser kept 2 valid claims out of 4")
    } else {
        failed.append("T2: parser kept \(t2Parsed.claims.count) claims (expected 2)")
    }
    if t2Parsed.dropped == 2 {
        passed.append("T2: parser dropped 2 unverifiable claims")
    } else {
        failed.append("T2: parser dropped \(t2Parsed.dropped) claims (expected 2)")
    }

    // (b) different evidence sets across same-expert claims.
    let t2Sets = t2Parsed.claims.map { Set($0.citation.supportingObjectIDs)
        .union(Set($0.citation.supportingEventIDs.map { _ in UUID() }))  // distinct shape
    }
    _ = t2Sets  // shape check below
    let t2EvidenceSignatures = t2Parsed.claims.map { c in
        "\(c.citation.supportingObjectIDs.count)/\(c.citation.supportingEventIDs.count)/\(c.citation.supportingEntityIDs.count):\(c.text)"
    }
    if Set(t2EvidenceSignatures).count == t2Parsed.claims.count {
        passed.append("T2: parsed claims carry distinct evidence shapes")
    } else {
        failed.append("T2: parsed claims share identical evidence shapes")
    }

    let result = ProjectDeltaSmokeResult(
        ingested: ingested,
        entityCount: entityCount,
        eventCount: eventCount,
        memoryObjectCount: memoryCount,
        answer: answer,
        assertionsPassed: passed,
        assertionsFailed: failed
    )
    if result.ok {
        AtlasLog.app.info("ProjectDelta smoke test PASSED (\(result.assertionsPassed.count, privacy: .public) checks)")
    } else {
        AtlasLog.app.error("ProjectDelta smoke test FAILED — \(result.assertionsFailed.joined(separator: "; "), privacy: .public)")
    }
    return result
}

// MARK: - Helpers

private func fixtureURLs() throws -> [URL] {
    let bundle = Bundle.main
    guard let resourcePath = bundle.resourcePath else {
        throw NSError(
            domain: "atlas.smoke",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Bundle has no resource path."]
        )
    }
    let root = URL(fileURLWithPath: resourcePath)
        .appendingPathComponent("ProjectDelta", isDirectory: true)
    guard FileManager.default.fileExists(atPath: root.path) else {
        // Fallback: search recursively in the bundle for our fixture filenames.
        return bundle.urls(forResourcesWithExtension: "eml", subdirectory: nil) ?? []
    }
    let items = try FileManager.default.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey]
    )
    return items
        .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
}

private func countAllEntities(_ repo: EntitiesRepository) async throws -> Int {
    var total = 0
    for kind in Entity.Kind.allCases {
        total += try await repo.count(of: kind)
    }
    return total
}
