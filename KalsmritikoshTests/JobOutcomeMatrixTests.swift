//
//  JobOutcomeMatrixTests.swift
//  KalsmritikoshTests
//
//  Ship-readiness review step 6 — a per-job OUTCOME matrix, separate from routing. Every advertised job
//  (168; the hidden content-creator persona excluded) is launched through the production
//  PersonaJobService of a booted app, on a real public case, and what came back is recorded. Beside
//  it: the job-specific professional work product, where one exists, and the suite that verifies it.
//  A job with no row there produces only its kind's generic case output — the matrix says so.
//
//  docs/JOB_OUTCOME_MATRIX.md is this test's output; it fails when the committed file is stale.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Job outcome matrix — every advertised job launched, its outcome recorded", .serialized)
struct JobOutcomeMatrixTests {

    struct Deliverable {
        let workProduct: String
        let verifiedBy: [Any.Type]
        let level: String
        /// false = the kind's generic work product (the same for every job of that kind).
        var jobSpecific = true
    }

    /// Jobs whose professional work product is built by a studio or service of its own. Reviewed by
    /// hand; every id must be a real job. Kind-derived deliverables (findings, closure, custody) are
    /// added in `deliverable(for:)`.
    static let studioDeliverables: [String: Deliverable] = {
        let rca = Deliverable(workProduct: "Root-cause analysis report (Reasoning Studio)", verifiedBy: [RootCauseAnalysisTests.self], level: "unit: work product renders")
        let review = Deliverable(workProduct: "Systematic review: protocol, PRISMA flow from screening decisions, extraction, GRADE per outcome", verifiedBy: [PersonaDeliverables2Tests.self], level: "unit: work product renders")
        let binder = Deliverable(workProduct: "Family / emergency binder", verifiedBy: [PersonaDeliverables2Tests.self], level: "unit: work product renders")
        let factCheck = Deliverable(workProduct: "Fact-check memo (claim table, reply log, checks)", verifiedBy: [FactCheckMemoTests.self], level: "unit: work product renders")
        return [
            "inv.analysis": Deliverable(workProduct: "Competing-hypotheses (ACH) matrix in the ledger", verifiedBy: [ACHRepositoryTests.self], level: "unit: ledger round-trip"),
            "inv.causal-analysis": rca,
            "law.privilege": Deliverable(workProduct: "Privilege log hardcopy", verifiedBy: [PrivilegeLogTests.self], level: "unit: work product renders"),
            "law.production": Deliverable(workProduct: "Bates production with DAT/OPT load files, privileged documents withheld", verifiedBy: [LegalProductionTests.self], level: "unit: production written"),
            "hr.findings-memo": Deliverable(workProduct: "Workplace investigation report", verifiedBy: [WorkplaceInvestigationTests.self], level: "unit: work product renders"),
            "hr.root-cause": rca,
            "fa.expert-report": Deliverable(workProduct: "Expert report (26(a)(2)(B) structure) with schedule", verifiedBy: [ForensicEngagementTests.self], level: "unit: work product renders"),
            "fa.tracing-schedule": Deliverable(workProduct: "Tracing schedule: Decimal money by currency, reconciliation", verifiedBy: [ForensicEngagementTests.self], level: "unit: schedule and reconciliation"),
            "fa.root-cause": rca,
            "siu.referral-report": Deliverable(workProduct: "SIU report & referral", verifiedBy: [SIUReferralTests.self], level: "unit: work product renders"),
            "jrn.claim-board": factCheck,
            "jrn.fact-verification": factCheck,
            "jrn.right-of-reply": Deliverable(workProduct: "Reply log: each adverse claim put to each affected subject", verifiedBy: [FactCheckMemoTests.self], level: "unit: policy enforced"),
            "res.protocol": review,
            "res.screening": review,
            "res.extraction": review,
            "gen.proof-argument": Deliverable(workProduct: "Proof argument (GPS elements in order)", verifiedBy: [PersonaDeliverables2Tests.self], level: "unit: work product renders"),
            "gen.research-log": Deliverable(workProduct: "Research log including nil results", verifiedBy: [PersonaDeliverables2Tests.self], level: "unit: gates enforced"),
            "ind.emergency-pack": binder,
            "ind.legacy-archive": binder,
        ]
    }()

    static func deliverable(for job: PersonaJob) -> Deliverable? {
        if let d = studioDeliverables[job.id] { return d }
        if JobExecutorKind.assignments[job.id] == .chronology {
            return Deliverable(workProduct: "Sourced chronology (persisted job result): dated rows, disputed dates flagged, undated documents listed",
                               verifiedBy: [ChronologyExecutorTests.self], level: "integration: launch persists a typed result")
        }
        switch job.kind {
        case .findings: return Deliverable(workProduct: "generic: case findings report with case-scoped citations", verifiedBy: [InvestigationFindingsServiceTests.self, InvestigationCaseSimulationTests.self], level: "integration: generic service + ledger", jobSpecific: false)
        case .closure: return Deliverable(workProduct: "generic: closure decision and reopen record", verifiedBy: [InvestigationClosureServiceTests.self], level: "integration: generic service + ledger", jobSpecific: false)
        case .evidenceCustody: return Deliverable(workProduct: "generic: chain-of-custody log", verifiedBy: [InvestigationCustodyServiceTests.self], level: "integration: generic service + ledger", jobSpecific: false)
        default: return nil
        }
    }

    static let advertised: [PersonaJob] = PersonaJobCatalogComposer.allJobs
        .filter { $0.persona != ContentCreatorPersonaPackage.applicationID.rawValue }

    @Test("The hand-reviewed deliverable table names only real jobs")
    func deliverableIDsAreReal() {
        let ids = Set(Self.advertised.map(\.id))
        for id in Self.studioDeliverables.keys { #expect(ids.contains(id), "\(id) is not an advertised job") }
        // K7: every studio's saved identity names a real persona and (when given) one of its jobs.
        let all = Dictionary(PersonaJobCatalogComposer.allJobs.map { ($0.id, $0.persona) }, uniquingKeysWith: { a, _ in a })
        for (studio, identity) in StudioStorage.identities {
            if let job = identity.jobID { #expect(all[job] == identity.persona, "\(studio): \(job) is not a job of \(identity.persona)") }
            #expect(PersonaJobCatalogComposer.allJobs.contains { $0.persona == identity.persona }, "\(studio): unknown persona")
        }
        #expect(Self.advertised.count == 168)
    }

    @Test("Every advertised job is launched through the production service; docs/JOB_OUTCOME_MATRIX.md is that measurement")
    func matrixIsMeasured() async throws {
        let pack = try #require(try InvestigationCasePacks.packs().first { $0.persona == "investigator" })
        await SharedSettingsLock.shared.acquire()
        defer { Task { await SharedSettingsLock.shared.release() } }
        let previous = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        var settings = previous
        settings["kalsmritikosh.privacy.offlineNoLLM"] = true
        UserDefaults.standard.setVolatileDomain(settings, forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(previous, forName: UserDefaults.argumentDomain) }

        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("jom-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let state = await AppState(bookmarks: BookmarkStore())
        await state.boot(databaseURL: temp.appendingPathComponent("case.sqlite"))
        guard case .ready = await state.phase, let ingest = await state.ingest, let db = await state.database,
              let service = await state.personaJobs else {
            Issue.record("ledger did not boot"); return
        }
        var fileIDs: [UUID] = []
        for name in pack.files {
            let dst = temp.appendingPathComponent(String(name.dropFirst("investigator".count + 1)))
            try FileManager.default.copyItem(at: try InvestigationCasePacks.url(name), to: dst)
            fileIDs.append(try await ingest.ingest(fileAt: dst).fileRecord.id)
        }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let ws = UUID()
        try await db.exec("INSERT INTO workspaces (id, title, created_at, updated_at) VALUES (?,?,?,?);",
                          [.uuid(ws), .text(pack.caseTitle), .real(now.timeIntervalSince1970), .real(now.timeIntervalSince1970)])
        try await (try #require(await state.workspaceSourceCoordinator)).addSources(Set(fileIDs), to: ws, at: now)
        let c = try await (try #require(await state.investigationCases)).createCase(workspaceID: ws, title: pack.caseTitle, actor: "matrix", at: now)
        _ = try await (try #require(await state.investigationWorkspaceIntake)).includeWorkspaceSources(caseID: c.id, actor: "matrix", at: now)
        let access = SensitiveAccessContext(scope: SensitiveScope(
            workspaceID: ws, maximumSensitivity: .restricted, permitsPrivilegedMaterial: false, purpose: .export))

        var rows: [String] = []
        var counts: [String: Int] = [:]
        var unavailable: [String] = []
        for job in Self.advertised {
            let ctx = PersonaJobLaunchContext(caseID: c.id, workspaceID: ws, title: pack.caseTitle, access: access,
                                              actor: "matrix", question: "What happened, and when?", at: now)
            let outcome: String
            do {
                let l = try await service.launch(job, context: ctx)
                if JobExecutorKind.assignments[job.id] != nil {
                    // A shared executor reports its own state and size ("draft: 12 row(s)", "blocked: …").
                    outcome = "result " + String(l.summary.prefix(90)).replacingOccurrences(of: "|", with: "/")
                    counts[l.items.isEmpty ? "record" : "rows", default: 0] += 1
                } else if !l.items.isEmpty {
                    let cited = l.items.filter { !$0.sourceVersionIDs.isEmpty || !$0.objectIDs.isEmpty }.count
                    outcome = "\(l.items.count) case row(s), \(cited) with sources"
                    counts["rows", default: 0] += 1
                } else if l.producedID != nil {
                    outcome = "record produced"
                    counts["record", default: 0] += 1
                } else {
                    outcome = "summary only"
                    counts["summary", default: 0] += 1
                }
            } catch let e as PersonaJobError {
                if case .serviceUnavailable = e { unavailable.append(job.id) }
                outcome = "fails closed: \(e)"
                counts["failed", default: 0] += 1
            } catch {
                outcome = "error: \(type(of: error))"
                counts["failed", default: 0] += 1
            }
            let d = Self.deliverable(for: job)
            if let d { counts[JobExecutorKind.assignments[job.id] != nil ? "executor" : (d.jobSpecific ? "specific" : "generic"), default: 0] += 1 }
            let persona = job.persona.replacingOccurrences(of: "com.kalsmritikosh.persona.", with: "")
            rows.append("| \(persona) | `\(job.id)` | \(job.title) | \(job.kind.rawValue) | \(outcome) | "
                        + "\(d?.workProduct ?? "none: generic \(job.kind.rawValue) rows") | "
                        + "\(d.map { $0.verifiedBy.map { String(describing: $0) }.joined(separator: ", ") } ?? "—") | "
                        + "\(d?.level ?? "not verified") |")
        }
        #expect(unavailable.isEmpty, "the production composition leaves these jobs without their service: \(unavailable)")

        let generated = """
        # Job outcome matrix

        Generated by `JobOutcomeMatrixTests.matrixIsMeasured`; do not hand-edit. Every advertised job (\(Self.advertised.count);
        the hidden content-creator persona excluded) is launched through the production `PersonaJobService` of a booted
        app with AI off, on the investigator case pack (\(pack.caseTitle)), and the result is recorded.

        **Read this honestly.** Jobs route by *kind*: every job of one kind gets the same output. A job-specific work product
        exists only where a studio builds it (the reviewed table in the test); it is made in that studio, and launching the
        job does not by itself produce it. "generic:" marks the kind's shared work product — for example, an exhibit binder
        job gets the generic custody log, not an exhibit binder. "Verified by" names the suite that checks the work product.
        No job is verified end to end through the UI or the signed app, and none is practitioner-reviewed.

        | Measure | Jobs |
        |---|---|
        | Launch returned case rows | \(counts["rows", default: 0]) |
        | Launch produced a record (case, run) | \(counts["record", default: 0]) |
        | Launch returned a summary only | \(counts["summary", default: 0]) |
        | Launch failed closed / errored | \(counts["failed", default: 0]) |
        | Job-specific work product (studio) with a verifying suite | \(counts["specific", default: 0]) |
        | Job's typed result persisted by a shared executor at launch | \(counts["executor", default: 0]) |
        | Generic kind work product (findings, closure, custody) with a verifying suite | \(counts["generic", default: 0]) |
        | Generic kind rows only, no work product | \(Self.advertised.count - counts["specific", default: 0] - counts["generic", default: 0] - counts["executor", default: 0]) |

        | Persona | Job | Title | Kind | Launch outcome (measured) | Work product | Verified by | Level |
        |---|---|---|---|---|---|---|---|
        \(rows.joined(separator: "\n"))

        """
        Attachment.record(generated, named: "JOB_OUTCOME_MATRIX.md")
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/JOB_OUTCOME_MATRIX.md")
        let committed = (try? String(contentsOf: path, encoding: .utf8)) ?? ""
        if committed != generated {
            Issue.record(Comment(rawValue: "docs/JOB_OUTCOME_MATRIX.md is stale — replace it with:\n" + generated))
        }
    }
}
