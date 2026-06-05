//
//  SmokeTest.swift
//  Atlas chronica memora
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
