//
//  CaseTeamSwarmSection.swift
//  Kalsmritikosh
//
//  Speed PERF-40 torrent (owner 2026-11-23) — not tested yet. Case tools ▸ Team folder ▸ "Share the work of this import
//  with the team": the per-case opt-in (every member sees who has it on), a button to start a shared import of files
//  already in the team folder, and the progress (pieces done by this Mac / by others).
//

import SwiftUI
import AppKit
import os

struct CaseTeamSwarmSection: View {
    @Environment(AppState.self) private var appState
    let caseID: UUID
    let actor: String
    let link: CaseTeamLink
    @State private var enabled = false
    @State private var progress: [CaseTeamSwarmProgress] = []
    @State private var members: [(name: String, on: Bool)] = []
    @State private var notice: String?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Text("Share the work of a big import").font(.headline)
            Text(Self.explainer).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            toggle
            if !members.isEmpty { memberLine }
            if enabled { actions }
            if let notice { Text(notice).font(.callout).fixedSize(horizontal: false, vertical: true) }
            ForEach(progress) { p in progressRow(p) }
        }
        .task { await load() }
    }

    static let explainer = "When this is on, a big import of files that are already in the team folder is cut into pieces. Each Mac of the team that has this on reads some pieces and puts them back in the folder, locked so only the folder's members can open them and signed by the Mac that read them. Every Mac then adds all the pieces to its own archive. Nothing goes anywhere except the team folder."

    private var toggle: some View {
        Toggle("Share the work of this import with the team", isOn: Binding(get: { enabled }, set: { v in Task { await set(v) } }))
            .disabled(working)
            .accessibilityIdentifier("case.teamfolder.swarm.toggle")
    }

    private var memberLine: some View {
        let on = members.filter(\.on).map(\.name)
        let text: String = on.isEmpty ? "No member shares the work yet." : "Sharing the work: \(on.joined(separator: ", "))."
        return Text(text).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private var actions: some View {
        HStack {
            Button("Import files from the team folder with the team…") { pick() }
                .caseMapControlHelp("Import files from the team folder with the team…")
            Button("Check shared imports now") { Task { await pass() } }
                .controlSize(.small)
                .caseMapControlHelp("Check shared imports now")
        }
        .disabled(working)
    }

    private func progressRow(_ p: CaseTeamSwarmProgress) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            ProgressView(value: Double(p.doneByMe + p.doneByOthers), total: Double(max(1, p.pieces)))
            Text(p.line).font(.caption2).foregroundStyle(p.lastError == nil ? Color.secondary : Color.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Actions

    private func load() async {
        guard let file = appState.caseFiles?.file else { return }
        do {
            enabled = try await file.swarmOptIn(caseID: caseID, linkID: link.id)?.enabled ?? false
            progress = try await file.swarmProgress(caseID: caseID).filter { $0.linkID == link.id }
        } catch {
            KalsmritikoshLog.ui.error("Shared import state not read: \(error.localizedDescription, privacy: .public)")
        }
        let l = link
        members = await Task.detached(priority: .utility) { () -> [(name: String, on: Bool)] in
            guard let (folder, _, release) = AppState.openSwarmFolder(l) else { return [] }
            defer { release() }
            return folder.optIns(in: folder.verifiedEntries().entries).map { (name: $0.name, on: $0.on) }
        }.value
    }

    private func set(_ on: Bool) async {
        working = true
        notice = await appState.setTeamSwarm(caseID: caseID, linkID: link.id, enabled: on, actor: actor)
        working = false
        await load()
    }

    private func pass() async {
        working = true
        notice = await appState.runTeamSwarmPass(caseID: caseID, linkID: link.id, actor: actor).summary
        working = false
        await load()
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Choose files or a folder inside the team folder. Only files already in the team folder can be shared out."
        if let (url, scoped) = CaseTeamService.resolve(link.bookmark) {
            panel.directoryURL = url
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let urls = panel.urls
        let title = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items"
        Task {
            working = true
            let scopes = urls.map { $0.startAccessingSecurityScopedResource() }
            notice = await appState.startTeamSwarmImport(caseID: caseID, linkID: link.id, roots: urls, title: title, actor: actor)
            for (u, s) in zip(urls, scopes) where s { u.stopAccessingSecurityScopedResource() }
            working = false
            await load()
        }
    }
}
