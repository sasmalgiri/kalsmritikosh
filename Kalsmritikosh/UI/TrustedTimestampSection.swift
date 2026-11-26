//
//  TrustedTimestampSection.swift
//  Kalsmritikosh
//
//  ALCOA ALC-12 (owner 2026-11-24) — Settings ▸ Privacy ▸ Trusted timestamps: off by default; the person names a
//  time-stamping authority (RFC 3161, https). Only a SHA-256 of the audit chain's head (or of a signed receipt's seal)
//  is sent, through the network helper. Kept tokens are listed and can be checked. Small expressions on purpose.
//

import SwiftUI
import os

struct TrustedTimestampSection: View {
    @Environment(AppState.self) private var appState
    @State private var enabled = TrustedTimestampSettings.isEnabled()
    @State private var url = TrustedTimestampSettings.url() ?? ""
    @State private var kept: [TrustedTimestamps.Kept] = []
    @State private var status: String?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Trusted timestamps").font(.headline)
            Text("Off by default. When on, the app can ask a time-stamping authority you choose (RFC 3161) to sign the time of the audit chain's current state and of signed receipts. Only a SHA-256 fingerprint is sent, through the app's network helper — never content. Needs Online mode.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("Use a time-stamping authority", isOn: $enabled)
                .onChange(of: enabled) { _, v in TrustedTimestampSettings.set(enabled: v, url: url) }
            TextField("https://… (the authority's RFC 3161 address)", text: $url)
                .textFieldStyle(.roundedBorder)
                .onSubmit { TrustedTimestampSettings.set(enabled: enabled, url: url) }
            HStack {
                Button(working ? "Timestamping…" : "Timestamp the audit chain now") { Task { await stampNow() } }
                    .disabled(working || !enabled || url.isEmpty)
                if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
            }
            ForEach(kept.prefix(20)) { k in keptRow(k) }
        }
        .task { await load() }
    }

    private func keptRow(_ k: TrustedTimestamps.Kept) -> some View {
        HStack(alignment: .top) {
            Text(line(k)).font(.caption).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Check") { status = TrustedTimestamps.verify(k).line }.controlSize(.small)
        }
    }

    private func line(_ k: TrustedTimestamps.Kept) -> String {
        let when = k.genTime.map { BackupLog.stamp($0.timeIntervalSince1970) } ?? "time not read"
        return "\(k.subjectKind == "chainHead" ? "Audit chain" : "Receipt") \(k.subjectRef.prefix(24)) · signed \(when) · \(URL(string: k.tsaURL)?.host ?? k.tsaURL)"
    }

    private func stampNow() async {
        TrustedTimestampSettings.set(enabled: enabled, url: url)
        guard let db = appState.database, let chain = appState.auditChain else { status = "The ledger is not open."; return }
        working = true
        defer { working = false }
        do {
            let k = try await TrustedTimestamps.stampChainHead(db, chain: chain)
            status = "Timestamped (\(k.subjectRef))."
            await load()
        } catch {
            KalsmritikoshLog.ui.error("Chain timestamp failed: \(error.localizedDescription, privacy: .private)")
            status = "Not timestamped: \(error.localizedDescription)"
        }
    }

    private func load() async {
        guard let db = appState.database else { return }
        do { kept = try await TrustedTimestamps.kept(db) } catch {
            KalsmritikoshLog.ui.error("Timestamps not read: \(error.localizedDescription, privacy: .private)")
        }
    }
}
