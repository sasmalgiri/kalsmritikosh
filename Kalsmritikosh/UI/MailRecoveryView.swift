//
//  MailRecoveryView.swift
//  Kalsmritikosh
//
//  W4-3 — deleted mail that is still present: email files in a Deleted Items /
//  Trash / Bin folder, and single-message files whose headers say they were
//  deleted (Thunderbird expunged flag, X-Status D, Gmail Trash label). Each is
//  shown as "recovered, partial" with the evidence for it, and can be tagged
//  "Recovered" — the ledger's evidence is never changed. Not included: carving
//  unlisted messages out of PST/NSF free space.
//

import SwiftUI
import os

struct RecoveredMail: Identifiable, Sendable {
    let id: UUID
    let name: String
    let info: RecoveryInfo
}

extension AppState {
    func scanForDeletedMail(limit: Int = 5000) async -> [RecoveredMail] {
        guard ProductModuleFlags.isEnabled(.mailRecovery), let database else { return [] }
        let rows = (try? await database.query("""
            SELECT ko.id, f.url FROM knowledge_objects ko JOIN files f ON f.id = ko.file_id
            WHERE LOWER(f.url) LIKE '%.eml' OR LOWER(f.url) LIKE '%.emlx' OR LOWER(f.url) LIKE '%.mbox%'
               OR LOWER(f.url) LIKE '%.msg'
            LIMIT ?;
            """, [.integer(Int64(limit))])) ?? []
        var out: [RecoveredMail] = []
        for r in rows {
            guard let id = r.uuid(0), let s = r.string(1), let url = URL(string: s) else { continue }
            var headers: [String: String] = [:]
            if ["eml", "emlx"].contains(url.pathExtension.lowercased()) {
                let scoped = url.startAccessingSecurityScopedResource()
                if let handle = try? FileHandle(forReadingFrom: url), let head = try? handle.read(upToCount: 64 * 1024) {
                    headers = EmailAuthenticityAnalyzer.headers(String(decoding: head, as: UTF8.self))
                    try? handle.close()
                }
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
            if let info = RecoveryDetector.detect(headers: headers, folderPath: url.path) {
                out.append(RecoveredMail(id: id, name: url.lastPathComponent, info: info))
            }
        }
        return out
    }
}

struct MailRecoveryView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var found: [RecoveredMail] = []
    @State private var scanning = false
    @State private var status: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Deleted email still present").font(.title3.bold())
            Text("Messages a mail program marked deleted or moved to the trash but did not erase. They are shown as recovered and partial, separately from live mail. Carving unlisted messages out of Outlook or Notes free space is not included.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(scanning ? "Scanning…" : "Scan") { Task { scanning = true; found = await appState.scanForDeletedMail(); scanning = false } }
                    .disabled(scanning)
                if !found.isEmpty, appState.tagsRepository != nil {
                    Button("Tag all “Recovered”") {
                        Task {
                            guard let repo = appState.tagsRepository, let tag = try? await repo.tag(named: "Recovered") else { return }
                            for f in found { try? await repo.attach(tagID: tag, to: .object, f.id) }
                            status = "Tagged \(found.count) message\(found.count == 1 ? "" : "s") “Recovered”."
                        }
                    }
                }
                if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
            }
            List(found) { f in
                VStack(alignment: .leading, spacing: 2) {
                    Text(f.name).font(.callout)
                    Text("\(f.info.label) — \(f.info.evidence)").font(.caption2).foregroundStyle(.orange)
                }
            }
            .frame(minHeight: 300)
            HStack { Text("\(found.count) found").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(16)
        .frame(minWidth: 640, minHeight: 480)
    }
}
