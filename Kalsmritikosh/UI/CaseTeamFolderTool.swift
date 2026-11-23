//
//  CaseTeamFolderTool.swift
//  Kalsmritikosh
//
//  Case tools ▸ Team folder (v198; owner decision 2026-11-18: team work over a shared folder, no server, no accounts),
//  and the contributor's sheet, which needs no case. Every line says whether a thing is only on this Mac or already in
//  the folder; nothing is shown as seen by the team before it is there.
//

import SwiftUI
import UniformTypeIdentifiers
import CryptoKit
import os

struct CaseTeamFolderTool: View {
    @Environment(AppState.self) private var appState
    let caseID: UUID
    let actor: String
    @State private var state: CaseToolState = .loading
    @State private var links: [CaseTeamLink] = []
    @State private var requests: [CaseTeamRequest] = []
    @State private var submissions: [CaseTeamSubmission] = []
    @State private var records: [CaseTeamRecord] = []
    @State private var conflicts: [CaseTeamConflict] = []
    @State private var members: [UUID: [TeamMember]] = [:]
    @State private var notice: String?
    // Linking
    @State private var picking: PickTarget?
    @State private var newPurpose: TeamFolderPurpose = .contribution
    @State private var displayName = ""
    // A request
    @State private var reqTitle = ""
    @State private var reqDeliverable = ""
    @State private var reqRecipient = "anyone"
    @State private var reqDue = ""
    @State private var reqInputs: [URL] = []
    @State private var declineReason = ""
    // Shared work
    @State private var workLabel = ""
    @State private var workAssignee = ""
    @State private var workNote = ""
    @State private var contributing = false

    enum PickTarget: Identifiable { case create, join, inputs; var id: Int { hashValue } }

    private var key: Curve25519.Signing.PrivateKey? { TeamIdentity.key() }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CaseToolStateView(state: state)
            if let notice { Text(notice).font(.callout).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("case.teamfolder.notice") }
            Text("Shared folders").font(.headline)
            Text("A folder everyone can reach — a file share, an external disk or a synced folder. Each Mac signs what it writes there. Whoever can open the folder can read it; a contribution folder holds only requests and what comes back, never the case.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if links.isEmpty, state == .ready {
                CaseToolStateView(state: .empty(what: "This case works through no shared folder.",
                                                next: "Create a team folder (or join one someone made) below."))
            }
            ForEach(links) { l in linkRow(l) }
            HStack {
                TextField("Your name in the folder", text: $displayName).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                Picker("Kind", selection: $newPurpose) {
                    Text("Contribution folder").tag(TeamFolderPurpose.contribution)
                    Text("Team folder").tag(TeamFolderPurpose.team)
                }.frame(maxWidth: 220)
                Button("Create a team folder…") { picking = .create }.caseMapControlHelp("Create a team folder…")
                    .disabled(reason: displayName.trimmingCharacters(in: .whitespaces).isEmpty ? "Your name in the folder is needed." : nil, remedy: "Type the name others will see.")
                Button("Join a team folder…") { picking = .join }.caseMapControlHelp("Join a team folder…")
                    .disabled(reason: displayName.trimmingCharacters(in: .whitespaces).isEmpty ? "Your name in the folder is needed." : nil, remedy: "Type the name others will see.")
            }
            Button("Contribute to a team folder…") { contributing = true }.caseMapControlHelp("Contribute to a team folder…")
            if let l = links.first { requestForm(l); workForm(l) }
            // Speed PERF-40 torrent (owner 2026-11-23) — not tested yet: sharing the work of a big import with the team.
            if let l = links.first(where: { $0.purpose == "team" }) { CaseTeamSwarmSection(caseID: caseID, actor: actor, link: l) }
            if !requests.isEmpty { requestList }
            if !submissions.isEmpty { submissionList }
            if !conflicts.filter({ $0.resolvedAt == nil }).isEmpty { conflictList }
            if !records.isEmpty { recordList }
        }
        .task { await load() }
        // One picker for both (a second file importer on the same view is not shown on macOS).
        .fileImporter(isPresented: Binding(get: { picking != nil }, set: { if !$0 { picking = nil } }),
                      allowedContentTypes: picking == .inputs ? [.item] : [.folder], allowsMultipleSelection: picking == .inputs) { result in
            let target = picking
            picking = nil
            guard case .success(let urls) = result else { return }
            switch target {
            case .inputs: reqInputs = urls
            case .create, .join: if let url = urls.first { Task { await link(url, create: target == .create) } }
            case nil: break
            }
        }
        .sheet(isPresented: $contributing) { TeamContributeSheet(close: { contributing = false }) }
    }

    @ViewBuilder private func linkRow(_ l: CaseTeamLink) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Label("\(l.folderLabel) — \(l.purpose == "team" ? "team folder" : "contribution folder"), as \(l.displayName)", systemImage: "folder")
                    .font(.callout)
                Spacer()
                Button("Read the team folder now") { Task { await read(l) } }.controlSize(.small).caseMapControlHelp("Read the team folder now")
                Button("Unlink this folder") { Task { await unlink(l) } }.controlSize(.small).caseMapControlHelp("Unlink this folder")
            }
            Text(Self.readLine(l)).font(.caption2).foregroundStyle(l.lastError == nil ? Color.secondary : Color.orange).fixedSize(horizontal: false, vertical: true)
        }
    }

    static func readLine(_ l: CaseTeamLink) -> String {
        if let e = l.lastError { return "Last read failed: \(e). Nothing changed in the case; it is read again when the folder is back." }
        guard let at = l.lastReadAt else { return "Not read yet." }
        return "Last read \(at.formatted(date: .abbreviated, time: .shortened))."
    }

    @ViewBuilder private func requestForm(_ l: CaseTeamLink) -> some View {
        Divider()
        Text("Ask for a contribution").font(.headline)
        TextField("What it is (a short title)", text: $reqTitle).textFieldStyle(.roundedBorder)
        TextField("What is wanted, exactly", text: $reqDeliverable).textFieldStyle(.roundedBorder)
        HStack {
            Picker("For", selection: $reqRecipient) {
                Text("Any member of the folder").tag("anyone")
                ForEach((members[l.id] ?? []).filter { $0.id != l.memberID }, id: \.id) { m in Text(m.name).tag(m.id) }
            }.frame(maxWidth: 300)
            TextField("Wanted by (optional, e.g. 25 November)", text: $reqDue).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
        }
        HStack {
            Button(reqInputs.isEmpty ? "Share files with it…" : "\(reqInputs.count) file(s) to share") { picking = .inputs }.caseMapControlHelp("Share files with it…")
            Button("Publish request") { Task { await publish(l) } }.caseMapControlHelp("Publish request")
                .disabled(reason: reqTitle.trimmingCharacters(in: .whitespaces).isEmpty || reqDeliverable.trimmingCharacters(in: .whitespaces).isEmpty
                          ? "A title and what is wanted are needed." : nil, remedy: "Type both above.")
        }
    }

    @ViewBuilder private func workForm(_ l: CaseTeamLink) -> some View {
        if l.purpose == "team" {
            Divider()
            Text("Share an assignment with the team").font(.headline)
            HStack {
                TextField("The work", text: $workLabel).textFieldStyle(.roundedBorder)
                TextField("Who does it", text: $workAssignee).textFieldStyle(.roundedBorder).frame(maxWidth: 180)
                TextField("Note", text: $workNote).textFieldStyle(.roundedBorder).frame(maxWidth: 200)
                Button("Share assignment") { Task { await shareAssignment(l, teamRecordID: nil) } }.caseMapControlHelp("Share assignment")
                    .disabled(reason: workLabel.trimmingCharacters(in: .whitespaces).isEmpty || workAssignee.trimmingCharacters(in: .whitespaces).isEmpty
                              ? "The work and who does it are needed." : nil, remedy: "Type both.")
            }
        }
    }

    @ViewBuilder private var requestList: some View {
        Divider()
        Text("Requests").font(.headline)
        ForEach(requests) { r in
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(r.title) — \(r.deliverable)").font(.callout).fixedSize(horizontal: false, vertical: true)
                    Text(Self.requestLine(r)).font(.caption2).foregroundStyle(r.state == "error" ? Color.orange : Color.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if !r.isWithdrawn {
                    Button("Withdraw request…") { Task { await withdraw(r) } }.controlSize(.small).caseMapControlHelp("Withdraw request…")
                        .disabled(reason: declineReason.trimmingCharacters(in: .whitespaces).isEmpty ? "A reason is needed." : nil, remedy: "Type it in the reason field below.")
                }
            }
        }
    }

    static func requestLine(_ r: CaseTeamRequest) -> String {
        let due: String = r.due.map { ", wanted by \($0)" } ?? ""
        let to: String = r.recipient == "anyone" ? "any member" : "one member"
        return "For \(to)\(due). \(r.stateLine)."
    }

    @ViewBuilder private var submissionList: some View {
        Divider()
        Text("What came back").font(.headline)
        TextField("Reason (to decline a submission or withdraw a request)", text: $declineReason).textFieldStyle(.roundedBorder)
        ForEach(submissions) { s in
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(Self.submissionLine(s, title: requests.first { $0.id == s.requestID }?.title)).font(.callout).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if s.decidedAt == nil {
                        Button("Include in the case") { Task { await decide(s, include: true) } }.controlSize(.small).caseMapControlHelp("Include in the case")
                        Button("Decline…") { Task { await decide(s, include: false) } }.controlSize(.small).caseMapControlHelp("Decline…")
                            .disabled(reason: declineReason.trimmingCharacters(in: .whitespaces).isEmpty ? "A reason is needed." : nil, remedy: "Type it in the reason field above.")
                    }
                }
                ForEach(s.files, id: \.sha256) { f in
                    Text(Self.fileLine(f)).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    static func submissionLine(_ s: CaseTeamSubmission, title: String?) -> String {
        let forWhat: String = title.map { " for “\($0)”" } ?? ""
        var line = "\(s.submitterName)\(forWhat): \(s.outcomeLine)"
        if let n = s.note { line += " — “\(n)”" }
        switch s.receiptState {
        case "written": line += ". Receipt in the folder."
        case "error": line += ". Receipt not yet in the folder (\(s.receiptDetail ?? "not written")); tried again on the next read."
        case "pending": line += ". Receipt waiting to be written."
        default: break
        }
        return line
    }

    static func fileLine(_ f: CaseTeamSubmissionFile) -> String {
        let size: String = ByteCountFormatter.string(fromByteCount: Int64(f.bytes), countStyle: .file)
        let status: String
        switch f.status {
        case "received": status = "taken into the case"
        case "duplicate": status = "the same file was already received; not read again"
        case "failed": status = "not taken in — \(f.detail ?? "it could not be read")"
        case "declined": status = "declined"
        default: status = "waiting"
        }
        return "• \(f.name) (\(size)): \(status)"
    }

    @ViewBuilder private var conflictList: some View {
        Divider()
        Text("Conflicting edits").font(.headline)
        ForEach(conflicts.filter { $0.resolvedAt == nil }) { c in
            VStack(alignment: .leading, spacing: 2) {
                Text("\(c.label): two people changed it from the same version.").font(.callout)
                Text("Yours (\(c.localAuthor)): \(Self.describe(c.localPayload))").font(.caption)
                Text("Theirs (\(c.remoteAuthor)): \(Self.describe(c.remotePayload))").font(.caption)
                HStack {
                    Button("Keep mine") { Task { await resolve(c, keepOurs: true) } }.controlSize(.small).caseMapControlHelp("Keep mine")
                    Button("Take theirs") { Task { await resolve(c, keepOurs: false) } }.controlSize(.small).caseMapControlHelp("Take theirs")
                }
            }
        }
    }

    @ViewBuilder private var recordList: some View {
        Divider()
        Text("Shared work").font(.headline)
        ForEach(records) { r in
            VStack(alignment: .leading, spacing: 1) {
                Text("\(r.kind.label): \(r.label) — \(Self.describe(r.payload))").font(.callout).fixedSize(horizontal: false, vertical: true)
                Text(r.stateLine).font(.caption2).foregroundStyle(r.state == "error" || r.state == "pending" ? Color.orange : Color.secondary)
            }
        }
    }

    static func describe(_ p: [String: String]) -> String {
        let order = ["assignee", "review", "outcome", "note", "comment"]
        let names = ["assignee": "who", "review": "review", "outcome": "outcome", "note": "note", "comment": "comment"]
        let parts: [String] = order.compactMap { k in p[k].map { "\(names[k] ?? k): \($0)" } }
        return parts.isEmpty ? "(nothing recorded)" : parts.joined(separator: "; ")
    }

    // MARK: Actions

    private func load() async {
        guard let file = appState.caseFiles?.file else { state = .failed(reason: "the ledger isn't open.", next: "Open the case again."); return }
        do {
            links = try await file.teamLinks(caseID: caseID)
            requests = try await file.teamRequests(caseID: caseID)
            submissions = try await file.teamSubmissions(caseID: caseID)
            records = try await file.teamRecords(caseID: caseID)
            conflicts = try await file.teamConflicts(caseID: caseID)
            var m: [UUID: [TeamMember]] = [:]
            for l in links {
                if let (url, scoped) = CaseTeamService.resolve(l.bookmark) {
                    m[l.id] = TeamCase.open(url)?.members() ?? []
                    if scoped { url.stopAccessingSecurityScopedResource() }
                }
            }
            members = m
            state = .ready
        } catch {
            KalsmritikoshLog.ui.error("Team folder tool failed to load: \(error.localizedDescription, privacy: .public)")
            state = .from(error, doing: "reading the team folder")
        }
    }

    private func run(_ what: String, _ body: (CaseTeamService, Curve25519.Signing.PrivateKey) async throws -> String?) async {
        guard let team = appState.caseTeam else { notice = "The ledger isn't open."; return }
        guard let key else { notice = "This Mac's team key could not be made in the Keychain; team folders can't be used now."; return }
        do {
            notice = try await body(team, key)
        } catch {
            KalsmritikoshLog.ui.error("Team folder: \(what, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            notice = error.localizedDescription
        }
        await load()
    }

    private func link(_ url: URL, create: Bool) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        await run("link") { team, key in
            let folder = create ? url.appendingPathComponent("Team folder", isDirectory: true) : url
            _ = try await team.linkFolder(caseID: caseID, folder: folder, create: create, name: url.lastPathComponent, purpose: newPurpose,
                                          displayName: displayName, key: key, actor: actor)
            return create ? "Team folder made in “\(url.lastPathComponent)”. Give the people who should take part access to that folder." : "Joined the team folder."
        }
    }

    private func unlink(_ l: CaseTeamLink) async {
        await run("unlink") { team, _ in
            try await team.file.unlinkTeamFolder(caseID: caseID, linkID: l.id, actor: actor)
            return "The case no longer works through “\(l.folderLabel)”. What it recorded stays in the case; the folder is unchanged."
        }
    }

    private func read(_ l: CaseTeamLink) async {
        await run("read") { team, key in try await team.read(caseID: caseID, linkID: l.id, key: key, actor: actor).summary }
    }

    private func publish(_ l: CaseTeamLink) async {
        let inputs = reqInputs
        let scoped = inputs.map { $0.startAccessingSecurityScopedResource() }
        defer { for (u, s) in zip(inputs, scoped) where s { u.stopAccessingSecurityScopedResource() } }
        await run("publish") { team, key in
            let r = try await team.publishRequest(caseID: caseID, linkID: l.id, title: reqTitle, deliverable: reqDeliverable, recipient: reqRecipient,
                                                  due: reqDue, inputs: inputs, workRef: nil, key: key, actor: actor)
            reqTitle = ""; reqDeliverable = ""; reqDue = ""; reqInputs = []
            return "“\(r.title)”: \(r.stateLine)."
        }
    }

    private func withdraw(_ r: CaseTeamRequest) async {
        await run("withdraw") { team, key in
            try await team.withdrawRequest(caseID: caseID, requestID: r.id, reason: declineReason, key: key, actor: actor)
            declineReason = ""
            return "“\(r.title)” withdrawn."
        }
    }

    private func decide(_ s: CaseTeamSubmission, include: Bool) async {
        if include, let refusal = PaidUse.refusal("add documents", importing: true) { notice = refusal.reason; return }
        await run("decide") { team, key in
            let d = try await team.decide(caseID: caseID, submissionID: s.id, include: include, note: include ? nil : declineReason, key: key, actor: actor)
            if include { await appState.refreshRetrievalCaches() }   // documents were read in
            if !include { declineReason = "" }
            return "\(s.submitterName)'s submission: \(d.outcomeLine)."
        }
    }

    private func shareAssignment(_ l: CaseTeamLink, teamRecordID: String?) async {
        await run("share") { team, key in
            var payload = ["assignee": workAssignee.trimmingCharacters(in: .whitespaces)]
            let note = workNote.trimmingCharacters(in: .whitespaces)
            if !note.isEmpty { payload["note"] = note }
            let r = try await team.shareWork(caseID: caseID, linkID: l.id, kind: .assignment, teamRecordID: teamRecordID, localID: nil, label: workLabel,
                                             payload: payload, key: key, actor: actor)
            workLabel = ""; workAssignee = ""; workNote = ""
            return "“\(r.label)”: \(r.stateLine)."
        }
    }

    private func resolve(_ c: CaseTeamConflict, keepOurs: Bool) async {
        await run("resolve") { team, key in
            let r = try await team.resolveConflict(caseID: caseID, conflictID: c.id, keepOurs: keepOurs, combined: nil, note: nil, key: key, actor: actor)
            return "“\(r.label)”: resolved — \(r.stateLine)."
        }
    }
}

/// The contributor's side: a contribution folder someone shared with you. No case is needed and none is shown — only the
/// requests addressed to you (or to anyone), the files shared with them, what you submitted and the receipts that came back.
struct TeamContributeSheet: View {
    let close: () -> Void
    @State private var folderURL: URL?
    @State private var scoped = false
    @State private var name = ""
    @State private var member: String?
    @State private var view: CaseTeamService.ContributorView?
    @State private var picking = false
    @State private var choosingFiles: String?
    @State private var note = ""
    @State private var notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Contribute to a team folder", systemImage: "tray.and.arrow.up").font(.headline)
                Spacer()
                Button("Close") { release(); close() }.keyboardShortcut(.cancelAction)
            }
            Text("Open the folder someone shared with you. You see only what was asked of you; what you submit is copied into the folder and signed by this Mac, and the asker's receipt comes back here.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let notice { Text(notice).font(.callout).fixedSize(horizontal: false, vertical: true) }
            if member == nil {
                HStack {
                    TextField("Your name (shown to the asker)", text: $name).textFieldStyle(.roundedBorder)
                    Button("Open the shared folder…") { picking = true }.caseMapControlHelp("Open the shared folder…")
                        .disabled(reason: name.trimmingCharacters(in: .whitespaces).isEmpty ? "Your name is needed." : nil, remedy: "Type the name the asker knows you by.")
                }
            }
            if let view, let folderURL, let member {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if view.requests.isEmpty { Text("Nothing is asked of you in this folder.").foregroundStyle(.secondary) }
                        ForEach(view.requests, id: \.value.id) { r in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(r.value.title) — from \(r.value.from)").font(.callout.weight(.semibold))
                                Text(r.value.deliverable).font(.callout).fixedSize(horizontal: false, vertical: true)
                                if let due = r.value.due { Text("Wanted by \(due)").font(.caption) }
                                ForEach(r.value.inputs, id: \.sha256) { i in
                                    Button("Show “\(i.name)” in Finder") {
                                        NSWorkspace.shared.activateFileViewerSelecting([TeamCase(root: folderURL).inputURL(requestID: r.value.id, name: i.name)])
                                    }.buttonStyle(.link).caseMapControlHelp("Show in Finder")
                                }
                                Button("Submit files…") { choosingFiles = r.value.id }.caseMapControlHelp("Submit files…")
                            }
                            Divider()
                        }
                        TextField("A note with your submission (optional)", text: $note).textFieldStyle(.roundedBorder)
                        ForEach(view.incomplete, id: \.id) { m in
                            HStack {
                                Text("A submission was cut off before every file was copied.").font(.caption).foregroundStyle(.orange)
                                Button("Finish the cut-off copy") { finish(m) }.controlSize(.small).caseMapControlHelp("Finish the cut-off copy")
                            }
                        }
                        if !view.mySubmissions.isEmpty { Text("What you submitted").font(.headline) }
                        ForEach(view.mySubmissions, id: \.value.id) { s in
                            Text(Self.mineLine(s.value, receipt: view.receipts[s.value.id], at: s.at)).font(.caption).fixedSize(horizontal: false, vertical: true)
                        }
                        Text("Signed in this folder as \(name) (member \(member)).").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 620, height: 520)
        // One picker for the folder and the files (a second file importer on the same view is not shown on macOS).
        .fileImporter(isPresented: Binding(get: { picking || choosingFiles != nil }, set: { if !$0 { picking = false; choosingFiles = nil } }),
                      allowedContentTypes: choosingFiles != nil ? [.item] : [.folder], allowsMultipleSelection: choosingFiles != nil) { result in
            let rid = choosingFiles
            picking = false; choosingFiles = nil
            guard case .success(let urls) = result else { return }
            if let rid { submit(urls, requestID: rid) } else if let url = urls.first { open(url) }
        }
    }

    static func mineLine(_ s: TeamSubmissionManifest, receipt: TeamReceipt?, at: String) -> String {
        let files: String = s.files.map(\.name).joined(separator: ", ")
        guard let receipt else { return "\(files) — in the folder; no receipt yet." }
        let outcome: String
        switch receipt.outcome {
        case "received": outcome = "received into the case"
        case "partial": outcome = "partly received"
        case "duplicate": outcome = "already received earlier"
        case "declined": outcome = "declined"
        default: outcome = receipt.outcome
        }
        return "\(files) — \(outcome) (receipt from the asker)."
    }

    private func open(_ url: URL) {
        release()
        scoped = url.startAccessingSecurityScopedResource()
        guard let folder = TeamCase.open(url), folder.reachable() else {
            notice = TeamFolderError.notATeamFolder.localizedDescription
            if scoped { url.stopAccessingSecurityScopedResource(); scoped = false }
            return
        }
        guard let key = TeamIdentity.key() else { notice = "This Mac's team key could not be made in the Keychain."; return }
        do {
            member = try folder.join(displayName: name.trimmingCharacters(in: .whitespaces), key: key)
            folderURL = url
            refresh()
        } catch {
            KalsmritikoshLog.ui.error("Contribution folder not joined: \(error.localizedDescription, privacy: .private)")
            notice = error.localizedDescription
        }
    }

    private func refresh() {
        guard let folderURL, let member, let folder = TeamCase.open(folderURL) else { return }
        view = CaseTeamService.contributorView(folder: folder, member: member)
    }

    private func submit(_ urls: [URL], requestID: String) {
        guard let folderURL, let member, let folder = TeamCase.open(folderURL), let key = TeamIdentity.key() else { return }
        let scopes = urls.map { $0.startAccessingSecurityScopedResource() }
        defer { for (u, s) in zip(urls, scopes) where s { u.stopAccessingSecurityScopedResource() } }
        do {
            let m = try folder.submit(requestID: requestID, files: urls, note: note.trimmingCharacters(in: .whitespaces).isEmpty ? nil : note, member: member, key: key)
            notice = "\(m.files.count) file(s) submitted. The asker's receipt appears here once their case has read the folder."
            note = ""
        } catch {
            KalsmritikoshLog.ui.error("Submission not finished: \(error.localizedDescription, privacy: .private)")
            notice = "\(error.localizedDescription) What was copied is kept; choose “Finish the cut-off copy” when the files are available."
        }
        refresh()
    }

    private func finish(_ m: TeamCase.IncompleteSubmission) {
        guard let folderURL, let folder = TeamCase.open(folderURL), let key = TeamIdentity.key() else { return }
        do {
            _ = try folder.resumeSubmission(m, key: key)
            notice = "The submission is complete."
        } catch {
            KalsmritikoshLog.ui.error("Cut-off submission still not finished: \(error.localizedDescription, privacy: .private)")
            notice = error.localizedDescription
        }
        refresh()
    }

    private func release() {
        if scoped, let folderURL { folderURL.stopAccessingSecurityScopedResource() }
        scoped = false
    }
}
