//
//  JobResultView.swift
//  Kalsmritikosh
//
//  Audit A1 — the result a job produced, opened from its job card: every row with its sources
//  (each opens the exact document passage), the run's limitations and next actions, the person's
//  decision and note on each row, corrections, review revisions (saved, restorable, never
//  overwritten) and completion — which needs the person's note, no undecided row and an unblocked
//  result. Export re-checks every cited source before writing.
//

import SwiftUI
#if canImport(AppKit)
import AppKit
import UniformTypeIdentifiers
#endif

@MainActor @Observable
final class JobResultModel {
    let repo: JobResultRepository
    let caseID: UUID
    let jobID: String
    let jobTitle: String
    private(set) var current: JobResultRecord?
    private(set) var history: [JobResultRecord] = []
    /// The person's working copy of the current rows (decisions, notes, corrections).
    var rows: [JobResultRow] = []
    var completionNote = ""
    private(set) var message: String?
    private(set) var problem: String?
    var viewing: JobResultRecord?       // an earlier revision opened read-only

    init(repo: JobResultRepository, caseID: UUID, jobID: String, jobTitle: String) {
        self.repo = repo; self.caseID = caseID; self.jobID = jobID; self.jobTitle = jobTitle
    }

    var dirty: Bool { current.map { $0.content.rows != rows } ?? false }

    /// B2 — a row the person adds by hand (a document no run turned into a candidate, a missing
    /// element). It carries no source until the person links one, and prints as their entry.
    func addManualRow() {
        var r = JobResultRow(title: "")
        r.manual = true
        rows.append(r)
    }

    /// Link a source to a row by its object id (from "Open source" / the evidence viewer).
    func link(_ ref: StudioEvidenceRef, toRow i: Int) {
        guard rows.indices.contains(i) else { return }
        let old = rows[i]
        rows[i] = JobResultRow(title: old.title, detail: old.detail, date: old.date, flags: old.flags, refs: old.refs + [ref],
                               decision: old.decision, note: old.note, fields: old.fields)
        rows[i].sourced = old.sourced; rows[i].assertions = old.assertions; rows[i].manual = old.manual
    }
    var undecided: Int { rows.filter { $0.decision == nil }.count }

    func load() async {
        do {
            current = try await repo.latest(caseID: caseID, jobID: jobID)
            history = try await repo.history(caseID: caseID, jobID: jobID)
            rows = current?.content.rows ?? []
            problem = nil
        } catch { problem = "The result could not be read: \(error.localizedDescription)" }
    }

    /// B2 — the app's check that cited sources still resolve (set by the view; nil in previews).
    var evidenceCheck: JobResultRepository.EvidenceCheck?

    func save(complete: Bool, actor: String) async {
        guard let current else { return }
        do {
            try await repo.saveReview(of: current, rows: rows, complete: complete,
                                      note: complete ? completionNote : nil, actor: actor, evidenceCheck: evidenceCheck)
            message = complete ? "Completed and saved. Earlier revisions are kept." : "Review saved as a new revision."
            problem = nil
            completionNote = ""
            await load()
        } catch { problem = error.localizedDescription; message = nil }
    }

    func restore(_ old: JobResultRecord, actor: String) async {
        do {
            try await repo.restore(old, over: current?.id, actor: actor)
            message = "That revision is current again (saved as a new revision)."
            viewing = nil
            await load()
        } catch { problem = error.localizedDescription }
    }
}

struct JobResultView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State var model: JobResultModel
    @State private var source: OpenedSource?
    let actor: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let record = model.viewing ?? model.current {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if model.viewing != nil {
                            Label("An earlier revision (\(record.createdAt.formatted()) by \(record.createdBy)) — read-only.", systemImage: "clock.arrow.circlepath")
                                .font(.callout).foregroundStyle(.orange)
                        }
                        if let review = record.content.review {
                            Label("\(review.completed ? "Completed" : "Reviewed") by \(review.by), \(review.at.formatted())\(review.note.map { " — \($0)" } ?? "")",
                                  systemImage: review.completed ? "checkmark.seal.fill" : "pencil.and.list.clipboard")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        list("Limitations of this run", record.content.limitations, icon: "exclamationmark.triangle")
                        rowsSection(record)
                        list("Next actions", record.content.nextActions, icon: "arrow.forward.circle")
                        historySection
                    }
                    .padding(16)
                }
                Divider()
                footer(record)
            } else {
                ContentUnavailableView("This job has no saved result yet", systemImage: "tray",
                                       description: Text("Run the job against the open matter; its result appears here."))
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(minWidth: 720, minHeight: 560)
        .task {
            model.evidenceCheck = appState.jobResultEvidenceCheck(caseID: model.caseID)
            await model.load()
        }
        .sheet(item: $source) { opened in
            VStack(spacing: 0) {
                EvidenceViewer(citation: opened.citation)
                HStack { Spacer(); Button("Close") { source = nil }.keyboardShortcut(.cancelAction) }.padding(10)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.jobTitle).font(.title3.weight(.semibold))
                if let c = model.current {
                    Text("\(Self.stateLabel(c.state)) · \(c.content.rows.count) row(s) · saved \(c.createdAt.formatted()) by \(c.createdBy)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    static func stateLabel(_ s: JobResultState) -> String {
        switch s {
        case .draft: return "Draft — awaiting your review"
        case .blocked: return "Blocked — something the job needs is missing"
        case .completed: return "Completed"
        case .superseded: return "Superseded"
        }
    }

    @ViewBuilder
    private func list(_ title: String, _ items: [String], icon: String) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Label(title, systemImage: icon).font(.subheadline.weight(.semibold))
                ForEach(items, id: \.self) { Text("• " + $0).font(.callout).fixedSize(horizontal: false, vertical: true) }
            }
        }
    }

    @ViewBuilder
    private func rowsSection(_ record: JobResultRecord) -> some View {
        let editable = model.viewing == nil && record.state != .superseded
        let rows = editable ? model.rows : record.content.rows
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Result (\(rows.count))", systemImage: "list.bullet.rectangle").font(.subheadline.weight(.semibold))
                Spacer()
                if editable {
                    Button("Add a row") { model.addManualRow() }.controlSize(.small)
                        .help("Record something the run did not produce — a document it did not read, a missing element — as your entry.")
                }
            }
            ForEach(rows.indices, id: \.self) { i in
                rowView(rows[i], index: i, editable: editable)
                    .padding(10)
                    .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: JobResultRow, index i: Int, editable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                if let d = row.date { Text(d).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                if editable {
                    TextField("Row", text: Binding(get: { model.rows[i].title }, set: { model.rows[i].title = $0 }), axis: .vertical)
                        .font(.callout)
                } else {
                    Text(row.title).font(.callout)
                }
            }
            if let detail = row.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            let current = editable ? model.rows[i] : row
            if current.manual == true {
                Text("Your entry — added by hand\(current.refs.isEmpty ? ", no source linked" : "")").font(.caption2).foregroundStyle(.orange)
            } else if current.changedSourcedValue {
                Text("Changed from the source (\(current.sourced?["title"].map { "it said: “\($0.prefix(120))”" } ?? "see the cited passage")). Your change prints as your entry; a note saying why is required to complete.")
                    .font(.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if !row.flags.isEmpty {
                Text(row.flags.map { "⚑ " + $0 }.joined(separator: "  ")).font(.caption2).foregroundStyle(.orange)
            }
            ForEach(Array(row.refs.enumerated()), id: \.offset) { _, ref in
                HStack(spacing: 6) {
                    Image(systemName: "doc.text.magnifyingglass").imageScale(.small).foregroundStyle(.secondary)
                    Text(ref.quote.map { "“\($0.prefix(160))”" } ?? "Source").font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    if let o = ref.objectID {
                        Button("Open source") { source = OpenedSource(citation: VerifiedAnswer.Citation(objectID: o, snippet: ref.quote ?? "")) }
                            .buttonStyle(.link).font(.caption2)
                    }
                }
            }
            if let spec = JobFields.specs[model.jobID] {
                fieldsView(spec, row: row, index: i, editable: editable)
            }
            if editable {
                HStack {
                    Picker("Decision", selection: Binding(get: { model.rows[i].decision }, set: { model.rows[i].decision = $0 })) {
                        Text("Undecided").tag(JobRowDecision?.none)
                        Text("Accepted").tag(JobRowDecision?.some(.accepted))
                        Text("Rejected").tag(JobRowDecision?.some(.rejected))
                    }
                    .pickerStyle(.segmented).frame(maxWidth: 320)
                    TextField("Your note", text: Binding(get: { model.rows[i].note ?? "" },
                                                         set: { model.rows[i].note = $0.isEmpty ? nil : $0 }))
                }
            } else if row.decision != nil || row.note != nil {
                Text([row.decision.map { $0.rawValue.capitalized }, row.note].compactMap { $0 }.joined(separator: " — "))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// The contract's columns for this row: pre-filled where the ledger states them, recorded here otherwise.
    @ViewBuilder
    private func fieldsView(_ spec: [JobField], row: JobResultRow, index i: Int, editable: Bool) -> some View {
        let missing = Set(JobFields.missing(job: model.jobID, row: editable ? model.rows[i] : row).map(\.key))
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
            ForEach(spec, id: \.key) { f in
                GridRow {
                    let shown = editable ? model.rows[i] : row
                    let value = shown.fields?[f.key] ?? ""
                    let invalid = value.isEmpty ? nil : JobFields.invalidReason(f.kind, value)
                    let entry = !value.isEmpty && shown.personEntries().contains(f.key)
                    Text(f.label + (f.required ? "" : " (optional)") + (invalid.map { " — \($0)" } ?? "") + (entry ? " · your entry" : ""))
                        .font(.caption)
                        .foregroundStyle(missing.contains(f.key) ? .orange : .secondary)
                    if editable {
                        let binding = Binding(get: { model.rows[i].fields?[f.key] ?? "" },
                                              set: { v in var d = model.rows[i].fields ?? [:]; d[f.key] = v; model.rows[i].fields = d })
                        switch f.kind {
                        case .choice(let options):
                            Picker(f.label, selection: binding) {
                                Text("—").tag("")
                                ForEach(options, id: \.self) { Text($0).tag($0) }
                            }
                            .labelsHidden().frame(maxWidth: 240)
                        case .date:
                            TextField("yyyy-mm-dd", text: binding).font(.caption).frame(maxWidth: 140)
                        case .amount:
                            TextField("1,250.00", text: binding).font(.caption.monospacedDigit()).frame(maxWidth: 160)
                        case .currency:
                            TextField("USD", text: binding).font(.caption).frame(maxWidth: 80)
                        case .text:
                            TextField(f.label, text: binding, axis: .vertical).font(.caption)
                        }
                    } else {
                        Text(row.fields?[f.key] ?? "—").font(.caption)
                    }
                }
            }
        }
        .padding(.leading, 4)
    }

    @ViewBuilder
    private var historySection: some View {
        if model.history.count > 1 {
            DisclosureGroup("Revisions (\(model.history.count))") {
                ForEach(model.history) { r in
                    HStack {
                        Text("\(r.createdAt.formatted()) · \(r.createdBy) · \(Self.stateLabel(r.state))").font(.caption)
                        Spacer()
                        if r.id != model.current?.id {
                            Button("View") { model.viewing = r }.controlSize(.small)
                            Button("Restore as current") { Task { await model.restore(r, actor: actor) } }.controlSize(.small)
                        }
                    }
                }
            }
            .font(.subheadline)
        }
    }

    private func footer(_ record: JobResultRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let m = model.message { Label(m, systemImage: "checkmark.circle").font(.caption).foregroundStyle(.green) }
            if let p = model.problem { Label(p, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
            if model.viewing != nil {
                HStack { Button("Back to current") { model.viewing = nil }; Spacer() }
            } else {
                HStack(spacing: 10) {
                    Button("Export…") { Task { await export(record) } }
                    Spacer()
                    Button("Save review") { Task { await model.save(complete: false, actor: actor) } }
                        .disabled(!model.dirty)
                    TextField("Completion note (required to complete)", text: $model.completionNote).frame(maxWidth: 280)
                    Button("Mark completed") { Task { await complete() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(record.state == .blocked || model.undecided > 0
                                  || model.completionNote.trimmingCharacters(in: .whitespaces).isEmpty)
                        .help(record.state == .blocked ? "A blocked result cannot be completed."
                              : model.undecided > 0 ? "\(model.undecided) row(s) are undecided." : "Record that you reviewed and completed this result.")
                }
            }
        }
        .padding(12)
    }

    /// Complete — a method job first saves each accepted method as a run in the case's method engine.
    private func complete() async {
        if model.jobID.hasSuffix(".methods") {
            let (runs, problems) = await appState.startMethodRuns(caseID: model.caseID, rows: model.rows, actor: actor)
            for (i, id) in runs { var d = model.rows[i].fields ?? [:]; d["run"] = id.uuidString; model.rows[i].fields = d }
            if !problems.isEmpty { model.setProblem("Method runs not saved: " + problems.joined(separator: "; ")); return }
        }
        await model.save(complete: true, actor: actor)
    }

    /// Export the current saved revision as Markdown (B2): unsaved edits refuse; the destination is
    /// chosen first; then the app re-checks the revision and every cited source immediately before
    /// writing, renders once, reads the file back and records the export.
    private func export(_ record: JobResultRecord) async {
        #if canImport(AppKit)
        guard !model.dirty else { model.setProblem(JobResultExportError.unsavedEdits.localizedDescription); return }
        let panel = NSSavePanel()
        if let md = UTType(filenameExtension: "md") { panel.allowedContentTypes = [md] }
        panel.nameFieldStringValue = "\(model.jobTitle).md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let receipt = try await appState.exportJobResult(record, title: model.jobTitle, to: url, actor: actor)
            model.setMessage("Exported \(url.lastPathComponent) (SHA-256 \(receipt.fileSHA256.prefix(12))…, recorded).")
        } catch { model.setProblem("Not exported: \(error.localizedDescription)") }
        #endif
    }
}

struct OpenedSource: Identifiable {
    let id = UUID()
    let citation: VerifiedAnswer.Citation
}

extension JobResultModel {
    func setProblem(_ p: String) { problem = p; message = nil }
    func setMessage(_ m: String) { message = m; problem = nil }
}

/// The exported form of a job result: state, review, rows with decisions and sources, limitations.
nonisolated enum JobResultMarkdown {
    static func render(_ r: JobResultRecord, title: String) -> String {
        var out = "# \(title)\n\nState: \(r.state.rawValue) · revision \(r.id.uuidString) · saved \(r.createdAt.formatted()) by \(r.createdBy)\n"
        if let review = r.content.review {
            out += "\n\(review.completed ? "Completed" : "Reviewed") by \(review.by) on \(review.at.formatted())\(review.note.map { ": \($0)" } ?? "")\n"
            if let d = review.digest { out += "Digest (SHA-256 of the completed rows): \(d)\n" }
        }
        if !r.content.limitations.isEmpty { out += "\n## Limitations\n" + r.content.limitations.map { "- \($0)" }.joined(separator: "\n") + "\n" }
        out += "\n## Result\n"
        for (i, row) in r.content.rows.enumerated() {
            let entries = Set(row.assertions ?? row.personEntries())
            out += "\n\(i + 1). \(row.date.map { "\($0) — " } ?? "")\(row.title)\(entries.contains("title") ? " [reviewer's entry]" : "")\n"
            if row.manual == true { out += "   Added by the reviewer\(row.refs.isEmpty ? " (no source linked)" : "").\n" }
            else if row.changedSourcedValue, let said = row.sourced?["title"], said != row.title { out += "   The source-derived text was: \(said)\n" }
            if let d = row.detail { out += "   \(d)\n" }
            if !row.flags.isEmpty { out += "   Flags: \(row.flags.joined(separator: "; "))\n" }
            for (k, v) in (row.fields ?? [:]).sorted(by: { $0.key < $1.key }) where !v.isEmpty {
                let label = JobFields.specs[r.jobID]?.first { $0.key == k }?.label ?? k
                let mark = entries.contains(k) ? " [reviewer's entry\(row.sourced?[k].map { "; source-derived value was \($0)" } ?? "")]" : ""
                out += "   \(label): \(v)\(mark)\n"
            }
            if let dec = row.decision { out += "   Decision: \(dec.rawValue)\(row.note.map { " — \($0)" } ?? "")\n" }
            else if let n = row.note { out += "   Note: \(n)\n" }
            for ref in row.refs {
                // B2 — the exact source: version, object and block identifiers, then the quoted passage.
                let ids = [ref.sourceVersionID.map { "version \($0.uuidString)" }, ref.objectID.map { "object \($0.uuidString)" },
                           ref.blockID.map { "block \($0.uuidString)" }].compactMap { $0 }.joined(separator: ", ")
                out += "   Source (\(ids.isEmpty ? "no locator" : ids)): “\(ref.quote ?? "")”\n"
            }
        }
        if !r.content.nextActions.isEmpty { out += "\n## Next actions\n" + r.content.nextActions.map { "- \($0)" }.joined(separator: "\n") + "\n" }
        return out
    }
}
