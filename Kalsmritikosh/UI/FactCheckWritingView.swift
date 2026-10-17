//
//  FactCheckWritingView.swift
//  Kalsmritikosh
//
//  I-6 — write or paste a draft; after a short pause every sentence is checked
//  against your archive: supported (with the source), contradicted (with the
//  conflicting sentence) or unsupported. Only your text and your ledger are
//  used; nothing leaves the Mac.
//

import SwiftUI
import os

extension AppState {
    /// Check each sentence of `draft` (at most 40) against the archive.
    public func factCheck(_ draft: String) async -> [SentenceCheck] {
        guard ProductModuleFlags.isEnabled(.liveFactCheck), let chunks else { return [] }
        let sentences = DisconfirmationScanner.sentences(draft)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 12 }
        var out: [SentenceCheck] = []
        for (i, s) in sentences.prefix(40).enumerated() {
            if Task.isCancelled { break }
            let hits: [Chunk]
            do { hits = try await chunks.searchFTS(s, limit: 8) }
            catch {
                KalsmritikoshLog.app.error("Fact-check search failed: \(error.localizedDescription, privacy: .public)")
                hits = []
            }
            let visible = await screenAuthorizer?.filterChunks(hits, boundary: .globalOwner) ?? []
            out.append(SentenceFactChecker.check(
                index: i, sentence: s,
                candidates: visible.map { .init(chunkID: $0.id, objectID: $0.objectID, text: $0.text) }))
        }
        return out
    }
}

struct FactCheckWritingView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var checks: [SentenceCheck] = []
    @State private var running = false
    @State private var pending: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Fact-check my writing").font(.title3.bold())
            Text("Write or paste a draft. Each sentence is checked against your archive after you pause typing. It shows what your documents support — it never calls a sentence false.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HSplitView {
                TextEditor(text: $draft)
                    .font(.body)
                    .frame(minWidth: 300, minHeight: 320)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                    .onChange(of: draft) { _, _ in schedule() }
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if running { ProgressView().controlSize(.small) }
                        ForEach(checks) { c in row(c) }
                        if checks.isEmpty && !running {
                            Text("Results appear here.").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    .padding(8)
                }
                .frame(minWidth: 280)
            }
            HStack {
                let s = checks.filter { $0.verdict == .supported }.count
                let c = checks.filter { $0.verdict == .contradicted }.count
                let u = checks.filter { $0.verdict == .unsupported }.count
                if !checks.isEmpty {
                    Text("\(s) supported · \(c) contradicted · \(u) unsupported").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(minWidth: 720, minHeight: 480)
    }

    private func schedule() {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            running = true
            let result = await appState.factCheck(draft)
            if !Task.isCancelled { checks = result }
            running = false
        }
    }

    @ViewBuilder
    private func row(_ c: SentenceCheck) -> some View {
        let (icon, color): (String, Color) = {
            switch c.verdict {
            case .supported: return ("checkmark.circle.fill", .green)
            case .contradicted: return ("exclamationmark.triangle.fill", .red)
            case .unsupported: return ("questionmark.circle", .orange)
            }
        }()
        VStack(alignment: .leading, spacing: 2) {
            Label(c.sentence, systemImage: icon).font(.caption).foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
            Text(c.reason).font(.caption2).foregroundStyle(.secondary)
            if let e = c.evidence {
                Text("\u{201C}\(e)\u{201D}").font(.caption2).foregroundStyle(.secondary).italic()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(6)
        .background(color.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }
}
