//
//  CaseMapUnifiedTools.swift
//  Kalsmritikosh
//
//  Unified-path program S3 (owner 2026-11-22) — two Case tools that connect built-but-unused code:
//  "Study deeper" (AI-28, the on-demand Tier 3 deep study) and "Check against saved lists" (IN-20,
//  CaseEnrichment's local adapter). Not tested yet (owner 2026-11-22: implement now, test later).
//

import SwiftUI
import os

/// Unified path AI-28 (owner 2026-11-22) — not tested yet.
struct CaseStudyDeeperTool: View {
    @Environment(AppState.self) private var appState
    let caseID: UUID
    @State private var people: [CasePersonIdentityView] = []
    @State private var state: CaseToolState = .loading
    @State private var running = false
    @State private var notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CaseToolStateView(state: state)
            if !people.isEmpty {
                Text("\(people.count) person(s) in the case").font(.headline)
                ForEach(people.prefix(25), id: \.person.id) { v in
                    Text(v.person.name).font(.callout)
                }
                Button(running ? "Studying…" : "Study these people deeper") { Task { await run() } }
                    .disabled(running)
                    .help("Rebuild what the app has distilled about each person from the documents, now.")
                    .accessibilityIdentifier("case.tools.studyDeeper.run")
            }
            if let notice { Text(notice).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
        .task { await load() }
    }

    private func load() async {
        guard let file = appState.caseFiles?.file else {
            state = .failed(reason: "the ledger isn't open yet.", next: "Wait for the case to finish opening, then reopen Case tools."); return
        }
        do {
            people = try await file.identityViews(caseID: caseID)
            state = people.isEmpty ? .empty(what: "No people are recorded in this case.", next: "Add people in People in the case, then come back.") : .ready
        } catch {
            KalsmritikoshLog.ui.error("Study deeper: people not read: \(error.localizedDescription, privacy: .public)")
            state = .failed(reason: error.localizedDescription, next: "Reopen Case tools.")
        }
    }

    private func run() async {
        running = true
        defer { running = false }
        let n = await appState.studyDeeper(subjects: people.map { (kind: .person, identifier: $0.person.name) },
                                           triggeringObjectID: nil)
        // Unified path IN-16 (owner 2026-11-22) — not tested yet: the case's documents go on the deep-study queue too.
        let queued = await appState.enqueueDeepStudy(caseID: caseID)
        notice = n == 0 && queued == 0
            ? "Nothing was studied: the app has no memory distiller ready, or nothing new was found for these people."
            : "\(n) person(s) studied or queued for deeper study" + (queued > 0 ? ", and \(queued) document(s) of the case queued for deep study in the background" : "")
                + ". Their distilled memory refreshes in Ask and the briefing."
    }
}

/// Unified path IN-20 (owner 2026-11-22) — not tested yet.
struct CaseLocalEnrichmentTool: View {
    @Environment(AppState.self) private var appState
    let caseID: UUID
    @State private var people: [CasePersonIdentityView] = []
    @State private var state: CaseToolState = .loading
    @State private var results: [(name: String, result: CaseEnrichmentResult)] = []
    @State private var running = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CaseToolStateView(state: state)
            if !people.isEmpty {
                Button(running ? "Checking…" : "Check \(people.count) person(s) against the saved lists") { Task { await run() } }
                    .disabled(running)
                    .help("Match each name against the sanctions lists saved on this Mac. Nothing is sent.")
                    .accessibilityIdentifier("case.tools.enrichment.run")
            }
            ForEach(Array(results.enumerated()), id: \.offset) { _, r in
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.name).font(.callout.weight(.semibold))
                    Text(r.result.summary).font(.caption).foregroundStyle(r.result.status == .matches ? .orange : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(Array(r.result.candidates.prefix(5).enumerated()), id: \.offset) { _, c in
                        Text("• \(c.label) — \(c.detail)\(c.exact ? "" : " (similar name)")").font(.caption2)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .task { await load() }
    }

    private func load() async {
        guard let file = appState.caseFiles?.file else {
            state = .failed(reason: "the ledger isn't open yet.", next: "Wait for the case to finish opening, then reopen Case tools."); return
        }
        do {
            people = try await file.identityViews(caseID: caseID)
            state = people.isEmpty ? .empty(what: "No people are recorded in this case.", next: "Add people in People in the case, then come back.") : .ready
        } catch {
            KalsmritikoshLog.ui.error("Local enrichment: people not read: \(error.localizedDescription, privacy: .public)")
            state = .failed(reason: error.localizedDescription, next: "Reopen Case tools.")
        }
    }

    private func run() async {
        running = true
        defer { running = false }
        var out: [(name: String, result: CaseEnrichmentResult)] = []
        for v in people.prefix(50) {
            out.append((v.person.name, await appState.localSanctionsCheck(v.person.name)))
        }
        results = out
    }
}

/// Unified path AI-37 (owner 2026-11-22, round 2) — not tested yet. The case's kept AI suggestions on a screen.
struct CaseAISuggestionsTool: View {
    @Environment(AppState.self) private var appState
    let caseID: UUID
    @State private var state: CaseToolState = .loading
    @State private var kept: (body: String, items: Int, dropped: Int, at: Date)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CaseToolStateView(state: state)
            if let kept {
                Text("\(kept.items) suggestion(s) kept" + (kept.dropped > 0 ? ", \(kept.dropped) left out (they did not cite or quote the case's documents)" : "")
                     + " · \(kept.at.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
                Text(kept.body.replacingOccurrences(of: "## AI suggestions\n", with: ""))
                    .font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { await load() }
    }

    private func load() async {
        guard let db = appState.database else {
            state = .failed(reason: "the ledger isn't open yet.", next: "Wait for the case to finish opening, then reopen Case tools."); return
        }
        do {
            kept = try await CaseBriefingRepository(database: db).latestAISuggestions(caseID: caseID)
            state = kept == nil ? .empty(what: "No AI suggestions yet.", next: "Ask a question in this case with AI set up; the suggestions are made once per set of case documents, after the answer.") : .ready
        } catch {
            KalsmritikoshLog.ui.error("AI suggestions not read: \(error.localizedDescription, privacy: .public)")
            state = .failed(reason: error.localizedDescription, next: "Reopen Case tools.")
        }
    }
}

/// Unified path REASON-17 (owner 2026-11-22, round 2) — not tested yet. The scope ledger with a Stale badge.
struct CaseScopeCheckTool: View {
    @Environment(AppState.self) private var appState
    let caseID: UUID
    @State private var state: CaseToolState = .loading
    @State private var rows: [InvestigationAnswerService.ScopeArtifactStatus] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CaseToolStateView(state: state)
            if !rows.isEmpty {
                let stale = rows.filter(\.stale).count
                Text(stale == 0 ? "Everything below was made under the case's current scope." : "\(stale) of \(rows.count) item(s) were made under an earlier scope.")
                    .font(.headline)
                ForEach(rows) { r in
                    HStack {
                        Text(Self.label(r.kind)).font(.callout)
                        Text(String(r.artifactID.prefix(8))).font(.caption.monospaced()).foregroundStyle(.secondary)
                        Text(r.recordedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if r.stale {
                            Text("Stale").font(.caption2.weight(.semibold))
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Color.orange.opacity(0.18), in: Capsule()).foregroundStyle(.orange)
                                .help("Made before the case's documents or scope changed. Check it again before relying on it.")
                        }
                    }
                }
            }
        }
        .task { await load() }
    }

    static func label(_ k: InvestigationScopeArtifactKind) -> String {
        switch k {
        case .ask: return "Answer"
        case .methodRun: return "Method"
        case .workbenchDataset: return "Data set"
        case .workProduct: return "Work product"
        }
    }

    private func load() async {
        guard let answers = appState.investigationAnswers else {
            state = .failed(reason: "the ledger isn't open yet.", next: "Wait for the case to finish opening, then reopen Case tools."); return
        }
        do {
            rows = try await answers.scopeArtifactStatus(caseID: caseID).sorted { $0.recordedAt > $1.recordedAt }
            state = rows.isEmpty ? .empty(what: "Nothing has been made in this case yet.", next: "Ask a question or run a method; it appears here with its scope.") : .ready
        } catch {
            KalsmritikoshLog.ui.error("Scope check not read: \(error.localizedDescription, privacy: .public)")
            state = .failed(reason: error.localizedDescription, next: "Reopen Case tools.")
        }
    }
}

// MARK: - ALCOA ALC-02 (owner 2026-11-24): Review AI findings

/// Every AI finding of the case with its run and model, and the person's accept / reject / correct (append-only: a new
/// decision is a new row, the latest counts). Reports: "Copy final" (accepted or corrected only) or "Copy draft" (all).
/// Small expressions on purpose (Xcode 26 CI type-check budget).
struct CaseAIReviewTool: View {
    @Environment(AppState.self) private var appState
    let caseID: UUID
    let actor: String
    @State private var state: CaseToolState = .loading
    @State private var records: [CaseAIRecord] = []
    @State private var latest: [UUID: CaseAIRecordRepository.DecisionRecord] = [:]
    @State private var runs: [UUID: CaseAIRecordRepository.Run] = [:]
    @State private var reason = ""
    @State private var correction = ""
    @State private var notice: String?
    /// ALCOA ALC-18 — the writes the checker refused, with its reason.
    @State private var refused: [CaseAIRecordRepository.RejectedRecord] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CaseToolStateView(state: state)
            if let notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
            if !records.isEmpty { controls }
            ForEach(records) { r in row(r) }
            if !refused.isEmpty { refusedList }
        }
        .task { await load() }
    }

    private var refusedList: some View {
        DisclosureGroup("Writes the checker refused: \(refused.count)") {
            ForEach(refused) { w in
                Text(CaseAIReviewText.refused(w)).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(.caption)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Reason (needed to reject or correct)", text: $reason).textFieldStyle(.roundedBorder)
            TextField("Corrected wording (for Correct)", text: $correction).textFieldStyle(.roundedBorder)
            HStack {
                Button("Copy final report") { Task { await copy(final: true) } }.caseMapControlHelp("Copy final report")
                Button("Copy draft report") { Task { await copy(final: false) } }.caseMapControlHelp("Copy draft report")
                Text("\(decidedCount) of \(records.count) decided").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var decidedCount: Int { records.filter { latest[$0.id] != nil }.count }

    private func row(_ r: CaseAIRecord) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(r.text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Text(provenance(r)).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(decisionLine(r)).font(.caption2).foregroundStyle(latest[r.id] == nil ? .orange : .secondary)
            HStack {
                Button("Accept") { Task { await decide(r, .accept) } }.caseMapControlHelp("Accept this AI finding")
                Button("Reject") { Task { await decide(r, .reject) } }.caseMapControlHelp("Reject this AI finding")
                Button("Correct") { Task { await decide(r, .correct) } }.caseMapControlHelp("Correct this AI finding")
            }
            .controlSize(.small)
        }
        .padding(6)
        .background(Color.secondary.opacity(0.06), in: .rect(cornerRadius: 6))
    }

    private func provenance(_ r: CaseAIRecord) -> String {
        CaseAIReviewText.provenance(r, run: r.runID.flatMap { runs[$0] })
    }

    private func decisionLine(_ r: CaseAIRecord) -> String {
        CaseAIReviewText.decision(latest[r.id])
    }

    private func load() async {
        guard let db = appState.database else {
            state = .failed(reason: "the ledger isn't open yet.", next: "Wait for the case to finish opening, then reopen Case tools."); return
        }
        let repo = CaseAIRecordRepository(database: db)
        do {
            records = try await repo.records(caseID: caseID)
            if !records.isEmpty { await CaseAccessLog.note(db, caseID: caseID, kind: .aiFindingsReviewed, actor: actor) }   // ALCOA ALC-11
            latest = try await repo.latestDecisions(caseID: caseID)
            refused = try await repo.rejected(caseID: caseID)
            runs = Dictionary(try await repo.runs(caseID: caseID).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            state = records.isEmpty ? .empty(what: "No AI findings in this case yet.", next: "Ask a question in this case with AI set up; the AI records what it finds, each quote checked, for you to review here.") : .ready
        } catch {
            KalsmritikoshLog.ui.error("AI findings not read: \(error.localizedDescription, privacy: .public)")
            state = .failed(reason: error.localizedDescription, next: "Reopen Case tools.")
        }
    }

    private func decide(_ r: CaseAIRecord, _ d: CaseAIRecordRepository.Decision) async {
        guard let db = appState.database else { return }
        do {
            try await CaseAIRecordRepository(database: db).decide(caseID: caseID, recordID: r.id, d, correctedText: correction,
                                                                  reason: reason, approver: actor)
            notice = "Recorded: \(d.rawValue) by \(actor)."
            reason = ""; correction = ""
            await load()
        } catch {
            KalsmritikoshLog.ui.error("AI finding decision not recorded: \(error.localizedDescription, privacy: .public)")
            notice = error.localizedDescription
        }
    }

    private func copy(final: Bool) async {
        guard let db = appState.database else { return }
        do {
            let text = CaseAIRecordRepository.reportText(try await CaseAIRecordRepository(database: db).reportRecords(caseID: caseID, final: final), final: final)
            if AIFindingsCopy.copy(text) { notice = final ? "Final report copied." : "Draft report copied." }
        } catch {
            KalsmritikoshLog.ui.error("AI findings report not made: \(error.localizedDescription, privacy: .public)")
            notice = error.localizedDescription
        }
    }
}

/// The review list's wording (testable without a view).
nonisolated enum CaseAIReviewText {
    /// ALCOA ALC-18 — one refused write: what the AI sent and why the checker refused it (never shown as a finding).
    static func refused(_ w: CaseAIRecordRepository.RejectedRecord) -> String {
        var s = "Refused \(w.tool)"
        if let d = w.document { s += " (Document \(d))" }
        if let t = w.text, !t.isEmpty { s += ": \u{201C}\(t)\u{201D}" }
        if let q = w.quote, !q.isEmpty { s += " · quote \u{201C}\(q.prefix(160))\u{201D}" }
        s += " · reason: \(w.reason) · \(ExportDateStyle.stamp(w.recordedAt))"
        if let m = w.modelServed { s += " · answered by \(m)" }
        return s
    }

    static func provenance(_ r: CaseAIRecord, run: CaseAIRecordRepository.Run?) -> String {
        var parts = ["Found by AI · quote checked", r.origin == "picture" ? "case picture" : "while answering a question"]
        if let m = r.modelRequested { parts.append("asked: \(m)") }
        if let m = r.modelServed { parts.append("answered by \(m)" + (r.modelRequested.map { $0 != m } == true ? " (fallback)" : "")) }
        if let who = r.requestedBy { parts.append("asked by \(who)") }
        if r.runID == nil { parts.append("run not recorded (made before runs were kept)") }
        else if let run { parts.append("run \(run.startedAt.formatted(date: .abbreviated, time: .shortened)), \(run.state)") }
        return parts.joined(separator: " · ")
    }

    static func decision(_ d: CaseAIRecordRepository.DecisionRecord?) -> String {
        guard let d else { return "Not reviewed yet — a draft report only." }
        let when = d.decidedAt.formatted(date: .abbreviated, time: .shortened)
        switch d.decision {
        case .accept: return "Accepted by \(d.approver), \(when)."
        case .reject: return "Rejected by \(d.approver), \(when): \(d.reason ?? "")"
        case .correct: return "Corrected by \(d.approver), \(when): “\(d.correctedText ?? "")” — \(d.reason ?? "")"
        }
    }
}

// MARK: - ALCOA ALC-13 (owner 2026-11-24): Data integrity report

/// What the app recorded for this case, principle by principle; exported (archival PDF + JSON + manifest, certified, or one
/// password-protected ZIP) into a folder the person chooses. Small expressions on purpose (Xcode 26 CI type-check budget).
struct CaseIntegrityReportTool: View {
    @Environment(AppState.self) private var appState
    let caseID: UUID
    let actor: String
    @State private var state: CaseToolState = .ready
    @State private var report: CaseIntegrityReport?
    @State private var password = ""
    @State private var notice: String?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CaseToolStateView(state: state)
            HStack {
                Button(working ? "Working…" : "Make the data integrity report") { Task { await make() } }
                    .disabled(working).caseMapControlHelp("Make the data integrity report")
                Button("Export the data integrity report…") { Task { await export() } }
                    .disabled(report == nil || working).caseMapControlHelp("Export the data integrity report…")
            }
            SecureField("Password for an encrypted ZIP (optional, 8 characters or more)", text: $password).textFieldStyle(.roundedBorder)
            if let notice { Text(notice).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if let report { IntegrityReportBody(report: report) }
        }
    }

    private func make() async {
        working = true
        defer { working = false }
        do {
            let r = try await appState.dataIntegrityReport(caseID: caseID, actor: actor)
            report = r
            state = r.documents.isEmpty ? .empty(what: "This case has no documents yet, so there is little to report.", next: "Add documents to the case, then make the report again.") : .ready
        } catch {
            KalsmritikoshLog.ui.error("Integrity report not made: \(error.localizedDescription, privacy: .private)")
            state = CaseToolState.from(error, doing: "making the data integrity report")
        }
    }

    private func export() async {
        guard let report, let parent = IntegrityExportFolder.choose() else { return }
        working = true
        defer { working = false }
        let scoped = parent.startAccessingSecurityScopedResource()
        defer { if scoped { parent.stopAccessingSecurityScopedResource() } }
        do {
            let out = try await report.export(into: parent, password: password.isEmpty ? nil : password, database: appState.database)
            if let db = appState.database { await CaseAccessLog.note(db, caseID: caseID, kind: .exportCreated, actor: actor) }
            notice = IntegrityExportFolder.line(out)
            password = ""
        } catch {
            KalsmritikoshLog.ui.error("Integrity report not exported: \(error.localizedDescription, privacy: .private)")
            notice = error.localizedDescription
        }
    }
}

/// The report on screen: the summary first, then each principle.
struct IntegrityReportBody: View {
    let report: CaseIntegrityReport
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(CaseIntegrityReport.wording).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Summary").font(.headline)
            ForEach(report.summary, id: \.self) { Text("• " + $0).font(.callout).fixedSize(horizontal: false, vertical: true) }
            ForEach(report.principles, id: \.name) { p in principle(p) }
        }
    }

    private func principle(_ p: CaseIntegrityReport.Principle) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(p.name).font(.subheadline.weight(.semibold))
            ForEach(p.lines, id: \.self) { Text("• " + $0).font(.caption).fixedSize(horizontal: false, vertical: true) }
        }
    }
}
