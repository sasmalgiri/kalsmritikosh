//
//  TeamReviewView.swift
//  Kalsmritikosh
//
//  W4-4 — open or create a team case in a shared folder, publish this Mac's
//  review codes as signed entries, see and apply the team's current codes, take
//  a lease on a document, and verify every reviewer's log.
//

import SwiftUI
import AppKit
import os

extension AppState {
    /// Local review codes keyed by source content hash, with the document name.
    func reviewCodesByContentHash() async -> [(ref: String, name: String, code: ReviewCode)] {
        guard let database, let codes = try? await ReviewCodesRepository(database: database).current(), !codes.isEmpty else { return [] }
        var out: [(String, String, ReviewCode)] = []
        let ids = Array(codes.keys)
        for start in stride(from: 0, to: ids.count, by: 400) {
            let slice = Array(ids[start..<min(start + 400, ids.count)])
            let rows = (try? await database.query("""
                SELECT ko.id, f.content_hash, f.url FROM knowledge_objects ko JOIN files f ON f.id = ko.file_id
                WHERE ko.id IN (\(slice.map { _ in "?" }.joined(separator: ","))) AND f.content_hash IS NOT NULL;
                """, slice.map { .uuid($0) })) ?? []
            for r in rows {
                guard let id = r.uuid(0), let hash = r.string(1), let code = codes[id] else { continue }
                out.append((hash, r.string(2).flatMap { URL(string: $0)?.lastPathComponent } ?? "", code))
            }
        }
        return out
    }

    /// Apply team codes to local documents with the same content hash. Returns how many were set.
    func applyTeamCodes(_ codes: [String: ReviewCode]) async -> (applied: Int, notHere: Int) {
        guard let database, !codes.isEmpty else { return (0, 0) }
        let repo = ReviewCodesRepository(database: database)
        var applied = 0, notHere = 0
        for (ref, code) in codes {
            let ids = ((try? await database.query("""
                SELECT ko.id FROM knowledge_objects ko JOIN files f ON f.id = ko.file_id WHERE f.content_hash = ?;
                """, [.text(ref)])) ?? []).compactMap { $0.uuid(0) }
            if ids.isEmpty { notHere += 1; continue }
            for id in ids { if (try? await repo.setCode(code, for: id, reviewer: "team")) != nil { applied += 1 } }
        }
        return (applied, notHere)
    }
}

struct TeamReviewView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @AppStorage("kalsmritikosh.team.displayName") private var displayName = ""
    @State private var teamCase: TeamCase?
    @State private var scoped: URL?
    @State private var memberID: String?
    @State private var state: [(ref: String, value: String, name: String, member: String, at: String)] = []
    @State private var findings: [TeamVerifyFinding] = []
    @State private var status: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Team review").font(.title3.bold())
            Text("Work on one case with other reviewers through a folder you all can reach. Each reviewer writes a signed log of their own; nothing goes through a server.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("Your name in the case", text: $displayName).frame(width: 200)
                Button("Open case folder…") { pick(create: false) }
                Button("New case in folder…") { pick(create: true) }
            }
            if let c = teamCase {
                Text("Case “\(c.name)” · \(c.members().count) member(s)").font(.headline)
                HStack {
                    Button("Publish my review codes") { Task { await publish() } }.disabled(memberID == nil)
                    Button("Apply team codes here") { Task { await apply() } }
                    Button("Verify all logs") { findings = c.verify(); status = nil }
                    Button("Refresh") { reload() }
                }
                if !findings.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(findings, id: \.self) { f in
                            Label(f.text, systemImage: f.isProblem ? "exclamationmark.triangle.fill" : "checkmark.seal")
                                .font(.caption).foregroundStyle(f.isProblem ? .orange : .secondary)
                        }
                    }
                }
                List(state, id: \.ref) { s in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(s.name.isEmpty ? String(s.ref.prefix(12)) : s.name).font(.callout)
                            Text("\(ReviewCode(rawValue: s.value)?.label ?? s.value) · \(s.member) · \(s.at)").font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Take for 1 hour") {
                            guard let memberID else { return }
                            let ok = (try? c.lease(s.ref, member: memberID)) ?? false
                            status = ok ? "You hold \(s.name) for the next hour." : "Another reviewer holds \(s.name) right now."
                        }
                        .buttonStyle(.borderless).font(.caption).disabled(memberID == nil)
                    }
                }
                .frame(minHeight: 220)
            }
            if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
            Spacer()
            HStack { Spacer(); Button("Done") { close(); dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(16)
        .frame(minWidth: 640, minHeight: 520)
        .onDisappear { close() }
    }

    private func pick(create: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        close()
        _ = url.startAccessingSecurityScopedResource()
        scoped = url
        do {
            let name = displayName.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { status = "Enter your name first."; return }
            if create { teamCase = try TeamCase.create(at: url, name: url.lastPathComponent) }
            else {
                teamCase = TeamCase.open(url)
                if teamCase == nil { status = "This folder is not a team case (no case.json)."; return }
            }
            guard let key = TeamIdentity.key() else { status = "Could not create this Mac's signing key."; return }
            memberID = try teamCase?.join(displayName: name, key: key)
            reload()
        } catch {
            KalsmritikoshLog.app.error("Team case failed: \(error.localizedDescription, privacy: .public)")
            status = "Could not open the case: \(error.localizedDescription)"
        }
    }

    private func close() {
        if let scoped { scoped.stopAccessingSecurityScopedResource() }
        scoped = nil
    }

    private func reload() {
        guard let c = teamCase else { return }
        state = c.currentCodes().map { (ref: $0.key, value: $0.value.value, name: $0.value.name, member: $0.value.member, at: $0.value.at) }
            .sorted { $0.name < $1.name }
    }

    private func publish() async {
        guard let c = teamCase, let memberID, let key = TeamIdentity.key() else { return }
        let mine = await appState.reviewCodesByContentHash()
        let current = c.currentCodes()
        // Only codes that differ from the shared state are written.
        let drafts = mine.filter { current[$0.ref]?.value != $0.code.rawValue }
            .map { (action: "code", objectRef: $0.ref, objectName: $0.name, value: $0.code.rawValue) }
        do {
            let n = try c.append(drafts, member: memberID, key: key)
            status = "Published \(n) signed entr\(n == 1 ? "y" : "ies")."
            reload()
        } catch {
            KalsmritikoshLog.app.error("Team publish failed: \(error.localizedDescription, privacy: .public)")
            status = "Could not write to the case folder: \(error.localizedDescription)"
        }
    }

    private func apply() async {
        guard let c = teamCase else { return }
        let problems = c.verify().filter(\.isProblem)
        guard problems.isEmpty else {
            findings = c.verify()
            status = "Not applied: a log failed verification (see above)."
            return
        }
        let codes = c.currentCodes().compactMapValues { ReviewCode(rawValue: $0.value) }
        let r = await appState.applyTeamCodes(codes)
        status = "Applied \(r.applied) code(s) to documents here; \(r.notHere) document(s) are not in this Mac's archive."
    }
}
