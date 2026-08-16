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
    private func markRan(_ jobID: String) {
        guard let caseID = activeCaseID else { return }
        ranJobs.insert(jobID)
        UserDefaults.standard.set(Array(ranJobs).sorted(), forKey: ranKey(caseID))
    }

    public init(service: PersonaJobService, catalog: PersonaJobCatalog, workspaces: WorkspaceRepository) {
        self.service = service; self.catalog = catalog; self.workspaces = workspaces
    }

    /// The persona-neutral intake job (the one job that opens a matter) for the selected persona.
    public var intakeJob: PersonaJob? { jobs.first { $0.kind == .caseIntake } }
    /// Every non-intake job — runnable only once a matter is open.
    public var runnableJobs: [PersonaJob] { jobs.filter { $0.kind != .caseIntake } }

    public func load() async {
        personas = await service.personas()
        if selectedPersona == nil { selectedPersona = personas.first?.id }
        workspaceList = (try? await workspaces.all(includeArchived: false)) ?? []
        if selectedWorkspace == nil { selectedWorkspace = workspaceList.first?.id }
        await reloadJobs()
    }

    public func select(persona id: ApplicationDefinitionID) async {
        selectedPersona = id
        activeCaseID = nil; activeMatterTitle = nil; lastOutcome = nil; lastError = nil
        ranJobs = []
        await reloadJobs()
    }

    private func reloadJobs() async {
        guard let id = selectedPersona else { jobs = []; return }
        jobs = await service.jobs(forPersona: id)
    }

    /// Open a matter by launching the selected persona's intake job in the chosen workspace.
    public func startMatter(actor: String, at date: Date) async {
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
            lastOutcome = out.summary; lastError = nil
            loadRanJobs()
            if let intakeID = intakeJob?.id { markRan(intakeID) }   // intake IS phase 1, done
        } catch { lastError = "\(error)"; lastOutcome = nil }
    }

    /// Run a job against the open matter, reaching the real shared service.
    public func run(_ job: PersonaJob, actor: String, at date: Date) async {
        guard let caseID = activeCaseID, let wsID = selectedWorkspace else {
            lastError = "Open a matter first."; return
        }
        let access = SensitiveAccessContext(scope: SensitiveScope(
            workspaceID: wsID, maximumSensitivity: .restricted, permitsPrivilegedMaterial: false, purpose: .export))
        busy = true; defer { busy = false }
        do {
            let out = try await service.launch(job, context: PersonaJobLaunchContext(
                caseID: caseID, access: access, actor: actor, at: date))
            lastOutcome = "\(job.title): \(out.summary)"; lastError = nil
            markRan(job.id)
        } catch { lastError = "\(job.title): \(error)"; lastOutcome = nil }
    }
}

// MARK: - View

public struct PersonaJobsView: View {
    @Environment(AppState.self) private var appState
    @State private var model: PersonaJobsModel?
    @State private var docJob: PersonaJob?          // JOB-DOC: job whose documentation sheet is open
    @State private var runnerJob: PersonaJob?       // JOB-RUN: job whose guided walkthrough is open

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
                                onClose: { runnerJob = nil })
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
        let m = PersonaJobsModel(service: service, catalog: catalog, workspaces: ws)
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
                jobGrid(model)
            }
            .padding(20)
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
            let total = model.jobs.count
            let done = model.ranJobs.intersection(Set(model.jobs.map(\.id))).count
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "folder.fill.badge.person.crop").foregroundStyle(Theme.brand)
                    Text(title).font(.headline)
                    Spacer()
                    Text("\(done) of \(total) jobs run")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                    .tint(Theme.brand)
                Text("Work down the phases below — the highlighted phase is your next step. Every job stays evidence-cited.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(14)
            .background(Theme.brand.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.brand.opacity(0.25), lineWidth: 1))
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    stepBadge(1, done: false, active: true)
                    Text("Start here — open a matter").font(.headline)
                }
                Text("A matter is the container all jobs run against (a case, story, research question, or personal topic). Name it, pick the workspace holding its documents, and start.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    TextField("Matter title", text: $model.matterTitle).textFieldStyle(.roundedBorder).frame(maxWidth: 280)
                    Picker("Workspace", selection: $model.selectedWorkspace) {
                        ForEach(model.workspaceList, id: \.id) { ws in Text(ws.title).tag(Optional(ws.id)) }
                    }.frame(maxWidth: 220)
                    Button {
                        Task { await model.startMatter(actor: "me", at: Date()) }
                    } label: { Label("Start matter", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.brand)
                    .disabled(model.busy || model.intakeJob == nil || model.selectedWorkspace == nil)
                }
            }
            .padding(14)
            .background(Theme.brand.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.brand.opacity(0.35), lineWidth: 1))
        }
    }

    private func stepBadge(_ n: Int, done: Bool, active: Bool) -> some View {
        ZStack {
            Circle()
                .fill(done ? Color.green : (active ? Theme.brand : Color.primary.opacity(0.15)))
                .frame(width: 22, height: 22)
            if done {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
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

    private func jobGrid(_ model: PersonaJobsModel) -> some View {
        let phased: [(JobPhase, [PersonaJob])] = JobPhase.allCases.compactMap { phase in
            let inPhase = model.runnableJobs.filter { JobPhase.phase(of: $0.kind) == phase }
            return inPhase.isEmpty ? nil : (phase, inPhase)
        }
        // The journey pointer: the first phase that still has unrun jobs.
        let nextPhase = phased.first { !$0.1.allSatisfy { model.ranJobs.contains($0.id) } }?.0
        return VStack(alignment: .leading, spacing: 18) {
            ForEach(Array(phased.enumerated()), id: \.element.0.id) { index, entry in
                let (phase, phaseJobs) = entry
                let done = phaseJobs.filter { model.ranJobs.contains($0.id) }.count
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
                        Text("\(done)/\(phaseJobs.count)")
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
                    let ran = model.ranJobs.contains(job.id)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .top, spacing: 4) {
                            if ran {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .imageScale(.small)
                                    .help("Already run against this matter — run again any time.")
                            }
                            Text(job.title).font(.callout.weight(.semibold))
                            Spacer(minLength: 0)
                            // JOB-DOC — SAP-style documentation for this job.
                            if JobDocumentationCatalog.doc(
                                personaLabel: model.personas.first { $0.id == model.selectedPersona }?.label ?? "",
                                jobTitle: job.title) != nil {
                                Button { docJob = job } label: {
                                    Image(systemName: "info.circle")
                                }
                                .buttonStyle(.borderless)
                                .help("What this job does, needs, produces, and must not conclude")
                            }
                        }
                        Text(job.detail).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                        Spacer(minLength: 0)
                        HStack(spacing: 8) {
                            Button {
                                Task { await model.run(job, actor: "me", at: Date()) }
                            } label: { Label("Run", systemImage: "arrow.right.circle") }
                            .buttonStyle(.bordered)
                            .disabled(model.busy || model.activeCaseID == nil)
                            // JOB-RUN — the guided step-by-step walkthrough of this
                            // job's documented workflow (Previous/Next/Save/progress).
                            if let doc = JobDocumentationCatalog.doc(
                                personaLabel: model.personas.first { $0.id == model.selectedPersona }?.label ?? "",
                                jobTitle: job.title) {
                                Button { runnerJob = job } label: {
                                    Label("Guide", systemImage: "signpost.right")
                                }
                                .buttonStyle(.borderless)
                                .help("Walk this job step by step — your place is saved.")
                                if let saved = JobRunnerProgress.savedStep(jobID: doc.jobID) {
                                    Text("step \(saved + 1)/\(JobRunnerView.steps(of: doc).count)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                        .help("Guided walkthrough in progress — reopen Guide to resume.")
                                }
                            }
                        }
                    }
                    .padding(12)
                    .frame(height: 130, alignment: .topLeading)
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
