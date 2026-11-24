//
//  AIPictureBlock.swift
//  Kalsmritikosh
//
//  AI split AI-49 — two small views every understanding screen uses:
//  • AIPictureBlock: what the AI found while reading your cases (the case picture records, case_ai_records), each line
//    labelled "Found by AI · quote checked". With a case: that case's records; without: every case's records the person may
//    read (background AI reading happens only inside cases — owner 2026-11-24).
//  • RuleHintBanner: put above anything the app's rules made, so it reads as a hint, never as a fact.
//  Small expressions on purpose (Xcode 26 CI type-check budget).
//

import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

struct AIPictureBlock: View {
    @Environment(AppState.self) private var appState
    let lens: AIFindingLabels.Lens
    var caseID: UUID? = nil
    var subject: String? = nil
    /// The most lines shown (the rest are counted).
    var limit = 12
    @State private var rows: [AIFindingLabels.Row] = []
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if loaded && rows.isEmpty { emptyLine }
            ForEach(rows.prefix(limit)) { row in AIPictureRow(row: row) }
            if rows.count > limit { moreLine }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.green.opacity(0.06), in: .rect(cornerRadius: 8))
        .task(id: taskKey) { await load() }
        .accessibilityIdentifier("aiPicture.\(lens.rawValue)")
    }

    private var taskKey: String { "\(lens.rawValue)|\(caseID?.uuidString ?? "all")|\(subject ?? "")" }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(AIFindingLabels.ai, systemImage: "checkmark.seal").font(.caption.weight(.semibold))
            Text(AIFindingLabels.aiExplanation).font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var emptyLine: some View {
        Text("Nothing found by AI here yet. The AI reads documents only inside a case: open a case and allow AI reading.")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private var moreLine: some View {
        Text("and \(rows.count - limit) more in the case file").font(.caption2).foregroundStyle(.secondary)
    }

    private func load() async {
        // Typing a subject reloads: wait a moment so only the last keystroke reads the records.
        if subject != nil {
            do { try await Task.sleep(nanoseconds: 300_000_000) } catch { return }
        }
        let records: [CaseAIRecord]
        if let caseID { records = await appState.caseAIRecords(caseID: caseID) } else { records = await appState.archiveAIRecords() }
        rows = AIFindingLabels.rows(lens, records: records, subject: subject)
        loaded = true
    }
}

private struct AIPictureRow: View {
    let row: AIFindingLabels.Row
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(row.title).font(.callout).textSelection(.enabled)
            if !row.detail.isEmpty {
                Text(row.detail).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            Text(row.label).font(.caption2.weight(.semibold)).foregroundStyle(.green)
        }
    }
}

/// Above anything the app's rules made: a hint, not checked, never a fact.
struct RuleHintBanner: View {
    /// What the rules made here, in plain words (e.g. "the gaps and causes below").
    let what: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "lightbulb").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(AIFindingLabels.hint + " — " + what).font(.caption.weight(.semibold))
                Text(AIFindingLabels.hintExplanation).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: .rect(cornerRadius: 6))
        .accessibilityIdentifier("ruleHint.banner")
    }
}

/// AI split AI-49 — inside a case: the AI case picture (people and roles, dated events, conflicts), each line quote checked.
struct CaseAIPictureSection: View {
    let caseID: UUID
    @State private var lens: AIFindingLabels.Lens = .people

    var body: some View {
        CaseSection(title: "What the AI found in this case",
                    subtitle: "The case picture the AI built while reading this case's documents. Every line is quote checked; nothing here is decided for you.") {
            Picker("Show", selection: $lens) {
                Text("People").tag(AIFindingLabels.Lens.people)
                Text("Organisations").tag(AIFindingLabels.Lens.organisations)
                Text("Events").tag(AIFindingLabels.Lens.events)
                Text("Relationships").tag(AIFindingLabels.Lens.relationships)
                Text("Conflicts").tag(AIFindingLabels.Lens.conflicts)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            AIPictureBlock(lens: lens, caseID: caseID, limit: 10)
        }
    }
}

/// ALCOA ALC-02 — the AI findings report (final or draft) to the clipboard, through the protected-names check.
enum AIFindingsCopy {
    @MainActor static func copy(_ text: String) -> Bool {
        #if canImport(AppKit)
        switch ProtectedExport.prepare(text) {
        case .success(let safe):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(safe, forType: .string)
            return true
        case .failure(let refusal):
            refusal.present()
            return false
        }
        #else
        return false
        #endif
    }
}
