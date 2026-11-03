//
//  AddPassageToChronologySheet.swift
//  Kalsmritikosh
//
//  G1 — "Add to case chronology…" from a cited passage or a search hit: choose the open case, check
//  the date (filled in only when the passage states exactly one full date), word the entry, and the
//  passage is recorded as its citation through `PassageChronology`. A source outside the case's
//  scope is refused with the case's reason; nothing here adds the source to the case.
//

import SwiftUI
import os

/// A passage that can go into a case chronology: its document and the words, plus the exact
/// source version and block when the caller already knows them.
struct ChronologyPassage: Identifiable, Hashable {
    let id = UUID()
    let objectID: UUID
    let quote: String
    var sourceVersionID: UUID? = nil
    var blockID: UUID? = nil
}

struct AddPassageToChronologySheet: View {
    let passage: ChronologyPassage
    let onDone: () -> Void

    @Environment(AppState.self) private var appState
    @State private var cases: [StudioCaseChoice]?
    @State private var caseID: UUID?
    @State private var hasDate = false
    @State private var when = Date()
    @State private var dateFromPassage = false
    @State private var text = ""
    @State private var problem: String?
    @State private var message: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Add to case chronology").font(.headline)
                Spacer()
                InfoPopoverButton(topic: "task-chronology-and-hypotheses")
            }
            Text("“\(passage.quote.prefix(400))\(passage.quote.count > 400 ? "…" : "")”")
                .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let cases {
                if cases.isEmpty {
                    Text("There is no open case to add this to. Open or create a case first; nothing was added.")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Case", selection: $caseID) {
                        ForEach(cases) { Text($0.title).tag(Optional($0.id)) }
                    }
                    .accessibilityIdentifier("chronology.passage.case")
                    Toggle("The entry has a date", isOn: $hasDate)
                        .accessibilityIdentifier("chronology.passage.hasDate")
                    if hasDate {
                        DatePicker("When it happened", selection: $when, displayedComponents: .date)
                            .accessibilityIdentifier("chronology.passage.date")
                    }
                    Text(dateFromPassage ? "Date read from the passage — check it before adding."
                                         : "No single full date could be read from the passage; enter one if you know it.")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("What happened", text: $text, axis: .vertical)
                        .lineLimit(3...8)
                        .accessibilityIdentifier("chronology.passage.text")
                    Text("The passage is kept as the entry's citation, verified against the source in the chosen case. A source the case does not include is refused.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                ProgressView()
            }
            if let problem {
                Text(problem).font(.callout).foregroundStyle(.red)
                    .accessibilityIdentifier("chronology.passage.problem")
            }
            if let message {
                Text(message).font(.callout).foregroundStyle(.green)
                    .accessibilityIdentifier("chronology.passage.message")
            }
            HStack {
                Spacer()
                Button(message == nil ? "Cancel" : "Done", action: onDone)
                    .keyboardShortcut(.cancelAction)
                if message == nil {
                    Button("Add to chronology") { add() }
                        .buttonStyle(.borderedProminent)
                        .disabled(busy || caseID == nil || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .help("Record this passage as your chronology entry in the chosen case, with the passage as its citation.")
                        .accessibilityIdentifier("chronology.passage.add")
                }
            }
        }
        .padding(16)
        .frame(minWidth: 480, idealWidth: 540)
        .task {
            text = passage.quote
            if let d = PassageChronology.suggestedDate(in: passage.quote) { when = d; hasDate = true; dateFromPassage = true }
            let open = await appState.studioCaseChoices()
            cases = open
            caseID = open.first?.id
        }
    }

    private func add() {
        guard let caseID, let caseFiles = appState.caseFiles else {
            problem = "The ledger isn't ready yet; nothing was added."
            return
        }
        // §11 — editing a case is a paid action (the sample case is the free preview), as in the case file.
        guard PurchaseCenter.shared.allowPaidAction("edit the case file") else {
            problem = PaidUse.refusal("edit the case file")?.reason ?? "A subscription is needed to edit the case file."
            return
        }
        let title = cases?.first { $0.id == caseID }?.title ?? "the case"
        let passage = passage, text = text, date = hasDate ? when : nil, actor = InvestigatorProfile.name
        busy = true
        Task {
            defer { busy = false }
            do {
                let r = try await PassageChronology.add(caseID: caseID, objectID: passage.objectID, sourceVersionID: passage.sourceVersionID,
                                                        blockID: passage.blockID, quote: passage.quote, text: text, eventDate: date,
                                                        caseFiles: caseFiles, actor: actor)
                problem = nil
                message = "Added to the chronology of “\(title)” as your entry, citing this passage (\(r.support.label))."
            } catch {
                KalsmritikoshLog.app.error("Add passage to chronology: \(error.localizedDescription, privacy: .public)")
                problem = error.localizedDescription
            }
        }
    }
}
