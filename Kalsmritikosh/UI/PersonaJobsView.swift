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
        } catch { lastError = "\(job.title): \(error)"; lastOutcome = nil }
    }
}

// MARK: - View

public struct PersonaJobsView: View {
    @Environment(AppState.self) private var appState
    @State private var model: PersonaJobsModel?

    public init() {}

    public var body: some View {
        Group {
            if let model {
                content(model)
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

    @ViewBuilder
    private func matterBar(_ model: PersonaJobsModel) -> some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 8) {
            if let title = model.activeMatterTitle, model.activeCaseID != nil {
                Label("Open matter: \(title)", systemImage: "folder.fill.badge.person.crop").font(.callout.weight(.medium))
            } else {
                Text("Start a matter to run this persona's jobs").font(.subheadline).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    TextField("Matter title", text: $model.matterTitle).textFieldStyle(.roundedBorder).frame(maxWidth: 280)
                    Picker("Workspace", selection: $model.selectedWorkspace) {
                        ForEach(model.workspaceList, id: \.id) { ws in Text(ws.title).tag(Optional(ws.id)) }
                    }.frame(maxWidth: 220)
                    Button {
                        Task { await model.startMatter(actor: "me", at: Date()) }
                    } label: { Label("Start matter", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.busy || model.intakeJob == nil || model.selectedWorkspace == nil)
                }
            }
        }
    }

    private func jobGrid(_ model: PersonaJobsModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Jobs").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], alignment: .leading, spacing: 12) {
                ForEach(model.runnableJobs) { job in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(job.title).font(.callout.weight(.semibold))
                        Text(job.detail).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                        Spacer(minLength: 0)
                        Button {
                            Task { await model.run(job, actor: "me", at: Date()) }
                        } label: { Label("Run", systemImage: "arrow.right.circle") }
                        .buttonStyle(.bordered)
                        .disabled(model.busy || model.activeCaseID == nil)
                    }
                    .padding(12)
                    .frame(height: 130, alignment: .topLeading)
                    .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08), lineWidth: 1))
                }
            }
        }
    }
}
