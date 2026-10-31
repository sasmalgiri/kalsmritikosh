//
//  HelpTutorial.swift
//  Kalsmritikosh
//
//  The one optional, replayable hands-on tutorial (App Store completion instructions §6.2–§6.3). It
//  runs ONLY inside the isolated sample case — its own ledger, in-memory folder bookmarks, the bundled
//  Project Delta documents — so replaying it can never touch the person's documents, cases, folders,
//  preferences for their own archive, legacy stores or credentials. The tutorial does not automate
//  anything: each step says what to press (exact control names, checked against the UI sources by
//  `HelpRegistryTests`), what you should see, and a “Show me” that opens the right screen. The person
//  does the work, so what they learn is the real app.
//
//  The path is the current case-to-report journey: open the sample → choose the investigation question
//  → inspect and authorise the case documents → ask → open the exact citation → review conflicting
//  accounts → save a reviewed result → carry it into the report → export and reopen it. It shows both a
//  supported conclusion (Amendment 7: approved 2 May 2024, signed by John Carter and Maria Lopez) and a
//  question the evidence cannot settle (whether invoice 432 was ever paid).
//

import SwiftUI

public nonisolated struct TutorialStep: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    /// What to do, with the exact control names in quotation marks.
    public let instruction: String
    /// What the screen should show once the step is done.
    public let expect: String
    public let destination: Destination?
    /// Exact control names used in `instruction` (verified against the UI sources).
    public let controls: [String]
}

public nonisolated enum HelpTutorial {
    /// Where the tutorial stands: the current step index, or absent when not running. Kept in the
    /// preference store like the sample flag itself; it carries one integer and nothing of the person's work.
    static let stepKey = "kalsmritikosh.tutorial.step"

    public static let steps: [TutorialStep] = [
        TutorialStep(id: "open-sample", title: "You are in the sample case",
                     instruction: "The purple banner says this is the sample archive: its own ledger with eight bundled Project Delta documents (a supply contract, Amendment 7, two invoices, four emails). Open Sources to see them read.",
                     expect: "Sources lists the Project Delta folder and shows “Ready” once all eight files are processed. Your own documents are not here and were not opened.",
                     destination: .sources, controls: ["Ready"]),
        TutorialStep(id: "question", title: "Choose the investigation question",
                     instruction: "Open Professional Jobs, choose “Investigator” and press “Start matter”. Name it “Project Delta slip”. The question for this matter: why did the first delivery slip, and who approved the change?",
                     expect: "A matter named Project Delta slip, with its workspace, and the jobs grouped in phases with “Start here — open a matter” done.",
                     destination: .work, controls: ["Start matter", "Start here — open a matter"]),
        TutorialStep(id: "authorise", title: "Inspect and authorise the case documents",
                     instruction: "Press “Add documents to this case”. Read the preview: how many documents are in scope now, how many are new, how many stay excluded. Confirm.",
                     expect: "“Documents: 8 in scope”. Only these documents are read for this matter’s jobs and questions.",
                     destination: .work, controls: ["Add documents to this case"]),
        TutorialStep(id: "ask", title: "Ask — one answerable question, one that is not",
                     instruction: "Open Ask. Type “When was Amendment 7 approved, and who signed it?” and press “Send question”. Then ask “Was invoice 432 paid?”.",
                     expect: "The first answer: effective 2 May 2024, signed by John Carter (Northwind) and Maria Lopez (Supplier ABC), cited to the amendment and the 24 May status digest. The second: no document records a payment — the invoice was unpaid as of 14 June 2024 — so the app says the documents do not answer it instead of guessing.",
                     destination: .ask, controls: ["Send question"]),
        TutorialStep(id: "citation", title: "Open the exact citation",
                     instruction: "Under the first answer press “Open at this passage” on the amendment citation.",
                     expect: "The amendment opens at the quoted sentence (“Signed by John Carter (Northwind) and Maria Lopez (Supplier ABC) on May 2, 2024.”). The quotation is checked against the document; whether the document is right is your judgement.",
                     destination: .ask, controls: ["Open at this passage"]),
        TutorialStep(id: "conflict", title: "Review conflicting accounts",
                     instruction: "Open Findings ▸ Contradictions (or Timeline). Look at the first-lot delivery date: the 8 April email estimates about 13 May 2024; the 18 April email and the amendment say 28 May 2024.",
                     expect: "Both versions are kept with their sources. An estimate that was later revised is shown as a change of account, not labelled wrong — you decide what it means and record why.",
                     destination: .findings, controls: []),
        TutorialStep(id: "review", title: "Save a reviewed result",
                     instruction: "Back in Professional Jobs, press “Run” on the first job of the intake phase. In the result, decide the rows (or press “Accept shown”), add a note, and press “Save review”.",
                     expect: "The result shows your decisions and the review time. Unreviewed rows stay marked unreviewed wherever they are carried.",
                     destination: .work, controls: ["Run", "Accept shown", "Save review"]),
        TutorialStep(id: "carry", title: "Carry it into the report",
                     instruction: "On a reviewed row press “Include in report”; try “Add to chronology” on a dated row.",
                     expect: "The case file’s report selection and chronology gain the rows with every citation and their review state. A row whose source changes later is shown as stale.",
                     destination: .work, controls: ["Include in report", "Add to chronology"]),
        TutorialStep(id: "export", title: "Export the report and reopen it",
                     instruction: "Open Cases, open the matter, press “Case file report…”, then “Export…”. Save the file, then open it from the Finder.",
                     expect: "The exported report lists what you included, each with its sources, and a section for what the evidence does not establish (invoice 432’s payment). The case log records the export with its digest.",
                     destination: .cases, controls: ["Case file report…", "Export…"]),
        TutorialStep(id: "finish", title: "What you saw, and back to your own archive",
                     instruction: "A supported conclusion (the amendment’s approval, two documents) and an insufficient one (the payment, no document). Press “Back to my archive” in the banner when you are done.",
                     expect: "The app relaunches on your own archive. Nothing from the sample was written to it; the tutorial can be replayed any time from Help.",
                     destination: .home, controls: ["Back to my archive"])
    ]

    /// Running means a step index is stored. Only meaningful inside the sample case.
    public static var isRunning: Bool { AppDefaults.store.object(forKey: stepKey) != nil }

    public static var currentIndex: Int {
        get { min(max(AppDefaults.store.integer(forKey: stepKey), 0), steps.count - 1) }
        set { AppDefaults.store.set(newValue, forKey: stepKey) }
    }

    /// Start (or restart) from the first step. Enters the sample case first when not already in it;
    /// the person's own archive is never used for the tutorial.
    @MainActor public static func replay() {
        AppDefaults.store.set(0, forKey: stepKey)
        if !SampleArchiveMode.isActive { SampleArchiveMode.enter() }
    }

    public static func stop() { AppDefaults.store.removeObject(forKey: stepKey) }
}

/// The floating tutorial card shown over the sample case while the tutorial runs. Back/Next, position,
/// Show me, Stop; nothing advances by itself; keyboard-operable buttons; no motion.
struct TutorialPanel: View {
    @State private var index = HelpTutorial.currentIndex
    @State private var running = HelpTutorial.isRunning
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if running {
            let step = HelpTutorial.steps[index]
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Tutorial", systemImage: "graduationcap").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Text("Step \(index + 1) of \(HelpTutorial.steps.count)").font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("tutorial.position")
                    Button { HelpTutorial.stop(); running = false } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help("Stop the tutorial. Replay it any time from Help ▸ Replay the tutorial.")
                        .accessibilityLabel("Stop tutorial")
                        .accessibilityIdentifier("tutorial.stop")
                }
                Text(step.title).font(.headline)
                Text(step.instruction).font(.callout).fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("What you should see").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(step.expect).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("Back") { move(to: index - 1) }.disabled(index == 0)
                        .accessibilityIdentifier("tutorial.back")
                    if let dest = step.destination {
                        Button { SurfaceOpener.open(dest) } label: { Label("Show me", systemImage: dest.icon) }
                            .help("Open \(dest.title)")
                            .accessibilityIdentifier("tutorial.showMe")
                    }
                    Spacer()
                    if index == HelpTutorial.steps.count - 1 {
                        Button("Finish") { HelpTutorial.stop(); running = false }.buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("tutorial.next")
                    } else {
                        Button("Next") { move(to: index + 1) }.buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("tutorial.next")
                    }
                }
                .controlSize(.small)
            }
            .padding(14)
            .frame(width: 380)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.08)))
            .shadow(radius: reduceMotion ? 0 : 8, y: 2)
            .padding(16)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Tutorial, step \(index + 1) of \(HelpTutorial.steps.count): \(step.title)")
            .accessibilityIdentifier("tutorial.panel")
            .transaction { $0.animation = nil }
        }
    }

    private func move(to i: Int) {
        let clamped = min(max(i, 0), HelpTutorial.steps.count - 1)
        HelpTutorial.currentIndex = clamped
        index = clamped
    }
}
