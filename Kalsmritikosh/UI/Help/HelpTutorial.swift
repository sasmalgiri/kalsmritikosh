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
//  question the evidence cannot settle (whether invoice 432 was ever paid — the record stops at “unpaid”).
//
//  The wording of every step was checked against UI run i (2026-10-31): the names are the controls that
//  exist, and “What you should see” is what the sample really showed.
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

/// Where the tutorial stands, observable so the panel appears and moves the moment Help ▸ Replay is
/// chosen (UI run i, I-13: a static read of the preference did not re-render). The index is mirrored to
/// the preference store (one integer, nothing of the person's work) so a relaunch resumes it.
@MainActor
@Observable
public final class TutorialProgress {
    static let stepKey = "kalsmritikosh.tutorial.step"

    /// The current step index, or nil when the tutorial is not running.
    public private(set) var index: Int? = {
        let d = AppDefaults.store
        return d.object(forKey: stepKey) == nil ? nil : min(max(d.integer(forKey: stepKey), 0), HelpTutorial.steps.count - 1)
    }()

    public var isRunning: Bool { index != nil }

    public func set(_ i: Int) {
        let clamped = min(max(i, 0), HelpTutorial.steps.count - 1)
        index = clamped
        AppDefaults.store.set(clamped, forKey: Self.stepKey)
    }

    public func stop() {
        index = nil
        AppDefaults.store.removeObject(forKey: Self.stepKey)
    }
}

public nonisolated enum HelpTutorial {
    /// The one progress object the panel, the Help menu and the Guide share.
    @MainActor public static let progress = TutorialProgress()

    public static let steps: [TutorialStep] = [
        TutorialStep(id: "open-sample", title: "You are in the sample case",
                     instruction: "The purple banner says this is the sample archive: its own ledger with eight bundled Project Delta documents (a supply contract, Amendment 7, two invoices, four emails). Open Sources to see them read.",
                     expect: "Sources lists the ProjectDelta folder, “8 file(s) ingested”, and the indicator reads “Ready”. Your own documents are not here and were not opened.",
                     destination: .sources, controls: ["Ready"]),
        TutorialStep(id: "question", title: "Choose the investigation question",
                     instruction: "Open Professional Jobs, choose the “Investigator” card and press “Start matter” after typing the title “Project Delta slip”. The question for this matter: why did the first delivery slip, and who approved the change?",
                     expect: "“Created case “Project Delta slip” … with 8 source(s) in scope”, the jobs grouped in phases, and “Start here — open a matter” done.",
                     destination: .work, controls: ["Start matter", "Start here — open a matter"]),
        TutorialStep(id: "authorise", title: "Inspect and authorise the case documents",
                     instruction: "Press “Add documents to this case” — or “Review new documents” when the matter already holds the workspace’s documents. Read the preview: how many are in scope now, how many are new, how many stay excluded. Nothing is added until you confirm.",
                     expect: "“Documents: 8 in scope”. Only these documents are read for this matter’s jobs and questions.",
                     destination: .work, controls: ["Add documents to this case", "Review new documents"]),
        TutorialStep(id: "ask", title: "Ask — one settled question, one the record cannot settle",
                     instruction: "Open Ask. Type “When was Amendment 7 approved, and who signed it?” and press “Send question”. Then ask “Was invoice 432 paid?”.",
                     expect: "The first answer quotes the amendment — effective 2 May 2024, signed by John Carter (Northwind) and Maria Lopez (Supplier ABC) — with a citation chip for it. The second quotes the record as it stands: invoice 432 issued 30 May 2024, due 29 June, “unpaid as of June 14, 2024”; no document records a payment and none is invented. The badge says how far the evidence goes.",
                     destination: .ask, controls: ["Send question"]),
        TutorialStep(id: "citation", title: "Open the exact citation",
                     instruction: "Under the first answer press the numbered citation chip “1 amendment-7.md”.",
                     expect: "The amendment opens in a sheet with the cited passage highlighted. The quotation is checked against the document; whether the document is right is your judgement. “Done” closes it.",
                     destination: .ask, controls: ["Done"]),
        TutorialStep(id: "conflict", title: "Review conflicting accounts",
                     instruction: "Open Findings ▸ Contradictions. The first-lot delivery date was given as about 13 May 2024 (8 April email), then 28 May 2024 (18 April email and the amendment).",
                     expect: "A row “Conflicting dates for “Delivery delayed”” — “Conflicts with a second source; both claims are preserved and not reconciled automatically”, 2 sources, “Review”. An estimate that was later revised is shown as a conflict to review, not labelled wrong — you decide what it means and record why.",
                     destination: .findings, controls: ["Review"]),
        TutorialStep(id: "review", title: "Save a reviewed result",
                     instruction: "Back in Professional Jobs, press “Run” on a Collect & organize job that produces rows — “Documentary evidence register” — then “Open result”. Decide a row (Accepted or Rejected), type a note, press “Save review”.",
                     expect: "The result shows “Reviewed by me, <date>” and your decisions; the jobs summary counts “1 to review”. Unreviewed rows stay marked unreviewed wherever they are carried.",
                     destination: .work, controls: ["Run", "Open result", "Save review"]),
        TutorialStep(id: "carry", title: "Carry it into the report",
                     instruction: "On the reviewed row press “Add to case…” and choose “Include in report”; then “Add to chronology”.",
                     expect: "“Row 1 selected for the case report (accepted on review; every citation and the revision kept).” and “Row 1 added to the case chronology …”. The case log records both.",
                     destination: .work, controls: ["Add to case…", "Include in report", "Add to chronology"]),
        TutorialStep(id: "export", title: "Export the report and reopen it",
                     instruction: "Open Cases, open the matter, go to “Log & exports” and press “Case file report…”. Save the file, then open it from the Finder.",
                     expect: "The notice reads “Exported <name> (SHA-256 …), recorded.” and the case log gains an “exported” line. The report lists the reviewed rows you included with their sources, the chronology entry, and an “Unresolved questions and limitations” section.",
                     destination: .cases, controls: ["Case file report…"]),
        TutorialStep(id: "finish", title: "What you saw, and back to your own archive",
                     instruction: "A settled point (the amendment’s approval, quoted from the document) and one the record leaves open (the payment: unpaid as of 14 June 2024, nothing later). Press “Back to my archive” in the banner when you are done.",
                     expect: "The app relaunches on your own archive. Nothing from the sample was written to it; the tutorial can be replayed any time from Help ▸ Replay the Tutorial.",
                     destination: .home, controls: ["Back to my archive"])
    ]

    /// Start (or restart) from the first step. Enters the sample case first when not already in it;
    /// the person's own archive is never used for the tutorial.
    @MainActor public static func replay() {
        progress.set(0)
        if !SampleArchiveMode.isActive { SampleArchiveMode.enter() }
    }
}

/// The tutorial column beside the sample case while the tutorial runs. Back/Next, position, Show me,
/// Stop; nothing advances by itself; keyboard-operable buttons; no motion.
struct TutorialPanel: View {
    @State private var progress = HelpTutorial.progress
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let index = progress.index {
            let step = HelpTutorial.steps[index]
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Tutorial", systemImage: "graduationcap").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Text("Step \(index + 1) of \(HelpTutorial.steps.count)").font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("tutorial.position")
                    Button { progress.stop() } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help("Stop the tutorial. Replay it any time from Help ▸ Replay the Tutorial.")
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
                    Button("Back") { progress.set(index - 1) }.disabled(index == 0)
                        .accessibilityIdentifier("tutorial.back")
                    if let dest = step.destination {
                        Button { SurfaceOpener.open(dest) } label: { Label("Show me", systemImage: dest.icon) }
                            .help("Open \(dest.title)")
                            .accessibilityIdentifier("tutorial.showMe")
                    }
                    Spacer()
                    if index == HelpTutorial.steps.count - 1 {
                        Button("Finish") { progress.stop() }.buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("tutorial.next")
                    } else {
                        Button("Next") { progress.set(index + 1) }.buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("tutorial.next")
                    }
                }
                .controlSize(.small)
            }
            .padding(14)
            .frame(width: 320, alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(.regularMaterial)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("tutorial.panel")
            .transaction { $0.animation = nil }
        }
    }
}
