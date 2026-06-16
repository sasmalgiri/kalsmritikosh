//
//  Gate1Baseline.swift
//  Kalsmritikosh
//
//  Boots an isolated AppState into a throwaway temp dir, ingests the
//  bundled ProjectDelta fixture, runs the EvalKit harness through the
//  freshly-booted MasterBrain, and writes `eval-report.md` to the app
//  container's Documents folder. This is the reproducible Gate 1
//  baseline that UPDATE_03 made the precondition for the G2-SWIFT6
//  migration.
//
//  Pure side-effect, idempotent: rerunning overwrites the previous
//  baseline at the same path. The temp DB is wiped on exit so the
//  user's real database is never touched.
//

import Foundation
import OSLog

public enum Gate1Baseline {

    public struct Result: Sendable {
        public let reportURL: URL
        public let retrievalProbeURL: URL?
        public let ingestedFixtureFiles: Int
        public let questionCount: Int
        public let ingestSeconds: Double
        public let querySeconds: Double
    }

    /// Run the full baseline cycle. Returns the URL of the written
    /// report; caller surfaces it in the UI.
    @MainActor
    public static func generate() async throws -> Result {
        AtlasLog.app.info("Gate 1 baseline starting")

        // 1. Isolated temp dir + fresh AppState pointed at a temp-dir DB.
        //    UPDATE_09 Item 1 — the previous baseline shared the user's
        //    real `knowledge.sqlite` under Application Support, so the
        //    eval kept reading whatever Gmail Takeout / mbox content the
        //    user had ingested (visible in reports as "Sent.mbox" cites
        //    and 186-second p50 lookup latency). The override below
        //    routes ALL DB traffic to the throwaway temp dir; the defer
        //    wipes it so nothing persists between runs.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Gate1Baseline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let isolatedDBURL = tempDir.appendingPathComponent("eval.sqlite", isDirectory: false)

        let isolatedBookmarks = BookmarkStore()
        let state = AppState(bookmarks: isolatedBookmarks)
        await state.boot(databaseURL: isolatedDBURL)

        guard case .ready = state.phase, let ingest = state.ingest else {
            throw NSError(
                domain: "Gate1Baseline",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "AppState failed to boot."]
            )
        }
        AtlasLog.app.info("Gate 1 baseline DB isolated at \(isolatedDBURL.path, privacy: .public)")

        // 2. Ingest the bundled ProjectDelta fixture (and ONLY that —
        //    no mbox, no Takeout, no real archive content).
        let ingestStarted = Date()
        let fixtureURLs = try Self.fixtureURLs()
        var ingested = 0
        for url in fixtureURLs {
            do {
                _ = try await ingest.ingest(fileAt: url)
                ingested += 1
            } catch {
                AtlasLog.app.error("Gate 1 baseline ingest failed for \(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        let ingestSeconds = Date().timeIntervalSince(ingestStarted)

        // 3. Force a synchronous distillation pass so the brain sees the
        //    memory layer the same way it would after a normal session.
        if let distiller = state.memoryDistiller, let entities = state.entities {
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

        // 4. Resolve the report's destination — sandbox-safe path inside
        //    the app container's Documents.
        let documentsDir = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let reportDir = documentsDir.appendingPathComponent("EvalBaselines", isDirectory: true)
        try? FileManager.default.createDirectory(at: reportDir, withIntermediateDirectories: true)

        // 5. Run the harness against the live brain. Pass the KO repo so
        //    the runner can resolve citation object-IDs to filenames at
        //    scoring time (the eval contract is filenames, not UUIDs).
        guard let objects = state.objects else {
            throw NSError(
                domain: "Gate1Baseline",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "KnowledgeObjectRepository not booted."]
            )
        }

        // 5a. UPDATE_09 Item 2 — retrieval-set diagnostic. Before running
        //     the full eval, probe the retriever directly for ONE lookup
        //     (L1 expects contract.md). Distinguishes the two failure
        //     modes: (a) contract.md was never retrieved → retrieval
        //     coverage bug; (b) retrieved but not cited → citation
        //     assembly bug. The sibling file lands next to eval-report.md.
        let retrievalProbeURL = await Self.runRetrievalProbe(
            state: state,
            objects: objects,
            outputDir: reportDir
        )

        let queryStarted = Date()
        let runner = EvalKitRunner()
        let reportURL = try await runner.run(brain: state.brain, objects: objects, outputDir: reportDir)
        let querySeconds = Date().timeIntervalSince(queryStarted)

        // Load question count for the result surface.
        let questionCount = (try? runner.loadQuestions().count) ?? 0

        AtlasLog.app.info("Gate 1 baseline complete → \(reportURL.path, privacy: .public) (ingest \(String(format: "%.1f", ingestSeconds))s, query \(String(format: "%.1f", querySeconds))s)")
        return Result(
            reportURL: reportURL,
            retrievalProbeURL: retrievalProbeURL,
            ingestedFixtureFiles: ingested,
            questionCount: questionCount,
            ingestSeconds: ingestSeconds,
            querySeconds: querySeconds
        )
    }

    /// Writes a side-by-side dump of every retrieval layer's candidates
    /// for one lookup question (L1: "Who is the project owner of Project
    /// Delta?"). Each chunk row shows its objectID's source filename so
    /// the reader can immediately see whether the expected `.md` doc was
    /// surfaced by any layer at all.
    @MainActor
    private static func runRetrievalProbe(
        state: AppState,
        objects: KnowledgeObjectRepository,
        outputDir: URL
    ) async -> URL? {
        guard let retriever = state.retriever else { return nil }
        let question = "Who is the project owner of Project Delta?"
        let intent = UserIntent(
            kind: .factualLookup,
            scope: .project("Project Delta"),
            timeframe: nil,
            entityHints: ["Project Delta"],
            rawQuestion: question
        )
        let result: RetrievalResult
        do {
            result = try await retriever.retrieve(for: intent, layers: [])
        } catch {
            AtlasLog.app.error("Retrieval probe failed: \(String(describing: error), privacy: .public)")
            return nil
        }
        let chunkObjectIDs = Set(result.chunks.map(\.chunk.objectID))
        let idToFilename = (try? await objects.sourceFilenames(for: chunkObjectIDs)) ?? [:]
        var md = "# Retrieval probe — L1\n\n"
        md += "Question: \"\(question)\"\n\n"
        md += "Expected source: contract.md\n\n"
        md += "Layers used: \(result.layersUsed.map(\.rawValue).joined(separator: ", "))\n"
        if let short = result.shortCircuitedAt {
            md += "Short-circuited at: \(short.rawValue)\n"
        }
        md += "\n## Chunks (top-N per layer, hybrid retrieval result)\n\n"
        md += "| # | layer | score | filename | objectID (short) | snippet |\n"
        md += "|---:|---|---:|---|---|---|\n"
        let containsExpected = result.chunks.contains { rc in
            (idToFilename[rc.chunk.objectID] ?? "") == "contract.md"
        }
        for (i, rc) in result.chunks.enumerated() {
            let fn = idToFilename[rc.chunk.objectID] ?? "—"
            let shortID = String(rc.chunk.objectID.uuidString.prefix(8))
            let snippet = rc.chunk.text
                .replacingOccurrences(of: "\n", with: " ")
                .prefix(80)
            md += "| \(i + 1) | \(rc.viaLayer.rawValue) | \(String(format: "%.3f", rc.score)) | \(fn) | \(shortID) | \(snippet) |\n"
        }
        md += "\n## Verdict\n\n"
        if containsExpected {
            md += "✓ `contract.md` IS in the retrieval candidate set. "
            md += "If it isn't being cited downstream, the bug is in **citation assembly**, not retrieval.\n"
        } else {
            md += "✗ `contract.md` is NOT in the retrieval candidate set. "
            md += "Retrieval coverage bug — the small `.md` doc is being outranked or never surfaced by any layer. "
            md += "Distinct chunk filenames retrieved: "
            md += Set(result.chunks.compactMap { idToFilename[$0.chunk.objectID] })
                .sorted().joined(separator: ", ")
            md += "\n"
        }
        md += "\n## Entities surfaced\n\n"
        for e in result.entities.prefix(20) {
            md += "- \(e.kind.rawValue): `\(e.value)` (conf \(String(format: "%.2f", e.confidence.value)))\n"
        }
        md += "\n## Events surfaced\n\n"
        for ev in result.events.prefix(10) {
            md += "- \(ev.date.formatted(date: .abbreviated, time: .omitted)): \(ev.title)\n"
        }
        let probeURL = outputDir.appendingPathComponent("eval-l1-retrieval.md", isDirectory: false)
        do {
            try md.data(using: .utf8)?.write(to: probeURL, options: .atomic)
            AtlasLog.app.info("Retrieval probe → \(probeURL.path, privacy: .public)")
            return probeURL
        } catch {
            AtlasLog.app.error("Retrieval probe write failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private static func fixtureURLs() throws -> [URL] {
        let bundle = Bundle.main
        guard let resourcePath = bundle.resourcePath else {
            throw NSError(
                domain: "Gate1Baseline",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Bundle has no resource path."]
            )
        }
        let root = URL(fileURLWithPath: resourcePath)
            .appendingPathComponent("ProjectDelta", isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else {
            return bundle.urls(forResourcesWithExtension: "eml", subdirectory: nil) ?? []
        }
        let items = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey]
        )
        return items.filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }
}
