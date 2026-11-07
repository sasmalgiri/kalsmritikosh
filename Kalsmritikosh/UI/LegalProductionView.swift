//
//  LegalProductionView.swift
//  Kalsmritikosh
//
//  W2-5 — build a production set from the review coding (N-4): documents coded
//  Responsive are produced; documents coded Privileged (or flagged privileged)
//  get a numbered slip sheet and a privilege-log line. Legal holds are created
//  from the same coding or a tag and block forgetting / erasing held documents.
//  Scope decision 2026-11-06 (SPLIT): holds are core — `LegalHoldsView` (Tools ▸
//  Legal holds) works with the "Production sets" module off; Bates numbering and
//  load files stay behind the switch.
//

import SwiftUI
import AppKit
import os

extension AppState {
    /// Documents for a production: coded Responsive or Privileged (privileged ones are withheld).
    /// Practitioner review 2026-11-02 (Lawyer blocker): a production is for ONE matter. Every candidate —
    /// review codes, tag, and the matter's own document coding — must be in that matter's authorised scope;
    /// another matter's documents (privileged or not) are never produced, slip-sheeted or logged.
    func productionDocuments(tag: String?, caseID: UUID) async -> [ProductionDocument] {
        guard let database, let answers = investigationAnswers, let objects,
              let context = try? await answers.scopeContext(caseID: caseID),
              let inScope = try? await objects.objectIDs(inSourceVersionIDs: Set(context.scope.authorizedSourceVersionIDs)) else { return [] }
        var ids: Set<UUID> = []
        var privileged: Set<UUID> = []
        if let codes = try? await ReviewCodesRepository(database: database).current() {
            for (id, c) in codes {
                if c == .responsive || c == .hot { ids.insert(id) }
                if c == .privileged { ids.insert(id); privileged.insert(id) }
            }
        }
        if let tag, !tag.isEmpty, let tagged = try? await tagsRepository?.subjects(taggedWith: tag, kind: .object) {
            ids.formUnion(tagged)
        }
        // Release-block directive item 1 — a document coded privileged or partly privileged in a case's
        // document-coding result (law.document-coding) is withheld: slip sheet and privilege-log line,
        // never its text or native. The coding controls the production, not only the review codes.
        if let coded = try? await JobResultRepository(database: database).codedPrivilegedObjectIDs(caseID: caseID) {
            ids.formUnion(coded); privileged.formUnion(coded)
        }
        ids.formIntersection(inScope)
        privileged.formIntersection(inScope)
        guard !ids.isEmpty else { return [] }
        var out: [ProductionDocument] = []
        let list = Array(ids)
        for start in stride(from: 0, to: list.count, by: 400) {
            let slice = Array(list[start..<min(start + 400, list.count)])
            let marks = slice.map { _ in "?" }.joined(separator: ",")
            let rows = (try? await database.query("""
                SELECT ko.id, f.url, ko.content, ko.privileged, f.modified_at FROM knowledge_objects ko JOIN files f ON f.id = ko.file_id
                WHERE ko.id IN (\(marks));
                """, slice.map { .uuid($0) })) ?? []
            for r in rows {
                guard let id = r.uuid(0) else { continue }
                let url = r.string(1).flatMap(URL.init(string:))
                out.append(ProductionDocument(id: id, fileName: url?.lastPathComponent ?? id.uuidString,
                                              text: r.string(2) ?? "", nativeURL: url,
                                              privileged: privileged.contains(id) || (r.int(3) ?? 0) != 0))
            }
        }
        // Produced in a stable order: by file name, then id.
        return out.sorted { $0.fileName == $1.fileName ? $0.id.uuidString < $1.id.uuidString : $0.fileName < $1.fileName }
    }
}

struct LegalProductionView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @AppStorage("kalsmritikosh.production.prefix") private var prefix = "PROD"
    @State private var tag = ""
    @State private var legend = "CONFIDENTIAL"
    @State private var redactEmails = false
    @State private var redactPhones = false
    @State private var redactTerms = ""
    @State private var includeNatives = true
    @State private var status: String?
    @State private var running = false
    /// The matter being produced (required).
    @State private var matters: [StudioCaseChoice] = []
    @State private var matter: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Legal production").font(.title3.bold())
            GroupBox("Production set") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Produces, for the matter chosen below, the documents in that matter's scope coded Responsive or Hot (Tools → Review coding), plus any in scope with the tag below. Documents coded Privileged get a numbered slip sheet and a line in the privilege log. Documents outside the matter are never included.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Picker("Matter", selection: $matter) {
                        Text("Choose the matter…").tag(UUID?.none)
                        ForEach(matters) { Text($0.title).tag(Optional($0.id)) }
                    }
                    .frame(maxWidth: 420)
                    HStack {
                        TextField("Bates prefix", text: $prefix).frame(width: 120)
                        TextField("Also include tag (optional)", text: $tag).frame(width: 200)
                        TextField("Legend", text: $legend).frame(width: 140)
                    }
                    HStack {
                        Toggle("Redact email addresses", isOn: $redactEmails)
                        Toggle("Redact phone numbers", isOn: $redactPhones)
                        Toggle("Include native files", isOn: $includeNatives)
                    }
                    TextField("Also redact these terms (comma-separated)", text: $redactTerms)
                    HStack {
                        Button(running ? "Producing…" : "Choose folder and produce…") { Task { await produce() } }
                            .disabled(running || matter == nil || prefix.trimmingCharacters(in: .whitespaces).isEmpty)
                        if let status { Text(status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            LegalHoldsSection(matter: matter, tag: tag.trimmingCharacters(in: .whitespaces), status: $status)
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(16)
        .frame(minWidth: 680, minHeight: 600)
        .task { matters = await appState.studioCaseChoices(); if matters.count == 1 { matter = matters[0].id } }
    }

    private var repo: LegalProductionRepository? { appState.database.map { LegalProductionRepository(database: $0) } }

    private func produce() async {
        guard let repo else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "Produce here"
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        running = true; defer { running = false }
        guard let matter else { status = "Choose the matter to produce."; return }
        let docs = await appState.productionDocuments(tag: tag.trimmingCharacters(in: .whitespaces), caseID: matter)
        guard !docs.isEmpty else { status = "Nothing to produce: no documents are coded Responsive, Hot or Privileged, or carry that tag."; return }
        let p = prefix.trimmingCharacters(in: .whitespaces)
        do {
            let start = try await repo.nextNumber(prefix: p)
            let terms = redactTerms.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            var options = ProductionOptions(prefix: p, startNumber: start)
            options.legend = legend
            options.includeNatives = includeNatives
            if redactEmails || redactPhones || !terms.isEmpty {
                options.redaction = RedactionPolicy(redactEmails: redactEmails, redactPhones: redactPhones, customTerms: terms)
            }
            let folder = parent.appendingPathComponent("\(p)_\(BatesNumbering.format(prefix: "", number: start, width: options.width))")
            let scoped = parent.startAccessingSecurityScopedResource()
            defer { if scoped { parent.stopAccessingSecurityScopedResource() } }
            let result = try await Task.detached { try ProductionBuilder.build(docs, options: options, into: folder) }.value
            try await repo.recordRun(prefix: p, result: result)
            status = "Produced \(result.documents) documents, \(result.pages) pages, \(result.firstBates)–\(result.lastBates)."
                + (result.withheld > 0 ? " \(result.withheld) withheld as privileged." : "")
                + (result.redactions > 0 ? " \(result.redactions) redactions." : "")
                + (result.nativesSkipped > 0 ? " \(result.nativesSkipped) natives not included (redacted or unreadable)." : "")
        } catch {
            KalsmritikoshLog.app.error("Production failed: \(error.localizedDescription, privacy: .public)")
            status = "Production failed: \(error.localizedDescription)"
        }
    }
}

/// The hold list with create and release — the core part of W2-5, shared by the production tool and
/// the always-available Legal holds tool. Holds stay in force whatever is switched on or off.
struct LegalHoldsSection: View {
    @Environment(AppState.self) private var appState
    let matter: UUID?
    let tag: String
    @Binding var status: String?
    @State private var holds: [LegalHold] = []
    @State private var newHoldName = ""

    var body: some View {
        GroupBox("Legal holds") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Held documents cannot be forgotten or erased until the hold is released. Holds stay in force whatever is switched on or off.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("New hold name", text: $newHoldName)
                    Button("Place hold") { Task { await createHold() } }
                        .disabled(matter == nil || newHoldName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                List(holds) { h in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(h.name).font(.callout)
                            Text("\(h.items) document\(h.items == 1 ? "" : "s") · since \(h.createdAt.formatted(date: .abbreviated, time: .omitted))"
                                 + (h.releasedAt.map { " · released \($0.formatted(date: .abbreviated, time: .omitted))" } ?? ""))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if h.releasedAt == nil {
                            Button("Release") { Task { await release(h) } }.buttonStyle(.borderless)
                        }
                    }
                }
                .frame(minHeight: 140)
            }
        }
        .task { await loadHolds() }
    }

    private var repo: LegalProductionRepository? { appState.database.map { LegalProductionRepository(database: $0) } }

    private func loadHolds() async {
        do { holds = try await repo?.holds() ?? [] }
        catch { KalsmritikoshLog.app.error("Legal holds could not be read: \(error.localizedDescription, privacy: .public)") }
    }

    private func createHold() async {
        guard let repo else { return }
        guard let matter else { status = "Choose the matter first."; return }
        let docs = await appState.productionDocuments(tag: tag, caseID: matter)
        guard !docs.isEmpty else { status = "Nothing to hold: give a tag the documents carry, or code them first."; return }
        do {
            let id = try await repo.createHold(name: newHoldName.trimmingCharacters(in: .whitespaces))
            try await repo.addToHold(id, objects: docs.map(\.id))
            newHoldName = ""
            status = "Held \(docs.count) document\(docs.count == 1 ? "" : "s")."
            await loadHolds()
        } catch {
            KalsmritikoshLog.app.error("Legal hold failed: \(error.localizedDescription, privacy: .public)")
            status = "Could not create the hold."
        }
    }

    private func release(_ h: LegalHold) async {
        do { try await repo?.release(h.id); await loadHolds() }
        catch { KalsmritikoshLog.app.error("Hold release failed: \(error.localizedDescription, privacy: .public)") }
    }
}

/// Tools ▸ Legal holds — core (no module switch): choose the matter and the documents (a tag, or the
/// review coding when it is in use), place a hold, release it.
struct LegalHoldsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var matters: [StudioCaseChoice] = []
    @State private var matter: UUID?
    @State private var tag = ""
    @State private var status: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Legal holds").font(.title3.bold())
            Text("A hold covers the documents in the chosen matter's scope that carry the tag below (and any coded Responsive, Hot or Privileged there). Documents outside the matter are never held by it.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("Matter", selection: $matter) {
                Text("Choose the matter…").tag(UUID?.none)
                ForEach(matters) { Text($0.title).tag(Optional($0.id)) }
            }
            .frame(maxWidth: 420)
            TextField("Documents with tag", text: $tag).frame(maxWidth: 260)
            LegalHoldsSection(matter: matter, tag: tag.trimmingCharacters(in: .whitespaces), status: $status)
            if let status { Text(status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(16)
        .frame(minWidth: 620, minHeight: 480)
        .task { matters = await appState.studioCaseChoices(); if matters.count == 1 { matter = matters[0].id } }
    }
}
