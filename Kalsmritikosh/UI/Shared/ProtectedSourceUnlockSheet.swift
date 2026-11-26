//
//  ProtectedSourceUnlockSheet.swift
//  Kalsmritikosh
//
//  Smart-map IN-09 — the password prompt for ONE protected source version. The password is held only in this
//  sheet's state while it is open, passed once to ProtectedSourceUnlockService and cleared immediately after
//  the attempt; it is never stored, logged or shown. The outcome (wrong password, cannot be opened, opened) is
//  shown with its remedy, and the original stays preserved whatever happens.
//

import SwiftUI

struct ProtectedSourceUnlockSheet: View {
    let sourceVersionID: UUID
    let filename: String
    /// Called after a successful unlock with the readable copy's version.
    var onUnlocked: ((UUID) -> Void)? = nil

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var working = false
    @State private var last: ProtectedSourceAttempt?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Enter password").font(.title3.bold())
            Text("“\(filename)” is password-protected. The password is used once to make a readable copy, linked to the original; it is not saved. The original is kept unchanged.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .disabled(working)
                .onSubmit { attempt() }
                .accessibilityLabel("Password for \(filename)")
            if let last {
                VStack(alignment: .leading, spacing: 4) {
                    Label(last.state.label, systemImage: last.state == .unlocked ? "checkmark.circle" : "exclamationmark.triangle")
                        .foregroundStyle(last.state == .unlocked ? .green : .orange)
                    Text(last.state.remedy).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Button("Cancel") { password = ""; dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button("Open") { attempt() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || password.isEmpty || appState.protectedSourceUnlock == nil)
                    .help(appState.protectedSourceUnlock == nil ? "The library is not open yet." : "Try this password on the original")
            }
        }
        .padding(20)
        .frame(width: 420)
        .onDisappear { password = "" }
    }

    private func attempt() {
        guard !working, !password.isEmpty, let service = appState.protectedSourceUnlock else { return }
        let secret = password
        password = ""   // cleared at once; the secret lives only in this call
        working = true
        Task {
            let result = await service.unlock(sourceVersionID: sourceVersionID, password: secret)
            working = false
            last = result
            if result.state == .unlocked, let derived = result.derivedSourceVersionID {
                onUnlocked?(derived)
            }
        }
    }
}
