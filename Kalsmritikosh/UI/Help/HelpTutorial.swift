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
//  → inspect and authorise the case documents → see the case at a glance and what was read → ask → open
//  the exact citation → review conflicting accounts and decide one in place → save a reviewed result →
//  carry it into the report → ask a custodian for missing material → export and reopen it (Package B). It shows both a
//  supported conclusion (Amendment 7: approved 2 May 2024, signed by John Carter and Maria Lopez) and a
//  question the evidence cannot settle (whether invoice 432 was ever paid — the record stops at “unpaid”).
//
//  The wording of every step was checked against UI run i (2026-10-31): the names are the controls that
//  exist, and “What you should see” is what the sample really showed.
//

import SwiftUI
import AppKit
import os

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
    static let pathKey = "kalsmritikosh.tutorial.path"

    /// Which tutorial runs (M9: the case map has its own path); mirrored to the preference store.
    public private(set) var path: TutorialPath = TutorialPath(rawValue: AppDefaults.store.string(forKey: pathKey) ?? "") ?? .caseToReport

    /// The current step index, or nil when the tutorial is not running.
    public private(set) var index: Int? = {
        let d = AppDefaults.store
        let steps = HelpTutorial.steps(for: TutorialPath(rawValue: d.string(forKey: pathKey) ?? "") ?? .caseToReport)
        return d.object(forKey: stepKey) == nil ? nil : min(max(d.integer(forKey: stepKey), 0), steps.count - 1)
    }()

    public var isRunning: Bool { index != nil }

    /// The steps of the running path.
    public var steps: [TutorialStep] { HelpTutorial.steps(for: path) }

    public func set(_ i: Int) {
        let clamped = min(max(i, 0), steps.count - 1)
        index = clamped
        AppDefaults.store.set(clamped, forKey: Self.stepKey)
    }

    /// Choose a path (from its first step). Nothing advances by itself.
    public func start(_ p: TutorialPath) {
        path = p
        AppDefaults.store.set(p.rawValue, forKey: Self.pathKey)
        set(0)
    }

    public func stop() {
        index = nil
        AppDefaults.store.removeObject(forKey: Self.stepKey)
        path = .caseToReport
        AppDefaults.store.removeObject(forKey: Self.pathKey)
    }
}

/// The replayable tutorials. Both run only in the isolated sample case.
public nonisolated enum TutorialPath: String, CaseIterable, Sendable {
    /// Matter → documents → ask → citation → contradiction → review → report → request → export.
    case caseToReport
    /// M9 (plan §10): the same work on the case map — question → document → passage → review → request →
    /// new evidence → revised view → report.
    case caseMap
    /// S12 (HELP-02): the first-case smart-map guide — report → point → question → action → result → deeper point, then the
    /// brief, case search, money and history.
    case smartMap

    public var title: String {
        switch self {
        case .caseToReport: return "Tutorial"
        case .caseMap: return "Case map tutorial"
        case .smartMap: return "Smart map guide"
        }
    }
}

public nonisolated enum HelpTutorial {
    /// The one progress object the panel, the Help menu and the Guide share.
    @MainActor public static let progress = TutorialProgress()

    public static let steps: [TutorialStep] = [
        TutorialStep(id: "open-sample", title: "You are in the sample case",
                     instruction: "The purple banner says this is the sample archive: its own ledger with eight bundled Project Delta documents (a supply contract, Amendment 7, two invoices, four emails). Open Evidence ▸ Sources to see them read.",
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
        TutorialStep(id: "overview", title: "See the case at a glance and what was read",
                     instruction: "Open Cases and open the matter. Its Overview starts with “This case at a glance”: the question, what waits for you, the evidence requests and “What the app could read”. Choose a count or the “Next:” step to go where it is done.",
                     expect: "“What the app could read” gives the documents read, partly read and not read, each one counted once, every unread one with its reason. The case reopens here, on the tab you leave, after a restart too.",
                     destination: .cases, controls: ["Show all"]),
        TutorialStep(id: "ask", title: "Ask — one settled question, one the record cannot settle",
                     instruction: "In the matter press “Ask about this case” (or open Search and choose “Ask a question”): with the matter open, the question is asked in it. Type “When was Amendment 7 approved, and who signed it?” and press “Send question”. Then ask “Was invoice 432 paid?”.",
                     expect: "The first answer quotes the amendment — effective 2 May 2024, signed by John Carter (Northwind) and Maria Lopez (Supplier ABC) — with a citation chip for it. The second quotes the record as it stands: invoice 432 issued 30 May 2024, due 29 June, “unpaid as of June 14, 2024”; no document records a payment and none is invented. The badge says how far the evidence goes.",
                     destination: .ask, controls: ["Ask about this case", "Ask a question", "Send question"]),
        TutorialStep(id: "citation", title: "Open the exact citation",
                     instruction: "Under the first answer press the numbered citation chip “1 amendment-7.md”.",
                     expect: "The amendment opens in a sheet with the cited passage highlighted. The quotation is checked against the document; whether the document is right is your judgement. “Done” closes it.",
                     destination: .ask, controls: ["Done"]),
        TutorialStep(id: "conflict", title: "Review conflicting accounts",
                     instruction: "Open Findings ▸ Contradictions. The first-lot delivery date was given as about 13 May 2024 (8 April email), then 28 May 2024 (18 April email and the amendment).",
                     expect: "A row “Conflicting dates for “Delivery delayed”” — “Conflicts with a second source; both claims are preserved and not reconciled automatically”, 2 sources, “Review”. An estimate that was later revised is shown as a conflict to review, not labelled wrong — you decide what it means and record why.",
                     destination: .findings, controls: ["Review"]),
        TutorialStep(id: "decide", title: "Decide a contradiction where it is shown",
                     instruction: "In the matter: Overview ▸ Contradictions, press “Find contradictions”. Choose an item: its two passages are shown beside it, each with “Open source”. Record “Confirm”, “Dismiss” (choose a reason) or “Defer”.",
                     expect: "The item shows your decision and its reason, kept with the version of both documents; neither document is changed. If the check lists nothing for this matter, the list says so and there is nothing to decide.",
                     destination: .cases, controls: ["Find contradictions", "Open source", "Confirm", "Dismiss", "Defer"]),
        TutorialStep(id: "review", title: "Save a reviewed result",
                     instruction: "Back in Professional Jobs, press “Run” on a Collect & organize job that produces rows — “Documentary evidence register” — then “Open result”. Decide a row (Accepted or Rejected), type a note, press “Save review”.",
                     expect: "The result shows “Reviewed by me, <date>” and your decisions; the jobs summary counts “1 to review”. Unreviewed rows stay marked unreviewed wherever they are carried.",
                     destination: .work, controls: ["Run", "Open result", "Save review"]),
        TutorialStep(id: "carry", title: "Carry it into the report",
                     instruction: "On the reviewed row press “Add to case…” and choose “Include in report”; then “Add to chronology”.",
                     expect: "“Row 1 selected for the case report (accepted on review; every citation and the revision kept).” and “Row 1 added to the case chronology …”. The case log records both.",
                     destination: .work, controls: ["Add to case…", "Include in report", "Add to chronology"]),
        TutorialStep(id: "request", title: "Ask a custodian for missing material",
                     instruction: "In the matter: Evidence ▸ Evidence requests. Type what is requested (for example “Proof of payment of invoice 432”), the custodian (“Northwind accounts”), and press “Create request”. Then “Draft request text…” to see the letter you would send yourself, and “Record sent”.",
                     expect: "The request is listed as Open with “No expected items listed.” and its history shows it was sent. The app sends nothing; only “Record decision” ever changes its status.",
                     destination: .cases, controls: ["Create request", "Draft request text…", "Record sent", "Record decision"]),
        TutorialStep(id: "export", title: "Export the report and reopen it",
                     instruction: "Open Cases, open the matter, go to “Log & exports” and press “Case file report…”. Save the file, then open it from the Finder.",
                     expect: "The notice reads “Exported <name> (SHA-256 …), recorded.” and the case log gains an “exported” line. The report lists the reviewed rows you included with their sources, the chronology entry, and an “Unresolved questions and limitations” section, followed by “What the app could read” and “Evidence requests” with the request you created.",
                     destination: .cases, controls: ["Case file report…"]),
        TutorialStep(id: "finish", title: "What you saw, and back to your own archive",
                     instruction: "A settled point (the amendment’s approval, quoted from the document) and one the record leaves open (the payment: unpaid as of 14 June 2024, nothing later). Press “Back to my archive” in the banner when you are done.",
                     expect: "The app relaunches on your own archive. Nothing from the sample was written to it; the tutorial can be replayed any time from Help ▸ Replay the Tutorial.",
                     destination: .home, controls: ["Back to my archive"])
    ]

    /// M9 (plan §10) — the case map path in the sample case: the real workflow, manually stepped. Each step is
    /// done by the person on the real map; the "What you should see" lines describe the map's own behaviour.
    public static let caseMapSteps: [TutorialStep] = [
        TutorialStep(id: "map-open", title: "Open the sample case on the map",
                     instruction: "Open Cases and open the sample matter (start one first with “Start matter” in Professional Jobs if the sample has none). Turn on “Case map (preview)” in the case's top bar.",
                     expect: "The case opens on the map. The header shows the case's title and stage, its question, what the app could read and the counts; the strip below starts on Overview. “Case sections” returns to the tabs at any time.",
                     destination: .cases, controls: ["Start matter", "Case map (preview)", "Case sections"]),
        TutorialStep(id: "map-question", title: "The question",
                     instruction: "Read the question in the header (“More” shows all of it). If none is recorded, the header says where to record it. Choose a count — for example the open questions — to see exactly those items in the list.",
                     expect: "The list shows the items the count names, under the same filters the map uses. Nothing is decided by opening them.",
                     destination: .cases, controls: ["More"]),
        TutorialStep(id: "map-document", title: "A document",
                     instruction: "Choose “List” in the strip and select a document, for example amendment-7.md (or choose it on the map). In the inspector press “Open source”.",
                     expect: "The inspector shows the document's version and where each citation points (“Position unavailable” when only the document is known). The source opens in a sheet; closing it brings you back to the same item.",
                     destination: .cases, controls: ["List", "Open source"]),
        TutorialStep(id: "map-passage", title: "A passage",
                     instruction: "Choose “Search this case” ▸ “Search case evidence” and search for “Amendment 7”. On a match choose “Add to chronology…”.",
                     expect: "Every matching document is listed with the matched words in their passage and what was searched. The passage goes into the case's chronology with its citation, checked against the document; on the map it appears next to the document it cites.",
                     destination: .cases, controls: ["Search this case", "Search case evidence", "Add to chronology…"]),
        TutorialStep(id: "map-review", title: "A review",
                     instruction: "Choose the “Questions” view. Select a contradiction (the first-lot delivery date) and, in the inspector, record “Confirm”, “Dismiss” (choose a reason) or “Defer”.",
                     expect: "The item shows your decision and its reason — the same decision as in the case's contradiction list, kept with the versions of both documents. Neither document changes.",
                     destination: .cases, controls: ["Confirm", "Dismiss", "Defer"]),
        TutorialStep(id: "map-request", title: "A request",
                     instruction: "Select the case's question and press “Create evidence request…”. Type what is requested (for example “Proof of payment of invoice 432”) and the custodian, then “Create request”.",
                     expect: "A request item appears linked to the question, Open, with what is expected. The app sends nothing.",
                     destination: .cases, controls: ["Create evidence request…", "Create request"]),
        TutorialStep(id: "map-new-evidence", title: "New evidence",
                     instruction: "Select a document that answers part of the request and choose “Received for request…” ▸ the request.",
                     expect: "The request shows what arrived, by source version, and what is still missing. It stays Open: arriving does not fulfil a request; only “Record decision” in Evidence requests changes its status.",
                     destination: .cases, controls: ["Received for request…", "Record decision"]),
        TutorialStep(id: "map-revised", title: "The revised view",
                     instruction: "Choose “What changed” in the header, read the list, then “Mark as seen”. Choose “Back” to return to where you were.",
                     expect: "The receipt, the chronology entry and your review are listed, each with where it comes from. Items you saw before stayed where they were; new ones sit next to what they link to. Marking as seen reviews nothing.",
                     destination: .cases, controls: ["What changed", "Mark as seen", "Back"]),
        TutorialStep(id: "map-report", title: "The report",
                     instruction: "Select the confirmed contradiction and press “Include in report”. Then choose “Export” at the foot of the map ▸ “Export map as PDF (with its relationship table)…”, or the case's “Case file report…”.",
                     expect: "The item is selected for the report with both passages, nothing retyped. The export is checked against the case's sources as they are now and recorded in the case log; the relationship table lists every link with why it exists and its sources.",
                     destination: .cases, controls: ["Include in report", "Export", "Export map as PDF (with its relationship table)…", "Case file report…"]),
        TutorialStep(id: "map-finish", title: "What you did, and back to your own archive",
                     instruction: "Question, document, passage, review, request, new evidence, revised view, report — the whole path on the map, with the list doing the same. “Reset view” tidies the map without changing the case. Press “Back to my archive” in the banner when you are done.",
                     expect: "The app relaunches on your own archive. Nothing from the sample was written to it; Help ▸ Replay the Case Map Tutorial plays this again.",
                     destination: .home, controls: ["Reset view", "Back to my archive"])
    ]

    /// S12 (HELP-02) — the smart-map journey in the sample case, manually stepped: a report, one of its points, the
    /// question it raises, the action that serves it, the result, a deeper point inside the result — then the brief, case
    /// search, money and history. Every step is done by the person on the real controls.
    public static let smartMapSteps: [TutorialStep] = [
        TutorialStep(id: "sm-open", title: "Open the sample case on the map",
                     instruction: "Open Cases and open the sample matter (start one with “Start matter” in Professional Jobs if the sample has none). Turn on “Case map (preview)”. The header holds “Case tools” — the case's automation, AI assistant, money, people and roles, patterns, history set, briefings and exchange files.",
                     expect: "The map opens on Overview with the case's question in the header. Nothing is sent anywhere by opening, panning or switching views.",
                     destination: .cases, controls: ["Start matter", "Case map (preview)", "Case tools"]),
        TutorialStep(id: "sm-report", title: "A report",
                     instruction: "Choose “List” and select the document amendment-7.md. In the inspector press “Record as a supplied report…”, name who produced it (Northwind and Supplier ABC) and what it covers.",
                     expect: "A report item appears beside the document, derived from it. The document is unchanged; the report is now something the case can examine point by point.",
                     destination: .cases, controls: ["List", "Record as a supplied report…"]),
        TutorialStep(id: "sm-point", title: "A point of the report",
                     instruction: "Select the report and press “Add point…”: type the point (the first-lot delivery moves to 28 May 2024) and paste the exact words from the amendment. Or press “Suggest points (rule-based, AI off)” and “Accept as a point”.",
                     expect: "The point is checked against the amendment's words and waits for your review. A suggestion is not a point until you accept it.",
                     destination: .cases, controls: ["Add point…", "Suggest points (rule-based, AI off)", "Accept as a point"]),
        TutorialStep(id: "sm-question", title: "The question it raises",
                     instruction: "Select the point and press “Ask a question about this point…”: “Who approved moving the delivery date?”",
                     expect: "An open question appears, linked to the point it was raised from. It decides nothing.",
                     destination: .cases, controls: ["Ask a question about this point…"]),
        TutorialStep(id: "sm-action", title: "The action that serves it",
                     instruction: "Select the question and press “Create action…”: the purpose, the result expected (the approval record) and “Responsible (a name; optional)”.",
                     expect: "A task appears serving the question, assigned to the person you named. Finishing it will not answer the question for you.",
                     destination: .cases, controls: ["Create action…", "Responsible (a name; optional)"]),
        TutorialStep(id: "sm-result", title: "Its result",
                     instruction: "Select the task and press “Record result…” (for example “Approval email from Maria Lopez”), then “Submit result for review” and “Accept result”.",
                     expect: "The result is a report of its own under the task. Working alone, your acceptance is recorded as self-review; the question keeps its own decision.",
                     destination: .cases, controls: ["Record result…", "Submit result for review", "Accept result"]),
        TutorialStep(id: "sm-deeper", title: "A deeper point",
                     instruction: "Select the result and press “Open as frame” (⌃⌘↩). Inside it press “Add point…” for what the result says. Press “Up one frame” (⌃⌘↑) to come back.",
                     expect: "The frame shows only the result's own sources, points and work; the breadcrumb names each level. Coming back returns exactly to where you were.",
                     destination: .cases, controls: ["Open as frame", "Add point…", "Up one frame"]),
        TutorialStep(id: "sm-brief", title: "The brief",
                     instruction: "Press “Brief” in the header, or select the question and press “Brief of this branch”.",
                     expect: "Purpose, the recorded position, what is unresolved, contrary material and the next work — each line opens its item. Reading it changes nothing.",
                     destination: .cases, controls: ["Brief", "Brief of this branch"]),
        TutorialStep(id: "sm-search", title: "Search the case",
                     instruction: "Choose “Search this case” ▸ “Search case evidence” and search for invoice 432.",
                     expect: "Every matching passage is listed with what was searched and what could not be. Nothing is sent anywhere.",
                     destination: .cases, controls: ["Search this case", "Search case evidence"]),
        TutorialStep(id: "sm-money", title: "Money",
                     instruction: "Open “Case tools” ▸ Money. Record invoice 432 as written (kind “invoice”, the amount as the invoice writes it) with “Record money…”. Then “Export the money report…” from the map's Export menu if you want the file.",
                     expect: "The invoice is listed as a mention of money: it is outstanding, not paid, and enters no paid figure. Currencies are never added together.",
                     destination: .cases, controls: ["Case tools", "Record money…", "Export the money report…"]),
        TutorialStep(id: "sm-history", title: "History",
                     instruction: "Press “History”, then “Record the current state”. Open the recorded state, look, and press “Return to current” (⌘⎋).",
                     expect: "The recorded state opens read-only with its review states and links as they were. Returning brings back the live case exactly as you left it.",
                     destination: .cases, controls: ["History", "Record the current state", "Return to current"]),
        TutorialStep(id: "sm-finish", title: "What you did, and back to your own archive",
                     instruction: "Report, point, question, action, result, deeper point — then brief, search, money and history. Help ▸ Replay the Smart Map Guide plays it again. Press “Back to my archive” in the banner when you are done.",
                     expect: "The app relaunches on your own archive. Nothing from the sample was written to it.",
                     destination: .home, controls: ["Replay the Smart Map Guide", "Back to my archive"])
    ]

    public static func steps(for path: TutorialPath) -> [TutorialStep] {
        switch path {
        case .caseToReport: return steps
        case .caseMap: return caseMapSteps
        case .smartMap: return smartMapSteps
        }
    }

    /// Start (or restart) from the first step. Enters the sample case first when not already in it;
    /// the person's own archive is never used for the tutorial.
    @MainActor public static func replay(_ path: TutorialPath = .caseToReport) {
        progress.start(path)
        if !SampleArchiveMode.isActive { SampleArchiveMode.enter() }
    }
}

/// The tutorial column beside the sample case while the tutorial runs. Back/Next, position, Show me,
/// Stop; nothing advances by itself; keyboard-operable buttons; no motion.
struct TutorialPanel: View {
    /// The column's width, given by the window (UI run k: a fixed 320 pt overflowed an 1100-pt window).
    var width: CGFloat = 320
    @State private var progress = HelpTutorial.progress
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let index = progress.index {
            let steps = progress.steps
            let step = steps[min(index, steps.count - 1)]
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(progress.path.title, systemImage: "graduationcap").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Text("Step \(index + 1) of \(steps.count)").font(.caption).foregroundStyle(.secondary)
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
                    if index >= steps.count - 1 {
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
            .frame(width: width, alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(.regularMaterial)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("tutorial.panel")
            .transaction { $0.animation = nil }
        }
    }
}


/// UI run k — widens the window for the tutorial column and gives the width back afterwards.
@MainActor
enum TutorialWindowRoom {
    private static var added: CGFloat = 0

    static func adjust(running: Bool, by extra: CGFloat) {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }),
              let screen = window.screen ?? NSScreen.main else {
            KalsmritikoshLog.app.error("Tutorial column: no window to widen")
            return
        }
        var frame = window.frame
        let visible = screen.visibleFrame
        if running {
            let target = min(visible.width, frame.width + extra)
            added = max(0, target - frame.width)
            guard added > 0 else { return }
            frame.size.width = target
            if frame.maxX > visible.maxX { frame.origin.x = max(visible.minX, visible.maxX - frame.width) }
        } else {
            guard added > 0 else { return }
            frame.size.width = max(window.minSize.width, frame.width - added)
            added = 0
        }
        window.setFrame(frame, display: true, animate: false)
        KalsmritikoshLog.app.info("Tutorial column: window width \(window.frame.width, privacy: .public) (running \(running, privacy: .public))")
    }
}
