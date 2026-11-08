//
//  CaseDraftsSection.swift
//  Kalsmritikosh
//
//  P5 — the case file's drafts (Overview): a proposed chronology, the cast of characters, gaps and next
//  leads, and an interview plan, drafted from this case's own documents. "Draft from the documents" runs
//  the rules on this Mac; "Draft with AI" (Online, document reading on) also has the person's AI reader
//  read the passages cleared for the case, every proposal checked against the documents first. Each item
//  shows its quote with "Open source"; nothing enters the case until the investigator accepts it, and
//  then only through the case file's own write paths (chronology with the passage as citation, people,
//  tasks, the interview's questions), behind the same paid-action gate as any edit of the case file.
//

import SwiftUI
import os

struct CaseDraftsSection: View {
    @Environment(AppState.self) private var appState
    let model: CaseFileModel
    let s: CaseFileSnapshot
    let closed: Bool
    @State private var drafts: CaseDrafts?
    @State private var running = false
    @State private var summary: String?
    @State private var status: [String: String] = [:]
    @State private var interviewee: String = ""
    @State private var interview: CaseInterviewDraft?
    @State private var interviewSummary: String?
    @State private var aiAvailable = false
    @State private var names: [UUID: String] = [:]
    @State private var openSource: CitationOpenTarget?
    @State private var openedPassage: OpenedSource?

    var body: some View {
        CaseSection(title: "Drafts",
                    subtitle: "A proposed chronology, cast, open points and interview questions from this case's documents. Each item quotes its document; nothing is added to the case until you accept it, and nothing here decides guilt or cause.") {
            HStack {
                Button { Task { await draft(useAI: false) } } label: {
                    Label("Draft from the documents", systemImage: "doc.text.below.ecg")
                }
                .disabled(running || appState.investigationContradictionGap == nil)
                .help("The rules read this case's documents on this Mac — never documents outside the case.")
                .accessibilityIdentifier("case.drafts.rules")
                if aiAvailable {
                    Button { Task { await draft(useAI: true) } } label: {
                        Label("Draft with AI", systemImage: "sparkles")
                    }
                    .disabled(running)
                    .help("Your AI reader also reads the passages cleared for this case; every proposal is checked against the documents before it is shown.")
                    .accessibilityIdentifier("case.drafts.ai")
                }
                if running { ProgressView().controlSize(.small) }
                Spacer()
            }
            if !aiAvailable {
                Text("AI drafting is available in Online mode with document reading on.")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("case.drafts.aiNote")
            }
            if let summary { Text(summary).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if let d = drafts {
                chronology(d)
                castList(d)
                leads(d)
                interviewPlan(d)
            }
        }
        .task(id: model.caseID) { aiAvailable = await appState.investigationContradictionGap?.draftReaderAvailable() ?? false }
        .sheet(item: $openSource) { target in CitationSourceSheet(target: target) { openSource = nil } }
        .sheet(item: $openedPassage) { opened in
            VStack(spacing: 0) {
                EvidenceViewer(citation: opened.citation)
                HStack { Spacer(); Button("Close") { openedPassage = nil }.keyboardShortcut(.cancelAction) }.padding(10)
            }
        }
    }

    // MARK: - Chronology

    @ViewBuilder private func chronology(_ d: CaseDrafts) -> some View {
        header("Proposed chronology", count: d.timeline.count)
        if d.timeline.isEmpty { empty("No dated step was found for a defendant in these documents.") }
        ForEach(d.timeline) { item in
            card(id: item.id, provenance: item.provenance) {
                Text("\(item.dateText) — \(item.what)").font(.callout.weight(.medium)).textSelection(.enabled)
                if item.dateFromDocumentDate {
                    Text("Day read from the document's printed date — check it.").font(.caption2).foregroundStyle(.orange)
                }
                quote(item.quote, object: item.objectID)
            } actions: {
                Button("Add to chronology") { addToChronology(item) }
                    .accessibilityIdentifier("case.drafts.timeline.accept")
            }
        }
    }

    // MARK: - Cast

    @ViewBuilder private func castList(_ d: CaseDrafts) -> some View {
        header("Cast of characters", count: d.cast.count)
        if d.cast.isEmpty { empty("No person or organisation is named in full in these documents.") }
        ForEach(CaseDraftCastMember.Group.allCases, id: \.self) { group in
            let members = d.cast.filter { $0.group == group }
            if !members.isEmpty {
                Text(group.title).font(.caption.bold()).foregroundStyle(.secondary).padding(.top, 4)
                ForEach(members) { m in
                    card(id: "cast:" + m.id, provenance: m.roleProvenance ?? .rules) {
                        HStack(spacing: 6) {
                            Text(m.name).font(.callout.weight(.medium))
                            Text(m.roleLabel).font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background((m.isOfficial ? Color.gray : Color.accentColor).opacity(0.15), in: .capsule)
                        }
                        Text(appearance(m)).font(.caption).foregroundStyle(.secondary)
                        if let q = m.roleQuote ?? m.firstQuote, let o = m.roleObjectID ?? m.firstObjectID { quote(q, object: o) }
                    } actions: {
                        if s.people.contains(where: { $0.name.caseInsensitiveCompare(m.name) == .orderedSame }) {
                            Text("In the case").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Button("Add to people") { addPerson(m) }
                                .accessibilityIdentifier("case.drafts.cast.accept")
                        }
                    }
                }
            }
        }
    }

    private func appearance(_ m: CaseDraftCastMember) -> String {
        var t = "Named in \(m.documentCount) document\(m.documentCount == 1 ? "" : "s")"
        if let f = m.firstAppearance {
            t += " · first \(CaseFileDocuments.d(f))"
            if let l = m.lastAppearance, l != f { t += ", last \(CaseFileDocuments.d(l))" }
        }
        return t
    }

    // MARK: - Leads

    @ViewBuilder private func leads(_ d: CaseDrafts) -> some View {
        header("Gaps and next leads", count: d.leads.count)
        if d.leads.isEmpty { empty("No open point was found by the checks run. That does not mean the record is complete.") }
        ForEach(d.leads) { lead in
            card(id: lead.id, provenance: lead.provenance) {
                Text(lead.notEstablished).font(.callout.weight(.medium)).textSelection(.enabled)
                Text("Records that would settle it: \(lead.records)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                quote(lead.quote, object: lead.objectID)
                if let other = lead.otherQuote, let o = lead.otherObjectID { quote(other, object: o) }
            } actions: {
                Button("Add as task") { addTask(lead) }
                    .accessibilityIdentifier("case.drafts.lead.accept")
            }
        }
    }

    // MARK: - Interview plan

    @ViewBuilder private func interviewPlan(_ d: CaseDrafts) -> some View {
        header("Interview plan", count: interview?.questions.count)
        let people = d.cast.filter { $0.kind == .person && !$0.isOfficial }.map(\.name)
        HStack {
            Picker("Person", selection: $interviewee) {
                Text("Choose").tag("")
                ForEach(people, id: \.self) { Text($0).tag($0) }
            }
            .frame(maxWidth: 320)
            .accessibilityIdentifier("case.drafts.interview.person")
            Button("Draft questions") { Task { await draftInterview(useAI: false) } }
                .disabled(interviewee.isEmpty || running)
                .accessibilityIdentifier("case.drafts.interview.rules")
            if aiAvailable {
                Button("Draft questions with AI") { Task { await draftInterview(useAI: true) } }
                    .disabled(interviewee.isEmpty || running)
                    .accessibilityIdentifier("case.drafts.interview.ai")
            }
        }
        if let interviewSummary { Text(interviewSummary).font(.caption).foregroundStyle(.secondary) }
        if let iv = interview {
            if iv.questions.isEmpty { empty("No question could be grounded in a passage naming \(iv.person).") }
            ForEach(iv.questions) { q in
                card(id: q.id, provenance: q.provenance) {
                    Text(q.question).font(.callout.weight(.medium)).textSelection(.enabled)
                    quote(q.quote, object: q.objectID)
                    if let other = q.otherQuote, let o = q.otherObjectID { quote(other, object: o) }
                } actions: {
                    Button("Add to interview") { addQuestion(q) }
                        .accessibilityIdentifier("case.drafts.interview.accept")
                }
            }
        }
    }

    // MARK: - Shared rows

    private func header(_ title: String, count: Int?) -> some View {
        Text(count.map { "\(title) (\($0))" } ?? title).font(.headline).padding(.top, 10)
    }

    private func empty(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func card<Body: View, Actions: View>(id: String, provenance: CaseDraftProvenance,
                                                 @ViewBuilder content: () -> Body, @ViewBuilder actions: () -> Actions) -> some View {
        if status[id] != "Rejected" {
            VStack(alignment: .leading, spacing: 4) {
                content()
                HStack(spacing: 10) {
                    Text(provenance.label).font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    if let st = status[id] {
                        Text(st).font(.caption).foregroundStyle(st.hasPrefix("Added") ? Color.green : Color.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("case.drafts.status")
                    } else {
                        actions().disabled(closed || model.busy)
                        Button("Reject") { reject(id) }
                            .disabled(closed)
                            .accessibilityIdentifier("case.drafts.reject")
                    }
                }
            }
            .padding(10)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityIdentifier("case.drafts.item")
        }
    }

    private func quote(_ text: String, object: UUID) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\u{201C}\(text)\u{201D}").font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            Button { open(object, quote: text) } label: {
                Label(names[object].map { "Open source — \($0)" } ?? "Open source", systemImage: "doc.text.magnifyingglass").font(.caption)
            }
            .buttonStyle(.link)
            .accessibilityIdentifier("case.drafts.open")
        }
    }

    // MARK: - Drafting

    private func draft(useAI: Bool) async {
        guard let desk = appState.investigationContradictionGap else { return }
        running = true
        defer { running = false }
        do {
            let d = try await desk.buildDrafts(caseID: model.caseID, useAI: useAI)
            drafts = d
            status = [:]
            var text = "Read \(d.documents) document(s): \(d.timeline.count) chronology item(s), \(d.cast.count) in the cast, \(d.leads.count) open point(s)"
            if useAI {
                if d.calls + d.roleBatches > 0 {
                    text += ". AI reading: \(d.verified) proposal(s) checked out and are shown, \(d.agreedWithRules) matched the rules, \(d.dropped.count) did not check out and are not shown; \(d.roleReadings) role(s) confirmed; \(d.passagesSent) passage(s) sent in \(d.calls + d.roleBatches) request(s)"
                } else {
                    text += ". The AI reading did not run\(d.notSentReason.map { ": \($0)" } ?? "")"
                }
                if d.deniedForCloud > 0 { text += "; \(d.deniedForCloud) document(s) stayed on this Mac" }
                if !d.failures.isEmpty { text += "; \(d.failures.count) request(s) failed — " + Array(NSOrderedSet(array: d.failures).compactMap { $0 as? String }.prefix(3)).joined(separator: "; ") }
            }
            summary = text + "."
            let ids = Set(d.timeline.map(\.objectID) + d.leads.flatMap { [$0.objectID] + [$0.otherObjectID].compactMap { $0 } }
                          + d.cast.compactMap { $0.roleObjectID ?? $0.firstObjectID })
            if !ids.isEmpty, let repo = appState.objects { names = try await repo.sourceFilenames(for: ids) }
            try? await appState.caseFiles?.file.logAction(caseID: model.caseID, action: "drafts made", detail: summary, actor: model.actor)
        } catch {
            KalsmritikoshLog.ui.error("Case drafts failed: \(String(describing: error), privacy: .public)")
            summary = "The drafts could not be made: \(error.localizedDescription)"
        }
    }

    private func draftInterview(useAI: Bool) async {
        guard let desk = appState.investigationContradictionGap, !interviewee.isEmpty else { return }
        running = true
        defer { running = false }
        do {
            let iv = try await desk.draftInterview(caseID: model.caseID, person: interviewee, useAI: useAI)
            interview = iv
            var text = "\(iv.questions.count) question(s) for \(iv.person), each resting on a quoted passage"
            if useAI {
                text += iv.calls > 0
                    ? ". AI reading: \(iv.verified) checked out, \(iv.dropped.count) did not (leading, accusatory or not in the passage) and are not shown; \(iv.passagesSent) passage(s) sent"
                    : ". The AI reading did not run\(iv.notSentReason.map { ": \($0)" } ?? "")"
            }
            interviewSummary = text + "."
            let ids = Set(iv.questions.flatMap { [$0.objectID] + [$0.otherObjectID].compactMap { $0 } }).subtracting(names.keys)
            if !ids.isEmpty, let repo = appState.objects { names.merge(try await repo.sourceFilenames(for: ids)) { a, _ in a } }
        } catch {
            KalsmritikoshLog.ui.error("Interview plan failed: \(String(describing: error), privacy: .public)")
            interviewSummary = "The questions could not be drafted: \(error.localizedDescription)"
        }
    }

    // MARK: - Accept / reject (the case file's own write paths)

    /// Run an accepted item's write behind the case file's paid-action gate; the result is shown on the item.
    private func accept(_ id: String, done: String, _ body: @escaping (CaseFileService) async throws -> Void) {
        guard let svc = appState.caseFiles else { status[id] = "The ledger isn't ready yet; nothing was added."; return }
        guard PurchaseCenter.shared.allowPaidAction("edit the case file") else {
            status[id] = PaidUse.refusal("edit the case file")?.reason ?? "A subscription is needed to edit the case file."
            return
        }
        Task {
            do {
                try await body(svc)
                status[id] = done
            } catch {
                KalsmritikoshLog.ui.error("Accept draft: \(error.localizedDescription, privacy: .public)")
                status[id] = error.localizedDescription
            }
            await model.load(appState)
        }
    }

    private func reject(_ id: String) {
        status[id] = "Rejected"
        let caseID = model.caseID, actor = model.actor
        Task { try? await appState.caseFiles?.file.logAction(caseID: caseID, action: "draft rejected", detail: id, actor: actor) }
    }

    private func addToChronology(_ item: CaseDraftTimelineItem) {
        let caseID = model.caseID, actor = model.actor
        accept(item.id, done: "Added to the chronology, citing this passage") { svc in
            _ = try await PassageChronology.add(caseID: caseID, objectID: item.objectID, sourceVersionID: item.sourceVersionID, quote: item.quote,
                                                text: item.what, eventDate: item.localDate, caseFiles: svc, actor: actor)
        }
    }

    private func addPerson(_ m: CaseDraftCastMember) {
        let caseID = model.caseID, actor = model.actor
        let role: CasePersonRole = m.role == .defendant ? .subject : (m.role == .witness ? .witness : .other)
        var notes = "Role in the documents: \(m.roleLabel)"
        if let q = m.roleQuote { notes += " — \u{201C}\(q)\u{201D}" }
        if let o = m.roleObjectID, let n = names[o] { notes += " (\(n))" }
        let note = notes
        accept("cast:" + m.id, done: "Added to the case's people") { svc in
            let entity = await model.entityToLink(appState, name: m.name, contact: nil)   // N1 — one exact match only
            _ = try await svc.file.addPerson(caseID: caseID, name: m.name, role: role, entityID: entity, contact: nil, notes: note, actor: actor)
        }
    }

    private func addTask(_ lead: CaseDraftLead) {
        let caseID = model.caseID, ws = model.workspaceID, actor = model.actor
        var detail = "Records that would settle it: \(lead.records)\nBasis: \u{201C}\(lead.quote)\u{201D}"
        if let n = names[lead.objectID] { detail += " (\(n))" }
        if let other = lead.otherQuote { detail += "\nOther account: \u{201C}\(other)\u{201D}" }
        let text = detail
        accept(lead.id, done: "Added as a case task") { svc in
            _ = try await svc.addTask(caseID: caseID, workspaceID: ws, title: lead.taskTitle, detail: text, type: .evidenceRequest,
                                      assignee: actor, due: nil, actor: actor)
        }
    }

    /// The question goes into the person's open interview record (planned or scheduled), else a new one;
    /// a person not yet in the case is added first.
    private func addQuestion(_ q: CaseDraftQuestion) {
        let caseID = model.caseID, actor = model.actor
        let line = CaseDraftBuilder.interviewLine(q, source: names[q.objectID])
        let role: CasePersonRole = drafts?.cast.first { $0.name == q.person }?.role == .defendant ? .subject : .witness
        accept(q.id, done: "Added to the interview's questions") { svc in
            let people = try await svc.file.people(caseID: caseID)
            let personID: UUID
            if let p = people.first(where: { $0.name.caseInsensitiveCompare(q.person) == .orderedSame }) {
                personID = p.id
            } else {
                let entity = await model.entityToLink(appState, name: q.person, contact: nil)
                personID = try await svc.file.addPerson(caseID: caseID, name: q.person, role: role, entityID: entity, contact: nil, notes: nil, actor: actor)
            }
            if var iv = try await svc.file.interviews(caseID: caseID).first(where: { $0.personID == personID && [.planned, .scheduled].contains($0.status) }) {
                let existing = iv.questions ?? ""
                guard !existing.contains(q.question) else { return }
                iv.questions = existing.isEmpty ? line : existing + "\n" + line
                try await svc.file.updateInterview(iv, actor: actor)
            } else {
                _ = try await svc.file.addInterview(caseID: caseID, personID: personID, questions: line, actor: actor)
            }
        }
    }

    private func open(_ objectID: UUID, quote: String) {
        // SRC-01/SRC-08 — the cited version, or the passage labelled with why it cannot open.
        Task { @MainActor in
            switch await CitedSourceOpening.resolve(appState, objectID: objectID, quote: quote) {
            case .viewer(let target): openSource = target
            case .passage(let opened): openedPassage = opened
            }
        }
    }
}
