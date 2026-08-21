//
//  AuthenticityView.swift
//  Kalsmritikosh
//
//  UI for FileAuthenticityInspector — pick a file, see its fingerprint and
//  the honest provenance signals. States plainly what it can and can't prove.
//

import SwiftUI
import UniformTypeIdentifiers
import OSLog

public struct AuthenticityView: View {
    @Environment(AppState.self) private var appState

    @State private var sourceURL: URL?
    @State private var report: AuthenticityReport?
    @State private var running = false
    @State private var errorMessage: String?
    @State private var showImporter = false

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                picker
                if let errorMessage { errorCard(errorMessage) }
                if let report { reportCard(report) }
                disclaimer

                LegalDisclaimer(text: "These signals are investigative leads, not proof, and not admissible expert opinion on their own. This is a tool, not legal advice.")
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .navigationTitle("Authenticity")
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item]) { res in
            switch res {
            case .success(let url):
                sourceURL = url
                report = nil
                errorMessage = nil
                Task { await analyze() }
            case .failure(let err):
                errorMessage = err.localizedDescription
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Authenticity signals", systemImage: "checkmark.shield")
                .font(.title2.bold())
            Text("Check a file's provenance the way an examiner does — a stable fingerprint, capture metadata, editing-software traces, and (for PDFs) whether it was edited after its original save.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var picker: some View {
        GroupBox {
            HStack(spacing: 12) {
                Image(systemName: "doc.viewfinder")
                    .font(.title3).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(sourceURL?.lastPathComponent ?? "No file chosen")
                        .fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                    Text("Images and PDFs get the deepest checks").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if running { ProgressView().controlSize(.small) }
                Button("Choose file…") { showImporter = true }.disabled(running)
            }
        }
    }

    private func reportCard(_ r: AuthenticityReport) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    row("Type", r.kindDescription)
                    row("Size", ByteCountFormatter.string(fromByteCount: r.sizeBytes, countStyle: .file))
                    if let c = r.createdAt { row("Created", c.formatted(date: .abbreviated, time: .shortened)) }
                    if let m = r.modifiedAt { row("Modified", m.formatted(date: .abbreviated, time: .shortened)) }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("SHA-256 fingerprint").font(.caption).foregroundStyle(.secondary)
                        Text(r.sha256).font(.caption.monospaced()).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Text("Signals").font(.headline)
            if r.signals.isEmpty {
                Text("No notable signals.").foregroundStyle(.secondary)
            } else {
                ForEach(r.signals) { signal in
                    signalRow(signal)
                }
            }
        }
    }

    private func signalRow(_ s: AuthenticitySignal) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon(for: s.severity))
                .foregroundStyle(color(for: s.severity))
                .font(.body)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.title).fontWeight(.medium)
                Text(s.detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(10)
        .background(color(for: s.severity).opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private var disclaimer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What this can and can't tell you").font(.subheadline.bold())
            Text("These are provenance signals, not a verdict. A clean metadata trail is not proof a file is genuine, and a warning is not proof it's fake — it's a lead to investigate. Pixel-level manipulation and AI-generation detection are deliberately out of scope: doing them honestly needs tooling this on-device app doesn't ship, and a false green light would be worse than none.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 8)
    }

    private func errorCard(_ message: String) -> some View {
        GroupBox {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange).font(.callout)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
            Text(value).font(.callout).textSelection(.enabled)
            Spacer()
        }
    }

    private func icon(for s: AuthenticitySignal.Severity) -> String {
        switch s {
        case .info: return "info.circle"
        case .notice: return "questionmark.circle"
        case .warning: return "exclamationmark.triangle.fill"
        }
    }
    private func color(for s: AuthenticitySignal.Severity) -> Color {
        switch s {
        case .info: return .blue
        case .notice: return .orange
        case .warning: return .red
        }
    }

    private func analyze() async {
        guard let url = sourceURL else { return }
        running = true; errorMessage = nil
        let outcome: Result<AuthenticityReport, Error> = await Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do { return .success(try FileAuthenticityInspector().analyze(url: url)) }
            catch { return .failure(error) }
        }.value
        switch outcome {
        case .success(let r): report = r
        case .failure(let err):
            errorMessage = (err as? LocalizedError)?.errorDescription ?? err.localizedDescription
            KalsmritikoshLog.ui.error("Authenticity analysis failed: \(err.localizedDescription, privacy: .public)")
        }
        running = false
    }
}
