//
//  CaseMapControlHelp.swift
//  Kalsmritikosh
//
//  Smart-map S12 (HELP-04 / HELP-05 / HELP-10) — one table of the case-map controls added in slices S1–S12, each with what
//  it is for and what happens when it is used, in plain words. The same text is the hover tooltip, the VoiceOver hint
//  (heard on keyboard focus, so nothing needs a mouse) and a Help topic rendered into the manual; the tools panel also
//  shows each section's purpose inline, so the critical instruction never depends on hovering. HelpRegistryTests checks
//  that every control named here exists in the UI sources and that no entry uses internal jargon.
//
//  Also: the empty, error and partial states of the case tools — each names ONE next action.
//

import SwiftUI

nonisolated enum CaseMapControlHelp {
    struct Entry: Sendable, Equatable {
        let control: String
        let purpose: String
        let consequence: String
        var text: String { "\(purpose) \(consequence)" }
    }

    static let entries: [Entry] = [
        // Recursive work (S1–S4)
        Entry(control: "Open as frame", purpose: "Focus on this item: its sources, points, questions, work and results become the map.",
              consequence: "Nothing in the case changes; “Up one frame” or the breadcrumb returns exactly to where you were."),
        Entry(control: "Up one frame", purpose: "Back to the level this frame was opened from.", consequence: "Nothing changes; the view is as you left it."),
        Entry(control: "Record as a supplied report…", purpose: "Records a document as a report of the case: who produced it, what was examined, its methods and limitations.",
              consequence: "A report item is added beside the document; its points can then be checked one by one."),
        Entry(control: "Add point…", purpose: "Records one point of a report with the exact words from its source.",
              consequence: "The point is checked against the report's document and waits for your review."),
        Entry(control: "Suggest points (rule-based, AI off)", purpose: "Lists candidate sentences of the report found by fixed rules.",
              consequence: "Nothing becomes a point until you accept it; no AI is used."),
        Entry(control: "Accept as a point", purpose: "Turns a suggested sentence into a point of the report.", consequence: "The point is recorded with those words; the suggestion is kept."),
        Entry(control: "Ask a question about this point…", purpose: "Adds an open question to the case, linked to this point.", consequence: "The question is open; it decides nothing."),
        Entry(control: "Create action…", purpose: "Creates a task with its purpose, the result expected, who does it and who reviews it.",
              consequence: "The task is linked to what it serves; finishing it does not answer the question."),
        Entry(control: "Create child action…", purpose: "Creates an action under this one.", consequence: "The parent cannot close until its required children are finished."),
        Entry(control: "Record result…", purpose: "Records what an action produced, as a result report.", consequence: "Add its points next; the question stays open until you decide it."),
        Entry(control: "Submit result for review", purpose: "Sends the result for review.", consequence: "The action waits for a reviewer; working alone, your review is recorded as self-review."),
        Entry(control: "Accept result", purpose: "Accepts this exact version of the result.", consequence: "A later version needs review again."),
        Entry(control: "Return for more work", purpose: "Returns the result to the person doing the work.", consequence: "Its history is kept; the action is open again."),
        Entry(control: "Record outcome…", purpose: "Records what the work found.", consequence: "This is separate from whether the task is done, and it does not decide the question."),
        Entry(control: "Request evidence about this point…", purpose: "Creates an evidence request linked to this point.",
              consequence: "The app sends nothing; only “Record decision” changes the request's status."),
        Entry(control: "Add qualification…", purpose: "Attaches an uncertainty, limitation, exclusion or condition to a point.", consequence: "It travels with the point wherever the point is used."),
        Entry(control: "Place in frame…", purpose: "Places this item in a branch of the case.", consequence: "The item is stored once; withdrawing the placement keeps its history."),
        Entry(control: "Link to another item…", purpose: "Draws a typed link between two items, with your reason.",
              consequence: "The link records who drew it and why; it can be revised or withdrawn, never silently removed."),
        Entry(control: "Record as the same person…", purpose: "Records your decision that two rows are the same person, with the reason.",
              consequence: "Nothing is merged; withdrawing the decision puts the pair back to pending."),
        Entry(control: "Record as different people…", purpose: "Records your decision that two rows are different people.", consequence: "Both rows stay as they are."),
        // Brief, history, search, outputs (S3, S6, S7, S11)
        Entry(control: "Brief", purpose: "Opens the case brief: purpose, scope, the recorded position, what is unresolved, contrary material and next work.",
              consequence: "Reading it changes nothing; each line opens its item on the map."),
        Entry(control: "Create briefing", purpose: "Starts a named briefing: an ordered set of items for a reader.", consequence: "Nothing leaves the app until you export it."),
        Entry(control: "Freeze this briefing", purpose: "Fixes the briefing's content at the case as it is now.", consequence: "Later changes to the case are not mixed into it."),
        Entry(control: "Export this briefing…", purpose: "Writes the briefing to a file through the export checks.", consequence: "The file is read back and the export recorded in the case log."),
        Entry(control: "Record the current state", purpose: "Records the map as it is now, read-only.", consequence: "Nothing in the case changes; open it later from History."),
        Entry(control: "Mark as seen", purpose: "Moves your own seen position in What changed.", consequence: "It reviews or accepts nothing."),
        Entry(control: "Search case evidence", purpose: "Searches the text and recorded details of this case's documents.",
              consequence: "It says what it could not search; nothing is sent anywhere."),
        Entry(control: "Export the money report…", purpose: "Writes the case's money figures and records to a file.", consequence: "It goes through the export checks and is recorded."),
        Entry(control: "Export the case package (read-only, whole case)…", purpose: "Writes the whole case as one read-only page that opens in any browser.",
              consequence: "It runs no script and fetches nothing; the export is checked and recorded."),
        Entry(control: "Approve the reports and the package at this revision", purpose: "Records a reviewer's approval of the case's reports exactly as they are now.",
              consequence: "Any later change makes them drafts again; working alone the approval is labelled self-approved."),
        // S12 — the case tools
        Entry(control: "Case tools", purpose: "Opens this case's automation, AI assistant, money, people and roles, relationship patterns, history set, briefings and exchange files.",
              consequence: "Opening it changes nothing."),
        Entry(control: "Set automation mode", purpose: "Chooses what the case's rules may do by themselves: nothing, propose, or create and route allowed work.",
              consequence: "A new policy version is recorded. It never changes whether documents may be sent to an AI."),
        Entry(control: "Resume held work", purpose: "Runs work that was held (for example after a restore or a budget stop) again.",
              consequence: "Each item is checked again first: the case is open, its documents are current and the policy still allows it."),
        Entry(control: "Cancel queued work", purpose: "Stops one queued item.", consequence: "It is cancelled with your reason and its record is kept."),
        Entry(control: "Set assistant mode", purpose: "Chooses whether the case's AI assistant is off, only suggests, or may apply allowed structural changes.",
              consequence: "A new policy version is recorded. It is not permission to send documents: that is asked once per case."),
        Entry(control: "Accept proposal", purpose: "Accepts an AI proposal.", consequence: "Its document versions are checked again first; the decision is recorded with your name."),
        Entry(control: "Reject proposal", purpose: "Rejects an AI proposal, with your reason.", consequence: "It is not offered again unless something it rests on changes."),
        Entry(control: "Defer proposal", purpose: "Decides later.", consequence: "It keeps waiting, with your reason."),
        Entry(control: "Record money…", purpose: "Records one amount exactly as a document writes it, with its day, parties and source.",
              consequence: "An unclassified record stays out of every figure until you classify it."),
        Entry(control: "Give a role…", purpose: "Gives a person a role in this case (owner, investigator, reviewer, contributor or viewer).",
              consequence: "The case becomes a team case and every change is checked against the roles recorded."),
        Entry(control: "Remove role…", purpose: "Removes a person's role, with the reason.", consequence: "It takes effect at once; what they recorded keeps their name."),
        Entry(control: "Find paths", purpose: "Finds how two items of the map connect, following only the link types you choose.",
              consequence: "It reads the map only; nothing is recorded until you save the pattern."),
        Entry(control: "Save pattern", purpose: "Keeps the pattern under a name in this case.", consequence: "It is saved as a live pattern; running it again reads the case as it is then."),
        Entry(control: "Add to history set…", purpose: "Adds another case to this case's history set, with a purpose and a scope.",
              consequence: "Nothing is copied: its records are read again each time under today's access."),
        Entry(control: "Export structured exchange (JSON)…", purpose: "Writes this case's questions, people, dated events, their sources and your links as a documented JSON file.",
              consequence: "It goes through the export checks and is recorded; every item keeps a stable identifier."),
        Entry(control: "Import structured exchange (JSON)…", purpose: "Reads a structured exchange file into this case.",
              consequence: "New records are added with their origin; records already imported are matched, not duplicated; the receipt lists everything not imported."),
        Entry(control: "Attach a supplied summary…", purpose: "Attaches a summary a person supplied for a document the app could not read.",
              consequence: "It is shown as supplied, with who supplied it — never as the document's own words."),
        Entry(control: "Start from a question…", purpose: "Starts a case from the question it is to answer, without the intake form.",
              consequence: "The case is created with that question; add documents and people when you are ready."),
        Entry(control: "Add as an open question", purpose: "Carries a reviewed result row into the case as an open question.",
              consequence: "It keeps the row's origin and review state; carrying the same row twice is refused."),
        Entry(control: "Add to money records", purpose: "Carries a result row's amount into the case's money records.",
              consequence: "It enters as unclassified, in no figure, until you classify it; carrying the same row twice is refused."),
        Entry(control: "Replay the Smart Map Guide", purpose: "Walks the whole case-map journey in the sample case, one step at a time.",
              consequence: "It runs only in the sample case; nothing touches your own cases."),
    ]

    static func entry(_ control: String) -> Entry? { entries.first { $0.control == control } }
    /// The tooltip and VoiceOver hint of a control (empty when it has none — the test keeps that from happening).
    static func text(_ control: String) -> String { entry(control)?.text ?? "" }

    /// Words that must not appear in help a person reads (internal names).
    static let jargon = ["projection", "fence", "node", "edge", "savepoint", "actor", "enum", "uuid", "sqlite", "outbox", "payload", "digest"]
}

extension View {
    /// The control's purpose and consequence as the tooltip and as the VoiceOver hint (heard on keyboard focus).
    func caseMapControlHelp(_ control: String) -> some View {
        let t = CaseMapControlHelp.text(control)
        return self.help(t).accessibilityHint(t)
    }
}

// MARK: - HELP-05: states of the case tools, each with one next action

nonisolated enum CaseToolState: Equatable, Sendable {
    case loading
    case ready
    /// Nothing recorded yet: what is missing, and the one next action.
    case empty(what: String, next: String)
    /// The ledger refused or failed: the reason, and the one next action.
    case failed(reason: String, next: String)
    /// The person's role does not allow it: who can fix it.
    case accessDenied(reason: String, next: String)
    /// The AI failed: what happened, and what still works by hand.
    case aiFailed(reason: String, next: String)
    /// Work is blocked: by what, and what would unblock it.
    case blocked(reason: String, next: String)

    var message: (title: String, next: String, symbol: String)? {
        switch self {
        case .loading, .ready: return nil
        case .empty(let what, let next): return (what, next, "tray")
        case .failed(let reason, let next): return ("Could not be read: \(reason)", next, "xmark.octagon")
        case .accessDenied(let reason, let next): return ("Not allowed: \(reason)", next, "lock")
        case .aiFailed(let reason, let next): return ("The AI did not answer: \(reason)", next, "exclamationmark.bubble")
        case .blocked(let reason, let next): return ("Blocked: \(reason)", next, "hand.raised")
        }
    }

    /// The state for an error from the ledger or a service: access refusals and AI failures get their own words.
    static func from(_ error: Error, doing what: String) -> CaseToolState {
        let text = error.localizedDescription
        if error is CaseAccessError {
            return .accessDenied(reason: text, next: "Ask the case's owner to give you a role that allows \(what) (Case tools ▸ People and roles).")
        }
        if error is CaseAIAssistError {
            return .aiFailed(reason: text, next: "Everything in the case still works by hand; check Settings ▸ Online, then try again.")
        }
        if let e = error as? CaseFileError, e == .caseClosed {
            return .blocked(reason: "the case is closed.", next: "Reopen the case in Case sections ▸ Overview to change it.")
        }
        return .failed(reason: text, next: "Choose Refresh. If it fails again, the case sections hold the same records.")
    }
}

/// The shared state message: the reason and the one next action, as text (never hover-only).
struct CaseToolStateView: View {
    let state: CaseToolState
    var body: some View {
        if let m = state.message {
            VStack(alignment: .leading, spacing: 4) {
                Label(m.title, systemImage: m.symbol).font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                Text("Next: " + m.next).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("case.tools.state")
        } else if state == .loading {
            ProgressView().controlSize(.small)
        }
    }
}
