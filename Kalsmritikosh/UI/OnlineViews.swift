//
//  OnlineViews.swift
//  Kalsmritikosh
//
//  Online mode UI: the consent sheet (O-5), the always-visible Online badge with
//  one-click return to Private (O-3), the failure banner (O-7), and the Online
//  settings section with the outbound log.
//

import SwiftUI

/// O-5 — exactly what is about to leave the Mac.
struct OutboundConsentSheet: View {
    let preview: OutboundPreview
    @State private var consent = OutboundConsent.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Send to \(preview.provider)?", systemImage: "icloud.and.arrow.up").font(.title3.bold())
            Text("This text will be sent to \(preview.host) (model \(preview.model)) with your own key. Nothing else leaves your Mac.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                Text("\(preview.bytes) bytes").font(.caption.monospacedDigit())
                if preview.maskedCount > 0 {
                    Text("\(preview.maskedCount) personal detail\(preview.maskedCount == 1 ? "" : "s") masked").font(.caption)
                }
            }
            ScrollView {
                Text(preview.text).font(.caption.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 240)
            .padding(6)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            HStack {
                Button("Don’t send") { consent.resolve(allow: false) }.keyboardShortcut(.cancelAction)
                Spacer()
                if !OnlineSettings.askEveryTime {
                    Button("Send and don’t ask again this session") { consent.resolve(allow: true, forSession: true) }
                }
                Button("Send") { consent.resolve(allow: true) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 620)
    }
}

/// O-3 + O-7 — shown at the top of the window while Online mode is in force or after a failure.
struct OnlineStatusBar: View {
    @Environment(AppState.self) private var appState
    @State private var status = OnlineStatus.shared
    @State private var version = 0

    var body: some View {
        let _ = version
        VStack(spacing: 0) {
            if ConnectivityMode.current == .online {
                HStack(spacing: 8) {
                    Label("Online — answers may use \(OnlineSettings.kind.displayName)", systemImage: "icloud")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Button("Switch to Private") {
                        ConnectivityMode.set(.privateMode)
                        version &+= 1
                    }
                    .font(.caption)
                }
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(Color.blue.opacity(0.12))
            }
            if let failure = status.lastFailure {
                HStack(spacing: 8) {
                    Label("The online answer did not go through: \(failure)", systemImage: "exclamationmark.icloud")
                        .font(.caption).lineLimit(2)
                    Spacer()
                    if ConnectivityMode.current == .online {
                        Button("Switch to Private") { ConnectivityMode.set(.privateMode); status.clear(); version &+= 1 }
                            .font(.caption)
                    }
                    Button("Dismiss") { status.clear() }.font(.caption)
                }
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(Color.orange.opacity(0.14))
            }
        }
    }
}

/// Settings ▸ Modules ▸ Online — provider, model, key, consent style, daily limit, and the log.
struct OnlineSettingsSection: View {
    @Environment(AppState.self) private var appState
    @State private var kind = OnlineSettings.kind
    @State private var model = OnlineSettings.model
    @State private var key = ""
    @State private var hasKey = OnlineSettings.apiKey(for: OnlineSettings.kind) != nil
    @State private var askEveryTime = OnlineSettings.askEveryTime
    @State private var capText = OnlineSettings.dailyByteCap.map(String.init) ?? ""
    @State private var log: [OutboundLogEntry] = []
    @State private var showLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Online (your own key)").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            Picker("Provider", selection: $kind) {
                ForEach(OnlineProviderKind.allCases) { Text($0.displayName).tag($0) }
            }
            .onChange(of: kind) { _, k in
                OnlineSettings.kind = k
                model = OnlineSettings.model
                hasKey = OnlineSettings.apiKey(for: k) != nil
            }
            TextField("Model name (from your provider)", text: $model)
                .textFieldStyle(.roundedBorder)
                .onSubmit { OnlineSettings.model = model }
            HStack {
                SecureField(hasKey ? "Key saved — paste a new one to replace" : "API key", text: $key)
                    .textFieldStyle(.roundedBorder)
                Button("Save key") {
                    OnlineSettings.model = model
                    hasKey = OnlineSettings.setAPIKey(key, for: kind) && !key.isEmpty
                    key = ""
                }
                .disabled(key.isEmpty)
                if hasKey {
                    Button("Remove key") { OnlineSettings.setAPIKey(nil, for: kind); hasKey = false }
                }
            }
            Text("The key is kept in your Mac's Keychain and sent only to \(kind.host).")
                .font(.caption2).foregroundStyle(.secondary)
            Toggle("Ask before every send", isOn: $askEveryTime)
                .onChange(of: askEveryTime) { _, v in OnlineSettings.askEveryTime = v }
            HStack {
                Text("Daily limit (bytes, blank = none, 0 = send nothing)").font(.caption)
                TextField("", text: $capText).textFieldStyle(.roundedBorder).frame(width: 120)
                    .onSubmit { OnlineSettings.dailyByteCap = Int(capText.trimmingCharacters(in: .whitespaces)) }
            }
            Button("What was sent…") {
                Task { log = (try? await appState.outboundLog?.recent()) ?? []; showLog = true }
            }
        }
        .sheet(isPresented: $showLog) {
            VStack(alignment: .leading, spacing: 8) {
                Text("What was sent").font(.title3.bold())
                List(log) { e in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(e.sentAt.formatted()) · \(e.provider) · \(e.outcome) · \(e.bytesSent) bytes").font(.caption.weight(.semibold))
                        Text("SHA-256 \(e.payloadSHA256.prefix(16))…  masked \(e.maskedCount)").font(.caption2.monospaced()).foregroundStyle(.secondary)
                        Text(e.payloadText.prefix(400)).font(.caption2).foregroundStyle(.secondary)
                        if let d = e.detail { Text(d).font(.caption2).foregroundStyle(.orange) }
                    }
                }
                .frame(minHeight: 320)
                HStack { Spacer(); Button("Done") { showLog = false }.keyboardShortcut(.defaultAction) }
            }
            .padding(16).frame(width: 620)
        }
    }
}
