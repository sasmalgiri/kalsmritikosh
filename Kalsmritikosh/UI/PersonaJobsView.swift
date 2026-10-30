//
//  PersonaJobsView.swift
//  Kalsmritikosh
//
//  The cross-persona production UI surface (owner Decision 1). Closes the "job registered but no screen" gap:
//  it DISCOVERS the shipped personas from the ONE production PersonaJobCatalog, ENUMERATES each persona's real
//  jobs, and LAUNCHES a selected job into the real implementation via the ONE live PersonaJobService — the same
//  path the acceptance suites drive. One shared surface for every persona; no per-persona bespoke screen.
//
//  Flow: pick a persona → start a matter (the persona's intake job creates a real case in a chosen workspace)
//  → run any of the persona's jobs against that matter. Every launch reaches a real shared service and reports
//  its real outcome; nothing here is a placeholder.
//

import SwiftUI
import os

// MARK: - Model (testable, @Observable)

@MainActor
@Observable
public final class PersonaJobsModel {
    private let service: PersonaJobService
    private let catalog: PersonaJobCatalog
    private let workspaces: WorkspaceRepository

    public private(set) var personas: [PersonaApplicationDefinition] = []
    public var selectedPersona: ApplicationDefinitionID?
    public private(set) var jobs: [PersonaJob] = []
    public private(set) var workspaceList: [Workspace] = []
    public var selectedWorkspace: Workspace.ID?
    public var matterTitle: String = ""
    public private(set) var activeCaseID: UUID?
    public private(set) var activeMatterTitle: String?
    public private(set) var lastOutcome: String?
    public private(set) var lastError: String?
    public private(set) var busy = false
    /// JOB-JOURNEY — job ids already run against the active matter. UI journey
    /// state (drives the phase progress + per-card checkmarks), persisted per
    /// case in UserDefaults; the durable truth of what actually happened stays
    /// in the ledger (case events / work products).
    public private(set) var ranJobs: Set<String> = []

    private func ranKey(_ caseID: UUID) -> String { "kalsmritikosh.jobs.ran.\(caseID.uuidString)" }
    private func loadRanJobs() {
        guard let caseID = activeCaseID else { ranJobs = []; return }
        ranJobs = Set(UserDefaults.standard.stringArray(forKey: ranKey(caseID)) ?? [])
    }
    private func markRan(_ jobID: String, in caseID: UUID) {
        var ran = Set(UserDefaults.standard.stringArray(forKey: ranKey(caseID)) ?? [])
        ran.insert(jobID)
        UserDefaults.standard.set(Array(ran).sorted(), forKey: ranKey(caseID))
        if caseID == activeCaseID { ranJobs = ran }
    }

    /// A1 — each job's current saved result in the active matter (state, size), from the ledger.
    public private(set) var results: [String: JobResultRecord] = [:]
    /// A1 — the question typed for each Ask job.
    public var questions: [String: String] = [:]
    public let resultsRepository: JobResultRepository?
    /// I1 — the explicit, auditable inclusion path (nil: the app has no intake wired; the scope strip hides).
    private let intake: InvestigationWorkspaceIntake?
    /// I2 — the case file (its next steps are the one guide) and custody (its manifest feeds the snapshot).
    private let caseFiles: CaseFileService?
    private let custody: InvestigationCustodyService?

    public init(service: PersonaJobService, catalog: PersonaJobCatalog, workspaces: WorkspaceRepository,
                cases: InvestigationCaseRepository? = nil, results: JobResultRepository? = nil,
                intake: InvestigationWorkspaceIntake? = nil,
                caseFiles: CaseFileService? = nil, custody: InvestigationCustodyService? = nil) {
        self.service = service; self.catalog = catalog; self.workspaces = workspaces; self.cases = cases
        self.resultsRepository = results
        self.intake = intake
        self.caseFiles = caseFiles; self.custody = custody
    }

    // MARK: I2 — progress is the state of the work, not the count of launches

    /// The person's "not applicable" decisions for the active matter: job id → reason. UI journey
    /// state per case (UserDefaults); each decision is also written to the case's log.
    public private(set) var notApplicable: [String: String] = [:]
    private func naKey(_ caseID: UUID) -> String { "kalsmritikosh.jobs.na.\(caseID.uuidString)" }
    private func loadNotApplicable() {
        guard let caseID = activeCaseID else { notApplicable = [:]; return }
        notApplicable = (UserDefaults.standard.dictionary(forKey: naKey(caseID)) as? [String: String]) ?? [:]
    }
    private func storeNotApplicable(_ map: [String: String], in caseID: UUID) {
        UserDefaults.standard.set(map, forKey: naKey(caseID))
        if caseID == activeCaseID { notApplicable = map }
    }

    /// Record that a job does not apply to this matter, with the reason. Refused without a reason.
    /// Recorded in the case's log, so the decision is part of the record, not a hidden tick.
    public func markNotApplicable(_ job: PersonaJob, reason: String, actor: String, at date: Date) async {
        guard let caseID = activeCaseID else { lastError = "Open a matter first."; return }
        let r = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !r.isEmpty else { lastError = "\(job.title): say why it does not apply to this matter."; return }
        var map = (UserDefaults.standard.dictionary(forKey: naKey(caseID)) as? [String: String]) ?? [:]
        map[job.id] = r
        storeNotApplicable(map, in: caseID)
        appendLog(jobTitle: job.title, summary: "Marked not applicable — \(r)", at: date, in: caseID)
        if let caseFiles {
            do { try await caseFiles.file.logAction(caseID: caseID, action: "job.notApplicable", detail: "\(job.title) — \(r)", actor: actor, at: date) }
            catch { KalsmritikoshLog.ui.error("Not-applicable log failed: \(error.localizedDescription, privacy: .public)") }
        }
        if caseID == activeCaseID { lastOutcome = "\(job.title) marked not applicable: \(r)"; lastError = nil }
    }

    /// Reverse a not-applicable decision (recorded too); the job is open work again.
    public func markApplicable(_ job: PersonaJob, actor: String, at date: Date) async {
        guard let caseID = activeCaseID else { return }
        var map = (UserDefaults.standard.dictionary(forKey: naKey(caseID)) as? [String: String]) ?? [:]
        guard map.removeValue(forKey: job.id) != nil else { return }
        storeNotApplicable(map, in: caseID)
        appendLog(jobTitle: job.title, summary: "Applicable again", at: date, in: caseID)
        if let caseFiles {
            do { try await caseFiles.file.logAction(caseID: caseID, action: "job.applicable", detail: job.title, actor: actor, at: date) }
            catch { KalsmritikoshLog.ui.error("Applicable log failed: \(error.localizedDescription, privacy: .public)") }
        }
        if caseID == activeCaseID { lastOutcome = "\(job.title) is open work again."; lastError = nil }
    }

    /// The state of one job's work in the open matter.
    public func progress(of job: PersonaJob) -> JobProgress {
        JobProgress.of(result: results[job.id], ran: ranJobs.contains(job.id), notApplicable: notApplicable[job.id], lastScopeChange: lastScopeChange)
    }
    /// Honest counts over the persona's runnable jobs.
    public var progressSummary: JobProgressSummary { JobProgressSummary(runnableJobs.map { progress(of: $0) }) }

    /// The case file's own next steps (CaseNextSteps) for the open matter; empty without a case file service.
    public private(set) var caseSteps: [CaseNextStep] = []
    public func refreshCaseSteps() async {
        guard let caseID = activeCaseID, let caseFiles else { caseSteps = []; return }
        do {
            var manifest: [CustodyManifestEntry] = []
            var custodyFailed = false
            if let custody { do { manifest = try await custody.manifest(caseID: caseID) } catch { custodyFailed = true } } else { custodyFailed = true }
            guard let snapshot = try await caseFiles.snapshot(caseID: caseID, custody: manifest) else { caseSteps = []; return }
            let unresolved = (try? await caseFiles.file.unresolvedReferences(caseID: caseID).count) ?? 0
            let steps = CaseNextSteps.compute(snapshot, unresolvedReferences: unresolved, custodyReadFailed: custodyFailed)
            if caseID == activeCaseID { caseSteps = steps }
        } catch {
            KalsmritikoshLog.ui.error("Case next steps failed: \(error.localizedDescription, privacy: .public)")
            if caseID == activeCaseID { caseSteps = [] }
        }
    }

    /// What to do next: the case's steps, then the jobs' blockers and reviews.
    public var recommendations: [JobRecommendation] {
        JobRecommendations.compute(caseSteps: caseSteps, jobs: runnableJobs.map { ($0, progress(of: $0)) })
    }

    // MARK: I1 — documents in the case (scope), reviewed and approved explicitly

    /// What the open matter's workspace holds versus what the case has decided: in scope, excluded,
    /// and new (undecided). Read-only until the person approves an inclusion.
    public private(set) var scopePreview: CaseInclusionPreview?
    /// When the case's scope last changed (a source included or excluded) — results saved before
    /// then were produced over an earlier scope.
    public private(set) var lastScopeChange: Date?
    /// The preview the review sheet is showing (nil: closed).
    public var inclusionReview: CaseInclusionPreview?
    public var canReviewScope: Bool { intake != nil && activeCaseID != nil }

    /// Reload the scope summary for the open matter. Reads only; never includes anything.
    public func refreshScope() async {
        guard let caseID = activeCaseID else { scopePreview = nil; lastScopeChange = nil; return }
        if let cases, let record = try? await cases.fetch(caseID: caseID) {
            let change = record.events.filter { [.sourceIncluded, .sourceExcluded].contains($0.action) }.map(\.occurredAt).max()
            if caseID == activeCaseID { lastScopeChange = change }
        }
        guard let intake else { scopePreview = nil; return }
        do {
            let p = try await intake.preview(caseID: caseID)
            if caseID == activeCaseID { scopePreview = p }
        } catch {
            KalsmritikoshLog.ui.error("Scope preview failed: \(error.localizedDescription, privacy: .public)")
            if caseID == activeCaseID { lastError = "Couldn't read the case's documents: \(error.localizedDescription)" }
        }
    }

    /// Open the review: what approval would add, what stays excluded. Nothing is included here.
    public func reviewNewDocuments() async {
        await refreshScope()
        inclusionReview = scopePreview
    }

    /// Approve the inclusion of the chosen new documents (a subset of the preview's pending list).
    /// Each inclusion is a recorded case event; excluded sources stay excluded; the case revision
    /// moves, so approvals bound to the earlier scope are stale from here on.
    public func approveInclusion(_ approved: Set<UUID>, actor: String, at date: Date) async {
        guard let caseID = activeCaseID, let intake else { lastError = "Open a matter first."; return }
        guard !approved.isEmpty else { inclusionReview = nil; return }
        busy = true; defer { busy = false }
        do {
            let (c, included) = try await intake.include(caseID: caseID, approved: approved, actor: actor, at: date)
            let summary = "\(included) document(s) added to the case's scope (revision \(c.revision)). Results and approvals made before this were produced over the earlier scope — run the jobs again to cover the new documents."
            appendLog(jobTitle: "Documents added to case", summary: summary, at: date, in: caseID)
            if caseID == activeCaseID {
                lastOutcome = summary; lastError = nil
                inclusionReview = nil
                await refreshScope()
                await reloadResults()
                await refreshCaseSteps()   // UI journey 2026-10-30b, D-6: the "Next" list follows the new scope at once
            }
        } catch {
            lastError = "Couldn't add the documents: \(error.localizedDescription)"
        }
    }

    /// A1 — reload every job's current result for the active matter.
    public func reloadResults() async {
        guard let caseID = activeCaseID, let resultsRepository else { results = [:]; return }
        let loaded = (try? await resultsRepository.latestByJob(caseID: caseID)) ?? [:]
        // A reload that finishes after a matter switch is dropped (the newer matter's reload wins).
        if caseID == activeCaseID { results = loaded }
    }

    /// I1 — a saved result produced before the case's scope last changed.
    public func isFromEarlierScope(_ job: PersonaJob) -> Bool {
        guard let r = results[job.id], let change = lastScopeChange else { return false }
        return r.createdAt < change
    }

    /// A1/I2 — what a job card says: the state of its work (nil when nothing has happened yet).
    public func status(of job: PersonaJob) -> String? {
        let p = progress(of: job)
        if case .notStarted = p.state { return nil }
        return p.label
    }

    // JOB-RESUME — matters are durable; the page must let the user return to
    // them (the whole point of a jobs system). Open matters for the selected
    // workspace, newest first.
    private let cases: InvestigationCaseRepository?
    public private(set) var openMatters: [InvestigationCase] = []

    public func reloadMatters() async {
        guard let cases, let wsID = selectedWorkspace else { openMatters = []; return }
        let all = (try? await cases.listCases(workspaceID: wsID)) ?? []
        openMatters = all.filter { $0.status == .open }.sorted { $0.createdAt > $1.createdAt }
    }

    /// Reopen an existing matter: all job runs, phase progress, work log, and
    /// guided-walkthrough positions come back exactly as left. Reopening never widens the case's
    /// scope: documents added to the workspace since are shown as new, and included only when the
    /// person approves them (I1).
    public func openMatter(_ matter: InvestigationCase) {
        activeCaseID = matter.id
        activeMatterTitle = matter.title
        lastOutcome = "Resumed matter \"\(matter.title)\""
        lastError = nil
        loadRanJobs()
        loadNotApplicable()
        loadWorkLog()
        Task {
            await reloadResults()   // A1 — each job's saved result comes back with the matter
            await refreshScope()
            await refreshCaseSteps()
            if let p = scopePreview, p.hasChanges, activeCaseID == matter.id {
                lastOutcome = "Resumed matter \"\(matter.title)\" — \(p.pending.count) new document(s) in its workspace are not in the case yet. Use “Review new documents” to add them."
            }
        }
    }

    // JOB-LOG (maxmailin pattern) — the work and its results live TOGETHER:
    // every job run against the matter is recorded with its outcome summary
    // and shown on this page, so returning to a matter shows what was done,
    // when, and what it found. UI journey state (UserDefaults per case); the
    // durable evidence itself stays in the ledger the services wrote to.
    public struct MatterLogEntry: Codable, Identifiable, Sendable {
        public var id: UUID = UUID()
        public let jobTitle: String
        public let summary: String
        public let at: Date
    }
    public private(set) var workLog: [MatterLogEntry] = []

    private func logKey(_ caseID: UUID) -> String { "kalsmritikosh.jobs.log.\(caseID.uuidString)" }
    private func loadWorkLog() {
        guard let caseID = activeCaseID,
              let data = UserDefaults.standard.data(forKey: logKey(caseID)),
              let entries = try? JSONDecoder().decode([MatterLogEntry].self, from: data) else {
            workLog = []; return
        }
        workLog = entries
    }
    private func appendLog(jobTitle: String, summary: String, at date: Date, in caseID: UUID) {
        var log = (UserDefaults.standard.data(forKey: logKey(caseID)).flatMap { try? JSONDecoder().decode([MatterLogEntry].self, from: $0) }) ?? []
        log.append(MatterLogEntry(jobTitle: jobTitle, summary: summary, at: date))
        if let data = try? JSONEncoder().encode(log) {
            UserDefaults.standard.set(data, forKey: logKey(caseID))
        }
        if caseID == activeCaseID { workLog = log }
    }

    /// The persona-neutral intake job (the one job that opens a matter) for the selected persona.
    public var intakeJob: PersonaJob? { jobs.first { $0.kind == .caseIntake } }
    /// Every non-intake job — runnable only once a matter is open.
    public var runnableJobs: [PersonaJob] { jobs.filter { $0.kind != .caseIntake } }

    public func load() async {
        // A5 — the Content creator persona stays hidden unless its module is on.
        personas = await service.personas().filter {
            ProductModuleFlags.isEnabled(.contentCreatorPersona) || $0.id != ContentCreatorPersonaPackage.applicationID
        }
        if selectedPersona == nil {
            // D1 — open with the persona onboarding chose for the first case.
            let chosen = UserDefaults.standard.string(forKey: AppState.investigationPersonaKey)
            selectedPersona = personas.first { $0.id.rawValue == chosen }?.id ?? personas.first?.id
        }
        workspaceList = (try? await workspaces.all(includeArchived: false)) ?? []
        if selectedWorkspace == nil { selectedWorkspace = workspaceList.first?.id }
        await reloadJobs()
        await reloadMatters()
    }

    public func select(persona id: ApplicationDefinitionID) async {
        selectedPersona = id
        activeCaseID = nil; activeMatterTitle = nil; lastOutcome = nil; lastError = nil
        ranJobs = []
        scopePreview = nil; lastScopeChange = nil; inclusionReview = nil
        notApplicable = [:]; caseSteps = []
        await reloadJobs()
    }

    private func reloadJobs() async {
        guard let id = selectedPersona else { jobs = []; return }
        jobs = await service.jobs(forPersona: id)
    }

    /// First run: no workspace exists yet — create the default one rather
    /// than dead-ending a brand-new user on a disabled button.
    public func ensureWorkspace() async {
        guard selectedWorkspace == nil else { return }
        if workspaceList.isEmpty {
            let ws = Workspace(title: "General")
            try? await workspaces.upsert(ws)
            workspaceList = (try? await workspaces.all(includeArchived: false)) ?? [ws]
        }
        selectedWorkspace = workspaceList.first?.id
    }

    /// Open a matter by launching the selected persona's intake job in the chosen workspace.
    public func startMatter(actor: String, at date: Date) async {
        await ensureWorkspace()
        guard let intake = intakeJob, let wsID = selectedWorkspace else {
            lastError = "Choose a workspace and a persona first."; return
        }
        let title = matterTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { lastError = "Give the matter a title."; return }
        busy = true; defer { busy = false }
        do {
            let out = try await service.launch(intake, context: PersonaJobLaunchContext(
                workspaceID: wsID, title: title, actor: actor, at: date))
            activeCaseID = out.producedID
            activeMatterTitle = title
            // UI journey 2026-10-30: a matter opened in an empty workspace has nothing in scope and every
            // job blocks; say so here, with the way to fix it, instead of letting each job say it.
            lastOutcome = out.summary.contains("with 0 source(s)")
                ? out.summary + " — nothing is in scope yet: add documents to this workspace (Projects → Add sources…), then come back and use “Review new documents” to bring them into the case; until then every job will report that the case has no documents."
                : out.summary
            lastError = nil
            loadRanJobs()
            loadNotApplicable()
            if let intakeID = intakeJob?.id, let c = out.producedID { markRan(intakeID, in: c) }   // intake IS phase 1, done
            await reloadResults()
            await refreshScope()
            await refreshCaseSteps()
            if let c = out.producedID { appendLog(jobTitle: "Matter opened", summary: out.summary, at: date, in: c) }
            await reloadMatters()
        } catch { lastError = "\(error)"; lastOutcome = nil }
    }

    /// Run a job against the open matter, reaching the real shared service.
    public func run(_ job: PersonaJob, actor: String, at date: Date) async {
        guard let caseID = activeCaseID, let wsID = selectedWorkspace else {
            lastError = "Open a matter first."; return
        }
        let access = SensitiveAccessContext(scope: SensitiveScope(
            workspaceID: wsID, maximumSensitivity: .restricted, permitsPrivilegedMaterial: false, purpose: .export))
        // A1 — an Ask job needs the person's question.
        let question = questions[job.id]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if job.kind == .ask, (question ?? "").isEmpty {
            lastError = "\(job.title): type the question to ask first."; lastOutcome = nil; return
        }
        busy = true; defer { busy = false }
        do {
            let out = try await service.launch(job, context: PersonaJobLaunchContext(
                caseID: caseID, access: access, actor: actor, question: job.kind == .ask ? question : nil, at: date))
            // T1 race 1 — the result belongs to the matter it was asked in (the service saved it
            // there). If the person switched matters meanwhile, it is logged under the asking matter
            // and never shown as the open matter's result.
            markRan(job.id, in: caseID)
            appendLog(jobTitle: job.title, summary: out.summary, at: date, in: caseID)
            if caseID == activeCaseID {
                lastOutcome = "\(job.title): \(out.summary)"; lastError = nil
                await reloadResults()
                await refreshCaseSteps()
            } else {
                lastOutcome = "\(job.title) finished for another matter; its result is saved there."; lastError = nil
            }
        } catch {
            lastError = caseID == activeCaseID ? "\(job.title): \(error.localizedDescription)"
                                               : "\(job.title) (another matter): \(error.localizedDescription)"
            lastOutcome = nil
        }
    }
}

// MARK: - View

public struct PersonaJobsView: View {
    @Environment(AppState.self) private var appState
    @State private var model: PersonaJobsModel?
    @State private var docJob: PersonaJob?          // JOB-DOC: job whose documentation sheet is open
    @State private var runnerJob: PersonaJob?       // JOB-RUN: job whose guided walkthrough is open
    @State private var resultJob: PersonaJob?       // A1: job whose saved result is open
    @State private var naJob: PersonaJob?           // I2: job being marked not applicable (reason prompt)
    @State private var naReason = ""
    /// SURFACE STYLE switch (Settings): classic fixed Analyze launchers vs the
    /// newer catalog-driven ones. Reactive via the shared FeatureFlags key.
    @AppStorage(FeatureFlags.preferClassicSurfacesKey) private var preferClassicSurfaces = false

    public init() {}

    public var body: some View {
        Group {
            if let model {
                content(model)
                    .sheet(item: $docJob) { job in
                        JobDocumentationDetail(
                            job: job,
                            personaLabel: model.personas.first { $0.id == model.selectedPersona }?.label ?? "")
                    }
                    .sheet(item: $resultJob, onDismiss: { Task { await model.reloadResults() } }) { job in
                        if let repo = model.resultsRepository, let caseID = model.activeCaseID {
                            JobResultView(model: JobResultModel(repo: repo, caseID: caseID, jobID: job.id, jobTitle: job.title), actor: "me",
                                          onRerun: { await model.run(job, actor: "me", at: Date()) })
                        }
                    }
                    .sheet(item: $runnerJob) { job in
                        // JOB-RUN — guided Previous/Next walkthrough over the job's
                        // documented workflow; "Run job now" uses the SAME launch path.
                        if let doc = JobDocumentationCatalog.doc(
                            personaLabel: model.personas.first { $0.id == model.selectedPersona }?.label ?? "",
                            jobTitle: job.title) {
                            JobRunnerView(
                                job: job, doc: doc,
                                canRun: !model.busy && model.activeCaseID != nil,
                                onRun: { Task { await model.run(job, actor: "me", at: Date()) } },
                                onClose: { runnerJob = nil },
                                onStartWorkflow: {
                                    // Hand off to the Work Center as a full guided
                                    // workflow; RootView navigates there and it starts.
                                    runnerJob = nil
                                    if let def = WCCatalog.jobWorkflow(forJob: job) {
                                        appState.pendingWorkCenterDefID = def.defID
                                    }
                                })
                        }
                    }
            } else if appState.personaJobs != nil {
                ProgressView().task { await setup() }
            } else {
                ContentUnavailableView("Persona jobs are still starting…",
                                       systemImage: "person.crop.rectangle.stack")
            }
        }
    }

    private func setup() async {
        guard let service = appState.personaJobs, let catalog = appState.personaJobCatalog,
              let ws = appState.workspaces else { return }
        let m = PersonaJobsModel(service: service, catalog: catalog, workspaces: ws,
                                 cases: appState.investigationCases,
                                 results: appState.database.map { JobResultRepository(database: $0) },
                                 intake: appState.investigationWorkspaceIntake,
                                 caseFiles: appState.caseFiles, custody: appState.investigationCustody)
        await m.load()
        model = m
    }

    @ViewBuilder
    private func content(_ model: PersonaJobsModel) -> some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                personaPicker(model)
                Divider()
                matterBar(model)
                if let outcome = model.lastOutcome {
                    Label(outcome, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
                }
                if let err = model.lastError {
                    Label(err, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
                }
                workLogSection(model)
                jobGrid(model)
            }
            .padding(20)
        }
        // JOB-RESUME — the resumable-matters list follows the chosen workspace.
        .onChange(of: model.selectedWorkspace) { _, _ in
            Task { await model.reloadMatters() }
        }
        // I2 — the not-applicable decision needs its reason.
        .alert("Not applicable to this matter", isPresented: Binding(get: { naJob != nil }, set: { if !$0 { naJob = nil } }), presenting: naJob) { job in
            TextField("Why it does not apply", text: $naReason)
            Button("Record") { let r = naReason; Task { await model.markNotApplicable(job, reason: r, actor: "me", at: Date()) }; naJob = nil }
                .disabled(naReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) { naJob = nil }
        } message: { job in
            Text("\(job.title) will stop holding its phase open. The reason is written to the case's log and the decision can be reversed.")
        }
    }

    private func personaPicker(_ model: PersonaJobsModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Choose a professional focus").font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(model.personas, id: \.id) { p in
                        let selected = model.selectedPersona == p.id
                        Button {
                            Task { await model.select(persona: p.id) }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.label).font(.callout.weight(.semibold))
                                if let d = p.detail {
                                    Text(d).font(.caption2).foregroundStyle(.secondary).lineLimit(2).frame(maxWidth: 220, alignment: .leading)
                                }
                            }
                            .padding(10)
                            .frame(width: 240, alignment: .leading)
                            .background(selected ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.04),
                                        in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10)
                                .stroke(selected ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // JOB-JOURNEY — the matter card is the journey's front door. No matter
    // open → a prominent "Start here" card (this IS phase 1, Intake). Matter
    // open → the matter header with whole-journey progress.
    @ViewBuilder
    private func matterBar(_ model: PersonaJobsModel) -> some View {
        @Bindable var model = model
        if let title = model.activeMatterTitle, model.activeCaseID != nil {
            let summary = model.progressSummary
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "folder.fill.badge.person.crop").foregroundStyle(Theme.brand)
                    Text(title).font(.headline)
                    Spacer()
                    Text("\(summary.resolved) of \(summary.total) jobs resolved")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        .help("Resolved = completed, or marked not applicable with a reason. A blocked, empty or unreviewed result is not resolved.")
                        .accessibilityIdentifier("jobs.progress.resolved")
                }
                ProgressView(value: summary.fraction).tint(Theme.brand)
                Text(summary.text).font(.caption2).foregroundStyle(.secondary).accessibilityIdentifier("jobs.progress.summary")
                recommendationList(model)
                scopeStrip(model)
            }
            .padding(14)
            .background(Theme.brand.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.brand.opacity(0.25), lineWidth: 1))
            .sheet(item: $model.inclusionReview) { preview in
                ScopeReviewSheet(preview: preview,
                                 onApprove: { chosen in Task { await model.approveInclusion(chosen, actor: "me", at: Date()) } },
                                 onCancel: { model.inclusionReview = nil })
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    stepBadge(1, done: false, active: true)
                    Text("Start here — open a matter").font(.headline)
                }
                Text("A matter is the container all jobs run against (a case, story, research question, or personal topic). Name it, pick the workspace holding its documents, and start.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // JOB-RESUME — matters are durable; come back to them any time.
                if !model.openMatters.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Resume where you left off")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(model.openMatters.prefix(5)) { matter in
                            HStack(spacing: 8) {
                                Image(systemName: "folder.badge.person.crop")
                                    .foregroundStyle(Theme.brand)
                                    .imageScale(.small)
                                Text(matter.title).font(.callout)
                                Text(matter.createdAt.formatted(date: .abbreviated, time: .omitted))
                                    .font(.caption2).foregroundStyle(.secondary)
                                Spacer()
                                Button("Open") { model.openMatter(matter) }
                                    .controlSize(.small)
                                    .buttonStyle(.bordered)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                    Text("Or start a new one:")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    TextField("Matter title", text: $model.matterTitle).textFieldStyle(.roundedBorder).frame(maxWidth: 280)
                    if !model.workspaceList.isEmpty {
                        Picker("Workspace", selection: $model.selectedWorkspace) {
                            ForEach(model.workspaceList, id: \.id) { ws in Text(ws.title).tag(Optional(ws.id)) }
                        }.frame(maxWidth: 220)
                    }
                    Button {
                        Task { await model.startMatter(actor: "me", at: Date()) }
                    } label: { Label("Start matter", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.brand)
                    .disabled(model.busy || model.intakeJob == nil
                              || model.matterTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .guidance(GuidanceTip("Start matter",
                                          what: "Opens a new case for this persona and runs its intake job — the container every later job works against. It's created in the chosen workspace.",
                                          enabledWhen: "Type a matter title first (a workspace is created automatically if you have none)."),
                              enabled: !(model.busy || model.intakeJob == nil
                                         || model.matterTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                }
                if model.workspaceList.isEmpty {
                    Text("No workspace yet — starting your first matter creates one named \u{201C}General\u{201D} automatically.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .background(Theme.brand.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.brand.opacity(0.35), lineWidth: 1))
        }
    }

    // I2 — what to do next, from the case's own state (CaseNextSteps) and the jobs' blockers and
    // reviews. Each line names the fact behind it and opens the record it is about.
    @ViewBuilder
    private func recommendationList(_ model: PersonaJobsModel) -> some View {
        let recs = model.recommendations
        if recs.isEmpty {
            Text("Nothing is waiting: no case step is open and no job is blocked or awaiting review. Run the jobs the matter needs; mark the rest not applicable with a reason.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("Next").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(recs.prefix(5)) { rec in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: icon(for: rec.kind)).foregroundStyle(rec.kind == .blockedJob ? Color.orange : Theme.brand).imageScale(.small)
                        Text(rec.text).font(.caption).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        if let jobID = rec.jobID, let job = model.jobs.first(where: { $0.id == jobID }) {
                            if model.results[jobID] != nil {
                                Button("Open") { resultJob = job }.controlSize(.mini)
                            } else {
                                Button("Run") { Task { await model.run(job, actor: "me", at: Date()) } }.controlSize(.mini).disabled(model.busy)
                            }
                        } else if case .caseStep(let place) = rec.kind {
                            Text(place.rawValue.capitalized).font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
                if recs.count > 5 { Text("and \(recs.count - 5) more").font(.caption2).foregroundStyle(.tertiary) }
            }
            .accessibilityIdentifier("jobs.recommendations")
        }
    }

    private func icon(for kind: JobRecommendation.Kind) -> String {
        switch kind {
        case .caseStep: return "arrow.right.circle"
        case .blockedJob: return "exclamationmark.octagon"
        case .reviewJob: return "eye"
        case .earlierScope: return "arrow.triangle.2.circlepath"
        case .emptyResult: return "tray"
        }
    }

    // I1 — the documents in the case: what is in scope, what is excluded, what is new in the
    // workspace and not yet in the case. The only way in is the explicit review and approval.
    @ViewBuilder
    private func scopeStrip(_ model: PersonaJobsModel) -> some View {
        if model.canReviewScope {
            HStack(spacing: 10) {
                Image(systemName: "doc.on.doc").foregroundStyle(.secondary).imageScale(.small)
                if let p = model.scopePreview {
                    Text("Documents: \(p.inScope) in scope" + (p.excluded.isEmpty ? "" : " · \(p.excluded.count) excluded")
                         + (p.pending.isEmpty ? " · nothing new in the workspace" : " · \(p.pending.count) new in the workspace, not in the case"))
                        .font(.caption)
                        .foregroundStyle(p.pending.isEmpty ? .secondary : .primary)
                        .accessibilityIdentifier("jobs.scope.summary")
                } else {
                    Text("Documents: reading the case's scope…").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                let pending = model.scopePreview?.pending.count ?? 0
                let reviewLabel = Label(pending > 0 ? "Review new documents (\(pending))" : "Review new documents",
                                        systemImage: "plus.rectangle.on.folder")
                Group {
                    if pending > 0 {
                        Button { Task { await model.reviewNewDocuments() } } label: { reviewLabel }.buttonStyle(.borderedProminent)
                    } else {
                        Button { Task { await model.reviewNewDocuments() } } label: { reviewLabel }.buttonStyle(.bordered)
                    }
                }
                .controlSize(.small)
                .tint(Theme.brand)
                .disabled(model.busy)
                .help("See the documents added to this matter's workspace that are not yet in the case, and approve which to include. Reopening the matter never adds them on its own.")
                .accessibilityIdentifier("jobs.scope.review")
            }
            .padding(.top, 4)
        }
    }

    // JOB-LOG (maxmailin pattern) — what was done against this matter, when,
    // and what it found: the results live on the same page as the work.
    @ViewBuilder
    private func workLogSection(_ model: PersonaJobsModel) -> some View {
        if model.activeCaseID != nil, !model.workLog.isEmpty {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.workLog.suffix(12).reversed()) { entry in
                        HStack(alignment: .top, spacing: 8) {
                            Text(entry.at.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2).foregroundStyle(.secondary)
                                .monospacedDigit()
                                .frame(width: 118, alignment: .leading)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.jobTitle).font(.caption.weight(.semibold))
                                Text(entry.summary).font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                .padding(.top, 6)
            } label: {
                Label("Work log — \(model.workLog.count) action(s) on this matter",
                      systemImage: "list.bullet.clipboard")
                    .font(.callout.weight(.medium))
            }
            .padding(12)
            .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08), lineWidth: 1))
        }
    }

    private func stepBadge(_ n: Int, done: Bool, active: Bool) -> some View {
        ZStack {
            Circle()
                .fill(done ? Color.green : (active ? Theme.brand : Color.primary.opacity(0.15)))
                .frame(width: 22, height: 22)
            if done {
                Image(systemName: "checkmark").scaledFont(11, weight: .bold, relativeTo: .caption).foregroundStyle(.white)
            } else {
                Text("\(n)").font(.caption.weight(.bold)).foregroundStyle(active ? .white : .secondary)
            }
        }
    }

    // JOB-JOURNEY — the persona's work as ordered PHASES (Intake → Collect →
    // Analyze → Act → Deliver) instead of one flat grid. The first phase with
    // unrun jobs is highlighted as the next step; each phase shows its own
    // progress; run jobs get a checkmark.
    private enum JobPhase: Int, CaseIterable, Identifiable {
        case intake, collect, analyze, act, deliver
        var id: Int { rawValue }
        var label: String {
            switch self {
            case .intake:  return "Intake & scope"
            case .collect: return "Collect & organize"
            case .analyze: return "Analyze"
            case .act:     return "Act & verify"
            case .deliver: return "Deliver & close"
            }
        }
        var icon: String {
            switch self {
            case .intake:  return "tray.and.arrow.down.fill"
            case .collect: return "shippingbox.fill"
            case .analyze: return "brain.head.profile"
            case .act:     return "checkmark.seal.fill"
            case .deliver: return "paperplane.fill"
            }
        }
        static func phase(of kind: PersonaJobKind) -> JobPhase {
            switch kind {
            case .caseIntake:
                return .intake
            case .dataLab, .evidenceCustody, .sourceReliability, .identityResolution:
                return .collect
            case .ask, .analysis, .methods, .causalAnalysis, .linkage, .contradictionGap, .subjectDossier:
                return .analyze
            case .capaRegister, .effectivenessReview:
                return .act
            case .findings, .closure:
                return .deliver
            }
        }
    }

    /// The analytic canvases to offer in the Analyze phase — derived from the
    /// Sūtra tooling catalog (analyze-tier jobs that name a real surface).
    private var analyticLaunchers: [(dest: Destination, help: String)] {
        JobToolingCatalog.analyticKinds.compactMap { kind in
            guard let p = JobToolingCatalog.profile(for: kind),
                  let s = p.surface, let d = Destination(rawValue: s) else { return nil }
            return (d, p.rationale)
        }
    }

    /// The analytic canvas a job earns, per the Sūtra tooling catalog — only
    /// analyze-tier jobs that name a real surface. nil = a Work Center form/service
    /// is the right depth. Honours the classic-surfaces switch (hidden when on).
    private func analyticCanvas(_ kind: PersonaJobKind) -> Destination? {
        guard !preferClassicSurfaces,
              let p = JobToolingCatalog.profile(for: kind), p.tier == .analyze,
              let s = p.surface, let d = Destination(rawValue: s) else { return nil }
        return d
    }

    private func jobGrid(_ model: PersonaJobsModel) -> some View {
        let phased: [(JobPhase, [PersonaJob])] = JobPhase.allCases.compactMap { phase in
            let inPhase = model.runnableJobs.filter { JobPhase.phase(of: $0.kind) == phase }
            return inPhase.isEmpty ? nil : (phase, inPhase)
        }
        // The journey pointer: the first phase with unresolved work (completed or not-applicable
        // resolve a job; a launch, a blocked or an unreviewed result does not).
        let nextPhase = phased.first { !$0.1.allSatisfy { model.progress(of: $0).state.isResolved } }?.0
        return VStack(alignment: .leading, spacing: 18) {
            ForEach(Array(phased.enumerated()), id: \.element.0.id) { index, entry in
                let (phase, phaseJobs) = entry
                let done = phaseJobs.filter { model.progress(of: $0).state.isResolved }.count
                let isNext = phase == nextPhase && model.activeCaseID != nil
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        stepBadge(index + 2, done: done == phaseJobs.count && model.activeCaseID != nil, active: isNext)
                        Image(systemName: phase.icon).foregroundStyle(Theme.brand).imageScale(.small)
                        Text(phase.label).font(.headline)
                        if isNext {
                            Text("Next up")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Theme.brand.opacity(0.15), in: Capsule())
                                .foregroundStyle(Theme.brand)
                        }
                        Spacer()
                        if phase == .analyze {
                            // The new/classic SWITCH, in the place it acts (also in
                            // Settings ▸ Answering & modes ▸ "Prefer classic surfaces").
                            Toggle(isOn: $preferClassicSurfaces) {
                                Text("Classic").font(.caption2)
                            }
                            .toggleStyle(.switch).controlSize(.mini)
                            .help("Switch between the classic fixed launchers and the newer catalog-driven ones. Also in Settings ▸ Answering & modes.")
                            if preferClassicSurfaces {
                                // CLASSIC — the previous fixed Analyze launchers (Settings switch).
                                Button { SurfaceOpener.open(.hypotheses) } label: {
                                    Label("Hypotheses (ACH)", systemImage: "tablecells").font(.caption)
                                }
                                .buttonStyle(.bordered).controlSize(.small)
                                .help("Open the Analysis of Competing Hypotheses matrix — rate evidence against rival explanations and rank by fewest inconsistencies.")
                                Button { SurfaceOpener.open(.reasoning) } label: {
                                    Label("Reasoning Studio", systemImage: "brain.head.profile").font(.caption)
                                }
                                .buttonStyle(.bordered).controlSize(.small)
                                .help("Open the Reasoning Studio — brainstorm, 5 Whys and a fishbone diagram to a root-cause conclusion and an approval-ready report.")
                            } else {
                                // NEW — the analytic canvases DERIVED from the Sūtra tooling catalog
                                // (JobToolingCatalog), not hard-coded — the constitution drives the UI.
                                ForEach(analyticLaunchers, id: \.dest) { item in
                                    Button { SurfaceOpener.open(item.dest) } label: {
                                        Label(item.dest.title, systemImage: item.dest.icon).font(.caption)
                                    }
                                    .buttonStyle(.bordered).controlSize(.small)
                                    .help(item.help)
                                }
                            }
                        }
                        Text("\(done)/\(phaseJobs.count) resolved")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    jobCards(model, jobs: phaseJobs)
                }
                .padding(12)
                .background(isNext ? Theme.brand.opacity(0.05) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .stroke(isNext ? Theme.brand.opacity(0.35) : Color.primary.opacity(0.06), lineWidth: 1))
            }
        }
    }

    private func jobCards(_ model: PersonaJobsModel, jobs: [PersonaJob]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], alignment: .leading, spacing: 12) {
                ForEach(jobs) { job in
                    let progress = model.progress(of: job)
                    let ran = progress.state.isResolved
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .top, spacing: 4) {
                            if case .completed = progress.state {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).imageScale(.small)
                                    .help("Completed and reviewed for this matter — run again any time.")
                            } else if case .notApplicable = progress.state {
                                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary).imageScale(.small)
                                    .help("Marked not applicable to this matter, with the reason recorded.")
                            } else if case .blocked = progress.state {
                                Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.orange).imageScale(.small)
                                    .help("Blocked — the case gave this job nothing to work from; see what is missing.")
                            }
                            Text(job.title).font(.callout.weight(.semibold))
                            Spacer(minLength: 0)
                            // JOB-DOC — SAP-style documentation for this job.
                            if JobDocumentationCatalog.doc(
                                personaLabel: model.personas.first { $0.id == model.selectedPersona }?.label ?? "",
                                jobTitle: job.title) != nil {
                                Button { docJob = job } label: { Label("More information", systemImage: "info.circle").labelStyle(.iconOnly) }
                                .buttonStyle(.borderless)
                                .help("What this job does, needs, produces, and must not conclude")
                            }
                        }
                        Text(job.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        // A1/I2 — the job's real state of work (not a launch count).
                        if let status = model.status(of: job) {
                            Text(status).font(.caption2.weight(.medium))
                                .foregroundStyle({ () -> Color in
                                    switch progress.state {
                                    case .completed: return .green
                                    case .blocked: return .orange
                                    default: return progress.fromEarlierScope ? .orange : .secondary
                                    }
                                }())
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if job.kind == .ask, model.activeCaseID != nil {
                            TextField("Question for this case", text: Binding(get: { model.questions[job.id] ?? "" },
                                                                              set: { model.questions[job.id] = $0 }))
                                .textFieldStyle(.roundedBorder).font(.caption)
                        }
                        Spacer(minLength: 0)
                        HStack(spacing: 8) {
                            if model.activeCaseID != nil {
                                Button("Run") { Task { await model.run(job, actor: "me", at: Date()) } }
                                    .controlSize(.small)
                                    .disabled(model.busy)
                                    .help("Run this job against the open matter now; its result is saved for review.")
                                if model.results[job.id] != nil {
                                    Button("Open result") { resultJob = job }
                                        .controlSize(.small)
                                        .help("See every row with its sources, decide and note each, correct, complete or export.")
                                }
                                // I2 — the explicit "does not apply" decision, with its reason, reversible.
                                if case .notApplicable = progress.state {
                                    Button("Applicable again") { Task { await model.markApplicable(job, actor: "me", at: Date()) } }
                                        .controlSize(.small)
                                } else if !ran {
                                    Button("Not applicable…") { naJob = job; naReason = "" }
                                        .controlSize(.small)
                                        .help("Record that this job does not apply to this matter, with the reason. It then stops holding the phase open.")
                                }
                            }
                            // ONE action per job (owner decision 2026-08-20): open the
                            // guided Work Center workflow — gated steps, typed fields,
                            // and a numbered document per confirmed step. Replaces the
                            // separate instant-Run and Guide buttons.
                            Button {
                                if let def = WCCatalog.jobWorkflow(forJob: job) {
                                    appState.pendingWorkCenterDefID = def.defID
                                }
                            } label: {
                                Label("Run workflow", systemImage: "list.bullet.clipboard")
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.brand)
                            .controlSize(.small)
                            .help("Open this job as a step-by-step guided workflow — gated steps, typed fields, and a numbered document for every step you confirm.")
                            // Analyze-tier jobs earn a direct canvas launch — decided by the
                            // Sūtra tooling catalog, not hard-coded (Step 2).
                            if let canvas = analyticCanvas(job.kind) {
                                Button { SurfaceOpener.open(canvas) } label: {
                                    Label(canvas.title, systemImage: canvas.icon).font(.caption)
                                }
                                .buttonStyle(.bordered).controlSize(.small)
                                .help("This is an analysis job — open its canvas directly (\(canvas.title)). Derived from the tooling map.")
                            }
                        }
                    }
                    .padding(12)
                    .frame(minHeight: 150, alignment: .topLeading)
                    .background(ran ? Color.green.opacity(0.05) : Color.primary.opacity(0.03),
                                in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .stroke(ran ? Color.green.opacity(0.25) : Color.primary.opacity(0.08), lineWidth: 1))
                }
            }
        }
    }
}

// MARK: - JOB-DOC — SAP-style job documentation sheet

private struct JobDocumentationDetail: View {
    let job: PersonaJob
    let personaLabel: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let doc = JobDocumentationCatalog.doc(personaLabel: personaLabel, jobTitle: job.title)
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.title).font(.title3.weight(.semibold))
                    if let doc { Text("\(doc.persona) · \(doc.jobID)").font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let doc {
                        section("Purpose", systemImage: "target") {
                            Text(job.detail).font(.callout)
                        }
                        section("Workflow", systemImage: "list.number") {
                            Text(doc.workflow).font(.callout)
                        }
                        bulletSection("Required inputs", systemImage: "tray.and.arrow.down", items: doc.requiredInputs)
                        bulletSection("Methods", systemImage: "flask", items: doc.methods)
                        bulletSection("Work products", systemImage: "doc.richtext", items: doc.workProducts)
                        bulletSection("Human decisions", systemImage: "person.crop.circle.badge.checkmark", items: doc.humanDecisions)
                        // The SAP-style guardrail: what this job must NOT assert.
                        bulletSection("Must NOT conclude", systemImage: "hand.raised", items: doc.prohibitedConclusions, tint: .red)
                    } else {
                        Text(job.detail).font(.callout)
                        Text("No structured documentation is recorded for this job yet.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
        }
        .frame(minWidth: 460, minHeight: 420)
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, systemImage: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage).font(.subheadline.weight(.semibold))
            content().foregroundStyle(.primary)
        }
    }

    @ViewBuilder
    private func bulletSection(_ title: String, systemImage: String, items: [String], tint: Color = .primary) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label(title, systemImage: systemImage).font(.subheadline.weight(.semibold)).foregroundStyle(tint)
                ForEach(items, id: \.self) { item in
                    HStack(alignment: .top, spacing: 6) {
                        Text("•").foregroundStyle(tint.opacity(0.7))
                        Text(item).font(.callout)
                    }
                }
            }
        }
    }
}

// MARK: - I1: review and approve the documents coming into the case

/// What approving would add to the case, shown before anything is authorised: each new document
/// (and what it was found inside), ticked by default; what stays excluded; one confirm button that
/// names the count. Cancel includes nothing.
struct ScopeReviewSheet: View {
    let preview: CaseInclusionPreview
    let onApprove: (Set<UUID>) -> Void
    let onCancel: () -> Void
    @State private var chosen: Set<UUID>

    init(preview: CaseInclusionPreview, onApprove: @escaping (Set<UUID>) -> Void, onCancel: @escaping () -> Void) {
        self.preview = preview; self.onApprove = onApprove; self.onCancel = onCancel
        _chosen = State(initialValue: Set(preview.pending.map(\.id)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add documents to this case").font(.title3.weight(.semibold))
            Text("The case answers only from documents in its scope. Below is what its workspace holds that the case has not decided on. Nothing is added until you confirm; what you leave unticked stays out, and excluded documents stay excluded.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                Label("\(preview.inScope) in scope now", systemImage: "checkmark.circle").font(.caption)
                if !preview.excluded.isEmpty { Label("\(preview.excluded.count) excluded (stay excluded)", systemImage: "minus.circle").font(.caption) }
                Label("\(preview.pending.count) new", systemImage: "plus.circle").font(.caption)
            }
            .foregroundStyle(.secondary)
            if preview.pending.isEmpty {
                ContentUnavailableView("Nothing new to add", systemImage: "doc.on.doc",
                                       description: Text("Every document in the workspace is already decided for this case. Add documents to the workspace (Projects → Add sources…) and review again."))
                    .frame(minHeight: 160)
            } else {
                List {
                    Section("New documents — tick what to include") {
                        ForEach(preview.pending) { item in
                            Toggle(isOn: Binding(get: { chosen.contains(item.id) },
                                                 set: { on in if on { chosen.insert(item.id) } else { chosen.remove(item.id) } })) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.label).font(.callout)
                                    Text(item.isRoot ? "In the workspace" : "Inside \(item.parentLabel ?? "a workspace document") (attachment, archive member or message)")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                    if !preview.excluded.isEmpty {
                        Section("Excluded — stay excluded") {
                            ForEach(preview.excluded) { item in
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.label).font(.callout).foregroundStyle(.secondary)
                                    if let n = item.note { Text(n).font(.caption2).foregroundStyle(.tertiary) }
                                }
                            }
                        }
                    }
                }
                .frame(minHeight: 220, maxHeight: 360)
                HStack {
                    Button("Tick all") { chosen = Set(preview.pending.map(\.id)) }.controlSize(.small)
                    Button("Untick all") { chosen = [] }.controlSize(.small)
                    Spacer()
                }
            }
            Text("After adding, results and approvals saved earlier were produced over the earlier scope; run the jobs again to cover the new documents. Each inclusion is recorded in the case's log.")
                .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Cancel", role: .cancel) { onCancel() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(chosen.count == 1 ? "Add 1 document to this case" : "Add \(chosen.count) documents to this case") { onApprove(chosen) }
                    .buttonStyle(.borderedProminent).tint(Theme.brand)
                    .disabled(chosen.isEmpty)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("jobs.scope.approve")
            }
        }
        .padding(20)
        .frame(minWidth: 560, idealWidth: 640)
    }
}

#if DEBUG
#Preview("Professional Jobs") {
    PersonaJobsView()
        .environment(AppState())
        .frame(width: 1040, height: 720)
}
#endif
