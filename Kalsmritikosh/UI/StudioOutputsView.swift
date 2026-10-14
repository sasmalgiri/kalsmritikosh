//
//  StudioOutputsView.swift
//  Kalsmritikosh
//
//  N-5 — one-click outputs built from the ledger, every line traceable:
//  briefing, FAQ, mind map (outline), and a spoken briefing read by the Mac's
//  own voice (offline). Deterministic: no generative model writes these.
//

import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import os

extension AppState {

    func studioBriefing() async -> String {
        guard let database else { return "" }
        var out = ["# Briefing", ""]
        let people = (try? await database.query("""
            SELECT e.value, e.kind, COUNT(DISTINCT m.source_object_id) n FROM entities e
            JOIN entity_mentions m ON m.entity_id = e.id
            WHERE e.merged_into IS NULL AND e.kind IN ('person','organization','vendor','client')
            GROUP BY e.id ORDER BY n DESC LIMIT 10;
            """, [])) ?? []
        if !people.isEmpty {
            out.append("## Who appears most")
            for r in people { out.append("- \(r.string(0) ?? "?") (\(r.string(1) ?? "")) — in \(r.int(2) ?? 0) documents") }
            out.append("")
        }
        if let events, let recent = try? await events.recent(limit: 10), !recent.isEmpty {
            out.append("## Latest dated events")
            for e in recent { out.append("- \(e.date.formatted(date: .abbreviated, time: .omitted)): \(e.title)") }
            out.append("")
        }
        let contradictions = Int((try? await database.query("SELECT COUNT(*) FROM contradictions WHERE status = 'open';", []).first?.int(0)) ?? 0)
        let gaps = Int((try? await database.query("SELECT COUNT(*) FROM gap_nodes WHERE dismissed = 0;", []).first?.int(0)) ?? 0)
        out.append("## Open questions")
        out.append("- \(contradictions) open contradiction\(contradictions == 1 ? "" : "s") between sources")
        out.append("- \(gaps) possible missing item\(gaps == 1 ? "" : "s")")
        return out.joined(separator: "\n")
    }

    func studioFAQ(limit: Int = 25) async -> String {
        guard let database else { return "" }
        let rows = (try? await database.query("""
            SELECT subject_label, field, value, COALESCE(source_count, 1) FROM generic_facts
            WHERE LENGTH(subject_label) >= 3 AND LENGTH(value) BETWEEN 1 AND 120
            ORDER BY COALESCE(source_count, 1) DESC LIMIT ?;
            """, [.integer(Int64(limit))])) ?? []
        var out = ["# Frequently asked", ""]
        for r in rows {
            let field = (r.string(1) ?? "").replacingOccurrences(of: "_", with: " ")
            out.append("**What is the \(field) of \(r.string(0) ?? "?")?**")
            out.append("\(r.string(2) ?? "") — stated in \(r.int(3) ?? 1) source\((r.int(3) ?? 1) == 1 ? "" : "s").")
            out.append("")
        }
        return out.joined(separator: "\n")
    }

    func studioMindMap() async -> String {
        let g = await relationshipGraph(limit: 20)
        var out = ["# Mind map", "", "- Archive"]
        for n in g.nodes {
            out.append("  - \(n.name)")
            for e in g.edges where e.a == n.id {
                if let other = g.nodes.first(where: { $0.id == e.b }) { out.append("    - \(e.kind) → \(other.name)") }
            }
        }
        return out.joined(separator: "\n")
    }
}

struct StudioOutputsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var tab = 0
    @State private var text = ""
    @State private var loading = false
    @State private var synthesizer = AVSpeechSynthesizer()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Briefings, FAQs and mind maps").font(.title3.bold())
            Picker("", selection: $tab) {
                Text("Briefing").tag(0); Text("FAQ").tag(1); Text("Mind map").tag(2)
            }
            .pickerStyle(.segmented).frame(width: 360)
            .onChange(of: tab) { _, _ in Task { await build() } }
            ScrollView {
                Text(text).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 340)
            .overlay { if loading { ProgressView() } }
            HStack {
                Button(synthesizer.isSpeaking ? "Stop reading" : "Read aloud") {
                    if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
                    else { synthesizer.speak(AVSpeechUtterance(string: text.replacingOccurrences(of: "#", with: ""))) }
                }
                .disabled(text.isEmpty)
                Button("Export…") { export() }.disabled(text.isEmpty)
                Text("Built from your ledger; no AI wrote this.").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { synthesizer.stopSpeaking(at: .immediate); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(minWidth: 680, minHeight: 500)
        .task { await build() }
    }

    private func build() async {
        loading = true
        switch tab {
        case 0: text = await appState.studioBriefing()
        case 1: text = await appState.studioFAQ()
        default: text = await appState.studioMindMap()
        }
        loading = false
    }

    private func export() {
        #if canImport(AppKit)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = ["briefing.md", "faq.md", "mind-map.md"][tab]
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try Data(text.utf8).write(to: url, options: .atomic) }
        catch { KalsmritikoshLog.ui.error("Studio export failed: \(error.localizedDescription, privacy: .public)") }
        #endif
    }
}
