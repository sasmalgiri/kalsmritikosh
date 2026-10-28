//
//  JobResultWorkflowTests.swift
//  KalsmritikoshTests
//
//  Audit A1 — the Jobs screen's model on a booted app: an Ask job needs and uses the person's
//  question; a run's saved result shows its real state (draft / blocked / completed, not a bare
//  checkmark); the person decides and notes each row, corrects it and completes it (completion is
//  refused while a row is undecided, without a note, or for a blocked result); every revision is
//  kept and restorable; reopening the app brings the reviewed result back.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Job results through the Jobs screen (A1)", .serialized)
struct JobResultWorkflowTests {

    @MainActor
    static func model(_ state: AppState) async throws -> PersonaJobsModel {
        let m = PersonaJobsModel(service: try #require(state.personaJobs), catalog: try #require(state.personaJobCatalog),
                                 workspaces: try #require(state.workspaces), cases: state.investigationCases,
                                 results: state.database.map { JobResultRepository(database: $0) })
        await m.load()
        return m
    }

    @MainActor
    @Test("Ask uses the question; a result shows its state; review, completion and reopening work")
    func resultLifecycle() async throws {
        let f = try await CaseErasureTests.boot()
        defer { try? FileManager.default.removeItem(at: f.temp) }
        let m = try await Self.model(f.state)
        await m.select(persona: ApplicationDefinitionID(rawValue: "com.kalsmritikosh.persona.investigator"))
        let ws = try #require(try await f.db.query("SELECT workspace_id FROM investigation_cases WHERE id = ?;", [.uuid(f.caseA)]).first?.string(0).flatMap(UUID.init(uuidString:)))
        m.selectedWorkspace = ws
        await m.reloadMatters()
        let matter = try #require(m.openMatters.first { $0.id == f.caseA })
        m.openMatter(matter)
        await m.reloadResults()

        // Ask without a question is refused with a clear message; with one it runs and is saved.
        let ask = try #require(m.jobs.first { $0.kind == .ask })
        await m.run(ask, actor: "Tester", at: Date())
        #expect(m.lastError?.contains("type the question") == true)
        m.questions[ask.id] = "Who was indicted?"
        await m.run(ask, actor: "Tester", at: Date())
        #expect(m.lastError == nil, "\(m.lastError ?? "")")
        #expect(m.results[ask.id] != nil, "the answer (or refusal) is saved as the job's result")
        let saved = try #require(m.results[ask.id])
        #expect(saved.content.rows.first?.detail == "Question: Who was indicted?")

        // An executor job: its card states the saved result, not a checkmark.
        let chronology = try #require(m.jobs.first { $0.id == "inv.linkage" })
        await m.run(chronology, actor: "Tester", at: Date())
        let result = try #require(m.results[chronology.id])
        #expect(m.status(of: chronology)?.hasPrefix(result.state == .blocked ? "Blocked" : "Draft") == true)

        // Review through the result model.
        let repo = try #require(m.resultsRepository)
        let review = JobResultModel(repo: repo, caseID: f.caseA, jobID: chronology.id, jobTitle: chronology.title)
        await review.load()
        if result.state == .blocked {
            await review.save(complete: true, actor: "Tester")
            #expect(review.problem?.contains("blocked") == true)
            return
        }
        #expect(!review.rows.isEmpty)
        review.completionNote = "Checked every date against the release."
        await review.save(complete: true, actor: "Tester")
        #expect(review.problem?.contains("undecided") == true, "completion needs every row decided")
        review.rows[0].decision = .accepted
        review.rows[0].note = "Matches the indictment date"
        review.rows[0].title += " (checked)"
        for i in review.rows.indices.dropFirst() { review.rows[i].decision = .rejected }
        // The contract's columns the ledger could not state are recorded by the person.
        for f in JobFields.missing(job: chronology.id, row: review.rows[0]) {
            var d = review.rows[0].fields ?? [:]; d[f.key] = "Recorded by the reviewer"; review.rows[0].fields = d
        }
        review.completionNote = ""
        await review.save(complete: true, actor: "Tester")
        #expect(review.problem?.contains("note") == true, "completion needs the person's note")
        review.completionNote = "Checked every date against the release."
        await review.save(complete: true, actor: "Tester")
        #expect(review.problem == nil, "\(review.problem ?? "")")
        #expect(review.current?.state == .completed && review.history.count >= 2)
        #expect(review.current?.content.rows[0].decision == .accepted && review.current?.content.rows[0].title.hasSuffix("(checked)") == true)

        // Restoring an earlier revision makes it current as a NEW revision; nothing is overwritten.
        let original = try #require(review.history.last)
        await review.restore(original, actor: "Tester")
        #expect(review.current?.state == .draft && review.history.count >= 3)
        #expect(try await repo.history(caseID: f.caseA, jobID: chronology.id).contains { $0.state == .superseded && $0.content.review?.completed == true },
                "the completed revision stays in the record")

        // Reopening the app brings the result back.
        let second = await AppState(bookmarks: BookmarkStore())
        await second.boot(databaseURL: f.temp.appendingPathComponent("case.sqlite"))
        let reopened = try await JobResultRepository(database: try #require(await second.database)).latest(caseID: f.caseA, jobID: chronology.id)
        #expect(reopened?.id == review.current?.id)
        // The exported form carries the decisions and sources.
        let md = JobResultMarkdown.render(try #require(review.history.first { $0.state == .superseded && $0.content.review?.completed == true }), title: "Chronology")
        #expect(md.contains("Decision: accepted — Matches the indictment date") && md.contains("Source (version "))
    }

    @Test("Export re-checks every cited source: a source made privileged after the run stops the export")
    func exportRecheck() async throws {
        let f = try await CaseErasureTests.boot()
        defer { try? FileManager.default.removeItem(at: f.temp) }
        let ws = try #require(try await f.db.query("SELECT workspace_id FROM investigation_cases WHERE id = ?;", [.uuid(f.caseA)]).first?.string(0).flatMap(UUID.init(uuidString:)))
        let service = try #require(await f.state.personaJobs)
        let job = try #require(PersonaJobCatalogComposer.allJobs.first { $0.id == "inv.source-reliability" })
        let access = SensitiveAccessContext(scope: SensitiveScope(workspaceID: ws, maximumSensitivity: .restricted, permitsPrivilegedMaterial: false, purpose: .export))
        _ = try await service.launch(job, context: PersonaJobLaunchContext(caseID: f.caseA, access: access, actor: "Tester", at: Date()))
        let repo = JobResultRepository(database: f.db)
        let record = try #require(try await repo.latest(caseID: f.caseA, jobID: job.id))
        #expect(await f.state.jobResultExportCheck(record) == nil)
        let version = try #require(record.content.rows.flatMap(\.refs).compactMap(\.sourceVersionID).first)
        _ = try await SensitiveScopeRepository(database: f.db).assign(
            target: SensitiveScopeTarget(kind: .sourceVersion, id: version), sensitivity: .confidential,
            authority: .userConfirmed(actorID: "Tester", confirmationID: UUID(), privileged: true), reason: "privileged")
        #expect(await f.state.jobResultExportCheck(record)?.contains("no longer cleared") == true)
    }

    @Test("A method job's completion saves each accepted method as a real method run in the case")
    func methodRunsSaved() async throws {
        let f = try await CaseErasureTests.boot()
        defer { try? FileManager.default.removeItem(at: f.temp) }
        let ws = try #require(try await f.db.query("SELECT workspace_id FROM investigation_cases WHERE id = ?;", [.uuid(f.caseA)]).first?.string(0).flatMap(UUID.init(uuidString:)))
        let service = try #require(await f.state.personaJobs)
        let job = try #require(PersonaJobCatalogComposer.allJobs.first { $0.id == "inv.methods" })
        let access = SensitiveAccessContext(scope: SensitiveScope(workspaceID: ws, maximumSensitivity: .restricted, permitsPrivilegedMaterial: false, purpose: .export))
        _ = try await service.launch(job, context: PersonaJobLaunchContext(caseID: f.caseA, access: access, actor: "Tester", at: Date()))
        let record = try #require(try await JobResultRepository(database: f.db).latest(caseID: f.caseA, jobID: job.id))
        var rows = record.content.rows
        #expect(rows.first?.fields?["methodID"] != nil, "each method row names its method")
        rows[0].decision = .accepted
        let (runs, problems) = await f.state.startMethodRuns(caseID: f.caseA, rows: rows, actor: "Tester")
        #expect(problems.isEmpty, "\(problems)")
        let runID = try #require(runs[0])
        #expect(try await f.db.query("SELECT COUNT(*) FROM case_method_runs WHERE case_id = ? AND method_run_id = ?;", [.uuid(f.caseA), .uuid(runID)]).first?.int(0) == 1,
                "the run is saved in the case's method engine")
    }
}
