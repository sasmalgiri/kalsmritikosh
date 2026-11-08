//
//  CaseMapBriefPanel.swift
//  Kalsmritikosh
//
//  Smart-map S3 (BRIEF-01–BRIEF-08, MAP-08; plan §18 SM-01, SM-10). One panel, four parts, all working with AI off:
//  • Brief — the computed case or branch brief; every entry says why it is there and opens its record on the map
//    ("Show on map" reveals it wherever it is folded). "Set aside from the brief…" keeps the record and its evidence.
//  • Your brief — the investigator's structured brief in versions: write the next version, accept it; an accepted version
//    is never edited, and a brief written before later changes says so.
//  • Briefings — curated paths for a handover or review: add the selected record, the open branch, a saved view or a
//    note; open any step into the map; freeze one to keep the state of every step.
//  • Since you were here — what changed for you (unseen), what needs a review, work due and blocked work, and Resume.
//

import SwiftUI
import os

struct CaseMapBriefPanel: View {
    @Environment(AppState.self) private var appState
    let model: CaseFileModel
    let service: CaseMapService?
    let onDone: () -> Void

    enum Part: String, CaseIterable, Identifiable {
        case brief, yours, briefings, returning
        var id: String { rawValue }
        var title: String {
            switch self {
            case .brief: return "Brief"
            case .yours: return "Your brief"
            case .briefings: return "Briefings"
            case .returning: return "Since you were here"
            }
        }
    }
    @State private var part: Part = .brief
    @State private var ledger = CaseBriefLedger()
    @State private var error: String?
    @State private var notice: String?
    @State private var draft = CaseBriefText()
    @State private var settingAside: CaseMapBrief.Entry?
    @State private var asideReason = ""
    @State private var newBriefingTitle = ""
    @State private var noteText = ""
    @State private var pages: [String: Int] = [:]

    private var map: CaseMapWorkspaceModel { model.map }
    private var file: CaseFileRepository? { appState.caseFiles?.file }
    private var anchor: CaseMapNodeID { map.briefAnchor ?? CaseMapNodeID(caseID: model.caseID, kind: .caseFile, id: model.caseID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(map.briefAnchor == nil ? "Case brief" : "Branch brief", systemImage: "doc.richtext").font(.headline)
                InfoPopoverButton(topic: "task-case-map-brief")
                Spacer()
                if map.briefAnchor != nil { Button("Brief of the whole case") { map.briefAnchor = nil } }
                Button("Close") { onDone() }.keyboardShortcut(.cancelAction)
            }
            .padding(14)
            Picker("Part", selection: $part) { ForEach(Part.allCases) { Text($0.title).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().padding(.horizontal, 14)
            if let e = error { Label(e, systemImage: "xmark.octagon").foregroundStyle(.red).font(.caption).padding(.horizontal, 14).padding(.top, 6) }
            else if let n = notice { Label(n, systemImage: "info.circle").foregroundStyle(.secondary).font(.caption).padding(.horizontal, 14).padding(.top, 6) }
            Divider().padding(.top, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let p = map.liveProjection {
                        switch part {
                        case .brief: briefPart(p)
                        case .yours: yoursPart(p)
                        case .briefings: briefingsPart(p)
                        case .returning: returningPart(p)
                        }
                    } else {
                        Text("The case map has not been read yet, so there is nothing to brief from. Choose Refresh on the map.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 560, idealWidth: 680, maxWidth: 820, minHeight: 520)
        .task(id: model.caseID) { await reload() }
        .sheet(item: $settingAside) { e in asideSheet(e) }
    }

    private func reload() async {
        guard let file else { error = "The ledger isn't ready yet."; return }
        do { ledger = try await file.briefLedger(caseID: model.caseID); error = nil } catch {
            KalsmritikoshLog.ui.error("Briefs not read: \(error.localizedDescription, privacy: .public)")
            self.error = "The briefs could not be read: \(error.localizedDescription). Nothing is shown as if there were none."
        }
    }

    private func run(_ done: String, _ body: @escaping (CaseFileRepository) async throws -> Void) {
        guard let file else { error = "The ledger isn't ready yet; nothing was recorded."; return }
        guard PurchaseCenter.shared.allowPaidAction("edit the case file") else { return }
        Task {
            do { try await body(file); notice = done; error = nil } catch {
                KalsmritikoshLog.ui.error("Brief change not recorded: \(error.localizedDescription, privacy: .public)")
                self.error = "Not recorded: \(error.localizedDescription)"
            }
            await reload()
        }
    }

    /// Open a record on the map wherever it is (MAP-08): the panel closes and the item is revealed and selected.
    private func show(_ id: CaseMapNodeID) {
        onDone()
        _ = map.reveal(id)
    }

    // MARK: Brief (BRIEF-01/03/04/05)

    @ViewBuilder private func briefPart(_ p: CaseMapProjection) -> some View {
        let brief = CaseMapBrief.compute(p, anchor: map.briefAnchor, changed: map.changedRecords, setAside: ledger.setAside)
        if let purpose = brief.purpose {
            section("Purpose") { Text(purpose).font(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) }
        } else {
            section("Purpose") { Text("No question is recorded for this case yet.").font(.callout).foregroundStyle(.secondary) }
        }
        section("Scope") { ForEach(brief.scope, id: \.self) { Text($0).font(.caption).fixedSize(horizontal: false, vertical: true) } }
        section("Where the material stands (counts, not a measure of truth)") {
            ForEach(Array(brief.evidentialStates.enumerated()), id: \.offset) { _, s in
                HStack { Text(s.label).font(.caption); Spacer(); Text("\(s.count)").font(.caption.monospacedDigit()) }
            }
            Text("Work, kept apart from the evidence:").font(.caption.weight(.semibold)).padding(.top, 4)
            ForEach(Array(brief.workStates.enumerated()), id: \.offset) { _, s in
                HStack { Text(s.label).font(.caption); Spacer(); Text("\(s.count)").font(.caption.monospacedDigit()) }
            }
        }
        ForEach(brief.sections) { sec in
            section("\(sec.title) (\(sec.entries.count))") {
                if sec.entries.isEmpty { Text(sec.empty).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                let shown = Array(sec.entries.prefix(25 * (pages[sec.id] ?? 1)))
                ForEach(shown) { e in entryRow(e, setAsideAllowed: true) }
                if shown.count < sec.entries.count {
                    Button("Show \(min(25, sec.entries.count - shown.count)) more (\(sec.entries.count - shown.count) not shown yet)") {
                        pages[sec.id] = (pages[sec.id] ?? 1) + 1
                    }.buttonStyle(.borderless).font(.caption)
                }
            }
        }
        if !brief.setAside.isEmpty {
            section("Set aside from the brief by you (\(brief.setAside.count)) — still in the case") {
                ForEach(brief.setAside) { e in
                    HStack {
                        entryRow(e, setAsideAllowed: false)
                        if let r = ledger.relevance.first(where: { $0.isActive && $0.record == e.node }) {
                            Button("Bring back") { run("Brought back into the brief.") { try await $0.withdrawBriefRelevance(caseID: model.caseID, id: r.id, reason: "Brought back into the brief", actor: model.actor) } }
                                .controlSize(.small)
                        }
                    }
                }
            }
        }
    }

    private func entryRow(_ e: CaseMapBrief.Entry, setAsideAllowed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(e.text).font(.callout).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Show on map") { show(e.node) }.buttonStyle(.link).font(.caption)
                    .help("Opens this record on the map — out of a frame, a collapsed group or a folded branch if needed — and selects it.")
                if setAsideAllowed {
                    Button("Set aside from the brief…") { asideReason = ""; settingAside = e }.buttonStyle(.link).font(.caption)
                        .help("Leaves the record in the case with its evidence; only this brief stops listing it. You can bring it back.")
                }
            }
            Text("Why it is here: \(e.why)").font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Basis: \(e.basis)").font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(6)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 6))
    }

    private func asideSheet(_ e: CaseMapBrief.Entry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Set aside from the brief").font(.headline)
            Text("“\(e.text)” stays in the case with its sources and links; the brief stops listing it and shows it under “Set aside”.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Why it does not belong in the brief", text: $asideReason)
            HStack {
                Spacer()
                Button("Cancel") { settingAside = nil }.keyboardShortcut(.cancelAction)
                Button("Set aside") {
                    let why = asideReason, node = e.node
                    run("Set aside from the brief. The record is unchanged.") { try await $0.setBriefRelevance(caseID: model.caseID, record: node, decision: .setAside, reason: why, actor: model.actor) }
                    settingAside = nil
                }
                .disabled(reason: asideReason.trimmingCharacters(in: .whitespaces).isEmpty ? "Say why." : nil)
            }
        }
        .padding(16).frame(width: 440)
    }

    // MARK: Your brief (BRIEF-02 / BRIEF-06)

    @ViewBuilder private func yoursPart(_ p: CaseMapProjection) -> some View {
        let versions = ledger.versions(of: anchor)
        Text("Write the brief in your own words. Each save is a new version; accepting a version fixes it — later material never rewrites it, and it says when it was written before later changes.")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        section("Next version (\(versions.count + 1))") {
            field("Purpose", \.purpose)
            field("Current position", \.position)
            field("Unresolved", \.unresolved)
            field("Alternatives and contrary material", \.alternatives)
            field("Next work", \.nextWork)
            HStack {
                Button("Start from the latest version") {
                    if let v = versions.first { draft = CaseBriefText(purpose: v.purpose, position: v.position, unresolved: v.unresolved, alternatives: v.alternatives, nextWork: v.nextWork) }
                }
                .disabled(reason: versions.isEmpty ? "There is no earlier version yet." : nil)
                Spacer()
                Button("Save as a new version") {
                    let text = draft, expected = versions.first?.version ?? 0, a = anchor
                    run("Saved as version \(expected + 1) (a draft until you accept it).") { try await $0.writeBrief(caseID: model.caseID, anchor: a, text: text, expectedVersion: expected, actor: model.actor) }
                    draft = CaseBriefText()
                }
                .disabled(reason: draft.isEmpty ? "Write at least one part." : nil)
            }
            .controlSize(.small)
        }
        if versions.isEmpty {
            Text("No version written yet. The computed brief (Brief) works without one.").font(.caption).foregroundStyle(.secondary)
        }
        ForEach(versions) { v in
            section("Version \(v.version) — \(v.attribution)") {
                if ledger.isStale(v) {
                    Label("Written before later changes to the case. It is kept as written; read the Brief for what changed, and write a new version if needed.",
                          systemImage: "exclamationmark.arrow.triangle.2.circlepath").font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                ForEach([("Purpose", v.purpose), ("Current position", v.position), ("Unresolved", v.unresolved),
                         ("Alternatives and contrary material", v.alternatives), ("Next work", v.nextWork)], id: \.0) { title, text in
                    if let text { VStack(alignment: .leading, spacing: 1) { Text(title).font(.caption.weight(.semibold)); Text(text).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) } }
                }
                Text("Written \(v.writtenAt.formatted(date: .abbreviated, time: .shortened))" + (v.acceptedAt.map { " · accepted \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""))
                    .font(.caption2).foregroundStyle(.secondary)
                if !v.isAccepted {
                    Button("Accept this version") { run("Accepted. It will not be edited; a change is a new version.") { try await $0.acceptBrief(caseID: model.caseID, id: v.id, actor: model.actor) } }
                        .controlSize(.small)
                }
            }
        }
    }

    private func field(_ title: String, _ key: WritableKeyPath<CaseBriefText, String?>) -> some View {
        TextField(title, text: Binding(get: { draft[keyPath: key] ?? "" }, set: { draft[keyPath: key] = $0 }), axis: .vertical).lineLimit(1...4)
    }

    // MARK: Briefings (BRIEF-08)

    @ViewBuilder private func briefingsPart(_ p: CaseMapProjection) -> some View {
        Text("A briefing is a path through the case for a handover or a review. Its steps point at the case's own records, branches and saved views — nothing is copied. A live briefing shows what changed since each step was added; a frozen one keeps every step as it was when frozen.")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        HStack {
            TextField("New briefing title (e.g. Handover to Ben)", text: $newBriefingTitle)
            Button("Create briefing") {
                let t = newBriefingTitle
                run("Briefing created. Add steps to it.") { _ = try await $0.createBriefing(caseID: model.caseID, title: t, purpose: nil, actor: model.actor) }
                newBriefingTitle = ""
            }
            .disabled(reason: newBriefingTitle.trimmingCharacters(in: .whitespaces).isEmpty ? "Give it a title." : nil)
        }
        .controlSize(.small)
        ForEach(ledger.briefings.filter(\.isActive)) { b in briefingView(b, p) }
        let gone = ledger.briefings.filter { !$0.isActive }.count
        if gone > 0 { Text("\(gone) withdrawn briefing(s) are kept in the case record.").font(.caption2).foregroundStyle(.secondary) }
    }

    @ViewBuilder private func briefingView(_ b: CaseBriefing, _ p: CaseMapProjection) -> some View {
        let steps = CaseBriefings.steps(b, in: p) { id in map.savedViews.first { $0.id == id }?.name }
        section(b.title + (b.isFrozen ? " — frozen \(b.frozenAt?.formatted(date: .abbreviated, time: .shortened) ?? "")" : " — live")) {
            if let problem = b.frozenProblem { Label(problem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
            if steps.isEmpty { Text("No steps yet.").font(.caption).foregroundStyle(.secondary) }
            ForEach(Array(steps.enumerated()), id: \.element.id) { i, step in
                HStack(alignment: .firstTextBaseline) {
                    Text("\(i + 1).").font(.caption.monospacedDigit())
                    VStack(alignment: .leading, spacing: 1) {
                        Text(step.title).font(.callout).lineLimit(2)
                        if !step.state.isEmpty { Text(step.state).font(.caption2).foregroundStyle(.secondary).lineLimit(2) }
                        if let c = step.change { Label(c, systemImage: "arrow.triangle.2.circlepath").font(.caption2).foregroundStyle(.orange) }
                    }
                    Spacer()
                    openButton(step)
                    if !b.isFrozen {
                        Button("Remove") { let id = step.id; run("Step removed (kept in the case record).") { try await $0.removeBriefingItem(caseID: model.caseID, itemID: id, actor: model.actor) } }
                            .buttonStyle(.borderless).font(.caption)
                    }
                }
            }
            if !b.isFrozen {
                HStack {
                    Menu("Add step") {
                        if case .node(let id)? = map.selection, let n = p.node(id) {
                            Button("The selected item: \(String(n.title.prefix(40)))") {
                                let rev = n.revision
                                run("Step added.") { _ = try await $0.addBriefingItem(caseID: model.caseID, briefingID: b.id, kind: .record, record: id, revision: rev, actor: model.actor) }
                            }
                        }
                        if let a = map.frameStack.last?.anchor, let n = p.node(a) {
                            Button("The open branch: \(String(n.title.prefix(40)))") {
                                let rev = n.revision
                                run("Step added.") { _ = try await $0.addBriefingItem(caseID: model.caseID, briefingID: b.id, kind: .frame, record: a, revision: rev, actor: model.actor) }
                            }
                        }
                        ForEach(map.savedViews) { v in
                            Button("Saved view: \(v.name)") { run("Step added.") { _ = try await $0.addBriefingItem(caseID: model.caseID, briefingID: b.id, kind: .savedView, viewID: v.id, actor: model.actor) } }
                        }
                    }
                    .fixedSize()
                    TextField("Or a note for the reader", text: $noteText)
                    Button("Add note") {
                        let t = noteText
                        run("Note added.") { _ = try await $0.addBriefingItem(caseID: model.caseID, briefingID: b.id, kind: .note, note: t, actor: model.actor) }
                        noteText = ""
                    }
                    .disabled(reason: noteText.trimmingCharacters(in: .whitespaces).isEmpty ? "Write the note." : nil)
                }
                .controlSize(.small)
                Button("Freeze this briefing") {
                    guard let load = map.current else { error = "The map has not been read yet."; return }
                    let proj = p, fence = load.fence
                    run("Frozen: every step is kept as it is now.") { try await $0.freezeBriefing(caseID: model.caseID, briefingID: b.id, projection: proj, fence: fence, actor: model.actor) }
                }
                .controlSize(.small)
                .help("Records the state of every step now. A frozen briefing never changes; its steps still open into the live map.")
            }
        }
    }

    @ViewBuilder private func openButton(_ step: CaseBriefings.Step) -> some View {
        switch step.kind {
        case .record:
            if let r = step.record, !step.missing { Button("Show on map") { show(r) }.buttonStyle(.link).font(.caption) }
        case .frame:
            if let r = step.record, !step.missing {
                Button("Open branch") { onDone(); Task { await map.openFrame(r, service: service) } }.buttonStyle(.link).font(.caption)
            }
        case .savedView:
            if let v = step.viewID, !step.missing { Button("Open view") { onDone(); map.go(to: .saved(v)); Task { await map.syncFramePlacements(service) } }.buttonStyle(.link).font(.caption) }
        case .note:
            EmptyView()
        }
    }

    // MARK: Since you were here (BRIEF-07)

    @ViewBuilder private func returningPart(_ p: CaseMapProjection) -> some View {
        let r = CaseReturnView.compute(p, feed: map.feed, memory: model.workspace.state.map)
        if let problem = r.feedProblem { Label(problem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
        if let sel = r.resumeSelection, let n = p.node(sel) {
            HStack {
                Text("You were at: \(n.title)" + (r.resumeFrames.isEmpty ? "" : " (inside \(r.resumeFrames.count) frame(s))")).font(.callout).lineLimit(2)
                Spacer()
                Button("Resume") { onDone(); _ = map.reveal(sel) }.controlSize(.small)
            }
        }
        list("New to you — not marked as seen (\(r.unseen.count))", r.unseen,
             empty: "Nothing new since you last marked the changes as seen. Seeing a change is not reviewing it.")
        list("Waiting for a review decision (\(r.reviewRequired.count))", r.reviewRequired, empty: "Nothing is waiting for a review decision.")
        list("Work due or overdue (\(r.due.count))", r.due, empty: "No open work is due in the next 7 days.")
        list("Blocked work (\(r.blocked.count))", r.blocked, empty: "No open work is blocked or waiting for other open work.")
    }

    private func list(_ title: String, _ entries: [CaseMapBrief.Entry], empty: String) -> some View {
        section(title) {
            if entries.isEmpty { Text(empty).font(.caption).foregroundStyle(.secondary) }
            ForEach(entries.prefix(50)) { e in entryRow(e, setAsideAllowed: false) }
            if entries.count > 50 { Text("and \(entries.count - 50) more — the Brief lists them all.").font(.caption2).foregroundStyle(.secondary) }
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold))
            content()
        }
    }
}
