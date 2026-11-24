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
        // ALCOA ALC-02 (owner 2026-11-24) — Review AI findings.
        Entry(control: "Accept this AI finding", purpose: "Records that you checked this AI finding and accept it.",
              consequence: "A decision is added with your name and the time; it can be changed later by a new decision, never edited."),
        Entry(control: "Reject this AI finding", purpose: "Records that this AI finding is wrong or not usable, with your reason.",
              consequence: "It stays in the case, marked rejected, and is left out of a final report."),
        Entry(control: "Correct this AI finding", purpose: "Records your corrected wording of this AI finding, with your reason.",
              consequence: "The AI's wording is kept; a final report uses your correction."),
        Entry(control: "Copy final report", purpose: "Copies the AI findings you accepted or corrected, as plain text.",
              consequence: "Nothing is changed. Protected names are checked before anything is copied."),
        Entry(control: "Copy draft report", purpose: "Copies every AI finding of the case, reviewed or not, labelled as a draft.",
              consequence: "Nothing is changed. Protected names are checked before anything is copied."),
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
        Entry(control: "Record money…", purpose: "Records one amount exactly as a document writes it, with the kind you chose, its day, parties and source document.",
              consequence: "It enters the figures its kind belongs to; an entry marked not yet classified is counted as not counted until you choose a kind."),
        // Ease fixes A (AI off) — statement import, explicit kinds and their revision, the source of a hand entry.
        Entry(control: "Import bank statement…", purpose: "Reads a bank statement file (CSV or tab-separated) and shows every row before anything is recorded.",
              consequence: "Nothing is written until you choose “Import all rows”; then you choose the account and period and see each refused row with why."),
        Entry(control: "Import all rows", purpose: "Records the statement and every previewed row, each with the kind shown beside it.",
              consequence: "All or nothing: if any row is refused, nothing is recorded. A receipt says how many rows were imported and refused, and why."),
        Entry(control: "Change kind…", purpose: "Changes what an amount is (payment, receipt, refund, transfer …).",
              consequence: "The change is kept with your name, the time and your reason; the figures follow the new kind."),
        Entry(control: "What haven't we considered?", purpose: "Reviews every professional method against what this case (or this item) records, with AI off, and lists the few useful now with the reason for each.",
              consequence: "Nothing is decided or marked done; \u{201C}Show all\u{201D} lists every method with why it is covered, needs an input, can wait or does not apply."),
        Entry(control: "Investigate this discrepancy…", purpose: "Reviews the methods against a question about this item: what explains it, what would tell the explanations apart.",
              consequence: "It reads the case only; nothing is decided or sent."),
        Entry(control: "Check this claim…", purpose: "Builds two searches from this item's words: records that state it, and records about the same subject that do not state its figure.",
              consequence: "Both are shown and can be edited first; nothing runs until you choose one, and nothing is decided."),
        Entry(control: "Search for it", purpose: "Runs the search for records that state the claim, in this case's documents.",
              consequence: "The case search shows what matched and what it could not search."),
        Entry(control: "Search against it", purpose: "Runs the search for records about the same subject that do not state the claimed figure.",
              consequence: "They are candidates to read, not contradictions; the case search shows what it could not search."),
        Entry(control: "Move to the top…", purpose: "Puts this check first in the list, with your reason.",
              consequence: "The change and the reason are written to the case log; the rules' order is kept for the rest."),
        Entry(control: "Independent", purpose: "Records your review that two sources sharing wording are separate origins, with your reason.",
              consequence: "They count as two origins from then on; the review is kept and can be revised."),
        Entry(control: "One origin", purpose: "Records your review that two sources come from one origin, with your reason.",
              consequence: "They count as one origin; the review is kept and can be revised."),
        Entry(control: "Save the line", purpose: "Keeps what this explanation predicts, what would tell it apart from the others and what it assumes.",
              consequence: "A new revision of the line is recorded; earlier work on it is not changed."),
        Entry(control: "Compare the next documents", purpose: "Runs the contradiction rules over the next page of this case's documents, after the ones already compared.",
              consequence: "It says which documents it compared; pairs between this page and earlier pages are not compared."),
        Entry(control: "Prepare for sending", purpose: "Readies this request for its custodian by letter, email or portal, once.",
              consequence: "Nothing is sent: the app records that it is prepared, not that it went."),
        Entry(control: "Record handed over", purpose: "Records that you posted, emailed or uploaded the request yourself, with any reference.",
              consequence: "Its arrival is not yet known; it cannot be handed over again until you confirm the first."),
        Entry(control: "Confirm sent", purpose: "Records that the hand-over reached the recipient, and how you know.",
              consequence: "The request shows as sent; it is never handed over again."),
        Entry(control: "Confirm not sent", purpose: "Records that the hand-over did not go, and how you know.",
              consequence: "It may be handed over again."),
        Entry(control: "Add to a revised brief…", purpose: "Writes a new version of the case brief with what this accepted result adds to the position.",
              consequence: "The earlier version stays as it was; the new one is marked for review if the result changes."),
        Entry(control: "Run the assistant", purpose: "Asks the case's AI assistant for the kind of help chosen, over the documents it may read.",
              consequence: "It asks once for permission to send them; privileged and restricted documents are never sent; what comes back is a proposal for you to accept, reject or defer."),
        Entry(control: "Add to archive", purpose: "Adds a checked photo, recording or video: the original unchanged, and the text you kept beside it.",
              consequence: "Your corrections are saved as a separate file that says it is a correction; the original is never edited."),
        Entry(control: "Discard", purpose: "Drops an item waiting in Capture.", consequence: "Nothing is added to the archive."),
        Entry(control: "Start this method", purpose: "Starts the method as a draft run in this case.",
              consequence: "The run is not complete until its steps are recorded and reviewed; the review then shows it to continue."),
        Entry(control: "Same payment…", purpose: "Records that two look-alike money records are one payment, with your reason from the documents.",
              consequence: "The figures count them once; the decision is kept with your name and the time, and a later decision can change it."),
        Entry(control: "Two payments…", purpose: "Records that two look-alike money records are two separate payments, with your reason.",
              consequence: "The figures count both; the decision is kept with your name and the time, and a later decision can change it."),
        Entry(control: "Record the new kind", purpose: "Records the kind you chose for the amount, with your reason.",
              consequence: "A classified record is replaced by a revision of the new kind; the original stays, out of every figure."),
        Entry(control: "Source document (optional)", purpose: "Ties the amount to the case document it comes from, with the page or place in it if you type one.",
              consequence: "The amount's provenance names that document; without one it is shown as your own entry."),
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
        Entry(control: "New case…", purpose: "Starts a case: type the question it is to answer (optional) or a title; the intake details are folded and optional.",
              consequence: "The case is created with that question as its purpose; on Professional Jobs it also opens for that profession. Add documents and people when you are ready."),
        Entry(control: "Add documents…", purpose: "Adds files from this Mac straight into this case in one step.",
              consequence: "Each file is read into the library, joins the case's workspace and is included in the case with an intake record and a batch receipt; a file the app could not read is added as not read, with why."),
        Entry(control: "Mark privileged…", purpose: "Marks this document privileged in the protection register, with your name and the reason.",
              consequence: "From then on a report, package or export that cites it is refused when it is released; the mark is kept with its history."),
        Entry(control: "Report as PDF or Word…", purpose: "Offers the case file report as a PDF or a Word document.",
              consequence: "Nothing is written until you choose a format and a place."),
        Entry(control: "Case file report as PDF…", purpose: "Writes the case file report as a PDF, with each citation as document and page.",
              consequence: "It is checked for protected names when it is written, read back and recorded in the case log; a refusal writes nothing."),
        Entry(control: "Case file report as Word…", purpose: "Writes the case file report as a Word document (.docx), with each citation as document and page.",
              consequence: "It is checked for protected names when it is written, read back and recorded in the case log; it holds no macros or links."),
        Entry(control: "Show all jobs", purpose: "Lists every job: every phase at once, and the jobs this profession's list leaves out (such as CAPA or Data Lab).",
              consequence: "It changes only what is listed; no job, result or case changes."),
        Entry(control: "Add as an open question", purpose: "Carries a reviewed result row into the case as an open question.",
              consequence: "It keeps the row's origin and review state; carrying the same row twice is refused."),
        Entry(control: "Add to money records", purpose: "Carries a result row's amount into the case's money records.",
              consequence: "It enters as unclassified, in no figure, until you classify it; carrying the same row twice is refused."),
        // Owner request 2026-11-16 — conflicts of any kind with the person's AI, around the rules.
        Entry(control: "Look for conflicts with AI…", purpose: "Shows what would be sent to your AI, what is withheld and why, and the cost estimate, before anything runs.",
              consequence: "Nothing is sent until you choose “Run the look”. Every quote the AI gives is checked word for word against its document; what it finds stays a proposal until you confirm it."),
        Entry(control: "Run the look", purpose: "Sends this case's allowed documents to your AI, once, and runs the rules as well.",
              consequence: "Checked findings join the contradiction list labelled “Found by AI (verified quotes)”; a pair the rules found too becomes one item. A failure or refusal stores nothing from the AI."),
        Entry(control: "Kind", purpose: "Shows only the conflicts of one kind (date, amount, missing record, a kind the AI named, and others).",
              consequence: "It changes only what is listed."),
        Entry(control: "Need more evidence", purpose: "Records that this conflict cannot be settled on what is in the case yet, with your note.",
              consequence: "It stays open and is kept with your name and the time; neither document changes."),
        Entry(control: "Open at this place", purpose: "Opens the document at the quoted words of this side.",
              consequence: "Nothing changes; the passage is read again from the case's documents."),
        Entry(control: "Replay the Smart Map Guide", purpose: "Walks the whole case-map journey in the sample case, one step at a time.",
              consequence: "It runs only in the sample case; nothing touches your own cases."),
        // QA-16 (2026-11-17): the entry points for the services that had no screen
        Entry(control: "Add person or role", purpose: "Records a person of the case with one role they hold here, in the context you give.",
              consequence: "If the documents already link them to someone in the case, the role is added to that person instead of a second row; a role never implies wrongdoing."),
        Entry(control: "Add profile line", purpose: "Adds one line to the person's profile with where it comes from: a document, someone who supplied it, or your own note.",
              consequence: "The line always shows its origin; a supplied or unsourced line is never shown as checked."),
        Entry(control: "Add question and answer", purpose: "Adds a question and its answer to an interview not yet confirmed.",
              consequence: "After the person confirms the statement, answers change only by a recorded correction."),
        Entry(control: "Add to the team", purpose: "Adds a person to the case team with a team role.",
              consequence: "Once a team is recorded, a person whose membership has ended can no longer act in the case."),
        Entry(control: "Admit material", purpose: "Admits material that arrived after closure into the reopened case, with your reason.",
              consequence: "It is refused while the case is still closed; the decision is kept with your name."),
        Entry(control: "Ask to reopen", purpose: "Records that this late material calls for the case to be reopened, with your reason.",
              consequence: "The case stays closed until a person reopens it in Case sections."),
        Entry(control: "Check finished work against newer evidence", purpose: "Looks for finished actions whose evidence has a newer version or a new result since they were finished.",
              consequence: "Each is proposed once with why; nothing is reopened until you decide."),
        Entry(control: "Check for gaps", purpose: "Looks for missing statements, movements no statement covers and statements not reconciled.",
              consequence: "Each gap is proposed once, however many times its statement appears; nothing is created until you decide."),
        Entry(control: "Compare with this case", purpose: "Lists what this case and the other have alike and what differs, with the limits of the comparison.",
              consequence: "It records nothing; a likeness is not a common cause and a same name is not the same person."),
        Entry(control: "Confirm as a revision", purpose: "Records that this document is a revised version of the earlier one, with what shows it.",
              consequence: "Both documents stay in the case with their own receipts; nothing is merged, and the decision can be withdrawn."),
        Entry(control: "Correct this answer…", purpose: "Opens a correction of an answer in a confirmed statement.",
              consequence: "The confirmed answer is kept; the correction is recorded beside it with its reason."),
        Entry(control: "Create follow-up action", purpose: "Creates an action with the exact question to settle and the result needed, linked to both accounts.",
              consequence: "Its outcome may be inconclusive; the contradiction's own decision stays separate."),
        Entry(control: "Create the action", purpose: "Creates the action this gap proposes, with its account, period and deliverable.",
              consequence: "The gap is marked as taken up and is not proposed again."),
        Entry(control: "Declare capability", purpose: "Records a capability a person declares, with its basis.",
              consequence: "It is used only to list who could take work; the app infers no expertise."),
        Entry(control: "Decline material", purpose: "Declines material that arrived after closure, with your reason.",
              consequence: "It is not added; the material and your reason are kept."),
        Entry(control: "Dismiss gap", purpose: "Dismisses a proposed money gap with your reason.",
              consequence: "It is not proposed again; the reason is kept."),
        Entry(control: "Dismiss reopening", purpose: "Dismisses a proposal to reopen finished work, with your reason.",
              consequence: "The work stays finished; the same unchanged issue is not proposed again."),
        Entry(control: "End membership…", purpose: "Ends a person's membership of the case team, with the reason and who takes over their open work.",
              consequence: "It is refused while open work has nobody to take it; what they recorded keeps their name."),
        Entry(control: "End role…", purpose: "Ends one role of a person in this case, with the reason.",
              consequence: "The role stays in the profile's history, marked ended."),
        Entry(control: "List who could take it", purpose: "Lists everyone who could take a piece of work, with the declared facts for and against each.",
              consequence: "The list is alphabetical and never ranked; nothing is assigned."),
        Entry(control: "Pin as known at that day", purpose: "References the other case's question as it was recorded on that day.",
              consequence: "Later changes are not shown as known then; if nothing was recorded by then, it says so."),
        Entry(control: "Record absence", purpose: "Records a period when a person is not available.",
              consequence: "They are shown as not eligible for new work in that period."),
        Entry(control: "Record as an explained difference", purpose: "Records that the two accounts differ for a reason you state, not because one is wrong.",
              consequence: "The decision is kept with both documents' versions; a change to either reopens it."),
        Entry(control: "Record closure position", purpose: "Records the position at this closure: the disposition, who authorised it, the work waived and what stays unresolved.",
              consequence: "It is fixed once recorded; reopening the case does not erase it."),
        Entry(control: "Record follow-up outcome", purpose: "Records what the follow-up action's result showed, including inconclusive.",
              consequence: "The contradiction's own decision is separate and unchanged."),
        Entry(control: "Record late material", purpose: "Records material that arrived while the case is closed.",
              consequence: "It waits in this list; nothing is added to the closed case."),
        Entry(control: "Record observation", purpose: "Records a place the person was observed, with the time, precision, source and uncertainty.",
              consequence: "It is always shown as a past observation, never as where the person is now."),
        Entry(control: "Record rate", purpose: "Records an exchange rate with its source, day and method.",
              consequence: "The original-currency figures stay the record; a converted figure is shown beside them."),
        Entry(control: "Record relationship", purpose: "Records who holds, signs for, owns or controls an account, over which period and from which source.",
              consequence: "A relationship does not say who authorised a payment."),
        Entry(control: "Record review finding", purpose: "Records the review's own finding about a referenced record of the other case.",
              consequence: "It is written in this review case only; the other case is never changed."),
        Entry(control: "Record the correction", purpose: "Records the corrected answer beside the confirmed one, with your reason.",
              consequence: "The confirmed answer is kept unchanged."),
        Entry(control: "Reference this question", purpose: "References a question of the other case for the purpose you state.",
              consequence: "It is read again each time it is shown, within the scope the history set allows."),
        Entry(control: "Reopen the work", purpose: "Reopens the finished action with your reason.",
              consequence: "Its earlier result and history are kept."),
        Entry(control: "Replace with a new action", purpose: "Replaces the finished action with a new one, with your reason.",
              consequence: "The earlier action is marked as replaced and kept."),
        Entry(control: "Run conflict check", purpose: "Compares the person's name and declared relationships with the people in this case.",
              consequence: "A match is recorded as a conflict for a person to decide; the check decides nothing alone."),
        Entry(control: "Start a review of this case", purpose: "Makes this case a review of the other case, for the purpose you state.",
              consequence: "Its findings are written here only; the other case is never changed."),
        Entry(control: "Use this time", purpose: "Chooses this asserted time as your interpretation, with your reason.",
              consequence: "Every other asserted time stays recorded as it was."),
        Entry(control: "What was known then", purpose: "Shows what the other case had recorded on the day you give, with its revisions until then.",
              consequence: "Absent history is said; later evidence is not shown as known earlier."),
        Entry(control: "Withdraw capability", purpose: "Withdraws a declared capability.",
              consequence: "It is kept in the history and no longer used to list who could take work."),
        Entry(control: "Withdraw line…", purpose: "Withdraws a line of the profile with your reason.",
              consequence: "It is kept in the history and no longer shown in the profile."),
        Entry(control: "Withdraw relationship", purpose: "Withdraws an account relationship with your reason.",
              consequence: "It is kept in the history and no longer used."),
        Entry(control: "Work history", purpose: "Shows everything the person did in this case: assignments, work, results, reviews and team periods.",
              consequence: "Each entry opens its record on the map when it can; otherwise it says why."),
        Entry(control: "Start from a template", purpose: "Fills the action from one of eight editable templates (contradiction check, missing records, interview, identity check, examination, reconciliation, changed evidence, output).",
              consequence: "Every field stays editable; a template's target is a proposed date, never a legal deadline."),
        Entry(control: "Propose a version from the case's records", purpose: "Writes a proposed version of this brief from the case's records by fixed rules, with no AI.",
              consequence: "It is labelled as generated and stays a proposal until you accept it; it never changes an accepted version or covers your own newer draft."),
        Entry(control: "Check with the matching rules", purpose: "Compares the two person rows under the current versioned rule and lists every reason for and against.",
              consequence: "It records the assessment only; nothing is merged and no decision is made."),
        Entry(control: "Look for this identifier", purpose: "Adds an identifier this case looks for in other cases, matched as an exact whole word, or a pattern with # for a digit.",
              consequence: "Each match states its basis; a same name is never treated as the same person."),
        Entry(control: "Set the date", purpose: "Sets a date on the task with what it is: your target, a confirmed external deadline with what sets it, or a reminder, in this Mac's time zone.",
              consequence: "The basis is shown beside the date; a target is never presented as a legal deadline."),
        Entry(control: "Apply to the selected tasks", purpose: "Applies one change to every selected task: reassign, defer, cancel, set the priority, or route by the rules.",
              consequence: "Each task reports its own result; one that cannot change does not stop the others, and a deliberate assignment is kept by the rules."),
        Entry(control: "Compare version", purpose: "Shows what changed between the version of the brief a reader was given and the latest one, part by part.",
              consequence: "Lines added and lines no longer there are listed; nothing is recorded."),
        Entry(control: "Ask the AI to review the methods", purpose: "Asks the case's AI to review the professional methods for this question and propose checks that would tell the explanations apart.",
              consequence: "It runs under the case's AI permission and limits; only quotes found word for word in the documents sent are kept, other checks are labelled ungrounded, and the result is shown as the AI's beside the offline review."),
        Entry(control: "Check this claim in the documents", purpose: "Turns the question into editable searches of the case's documents, one for what supports it and one for what would contradict it.",
              consequence: "The method review closes and the claim check opens; nothing is decided, and the search's receipt is kept with the item."),
        Entry(control: "Record who supplied it", purpose: "Records who supplied this document, the author it claims or when it was captured, as a person states it.",
              consequence: "It is kept apart from who entered the document and when it arrived; it is a statement, never a verification, and a later one is added beside it."),
        Entry(control: "Record as given", purpose: "Records that this version of the brief was given to the reader you name.",
              consequence: "Later, what changed since that reader's version can be shown from it; the version itself is unchanged."),
        Entry(control: "Include and link", purpose: "Includes a document that arrived and waits in the case's intake, then links it to this request as received.",
              consequence: "The inclusion is recorded as your decision and the link is checked against the case's scope; it never marks the request fulfilled."),
        // Team folder (v198): team work over a shared folder, no server and no account
        Entry(control: "Create a team folder…", purpose: "Makes a new shared folder inside a folder you choose, for this case to work through, with you as its first member.",
              consequence: "Nothing is shared until you give people access to that folder; a contribution folder holds only requests and what comes back, never the case."),
        Entry(control: "Join a team folder…", purpose: "Links this case to a shared folder someone else made, as this Mac.",
              consequence: "Your name is added to the folder's members; this Mac signs what it writes there."),
        Entry(control: "Contribute to a team folder…", purpose: "Opens a shared folder someone asked you to contribute to, without any case.",
              consequence: "You see only the requests addressed to you or to anyone, and the receipts for what you submitted."),
        Entry(control: "Read the team folder now", purpose: "Reads the shared folder: what came back for your requests, shared work from the others, and anything of yours still waiting to be written.",
              consequence: "New submissions wait for your decision (or are included under a named team policy); if the folder can't be reached, nothing in the case changes."),
        Entry(control: "Unlink this folder", purpose: "Stops this case working through the shared folder.",
              consequence: "Everything the case recorded stays; the folder and what others wrote there are unchanged."),
        Entry(control: "Share files with it…", purpose: "Chooses files to give the person you ask, such as the invoice a statement should match.",
              consequence: "They are copied into the folder with the request and checked after copying."),
        Entry(control: "Publish request", purpose: "Writes the request to the shared folder: what is wanted, for whom, by when, and the files shared with it.",
              consequence: "Until it is in the folder the request says it is only on this Mac; if the folder is away it is written on the next read."),
        Entry(control: "Withdraw request…", purpose: "Withdraws a request, with the reason you typed.",
              consequence: "The person asked no longer sees it; anything they already submitted stays and still waits for your decision."),
        Entry(control: "Include in the case", purpose: "Takes a submission into the case: each file is checked against what was submitted, read in, and recorded through the case's intake with who supplied it.",
              consequence: "A file the case already received is not read again; the person who submitted it gets a receipt saying what became of each file."),
        Entry(control: "Decline…", purpose: "Declines a submission, with the reason you typed.",
              consequence: "Nothing is read into the case; the person who submitted it gets a receipt saying it was declined."),
        Entry(control: "Share assignment", purpose: "Shares a piece of work and who does it with everyone in the team folder.",
              consequence: "It says it is only on this Mac until it is in the folder; a later change by anyone is a new version, and two changes made at once are both kept for you to choose."),
        Entry(control: "Keep mine", purpose: "Settles two changes made at once to the same work by keeping yours.",
              consequence: "Your version is shared as the next one; both earlier versions stay in the record."),
        Entry(control: "Take theirs", purpose: "Settles two changes made at once to the same work by taking the other person's.",
              consequence: "Their version is shared as the next one; both earlier versions stay in the record."),
        Entry(control: "Open the shared folder…", purpose: "Opens the folder you were asked to contribute to, under the name the person asking knows you by.",
              consequence: "Your name is added to the folder's members; you see only what is asked of you."),
        Entry(control: "Show in Finder", purpose: "Shows a file shared with a request in the Finder.",
              consequence: "Nothing is changed or recorded."),
        Entry(control: "Submit files…", purpose: "Copies the files you choose into the shared folder as your answer to this request.",
              consequence: "They are announced only once every file is copied and checked; the receipt from the person asking appears here when their case has read the folder."),
        Entry(control: "Finish the cut-off copy", purpose: "Finishes a submission whose copy stopped part-way (the folder went away or a file was not available).",
              consequence: "Files already copied intact are kept; the rest are copied, then the submission is announced once."),
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
