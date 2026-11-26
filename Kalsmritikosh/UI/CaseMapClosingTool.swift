//
//  CaseMapClosingTool.swift
//  Kalsmritikosh
//
//  Reachability recheck 2026-11-17 (QA-16) — one screen for what happens around a closure, whose services had none:
//  • OUTPUT-09: the position recorded at each closure (disposition, who authorised it, the work waived with its reason,
//    what stays unresolved), fixed once recorded; reopening never erases it.
//  • CHANGE-07: material that arrives while the case is closed waits in a queue — nothing is added to the closed case —
//    until a person admits it (after reopening), declines it with a reason, or asks for the case to be reopened.
//  • ACTION-12: finished work checked against newer evidence: each proposal names the work and why, and a person reopens
//    it, replaces it with a new action, or dismisses it with a reason; the same unchanged issue is proposed only once.
//  Close and reopen themselves stay in Case sections ▸ Overview.
//

import SwiftUI
import os

struct CaseMapClosingTool: View {
    @Environment(AppState.self) private var appState
    let caseID: UUID
    let actor: String
    let service: CaseMapService?
    var open: ((CaseMapNodeID) -> Void)?
    @State private var state: CaseToolState = .loading
    @State private var positions: [CaseClosurePosition] = []
    @State private var late: [CaseLateContribution] = []
    @State private var proposals: [CaseReopenProposal] = []
    @State private var notice: String?
    @State private var reason = ""
    // Closure position
    @State private var disposition = ""
    @State private var authorizedBy = ""
    @State private var waived = ""
    @State private var unresolved = ""
    // Late material
    @State private var lateKind: CaseLateContributionKind = .document
    @State private var lateDescription = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CaseToolStateView(state: state)
            if let notice { Text(notice).font(.callout).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("case.closing.notice") }
            TextField("Reason (needed for every decision below)", text: $reason).textFieldStyle(.roundedBorder)

            Text("Position at each closure").font(.headline)
            if positions.isEmpty, state == .ready {
                CaseToolStateView(state: .empty(what: "No closure position is recorded.", next: "Close the case in Case sections ▸ Overview, then record its position here."))
            }
            ForEach(positions, id: \.id) { p in
                VStack(alignment: .leading, spacing: 2) {
                    Text("Closure \(p.closureSequence): \(p.disposition) — authorised by \(p.dispositionAuthorizedBy) (recorded by \(p.recordedBy), \(p.recordedAt.formatted(date: .abbreviated, time: .shortened)))")
                        .font(.caption).fixedSize(horizontal: false, vertical: true)
                    ForEach(p.waived, id: \.item) { w in Text("Waived: \(w.item) — \(w.reason)").font(.caption2) }
                    ForEach(p.unresolved, id: \.self) { Text("Unresolved: \($0)").font(.caption2) }
                }
                .padding(6).background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            }
            TextField("Disposition (e.g. Closed — not substantiated)", text: $disposition).textFieldStyle(.roundedBorder)
            TextField("Authorised by", text: $authorizedBy).textFieldStyle(.roundedBorder)
            TextField("Waived work, one per line as: item — reason", text: $waived, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(2...4)
            TextField("Unresolved items, one per line", text: $unresolved, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(2...4)
            Button("Record closure position") { Task { await recordPosition() } }.caseMapControlHelp("Record closure position")
                .disabled(reason: disposition.trimmingCharacters(in: .whitespaces).isEmpty || authorizedBy.trimmingCharacters(in: .whitespaces).isEmpty
                          ? "The disposition and who authorised it are needed." : nil)

            Divider()
            Text("Material that arrived after closure").font(.headline)
            if late.isEmpty, state == .ready { Text("Nothing is waiting.").font(.caption).foregroundStyle(.secondary) }
            ForEach(late) { c in
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(c.kind.rawValue.capitalized): \(c.description) — from \(c.contributedBy), \(c.receivedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).fixedSize(horizontal: false, vertical: true)
                    Text(c.state.label + (c.decisionReason.map { " — \($0)" } ?? "")).font(.caption2).foregroundStyle(.secondary)
                    if c.state == .queued || c.state == .reopenRequested {
                        HStack {
                            Button("Admit material") { Task { await decideLate(c.id, .admit) } }.caseMapControlHelp("Admit material")
                            Button("Decline material") { Task { await decideLate(c.id, .decline) } }.caseMapControlHelp("Decline material")
                            if c.state == .queued { Button("Ask to reopen") { Task { await decideLate(c.id, .requestReopen) } }.caseMapControlHelp("Ask to reopen") }
                        }
                        .controlSize(.small)
                        .disabled(reason: reason.trimmingCharacters(in: .whitespaces).isEmpty ? "A reason is needed." : nil, remedy: "Type the reason at the top.")
                    }
                }
            }
            HStack {
                Picker("Kind", selection: $lateKind) { ForEach(CaseLateContributionKind.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }.frame(maxWidth: 180)
                TextField("What arrived (e.g. the bank's reply of 4 May)", text: $lateDescription).textFieldStyle(.roundedBorder)
                Button("Record late material") { Task { await queueLate() } }.caseMapControlHelp("Record late material")
                    .disabled(reason: lateDescription.trimmingCharacters(in: .whitespaces).isEmpty ? "Say what arrived." : nil)
            }

            Divider()
            Text("Finished work and newer evidence").font(.headline)
            Button("Check finished work against newer evidence") { Task { await propose() } }.caseMapControlHelp("Check finished work against newer evidence")
            let pending = proposals.filter { $0.state == .pending }
            if pending.isEmpty, state == .ready { Text("No finished work waits for a decision.").font(.caption).foregroundStyle(.secondary) }
            ForEach(pending) { p in
                VStack(alignment: .leading, spacing: 3) {
                    Text(p.explanation).font(.caption).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        if let open { Button("Show on map") { open(CaseMapNodeID(caseID: caseID, kind: .task, id: p.taskID)) }.buttonStyle(.link) }
                        Button("Reopen the work") { Task { await decideReopen(p.id, .reopen) } }.caseMapControlHelp("Reopen the work")
                        Button("Replace with a new action") { Task { await decideReopen(p.id, .supersede) } }.caseMapControlHelp("Replace with a new action")
                        Button("Dismiss reopening") { Task { await decideReopen(p.id, .dismiss) } }.caseMapControlHelp("Dismiss reopening")
                    }
                    .controlSize(.small)
                    .disabled(reason: reason.trimmingCharacters(in: .whitespaces).isEmpty ? "A reason is needed." : nil, remedy: "Type the reason at the top.")
                }
                .padding(6).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }
            let decided = proposals.filter { $0.state != .pending }
            if !decided.isEmpty {
                DisclosureGroup("Decided (\(decided.count))") {
                    ForEach(decided) { p in Text("\(p.state.rawValue.capitalized): \(p.explanation)" + (p.decisionReason.map { " — \($0)" } ?? "")).font(.caption2) }
                }
            }
        }
        .task { await load() }
    }

    /// "item — reason" lines → waived work (a line without a reason is refused by the form, not guessed).
    static func waivedWork(_ text: String) -> [CaseWaivedWork]? {
        var out: [CaseWaivedWork] = []
        for line in text.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }) where !line.isEmpty {
            let parts = line.components(separatedBy: " — ")
            guard parts.count >= 2, !parts[0].isEmpty, !parts[1...].joined(separator: " — ").isEmpty else { return nil }
            out.append(CaseWaivedWork(item: parts[0], reason: parts[1...].joined(separator: " — ")))
        }
        return out
    }

    private var history: CaseHistoryService? {
        guard let db = appState.database, let map = service ?? CaseMapServiceFactory.map(appState) else { return nil }
        return CaseHistoryService(database: db, map: map)
    }

    private func load() async {
        guard let file = appState.caseFiles?.file, let history else {
            state = .failed(reason: "the ledger isn't open yet.", next: "Wait for the case to finish opening, then reopen Case tools."); return
        }
        do {
            positions = try await history.closurePositions(caseID: caseID)
            late = try await file.lateContributions(caseID: caseID)
            proposals = try await file.reopenProposals(caseID: caseID)
            state = .ready
        } catch { KalsmritikoshLog.ui.error("Closing tool: \(error.localizedDescription, privacy: .public)"); state = .from(error, doing: "reading closures") }
    }
    private func fail(_ error: Error, _ doing: String) {
        KalsmritikoshLog.ui.error("Closing tool, \(doing, privacy: .public): \(error.localizedDescription, privacy: .public)")
        state = .from(error, doing: doing)
    }

    private func recordPosition() async {
        guard let history else { return }
        guard let w = Self.waivedWork(waived) else { notice = "Write each waived item as: item — reason."; return }
        let open = unresolved.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        do {
            let p = try await history.recordClosurePosition(caseID: caseID, disposition: disposition, authorizedBy: authorizedBy, waived: w, unresolved: open, actor: actor)
            notice = "Closure \(p.closureSequence)'s position is recorded and fixed."
            disposition = ""; authorizedBy = ""; waived = ""; unresolved = ""
            await load()
        } catch { fail(error, "recording closure positions") }
    }
    private func queueLate() async {
        guard let file = appState.caseFiles?.file else { return }
        do {
            _ = try await file.queueLateContribution(caseID: caseID, kind: lateKind, sourceRef: nil, description: lateDescription, contributedBy: actor)
            notice = "Recorded as waiting; nothing was added to the case."; lateDescription = ""
            await load()
        } catch { fail(error, "recording late material") }
    }
    private func decideLate(_ id: UUID, _ d: CaseLateContribution.Decision) async {
        guard let file = appState.caseFiles?.file else { return }
        do { try await file.decideLateContribution(caseID: caseID, id: id, decision: d, reason: reason, actor: actor); reason = ""; notice = "Decision recorded."; await load() }
        catch { fail(error, "deciding late material") }
    }
    private func propose() async {
        guard let file = appState.caseFiles?.file else { return }
        do { let n = try await file.proposeReopenings(caseID: caseID).count; notice = n == 0 ? "No finished work is affected by newer evidence." : "\(n) new proposal(s) to decide."; await load() }
        catch { fail(error, "checking finished work") }
    }
    private func decideReopen(_ id: UUID, _ d: CaseReopenProposal.Decision) async {
        guard let svc = appState.caseFiles else { return }
        do { _ = try await svc.decideReopening(caseID: caseID, proposalID: id, d, reason: reason, actor: actor); reason = ""; notice = "Decision recorded."; await load() }
        catch { fail(error, "deciding reopenings") }
    }
}
