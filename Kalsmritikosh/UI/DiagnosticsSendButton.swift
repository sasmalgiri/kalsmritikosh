//
//  DiagnosticsSendButton.swift
//  Kalsmritikosh
//
//  U-4 — "Send diagnostics…". Shows the saved crash/hang/timing files first, says what
//  is (and is not) in them, and only on the person's click hands them to the system
//  email sharing service (their own Mail app, a draft they can still edit or discard).
//  The app itself makes no network call and nothing is sent automatically.
//

import SwiftUI
import os
#if canImport(AppKit)
import AppKit
#endif

/// The button that sits next to "Report a problem / send feedback" in Help & feedback.
struct DiagnosticsSendButton: View {
    @State private var showingPreview = false

    var body: some View {
        Button {
            showingPreview = true
        } label: {
            Label("Send diagnostics…", systemImage: "stethoscope")
        }
        .help("See the crash and hang reports saved on this Mac, then choose whether to email them.")
        .sheet(isPresented: $showingPreview) {
            DiagnosticsPreviewSheet { showingPreview = false }
        }
    }
}

/// The preview: every file that would be attached, and what they contain. Nothing leaves
/// until "Email these files…" is pressed.
struct DiagnosticsPreviewSheet: View {
    let close: () -> Void

    private struct Entry: Identifiable {
        let url: URL
        let bytes: Int
        var id: URL { url }
    }

    @State private var entries: [Entry] = []
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Send diagnostics").font(.title2.bold())
            Text("These files contain app timing and crash stacks: how long the app took to start and respond, memory, CPU and disk counters, and the app's own call stacks at a crash or hang, with the Mac model and macOS and app versions. They contain no documents, no questions or answers, and nothing from your ledger. They were made by macOS on this Mac and have not been sent anywhere.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Text("Pressing \u{201C}Email these files…\u{201D} opens a draft in your own Mail app with them attached. You can open the files first, remove any of them from the draft, or not send it at all.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if entries.isEmpty {
                Text("No diagnostics have been saved yet. macOS hands them to the app after a crash or a hang (usually the next time the app starts), and a timing summary about once a day.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 8)
            } else {
                Text("\(entries.count) file\(entries.count == 1 ? "" : "s") would be attached:")
                    .font(.headline)
                List(entries) { e in
                    HStack {
                        Image(systemName: "doc.text").foregroundStyle(.secondary).accessibilityHidden(true)
                        Text(e.url.lastPathComponent).font(.system(.callout, design: .monospaced))
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: Int64(e.bytes), countStyle: .file))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
                .frame(minHeight: 160)
            }

            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Show in Finder") { showInFinder() }
                    .disabled(entries.isEmpty)
                Spacer()
                Button("Cancel", role: .cancel) { close() }
                    .keyboardShortcut(.cancelAction)
                Button("Email these files…") { email() }
                    .buttonStyle(.borderedProminent)
                    .disabled(entries.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 360)
        .task { reload() }
    }

    private func reload() {
        entries = DiagnosticsStore.files().map { Entry(url: $0, bytes: DiagnosticsStore.size(of: $0)) }
    }

    private func showInFinder() {
        #if canImport(AppKit)
        NSWorkspace.shared.activateFileViewerSelecting(entries.map(\.url))
        #endif
    }

    /// Hand the files to the system "Email" sharing service — the person's own Mail app.
    private func email() {
        #if canImport(AppKit)
        let urls = entries.map(\.url)
        guard let service = NSSharingService(named: .composeEmail), service.canPerform(withItems: urls) else {
            problem = "No email app is set up on this Mac, so nothing was sent. Use \u{201C}Show in Finder\u{201D} and attach the files to a message to \(FeedbackMail.supportAddress) yourself."
            KalsmritikoshLog.ui.error("Diagnostics: the email sharing service is not available")
            return
        }
        let v = FeedbackMail.currentVersions()
        service.recipients = [FeedbackMail.supportAddress]
        service.subject = "Investigations Made Easy — diagnostics (\(v.app), \(v.os))"
        service.perform(withItems: urls)
        close()
        #endif
    }
}
