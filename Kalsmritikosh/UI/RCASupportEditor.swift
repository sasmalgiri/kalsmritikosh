//
//  RCASupportEditor.swift
//  Kalsmritikosh
//
//  Case plan 2026-11-16 (REASON-13) — under a brainstorm idea, a Why answer, a fishbone cause or the conclusion:
//  cite an exact passage of a source in the analysis's case, or record the assumption the step rests on. A citation
//  counts as evidence only once it quotes a passage; export, copy, print and approval re-check every quote against its
//  source in the case (StudioStorage.package / approve). Text typed before this existed stays the investigator's own.
//

import SwiftUI

struct RCASupportEditor: View {
    @Binding var citations: [StudioEvidenceRef]
    @Binding var assumption: String
    /// The exact source versions in the analysis's case scope, labelled (empty: the analysis has no case).
    let choices: [(id: UUID, label: String)]
    var showsAssumption = true
    @State private var editingAssumption = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(citations.enumerated()), id: \.offset) { i, ref in
                citationRow(i, ref)
            }
            if showsAssumption && (editingAssumption || !assumption.trimmed.isEmpty) {
                HStack(spacing: 6) {
                    Image(systemName: "questionmark.circle").foregroundStyle(.orange)
                    TextField("The assumption this rests on (stated, not evidenced)", text: $assumption)
                        .textFieldStyle(.plain)
                        .accessibilityIdentifier("rca.assumption")
                }
                .font(.caption)
            }
            HStack(spacing: 12) {
                linkMenu
                if showsAssumption && !editingAssumption && assumption.trimmed.isEmpty {
                    Button("Record assumption") { editingAssumption = true }
                        .buttonStyle(.link)
                        .help("Say plainly what this step assumes; the report prints it as an assumption, not as evidence.")
                        .accessibilityIdentifier("rca.recordAssumption")
                }
            }
            .font(.caption)
        }
    }

    @ViewBuilder private var linkMenu: some View {
        if choices.isEmpty {
            Text("No case sources to cite — file the analysis under a case to link sources.")
                .foregroundStyle(.secondary)
        } else {
            Menu {
                ForEach(choices, id: \.id) { choice in
                    Button(choice.label) { citations.append(StudioEvidenceRef(sourceVersionID: choice.id)) }
                }
            } label: {
                Label("Link source…", systemImage: "link.badge.plus")
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help("Cite an exact source version in this case, then quote the passage the step rests on.")
            .accessibilityIdentifier("rca.linkSource")
        }
    }

    private func citationRow(_ i: Int, _ ref: StudioEvidenceRef) -> some View {
        let quoted = !(ref.quote ?? "").trimmed.isEmpty
        let name = ref.sourceVersionID.flatMap { id in choices.first { $0.id == id }?.label } ?? "a source"
        return HStack(spacing: 6) {
            Image(systemName: "doc.text").foregroundStyle(quoted ? Color.accentColor : Color.orange)
            Text(name).lineLimit(1).frame(maxWidth: 160, alignment: .leading)
            TextField("quote the passage — its exact words", text: Binding(
                get: { i < citations.count ? (citations[i].quote ?? "") : "" },
                set: { new in
                    guard i < citations.count else { return }
                    citations[i].quote = new.trimmed.isEmpty ? nil : new
                }))
                .textFieldStyle(.plain)
            if !quoted {
                Text("not a citation until quoted").foregroundStyle(.orange)
            }
            Button {
                if i < citations.count { citations.remove(at: i) }
            } label: { Label("Remove citation", systemImage: "xmark.circle").labelStyle(.iconOnly) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .font(.caption)
        .accessibilityElement(children: .contain)
    }
}
