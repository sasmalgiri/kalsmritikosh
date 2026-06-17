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
        public let coverageProbeURL: URL?
        public let ingestedFixtureFiles: Int
        public let questionCount: Int
        public let ingestSeconds: Double
        public let querySeconds: Double
        /// Resolved provider ID for a reasoning capability at the start
        /// of the run, or nil when no reasoning provider was reachable
        /// (i.e. the baseline ran on heuristic floor). This is the
        /// single fastest way to confirm whether the run measured the
        /// LLM-on engine or the heuristic floor, surfaced in the
        /// Settings UI alongside the report URL.
        public let reasoningProviderID: String?
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

        // Preflight: resolve a reasoning capability against the live
        // registry and log the outcome. Without this, the user only
        // discovers a misconfigured Ollama provider 5 minutes into the
        // eval when every expert silently logs available=false. The
        // probe takes <2s and gives a single binary answer up front:
        // "this run is measuring the LLM-on engine" or "this run is
        // measuring the heuristic floor".
        let reasoningProviderID: String? = await {
            guard let caps = state.capabilities else { return nil }
            let spec = CapabilitySpec.reasoning(contextTokens: 4_000, purpose: "gate1.preflight")
            do {
                let provider = try await caps.resolve(spec)
                AtlasLog.app.info("Gate 1 preflight: reasoning provider RESOLVED → \(provider.id, privacy: .public). LLM path will be exercised.")
                return provider.id
            } catch {
                AtlasLog.app.info("Gate 1 preflight: NO reasoning provider available. Eval will run on heuristic floor.")
                return nil
            }
        }()

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

        // 5a. UPDATE_10 Item 0 — per-file ingest coverage probe. For
        //     every ingested fixture file, report how many KOs / chunks
        //     / embeddings / entities / FTS rows it produced. This rules
        //     out the simpler "the .md files aren't being chunked at
        //     all" explanation before assuming it's a retrieval ranking
        //     bug. Writes `eval-ingest-coverage.md`.
        let coverageProbeURL = await Self.runIngestCoverageProbe(
            state: state,
            outputDir: reportDir
        )

        // 5b. UPDATE_09 Item 2 — retrieval-set diagnostic. Before running
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
            coverageProbeURL: coverageProbeURL,
            ingestedFixtureFiles: ingested,
            questionCount: questionCount,
            ingestSeconds: ingestSeconds,
            querySeconds: querySeconds,
            reasoningProviderID: reasoningProviderID
        )
    }

    /// Writes a per-file table covering every ingested fixture file:
    /// #KOs, #chunks, #vector embeddings, #entities, #FTS rows. This
    /// rules out "the file produced nothing" before assuming the
    /// retrieval layer is misranking it. UPDATE_10 Item 0.
    @MainActor
    private static func runIngestCoverageProbe(
        state: AppState,
        outputDir: URL
    ) async -> URL? {
        guard let db = state.database else { return nil }
        struct Row {
            let filename: String
            let koCount: Int
            let chunkCount: Int
            let vectorCount: Int
            let entityCount: Int
            let ftsCount: Int
        }
        var rows: [Row] = []
        var globalFtsCount = 0
        do {
            // Global FTS row count up front — if this is 0, every
            // per-file FTS count will be 0 and the FTS layer is dead.
            let ftsRows = try await db.query("SELECT COUNT(*) FROM chunks_fts;")
            globalFtsCount = Int(ftsRows.first?.int(0) ?? 0)

            // Per-file aggregates. Two queries because joining vectors
            // and entities into one would multiply rows.
            let countsRows = try await db.query("""
            SELECT
              f.url,
              COUNT(DISTINCT k.id),
              COUNT(DISTINCT c.id),
              COUNT(DISTINCT v.chunk_id)
            FROM files f
            LEFT JOIN knowledge_objects k ON k.file_id = f.id
            LEFT JOIN chunks c ON c.object_id = k.id
            LEFT JOIN vectors v ON v.chunk_id = c.id
            GROUP BY f.id, f.url
            ORDER BY f.url;
            """, [])

            // Entity count per file (separate to avoid join blow-up).
            var entityByURL: [String: Int] = [:]
            let entityRows = try await db.query("""
            SELECT f.url, COUNT(DISTINCT e.id)
            FROM files f
            LEFT JOIN knowledge_objects k ON k.file_id = f.id
            LEFT JOIN entities e ON e.source_object_id = k.id
            GROUP BY f.id, f.url;
            """, [])
            for r in entityRows {
                if let url = r.string(0) { entityByURL[url] = Int(r.int(1) ?? 0) }
            }

            // FTS rowid presence per file.
            var ftsByURL: [String: Int] = [:]
            let ftsByFileRows = try await db.query("""
            SELECT f.url, COUNT(*)
            FROM files f
            LEFT JOIN knowledge_objects k ON k.file_id = f.id
            LEFT JOIN chunks c ON c.object_id = k.id
            LEFT JOIN chunks_fts fts ON fts.rowid = c.rowid
            GROUP BY f.id, f.url;
            """, [])
            for r in ftsByFileRows {
                if let url = r.string(0) { ftsByURL[url] = Int(r.int(1) ?? 0) }
            }

            for r in countsRows {
                guard let url = r.string(0) else { continue }
                let filename = URL(fileURLWithPath: url).lastPathComponent
                rows.append(Row(
                    filename: filename.isEmpty ? url : filename,
                    koCount: Int(r.int(1) ?? 0),
                    chunkCount: Int(r.int(2) ?? 0),
                    vectorCount: Int(r.int(3) ?? 0),
                    entityCount: entityByURL[url] ?? 0,
                    ftsCount: ftsByURL[url] ?? 0
                ))
            }
        } catch {
            AtlasLog.app.error("Ingest coverage probe SQL failed: \(String(describing: error), privacy: .public)")
            return nil
        }

        var md = "# Ingest coverage probe — per-file\n\n"
        md += "Total `chunks_fts` rows in the isolated DB: **\(globalFtsCount)**\n\n"
        md += "| filename | KOs | chunks | vectors | entities | FTS rows |\n"
        md += "|---|---:|---:|---:|---:|---:|\n"
        for r in rows.sorted(by: { $0.filename < $1.filename }) {
            md += "| \(r.filename) | \(r.koCount) | \(r.chunkCount) | \(r.vectorCount) | \(r.entityCount) | \(r.ftsCount) |\n"
        }
        md += "\n## Verdict\n\n"
        let mdRows = rows.filter { $0.filename.hasSuffix(".md") }
        let mdHasContent = mdRows.allSatisfy { $0.chunkCount > 0 && $0.vectorCount > 0 }
        if mdRows.isEmpty {
            md += "No `.md` files in the coverage table. Fixture didn't ingest as expected.\n"
        } else if mdHasContent && globalFtsCount == 0 {
            md += "✗ `.md` files DO have chunks and vector embeddings, "
            md += "but **`chunks_fts` is globally empty**. ChunksRepository.insertBatch "
            md += "writes to `chunks` but never to `chunks_fts`, and the schema has no "
            md += "sync triggers. The FTS layer can return nothing — not because the query "
            md += "is malformed, but because the index is unpopulated. Fix is to either "
            md += "(a) populate `chunks_fts` on chunk insert, or (b) add INSERT/DELETE/"
            md += "UPDATE triggers on `chunks` that mirror into `chunks_fts`. "
            md += "Once FTS is populated, UPDATE_10 Items 1–3 (better FTS query, entity "
            md += "doc injection, vector union) become applicable.\n"
        } else if mdHasContent {
            md += "✓ `.md` files have chunks, vector embeddings, AND FTS rows. "
            md += "Pure ranking/coverage problem in the retrieval layers — proceed to "
            md += "UPDATE_10 Items 1–3 (FTS query construction, entity→document injection, "
            md += "vector union vs confine).\n"
        } else {
            md += "✗ One or more `.md` files have 0 chunks or 0 vectors — INGESTION "
            md += "bug. Fix the chunker/embed path for that source type before any "
            md += "retrieval-layer work.\n"
        }
        let probeURL = outputDir.appendingPathComponent("eval-ingest-coverage.md", isDirectory: false)
        do {
            try md.data(using: .utf8)?.write(to: probeURL, options: .atomic)
            AtlasLog.app.info("Coverage probe → \(probeURL.path, privacy: .public)")
            return probeURL
        } catch {
            AtlasLog.app.error("Coverage probe write failed: \(String(describing: error), privacy: .public)")
            return nil
        }
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

    /// Filenames that make up the Gate 1 ProjectDelta fixture. The eval
    /// MUST have all of these — a partial corpus produces meaningless
    /// numbers (UPDATE_11 root cause: three eval runs reported "the .md
    /// files were outranked" when the .md files were never in the
    /// bundle at all because the prior fallback silently loaded only
    /// .eml files).
    private static let expectedFixtureFilenames: Set<String> = [
        "contract.md",
        "amendment-7.md",
        "invoice-401.eml",
        "invoice-432.eml",
        "supplier_abc_22.eml",
        "supplier_abc_23.eml",
        "supplier_abc_24.eml",
        "supplier_abc_25.eml"
    ]

    private static func fixtureURLs() throws -> [URL] {
        let bundle = Bundle.main
        guard let resourcePath = bundle.resourcePath else {
            throw NSError(
                domain: "Gate1Baseline",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Bundle has no resource path."]
            )
        }

        // First preference: the ProjectDelta subdirectory exists in the
        // bundle (proper folder reference). Reads every regular file
        // from there, preserving any future additions to the fixture.
        let subdir = URL(fileURLWithPath: resourcePath)
            .appendingPathComponent("ProjectDelta", isDirectory: true)
        if FileManager.default.fileExists(atPath: subdir.path) {
            let items = (try? FileManager.default.contentsOfDirectory(
                at: subdir,
                includingPropertiesForKeys: [.isRegularFileKey]
            )) ?? []
            let regular = items.filter {
                (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            }
            AtlasLog.app.info("Gate 1 fixture: ProjectDelta/ subdir present, \(regular.count) regular files")
            try Self.assertExpectedFixture(regular)
            return regular
        }

        // Fallback: Xcode 16's PBXFileSystemSynchronizedRootGroup flattens
        // synced subdirectories into the bundle root. Gather every fixture
        // filename across the .eml AND .md extensions and match by name.
        // Crucially, this is no longer .eml-only — that quiet bug masked
        // the missing .md files for three eval runs.
        var found: [URL] = []
        let extensions = ["eml", "md"]
        for ext in extensions {
            let bucket = bundle.urls(forResourcesWithExtension: ext, subdirectory: nil) ?? []
            for url in bucket where Self.expectedFixtureFilenames.contains(url.lastPathComponent) {
                found.append(url)
            }
        }
        AtlasLog.app.info("Gate 1 fixture: flat-bundle lookup matched \(found.count) of \(Self.expectedFixtureFilenames.count) expected filenames")
        try Self.assertExpectedFixture(found)
        return found
    }

    /// Throws a precise, actionable error when the bundle doesn't have
    /// the full ProjectDelta fixture. Gate 1 ALWAYS fails loud now —
    /// a baseline run on a partial corpus is worse than no run.
    private static func assertExpectedFixture(_ urls: [URL]) throws {
        let foundNames = Set(urls.map { $0.lastPathComponent })
        let missing = Self.expectedFixtureFilenames.subtracting(foundNames)
        guard missing.isEmpty else {
            let foundList = foundNames.sorted().joined(separator: ", ")
            let missingList = missing.sorted().joined(separator: ", ")
            throw NSError(
                domain: "Gate1Baseline",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: """
                    ProjectDelta fixture not fully bundled. Missing: \(missingList). \
                    Found: \(foundList). Add Resources/Fixtures/ProjectDelta to the \
                    Kalsmritikosh target as a folder reference (or ensure the missing \
                    files are members of "Copy Bundle Resources") so they ship in the \
                    app bundle. A Gate 1 run on a partial corpus is worse than no run.
                    """]
            )
        }
    }
}
