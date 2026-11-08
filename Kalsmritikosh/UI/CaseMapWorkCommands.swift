//
//  CaseMapWorkCommands.swift
//  Kalsmritikosh
//
//  Smart-map M1 — the inspector's (and the list's) commands for recursive work, over the EXISTING services only:
//  "Open as frame" for any record; a document recorded as a supplied report; "Add point" from a passage of the
//  report's source; qualifications; "Ask a question about this point" (a case allegation); "Create action" (a case
//  task with its contract); "Record result" (a result report with its own points); submit, review (self-review is
//  labelled) and outcome. Every write goes through CaseFileService / CaseFileRepository, inside the case's guards
//  (closed case, case scope, paid action). Nothing here calls a model or sends anything.
//

import SwiftUI
import os

/// The sheets the commands open.
enum CaseMapWorkSheet: Identifiable {
    case report(version: UUID, name: String, amends: UUID?)
    case point(report: UUID)
    case qualification(point: UUID)
    case question(point: UUID)
    case action(parent: UUID?, point: UUID?, question: UUID?)
    case result(task: UUID)
    case outcome(task: UUID)
    /// S4 (REPORT-02/04/09): a section, an evidence request from a point, a supplied item.
    case section(report: UUID)
    case request(point: UUID)
    case artifact(report: UUID)
    var id: String {
        switch self {
        case .report(let v, _, let a): return "report-\(v)-\(a?.uuidString ?? "")"
        case .point(let r): return "point-\(r)"
        case .qualification(let p): return "qual-\(p)"
        case .question(let p): return "question-\(p)"
        case .action(let a, let p, let q): return "action-\(a?.uuidString ?? "")-\(p?.uuidString ?? "")-\(q?.uuidString ?? "")"
        case .result(let t): return "result-\(t)"
        case .outcome(let t): return "outcome-\(t)"
        case .section(let r): return "section-\(r)"
        case .request(let p): return "request-\(p)"
        case .artifact(let r): return "artifact-\(r)"
        }
    }
}

struct CaseMapWorkCommands: View {
    @Environment(AppState.self) private var appState
    let model: CaseFileModel
    let node: CaseMapNode
    let projection: CaseMapProjection
    let closed: Bool
    let openFrame: (CaseMapNodeID) -> Void
    @State private var sheet: CaseMapWorkSheet?

    private var recordID: UUID? { UUID(uuidString: node.id.recordID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button("Open as frame") { openFrame(node.id) }
                .keyboardShortcut(.return, modifiers: [.command, .control])
                .help("Focus on this item: its sources, points, questions, work and results become the map (⌃⌘↩). The breadcrumb takes you back exactly.")
                .accessibilityHint("Opens this item as a frame of the map. The breadcrumb returns to where you were.")
            switch node.id.kind {
            case .document:
                if let v = node.sources.first?.sourceVersionID {
                    Button("Record as a supplied report…") { sheet = .report(version: v, name: node.title, amends: nil) }
                        .help("Records this document as a report of the case — who produced it, what was examined, its date, methods and limitations — so its points can be investigated one by one.")
                }
            case .report:
                if let r = recordID {
                    Button("Add point…") { sheet = .point(report: r) }
                        .help("Records one point of the report — its kind, your statement of it and the exact words from the source, verified in the report's document.")
                    if let v = node.sources.first?.sourceVersionID {
                        Button("Record an amendment or supplement…") { sheet = .report(version: v, name: node.title, amends: r) }
                            .help("Records a later version of this report as a new report. The first report is kept as it was.")
                    }
                    // S4 (REPORT-02 / REPORT-06 / REPORT-08 / REPORT-09).
                    Button("Add section…") { sheet = .section(report: r) }
                        .help("Records a heading of the report (as the report numbers it), so its points can be placed where the report put them.")
                    Button("Suggest points (rule-based, AI off)") {
                        run { svc, caseID, actor in _ = try await svc.suggestPoints(caseID: caseID, reportID: r, actor: actor) }
                    }
                    .help("Reads the report's own passages by fixed rules and lists candidate sentences as suggestions. Nothing becomes a point until you accept it; reading again never changes an accepted point.")
                    CaseMapSuggestionsList(model: model, reportID: r)
                    Button("Add supplied table, figure or media…") { sheet = .artifact(report: r) }
                        .help("Keeps a table, figure, media item or dataset the specialist supplied with the report. The app did not perform the acquisition or the analysis.")
                    if let earlier = projection.links(of: node.id).first(where: { $0.from == node.id && ($0.type == .supersedes || $0.type == .derivedFrom) && $0.to.kind == .report })?.to,
                       let e = UUID(uuidString: earlier.recordID) {
                        Button("Compare with the earlier report") {
                            run { svc, caseID, actor in _ = try await svc.compareReports(caseID: caseID, earlier: e, later: r, actor: actor) }
                        }
                        .help("Records what changed between the two versions — wording, qualifications, report details — and flags the work that rests on a changed point for review. No decision is changed.")
                    }
                }
            case .reportPoint:
                if let p = recordID {
                    Button("Ask a question about this point…") { sheet = .question(point: p) }
                        .help("Adds an open question to the case, linked to this point.")
                    Button("Create action…") { sheet = .action(parent: nil, point: p, question: nil) }
                        .help("Creates a task for this point with its purpose, expected result, responsible person and reviewer.")
                    Button("Request evidence about this point…") { sheet = .request(point: p) }
                        .help("Creates an evidence request of the case, linked to this point with its purpose. What is asked for is what the request should deliver.")
                    Button("Add qualification…") { sheet = .qualification(point: p) }
                        .help("Attaches an uncertainty, limitation, exclusion or condition to this point. It travels with the point everywhere.")
                    HStack {
                        Button("Accept point") { review(p, .accepted) }.disabled(node.review == .accepted)
                        Button("Reject point") { review(p, .rejected) }.disabled(node.review == .rejected)
                        if node.review != .unreviewed { Button("Reopen review") { review(p, .unreviewed) } }
                    }
                    .help("Your decision on the point. An accepted point is never changed automatically.")
                }
            case .allegation:
                if let q = recordID {
                    Button("Create action…") { sheet = .action(parent: nil, point: nil, question: q) }
                        .help("Creates a task serving this question, with its purpose and expected result. Completing it does not answer the question.")
                }
            case .task:
                if let t = recordID { taskCommands(t) }
            default:
                EmptyView()
            }
        }
        .controlSize(.small)
        .disabled(closed)
        .sheet(item: $sheet) { s in sheetView(s) }
    }

    @ViewBuilder private func taskCommands(_ t: UUID) -> some View {
        let contract = node.wording?.hasPrefix("Purpose:") == true
        Button("Create child action…") { sheet = .action(parent: t, point: nil, question: nil) }
            .help("Creates an action under this one (no depth limit; an action can't become its own ancestor).")
        if contract {
            Button("Record result…") { sheet = .result(task: t) }
                .help("Records what this action produced as a result report; add its points, and open deeper work from them.")
            Button("Submit result for review") { run { svc, caseID, actor in try await svc.file.submitAction(caseID: caseID, taskID: t, note: nil, actor: actor) } }
            if node.review == .pendingReview {
                HStack {
                    Button("Accept result") { run { svc, caseID, actor in _ = try await svc.file.reviewAction(caseID: caseID, taskID: t, accept: true, note: nil, actor: actor) } }
                    Button("Return for more work") { run { svc, caseID, actor in _ = try await svc.file.reviewAction(caseID: caseID, taskID: t, accept: false, note: nil, actor: actor) } }
                }
                Text("If you did this work yourself, the review is recorded as self-review — no second name is needed.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Button("Record outcome…") { sheet = .outcome(task: t) }
                .help("What the work found — separate from whether the task is done, and it does not decide the question.")
        }
    }

    private func review(_ point: UUID, _ state: CaseReportPointReview) {
        run { svc, caseID, actor in try await svc.file.reviewPoint(caseID: caseID, pointID: point, to: state, actor: actor) }
    }

    private func run(_ body: @escaping @Sendable (CaseFileService, UUID, String) async throws -> Void) {
        let caseID = model.caseID, actor = model.actor
        model.run(appState) { svc in try await body(svc, caseID, actor) }
    }

    @ViewBuilder private func sheetView(_ s: CaseMapWorkSheet) -> some View {
        switch s {
        case .report(let v, let name, let amends):
            CaseMapReportSheet(documentName: name, amends: amends) { d in
                var d = d; d.sourceVersionID = v; d.amendsReportID = amends
                let details = d
                run { svc, caseID, actor in _ = try await svc.file.addReport(caseID: caseID, details, actor: actor) }
            } close: { sheet = nil }
        case .point(let r):
            CaseMapPointSheet(reportTitle: node.title) { kind, statement, quote, locator in
                run { svc, caseID, actor in
                    _ = try await svc.addPoint(caseID: caseID, reportID: r, kind: kind, statement: statement, quote: quote, locatorNote: locator, actor: actor)
                }
            } close: { sheet = nil }
        case .qualification(let p):
            CaseMapQualificationSheet { kind, text, quote in
                run { svc, caseID, actor in _ = try await svc.file.addQualification(caseID: caseID, pointID: p, kind: kind, text: text, quote: quote, actor: actor) }
            } close: { sheet = nil }
        case .question(let p):
            CaseMapTextSheet(title: "Ask a question about this point", hint: "The question (e.g. Was the seal intact when the sample arrived?)",
                             note: "Added to the case's questions, open, and linked to this point. It decides nothing.") { text in
                run { svc, caseID, actor in _ = try await svc.raiseQuestion(caseID: caseID, fromPoint: p, text: text, actor: actor) }
            } close: { sheet = nil }
        case .action(let parent, let point, let question):
            CaseMapActionSheet(questions: projection.nodes.filter { $0.id.kind == .allegation }, preselected: question) { a in
                var a = a; a.parentTaskID = parent; a.fromPoint = point
                let action = a
                run { svc, caseID, actor in _ = try await svc.createAction(caseID: caseID, action, actor: actor) }
            } close: { sheet = nil }
        case .result(let t):
            CaseMapTextSheet(title: "Record result", hint: "Title of the result (e.g. Seal examination — laboratory note)",
                             note: "Recorded as a result report of this action. Add its points next; the action's question stays open until you decide it.") { text in
                run { svc, caseID, actor in _ = try await svc.recordResult(caseID: caseID, taskID: t, title: text, actor: actor) }
            } close: { sheet = nil }
        case .outcome(let t):
            CaseMapOutcomeSheet { outcome, note in
                run { svc, caseID, actor in try await svc.file.recordOutcome(caseID: caseID, taskID: t, outcome: outcome, note: note, actor: actor) }
            } close: { sheet = nil }
        case .section(let r):
            CaseMapTextSheet(title: "Add section", hint: "The heading as the report numbers it (e.g. 3.1 Seal examination)",
                             note: "Kept with the report. A point can be placed in it when it is recorded.") { text in
                run { svc, caseID, actor in _ = try await svc.file.addSection(caseID: caseID, reportID: r, heading: text, actor: actor) }
            } close: { sheet = nil }
        case .request(let p):
            CaseMapTextSheet(title: "Request evidence about this point", hint: "What is asked for (e.g. The balance calibration log for March)",
                             note: "Added to the case's evidence requests, linked to this point. The app sends nothing; record when you send it.") { text in
                let analysis = appState.investigationAnalysis
                run { svc, caseID, actor in
                    guard let analysis else { throw CaseWorkError.notInCase("evidence request service") }
                    _ = try await svc.requestEvidence(caseID: caseID, fromPoint: p, details: EvidenceRequestDetails(description: text),
                                                      purpose: "Evidence about this report point", analysis: analysis, actor: actor)
                }
            } close: { sheet = nil }
        case .artifact(let r):
            CaseMapTextSheet(title: "Add supplied table, figure or media", hint: "Its label as the report gives it (e.g. Table 2 — weights)",
                             note: LegalNotice.suppliedSpecialistResult) { text in
                run { svc, caseID, actor in _ = try await svc.file.addArtifact(caseID: caseID, reportID: r, kind: .other, label: text, actor: actor) }
            } close: { sheet = nil }
        }
    }
}

// MARK: - Sheets

struct CaseMapReportSheet: View {
    let documentName: String
    let amends: UUID?
    let save: (CaseReportDetails) -> Void
    let close: () -> Void
    @State private var d = CaseReportDetails(title: "")
    var body: some View {
        Form {
            Text(amends == nil ? "Record a supplied report" : "Record an amendment or supplement").font(.headline)
            Text("From: \(documentName). Recording a report says nothing about whether what it states is true.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if amends != nil {
                Picker("This is", selection: $d.kind) {
                    Text("An amendment").tag(CaseReportKind.amendment)
                    Text("A supplement").tag(CaseReportKind.supplement)
                }
            }
            TextField("Title", text: $d.title)
            TextField("Producer (laboratory, firm)", text: Binding(get: { d.producer ?? "" }, set: { d.producer = $0 }))
            TextField("Author", text: Binding(get: { d.author ?? "" }, set: { d.author = $0 }))
            TextField("Material examined", text: Binding(get: { d.examinedMaterial ?? "" }, set: { d.examinedMaterial = $0 }))
            TextField("Report date, as written", text: Binding(get: { d.reportDateText ?? "" }, set: { d.reportDateText = $0 }))
            TextField("Methods", text: Binding(get: { d.methods ?? "" }, set: { d.methods = $0 }), axis: .vertical)
            TextField("Limitations stated in the report", text: Binding(get: { d.limitations ?? "" }, set: { d.limitations = $0 }), axis: .vertical)
            HStack {
                Spacer()
                Button("Cancel") { close() }.keyboardShortcut(.cancelAction)
                Button("Record report") { save(d); close() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(reason: d.title.trimmingCharacters(in: .whitespaces).isEmpty ? "Give the report a title." : nil)
            }
        }
        .padding(16).frame(width: 520)
        .onAppear { if amends != nil { d.kind = .amendment } }
    }
}

struct CaseMapPointSheet: View {
    let reportTitle: String
    let save: (CaseReportPointKind, String, String?, String?) -> Void
    let close: () -> Void
    @State private var kind: CaseReportPointKind = .finding
    @State private var statement = ""
    @State private var quote = ""
    @State private var locator = ""
    var body: some View {
        Form {
            Text("Add point").font(.headline)
            Text("From: \(reportTitle). Paste the exact words you selected in the source (Open source shows it); they are checked in the report's own document and pinned to their passage.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("Kind", selection: $kind) { ForEach(CaseReportPointKind.allCases) { Text($0.label).tag($0) } }
            TextField("Your statement of the point", text: $statement, axis: .vertical).lineLimit(2...4)
            TextField("The exact words from the source", text: $quote, axis: .vertical).lineLimit(2...6)
            TextField("Page or section (optional)", text: $locator)
            Text("A point is what the report says — not that it is true. Unverified words are kept and labelled unverified.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { close() }.keyboardShortcut(.cancelAction)
                Button("Add point") { save(kind, statement, quote.isEmpty ? nil : quote, locator.isEmpty ? nil : locator); close() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(reason: statement.trimmingCharacters(in: .whitespaces).isEmpty ? "State the point." : nil)
            }
        }
        .padding(16).frame(width: 520)
    }
}

struct CaseMapQualificationSheet: View {
    let save: (CaseQualificationKind, String, String?) -> Void
    let close: () -> Void
    @State private var kind: CaseQualificationKind = .condition
    @State private var text = ""
    @State private var quote = ""
    var body: some View {
        Form {
            Text("Add qualification").font(.headline)
            Picker("Kind", selection: $kind) { ForEach(CaseQualificationKind.allCases) { Text($0.label).tag($0) } }
            TextField("The qualification (e.g. only if the seal was intact)", text: $text, axis: .vertical).lineLimit(1...4)
            TextField("The report's words for it (optional)", text: $quote, axis: .vertical).lineLimit(1...4)
            Text("It is shown with the point everywhere, so a conditional result never reads as unconditional. It can't be edited later.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { close() }.keyboardShortcut(.cancelAction)
                Button("Add qualification") { save(kind, text, quote.isEmpty ? nil : quote); close() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(reason: text.trimmingCharacters(in: .whitespaces).isEmpty ? "Write the qualification." : nil)
            }
        }
        .padding(16).frame(width: 480)
    }
}

struct CaseMapTextSheet: View {
    let title: String
    let hint: String
    let note: String
    let save: (String) -> Void
    let close: () -> Void
    @State private var text = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            TextField(hint, text: $text, axis: .vertical).lineLimit(1...4)
            Text(note).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { close() }.keyboardShortcut(.cancelAction)
                Button(title) { save(text); close() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(reason: text.trimmingCharacters(in: .whitespaces).isEmpty ? "Write it first." : nil)
            }
        }
        .padding(16).frame(width: 480)
    }
}

struct CaseMapActionSheet: View {
    let questions: [CaseMapNode]
    let preselected: UUID?
    let save: (CaseFileService.ChildAction) -> Void
    let close: () -> Void
    @State private var a = CaseFileService.ChildAction(title: "", purpose: "", deliverable: "")
    @State private var serves: Set<UUID> = []
    var body: some View {
        Form {
            Text("Create action").font(.headline)
            TextField("Action (e.g. Examine the seal photographs)", text: $a.title)
            TextField("Purpose — the question it is to answer", text: $a.purpose, axis: .vertical).lineLimit(1...3)
            TextField("Expected result (e.g. a short note saying whether the seal was intact)", text: $a.deliverable, axis: .vertical).lineLimit(1...3)
            TextField("Responsible (a name; optional)", text: Binding(get: { a.responsible ?? "" }, set: { a.responsible = $0.isEmpty ? nil : $0 }))
            TextField("Reviewer (optional; working alone, leave it empty — your review is labelled self-review)",
                      text: Binding(get: { a.reviewer ?? "" }, set: { a.reviewer = $0.isEmpty ? nil : $0 }))
            if !questions.isEmpty {
                Section("Serves these questions") {
                    ForEach(questions) { q in
                        if let id = UUID(uuidString: q.id.recordID) {
                            Toggle(q.title, isOn: Binding(get: { serves.contains(id) }, set: { if $0 { serves.insert(id) } else { serves.remove(id) } }))
                                .toggleStyle(.checkbox).lineLimit(1)
                        }
                    }
                }
            }
            Text("A task in Tasks, with this contract. Finishing it does not answer the question — record the outcome, then decide the question.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { close() }.keyboardShortcut(.cancelAction)
                Button("Create action") { var x = a; x.servesQuestions = serves.sorted { $0.uuidString < $1.uuidString }; save(x); close() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(reason: a.title.trimmingCharacters(in: .whitespaces).isEmpty ? "Name the action."
                              : a.purpose.trimmingCharacters(in: .whitespaces).isEmpty ? "Say what it is for."
                              : a.deliverable.trimmingCharacters(in: .whitespaces).isEmpty ? "Say what result is expected." : nil)
            }
        }
        .padding(16).frame(width: 560)
        .onAppear { if let preselected { serves.insert(preselected) } }
    }
}

struct CaseMapOutcomeSheet: View {
    let save: (CaseActionOutcome, String?) -> Void
    let close: () -> Void
    @State private var outcome: CaseActionOutcome = .furtherWorkNeeded
    @State private var note = ""
    var body: some View {
        Form {
            Text("Record outcome").font(.headline)
            Picker("Outcome", selection: $outcome) { ForEach(CaseActionOutcome.allCases) { Text($0.label).tag($0) } }
            TextField("Note (optional)", text: $note, axis: .vertical).lineLimit(1...3)
            Text("The outcome is separate from the task's status. It does not decide the question the action serves.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { close() }.keyboardShortcut(.cancelAction)
                Button("Record outcome") { save(outcome, note.isEmpty ? nil : note); close() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16).frame(width: 440)
    }
}

/// S4 (REPORT-02 / REPORT-06) — the report's suggestions awaiting a decision: accept (records a verified point) or dismiss
/// (with a reason). A suggestion is never a point by itself.
struct CaseMapSuggestionsList: View {
    @Environment(AppState.self) private var appState
    let model: CaseFileModel
    let reportID: UUID
    @State private var proposals: [CaseReportPointProposal] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !proposals.isEmpty {
                Text("Suggested points — not points until you accept them").font(.caption.weight(.semibold))
                ForEach(proposals) { p in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(p.kind.label): \u{201C}\(p.quote)\u{201D}").font(.caption).fixedSize(horizontal: false, vertical: true)
                        Text(p.originLabel + (p.sectionHint.map { " · under “\($0)”" } ?? "")).font(.caption2).foregroundStyle(.secondary)
                        HStack {
                            Button("Accept as a point") { decide(p, accept: true) }
                            Button("Dismiss") { decide(p, accept: false) }
                        }
                    }
                    .padding(4)
                }
            }
        }
        .task(id: model.busy) { await load() }
    }

    private func load() async {
        guard let svc = appState.caseFiles else { return }
        do { proposals = try await svc.file.reportStructure(caseID: model.caseID).proposals(of: reportID, .proposed) } catch {
            KalsmritikoshLog.ui.error("Report suggestions unreadable: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func decide(_ p: CaseReportPointProposal, accept: Bool) {
        let caseID = model.caseID, actor = model.actor
        model.run(appState) { svc in
            if accept { _ = try await svc.acceptSuggestion(caseID: caseID, proposalID: p.id, actor: actor) }
            else { try await svc.dismissSuggestion(caseID: caseID, proposalID: p.id, reason: "Not a point of this case", actor: actor) }
        }
    }
}
