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
        public let ingestedFixtureFiles: Int
        public let questionCount: Int
    }

    /// Run the full baseline cycle. Returns the URL of the written
    /// report; caller surfaces it in the UI.
    @MainActor
    public static func generate() async throws -> Result {
        AtlasLog.app.info("Gate 1 baseline starting")

        // 1. Isolated temp dir + fresh AppState.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Gate1Baseline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let isolatedBookmarks = BookmarkStore()
        let state = AppState(bookmarks: isolatedBookmarks)
        await state.boot()

        guard case .ready = state.phase, let ingest = state.ingest else {
            throw NSError(
                domain: "Gate1Baseline",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "AppState failed to boot."]
            )
        }

        // 2. Ingest the bundled ProjectDelta fixture.
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
        let runner = EvalKitRunner()
        let reportURL = try await runner.run(brain: state.brain, objects: objects, outputDir: reportDir)

        // Load question count for the result surface.
        let questionCount = (try? runner.loadQuestions().count) ?? 0

        AtlasLog.app.info("Gate 1 baseline complete → \(reportURL.path, privacy: .public)")
        return Result(
            reportURL: reportURL,
            ingestedFixtureFiles: ingested,
            questionCount: questionCount
        )
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
