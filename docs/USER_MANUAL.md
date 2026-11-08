<!-- GENERATED from Kalsmritikosh/UI/Help/HelpRegistry.swift by HelpDocsRenderer; do not edit by hand. Regenerate: HELP_DOCS_WRITE=1 HelpRegistryTests.generatedDocsMatch -->
# Investigations Made Easy — user manual

Investigations Made Easy reads the documents and email you already have, on your Mac, and builds a record of what they say: people and organisations, dated events, a timeline, and the exact passage each fact came from. You start a matter, bring documents into its scope, run the jobs of your profession, ask questions, review what you keep, and export a report whose every claim cites its source — or says honestly that the documents do not answer. This manual is the same text as Help inside the app (⌘?), which works offline.

Single-user, English-language v1. The app documents and finds; the decisions are yours. It is not legal, accounting, medical or disciplinary advice.

## Get started

### Get started: from documents to an exported report

Ten steps that take a folder of documents to a cited, reviewed, exported report. Each step names the exact control. The isolated sample case (Help ▸ Replay the tutorial) walks the same path on bundled documents.

1. Add documents. Open Evidence ▸ Sources and press “Add Folder…”. Files are read where they are; nothing is moved or copied. Supported: PDF, Word (DOCX), text and Markdown, RTF, ODT, EPUB, Excel (XLSX), CSV, ODS, PowerPoint (PPTX), email (EML, EMLX, MBOX), HTML, images and scans (PNG, JPG, HEIC, TIFF, WebP — read by OCR), audio and video (transcribed on your Mac while importing while “Transcribe audio & video” is on in Settings ▸ Modules, which it is by default), and ZIP archives. Older Office formats (DOC, XLS, PPT), Outlook stores (MSG, PST), RAR and 7z are kept but not read. The indicator reads “Ready” when every file has been processed; a count “could not be read — see Needs attention” lists the files that failed and why.
2. Start a matter. Open Professional Jobs, choose your profession, and press “Start matter”. Name the matter and choose its workspace.
3. Bring documents into the case. Press “Add documents to this case” (or “Review new documents” when the matter already holds its workspace’s documents). The preview shows how many documents are in scope now, how many are new, and how many stay excluded — nothing is included until you confirm. Jobs and answers read only the documents in the case’s scope.
4. Run the first job. Each job card says what it needs and what it produces; press “Run”. A job that cannot run says why and what to do (for example, no documents in scope yet).
5. Ask a question. Open Search and choose “Ask a question” (or “Ask about this case” in the case file), type the question and press “Send question”. With a case open the question is asked in that case; “Whole library” asks across everything. The answer is built only from the documents in scope; each claim carries a citation, and a question the documents do not answer is said to be unanswered rather than guessed.
6. Open the exact citation. Press the numbered citation chip under an answer (or “Open source” on a result row, “Open at this passage” under a closest-passage note) to open the original document with the cited passage highlighted. Read it: the quotation is checked against the document, but the document itself can be wrong, out of date or one side of a dispute.
7. Review the result. Press “Open result” on the job card; decide each row (Accepted / Rejected), or “Accept shown” / “Reject shown” where the job allows one decision over the rows shown, add a note, then “Save review”; “Mark completed” closes the review once every row is decided. Unreviewed rows are marked as such wherever they are carried.
8. Choose what goes in the report. Press “Include in report” on a reviewed row (or “Exclude from report (reason = your note)”). Rows can also go to the case with “Add to case…” or “Add to chronology”.
9. Export. In the case file’s “Log & exports” section press “Case file report…” and choose where to save it. The report is checked once more against the current evidence as it is written, protected identities are kept out, and the export is recorded in the case log with its digest (the notice under the button says so). Reopen the exported file to confirm what the reader will see.
10. Make a complete backup and keep the recovery key. Settings ▸ Your data: “Complete backup” writes the ledger and every original with its SHA-256; the recovery key shown there unlocks the backup on another Mac. Without the key an encrypted backup cannot be opened by anyone, including us.

Private mode is the default: the app opens no connection for your documents. Online AI is optional — an AI plan (credits) or your own Anthropic key (billed by Anthropic) — asks once per case before that case's documents go, then sends your questions in that case without a further prompt, and is never switched on by subscribing alone.

Before a subscription, and after one ends, every case stays readable and exports, backups, recovery, Help and the privacy controls keep working; only creating, editing and analysing wait for a subscription.

Screen: **Professional Jobs**.

## How do I…

### Where things are: Cases, Evidence, Search and Outputs

Four areas hold an ordinary case from intake to report; Settings and Help sit under them, and every specialist screen is in More tools and the ⌘K palette. Nothing was taken away — a screen you used before opens in its new place.

1. Cases (⌘1): start a case with “New case”, or open one to resume it. A case open here is the active case for Evidence, Search and Outputs. Projects that group several cases, and the caseload triage, are under “Projects”.
2. Evidence (⌘2): add and review documents — Sources, Library, Completeness and Processing, with the import queue. The line at the top says whether a case is open and how many of its documents are in scope or excluded; excluded documents stay excluded.
3. Search (⌘3): “Find words” or “Ask a question”. With a case open both look only in that case (“This case”); choose “Whole library” to look everywhere. Nothing widens by itself. ⌘5 opens “Ask a question” directly.
4. Outputs (⌘4): saved answers, saved questions, the Notebook and work products, and “Export timeline, people or documents…”. A case's own report is in its file ▸ Log & exports.
5. More tools (⌘6): timelines, dossiers, connections, findings, comparisons, Professional Jobs, Work Center, the registers and studios, audit and receipts, and archive analysis. ⌘7 opens the Timeline, ⌘8 Processing, ⌘9 Settings.

Screens you knew by their old names keep them in the ⌘K palette (for example “Sources”, “Library”, “Answers”, “Ask”), and a saved Back/Forward history or a link opens the same screen inside its area.

A screen whose optional tool is switched off still opens, says that it is off and offers “Turn on in Settings ▸ Modules”; work made with it stays readable.

Keyboard shortcuts before this change: ⌘1 Ask, ⌘2 Search, ⌘3 Timeline, ⌘4 Insights, ⌘5 Knowledge, ⌘6 Sources, ⌘7 Convert, ⌘8 Live, ⌘9 Settings. Insights, Knowledge and Convert are now in More tools and the palette.

Screen: **More tools**.

### A file could not be read, a scan has no text, or a recording was not transcribed

Every file ends in one recorded state: read, kept but not read, or failed with a reason. Nothing is silently skipped and nothing is invented for an unreadable file.

1. Open Evidence ▸ Sources. The indicator reads “Ready” when the folder is fully processed; a line “could not be read — see Needs attention” counts the failures.
2. Open Needs attention for the file’s reason: corrupt or password-protected file, an unsupported format (PPT, RAR and 7z are kept but not read; DOC, XLS, MSG and PST are read), a scan with too little text for OCR, or a recording that could not be transcribed.
3. Scans: OCR quality follows scan quality. Tools ▸ Documents ▸ Improved text recognition lists weak scans and can save a searchable copy.
4. Recordings: with “Transcribe audio & video” on (Settings ▸ Modules, the default) recordings are transcribed on your Mac while importing (Apple Speech, English). With it off, recordings are catalogued and kept, and can be transcribed on demand in Transcripts. Transcripts are evidence of what the speech model heard, not a certified transcript.
5. Fix the file (open it in its own app and re-save, remove the password, re-scan) and press “Ingest All”, or leave it: a failed file stays listed as failed so the gap is visible in the case.

Screen: **Sources**.

### Search, ask, and understand an honest refusal

Search finds passages; Ask builds a cited answer from the documents in scope. When no passage supports an answer the app says so and shows the closest passage. Answers can still be incomplete or wrong — check the cited source.

1. Search: plain words or the syntax `type:email`, `file:report`, `before:2024-06-01`, `after:2023-01-01`, `person:"Ann Lee"`, `org:acme`, `tag:urgent`, quoted phrases, `-word` to exclude. The coverage badge says how much of the archive the search covered.
2. Ask: type the question and press “Send question”. The badge under the answer gives its status; “Evidence for this answer” lists each cited passage.
3. A refusal (“Not an answer — the closest passage in your documents”) means no passage supported an answer. The closest passage is shown so you can judge for yourself; it is not presented as an answer.
4. With “Answer general questions too” on (Settings), general knowledge appears in a separate block marked “Not from your documents” — no sources, may be wrong, never part of the evidence or any export.

Screen: **Ask**.

### Read an evidence status

Every fact carries how it is known. The statuses are explained under “Words the app uses”; this topic says what to do with each.

1. Observed and Asserted: open the citation and read the passage; an asserted statement is proof that it was said, not that it is true.
2. Derived: check the inputs (for example the invoice date and the payment term) — a derived date is only as good as them.
3. Inferred: treat as a lead. Look for a document that states it directly before relying on it.
4. Contradicted: both versions are kept; open Findings ▸ Contradictions and decide, recording why.
5. Corroborated: counts independent documents. Copies, forwards and near-duplicates count once, and shared wording between two documents does not make them independent.
6. Unverified evidence link: the quoted passage could not be found again in the current version of the source. It is shown as unverified and never carried into a report as verified.

Screen: **Findings**.

### People, organisations and namesakes

Spellings and aliases of one real person or company are combined into one entity; two different people with the same name must stay apart.

1. Knowledge lists canonical people and organisations with their aliases and counts; Dossier shows everything about one of them.
2. Every automatic merge is listed under Knowledge ▸ Merged. If two namesakes were combined, press “Unmerge” — nothing is deleted, the split is recorded.
3. A merge is a judgement about identity, not a fact in the documents; the audit log records who merged or unmerged and when.
4. Erasing a person from a case keeps namesakes and evidence shared with other people (see “Erase, holds and what stays”).

Screen: **Knowledge**.

### Statements, interviews and who said what

Interviews are planned and recorded in the case file; statements carry the speaker only when the document attributes them.

1. In the case file press “Plan interview”, then after the interview “Record confirmation” for the confirmed statement, and “Export statement for signature…” when a signature is needed.
2. Speaker attribution follows the reporting verb in the document (“Lopez wrote…”). Where attribution is ambiguous the speaker is left unassigned rather than guessed.
3. “How an account changed” (Tools ▸ Writing & checking) compares what a person said at different times; a changed account is shown as a change, not labelled a lie.
4. Credibility notes (“Add credibility note”) are your assessment and are recorded as such, separate from the evidence.
5. Case file ▸ Overview ▸ Drafts ▸ Interview plan: choose a person and press “Draft questions” (or “Draft questions with AI” in Online mode with document reading on). Each question rests on a quoted passage or on two documents that disagree; leading or accusatory questions are never proposed. “Add to interview” puts the question, with its quote, in the person's planned interview.

Screen: **Cases**.

### Build a chronology and weigh alternative explanations

Timeline orders every dated fact; Findings shows the chronology by status; Competing Hypotheses ranks explanations by how much evidence is inconsistent with each.

1. Timeline: filter by date, entity or event kind; open an event for its participants and source. Date precision travels with the event (a month-only date is shown as such).
2. From a job result, “Add to chronology” carries a reviewed row, with its citations and review state, into the case chronology.
3. From a cited passage or a search hit, “Add to case chronology…” makes an entry in the case you choose, with the passage as its citation; the date is filled in only when the passage states one full date. A source the case does not include is refused, and the same passage is not added twice. In the case file's chronology, “Open source” opens the entry's passage.
4. In the case file's chronology, the label beside the source (“quote found in source”, or why not) is the app's check of the citation; it is not a person's verification. “Mark verified…” records that you checked the entry yourself (your name, the date and the entry as it stood); “Withdraw…” takes the mark back with a reason. If the entry changes afterwards, the mark reads “Verified on an earlier version — check again”. Every mark and withdrawal stays in the entry's verification history and in the case log.
5. Competing Hypotheses: list the explanations, mark each piece of evidence consistent, inconsistent or not assessed. The matrix prefers the hypothesis with the fewest inconsistencies and says when there is no preference; “not assessed” is never counted as neutral support.
6. A gap in the timeline is a gap in the record, not proof that nothing happened; it tells you what to collect next.
7. Case file ▸ Overview ▸ Drafts: “Draft from the documents” proposes a chronology of the defendants' dated steps, a cast of characters (officials listed apart from defendants and subjects, each role with its quote), and gaps and next leads (what the documents do not establish yet and the records that would settle it), from this case's documents only. In Online mode with document reading on, “Draft with AI” also has your AI reader read the passages cleared for the case; a proposal whose quote, date, person or role does not check out against the documents is not shown. Each item shows its quote and “Open source”; “Add to chronology” makes your chronology entry citing the passage (the same passage is not added twice), “Add to people” adds the person, “Add as task” makes a case task, “Reject” sets the item aside. Nothing is added until you accept it.

Screen: **Timeline**.

### Money: amounts, duplicates, refunds and currencies

Amounts are read with their currency and the document they came from; matching figures are shown as matches for you to classify, never as proof.

1. Fund Flow and DataLab show amounts with their source rows; the query above a DataLab table can be edited and re-run, and “Unresolved only” narrows to what still needs a decision.
2. The same amount in two documents is a candidate duplicate, refund, instalment or coincidence. The app marks it as a match; you record which it is and why.
3. Currencies are kept as written. Amounts are not converted between currencies, so a USD figure and an INR figure are never summed.
4. Balances and tracing follow the rows you include; a tracing schedule lists the inputs it rests on so an omitted document is visible.

Screen: **Fund Flow**.

### Review, approve, redact and export

Nothing is a finding until you review it; nothing leaves the case except through the one output route that re-checks citations and keeps protected identities out.

1. Review each result (“Save review”); an unreviewed row carried anywhere stays marked unreviewed.
2. “Include in report” (from “Add to case…” on a reviewed row) selects what the report contains; the case file report is built from the current evidence and lists its sources.
3. Redaction removes text from a PDF for real (flattened and verified); if anything is still readable, no file is produced.
4. Every export, copy and print of case content goes through one route: the content is frozen, each citation is re-verified, access is re-checked after the save dialog, protected identities are scrubbed, the file is written and read back, and the case log records it with its digest. A refused output is recorded too.
5. Print is available only when the build is entitled to print; otherwise the app says so plainly and records nothing.

Screen: **Cases**.

### What a case takes in, and from where

Every item a case takes in has one intake record: how it arrived, who supplied it, who entered it, who it says wrote it, when it was captured and when it was received. Documents come in only by your decision or by a trusted-source policy that is named on each inclusion.

1. Opening a case over a workspace includes what the workspace holds at that moment, under the policy “Documents in the case's workspace when the case was opened”. A document added to the workspace later, or a new version read later, waits in “Review new documents”.
2. Items shared to the app from another app, captured, or imported from an iPhone or iPad after the case was opened are offered in the review too, unticked. Adding one also adds it to the case's workspace.
3. To keep a document out, tick it, write the reason and press “Exclude ticked”. The exclusion is recorded in the case and stays: the review and the policies leave it out.
4. A typed entry records separately who supplied it and who it says wrote it (open “Where it came from (optional)”). It stays your typed entry; it becomes verified only when a person marks it verified.
5. Each read of your folders is an intake batch. Its receipt lists every file selected: received, already held, an exact duplicate, failed or not finished. The case overview shows how many of the case's documents trace to a batch, and which files of the latest batch could not be taken in.

Screen: **Cases**.

### Work a case: review contradictions in place and follow up evidence requests

The case file keeps your place, shows what is waiting for you, lets you decide each contradiction where it is shown, and tracks what you asked custodians for until you decide it is complete.

1. Cases ▸ open a case. Its Overview starts with “This case at a glance”: the question the investigation is to answer, what limits what the app could read (documents not allowed for the AI, references that no longer resolve, a check not yet run), how many contradictions and result rows wait for a decision, the open evidence requests with their missing items, and the next step. Choose a count or a next step to go where it is done: the contradictions count goes to the contradiction list, the job-result count opens Professional Jobs, the evidence-request count opens the Evidence tab. The case reopens on the tab, item, filter and search you left, after a restart too; “Return to the last source” opens the passage you last opened.
2. Overview ▸ Contradictions: “Find contradictions”, then choose an item in the list; its two passages, each with “Open source”, are shown beside it. Choose a reason when needed and “Confirm”, “Dismiss” or “Defer”. Dismissing needs a reason (different event, different person, changed estimate, transcription error, not enough context, or other with a note). Keys (also in the Case Review menu, and while you type a note): ⌥⌘↓ and ⌥⌘↑ move through the list; ⌥⌘Y confirms, ⌥⌘N dismisses, ⌥⌘L defers.
3. A decision is kept with the version of both documents. Running the check again over the same documents keeps it; when one of the documents is revised the item comes back as “Reopened because … changed”, and the earlier decisions stay in its decision history. A dismissal changes neither document.
4. A confirmed contradiction can be carried with “Add to chronology” or “Include in report”: both passages travel as citations with the decision they came from; nothing is retyped.
5. Evidence ▸ Evidence requests: “Create request” with what is requested, the custodian, the allegation or question it serves, the expected items (one per month gives three monthly statements as three items) and a due date. When a document arrives, “Link received document” (or “Link” on a suggestion whose date or name fits a missing item); a copy of a document already received is shown as a duplicate and not counted. The row says what is still missing.
6. “Record sent” and “Record reply” keep the history of asking and answering; “Draft request text…” prepares a letter to copy and send yourself — the app sends nothing. “Record decision” sets the request to fulfilled, partly provided, refused, cannot be obtained or cancelled; an arrival does not change it, and fulfilled with items still missing needs your reason. When material arrives after the linked allegation was decided, the request says it may need revisiting; the finding is not changed.
7. Professional Jobs: the jobs of the next step are shown and the other phases are one click away; “Find a job” (⌥⌘F) searches every job by name, and “Show all jobs” lists the whole catalogue.

Screen: **Cases**.

### The case map (preview): see a case's questions, evidence and decisions together

A map of one case: its question, allegations, hypotheses, documents, statements, events, contradictions, requests and report items, with the links between them and where each came from. It shows the case's own records — it decides nothing and copies nothing. It is a preview: it is off until you turn it on, and the case sections stay available.

1. Cases ▸ open a case ▸ turn on “Case map (preview)” in the case's top bar. The case opens on the map; “Case sections” returns to the tabs for this case (and “Case map” comes back). Turning the switch off returns every case to its sections; nothing in any case changes.
2. The top of the map stays in place: the case's title and stage, the question it is to answer (“More” shows it all), what the app could read, and counts — open questions, items awaiting review, outstanding requests, overdue actions. Choose a count to open exactly those items in the list. “What changed”, “Next action”, “Search this case” and “Return to overview” are beside them.
3. Choose “Map” or “List” at any time: the list shows the same items with the same filters, and what you selected stays selected. The list works with the keyboard and VoiceOver.
4. On the map: drag the background to move around, pinch or use “Zoom in” and “Zoom out”, “Fit all” to see everything shown, “Fit selection” for the selected item and what links to it. Drag an item to move it; “Pin” keeps it where you put it. A collapsed group shows how many items it holds; choose it to open it. Material nothing links to is listed under “Unlinked material”.
5. When new material arrives, items already on the map stay where they are; new ones appear next to what they link to, or beside the map. “Arrange” tidies the selected item's branch or the whole view — it asks first, leaves pinned items alone, and “Undo” puts everything back.
6. Opening, moving around or switching views reads this Mac's ledger only: nothing is sent anywhere.

The map shows at most 400 items in the visible area at once and says how many more there are; zoom in or use the list to reach the rest. The footer always counts what is shown, in collapsed groups, filtered out and hidden, against everything in the case. If a part of the case could not be read, the map says “Incomplete” and names it — that is never shown as an empty case.

Screen: **Cases**.

### Case map views: Overview, Questions, People, Evidence, Money, Chronology, Work, Findings, Changes

The strip above the map holds focused views of the same case. You move between them yourself; nothing moves on its own. Each keeps its own zoom, hidden items and collapsed groups, and Back returns to where you were.

1. Choose a view in the strip, or “Previous view” and “Next view” (⌃⌘← and ⌃⌘→). Overview starts with the questions and what is unresolved; Questions adds the supporting and challenging material; People, statements and events; Evidence, documents, reports, points and exhibits; Money, money movements read from the documents (each in its own currency, not verified payments); Chronology, events with their evidence; Work, actions and requests with what they serve and wait for; Findings, report items and decided questions; Changes, items that changed since they were decided or carried.
2. “Back” (⌃⌘[) returns to the previous view and selection, and “Forward” (⌃⌘]) goes where Back left. The line beside it shows where you are, for example Overview › A1 › Approval email.
3. “Find on this map” finds items of the whole case by their words, including those in collapsed groups; “Waiting for me” keeps only items not yet reviewed, deferred, reopened or pending. It does not search inside documents — “Search this case” ▸ “Search case evidence” does.
4. “Save view…” keeps the current view's kinds, filters, hidden items and collapsed groups under a name in the case's encrypted ledger; it appears at the end of the strip. Right-click a saved view to remove it. A view keeps references and settings only; it never copies the case.

Screen: **Cases**.

### The case map inspector: sources, state and actions for one item or link

Selecting an item or a link opens one panel: what it is, its recorded state, its exact wording, every source with its version and position, who recorded or proposed it, its review history, and the actions the case already has for it.

1. Each source shows the document, the version and where in it (“Position unavailable” when only the document is known), with “Open source”. Every citation is listed, not only the first.
2. A link says why it exists — the record it comes from, or the reason you gave — and who asserted it: you, a rule, or the AI reading (a proposal checked against the documents, never a decision).
3. Contradictions: choose a reason when needed and “Confirm”, “Dismiss” or “Defer” — the same decision as in the case's contradiction list, kept with both documents' versions. A confirmed one can be carried with “Add to chronology” or “Include in report”, both passages included, nothing retyped.
4. Documents: “Link to allegation…” (supports, challenges or mentions), “Link to hypothesis…” (for or against) and “Received for request…”. A whole document links without a passage and shows as unverified until a passage is chosen. Questions and hypotheses: “Create evidence request…”. Requests, entries and report items open in their case section.
5. “Link to another item…” draws a typed link with your reason, for a connection no other record holds; “Withdraw link…” withdraws it with a reason and keeps it in the record. “Hide from this view” hides an item from this view only.

States are kept apart: not yet assessed, not supported by a verified source, source unavailable, restricted, needs review (changed since), could not be read. An investigator's note is always labelled a note and is never documentary support. Same name is not the same person: two people with one name stay two items, offered as “possibly the same person” until you decide.

Screen: **Cases**.

### Open an item as a frame: go deeper and come back exactly

Any item on the map — a report, a point, a question, an action, a person, an event or a document — can be opened as a frame. The frame shows the item and everything it is related to: what it was taken from, its points, the questions and work raised from it and the results returned. There is no depth limit, and the breadcrumb returns you exactly to where you were.

1. Select an item and choose “Open as frame” in the inspector (⌃⌘↩), or in the list choose “Open as frame” from the item's menu.
2. Inside the frame, select any related item and open it as the next frame. The breadcrumb above the map lists every level.
3. Choose “Case map” or an earlier frame in the breadcrumb, or “Up one frame” (⌃⌘↑), to return: the selection and the view of that level are put back as you left them.
4. Each frame keeps its own positions. The same record can appear in several frames; it is one record, so a change to it shows in every frame.

A frame is a way of looking at the case's records; it copies nothing. A long frame lists its items a page at a time, and nothing is dropped.

When an item you are looking for is in a collapsed group, choose “Show on map” in What changed, or the “match(es) are in collapsed groups” link under Find: the group opens, the item is selected and the map is centred on it.

Screen: **Cases**.

### Brief the case: the recorded position, what is open, briefings and handover

“Brief” sums up the case — or one branch — from its own records: its purpose and scope, the current recorded position, what is unresolved, contrary material and open alternatives beside the position, material changes and next work. Every entry says why it is there and opens on the map. It works with AI off and ranks nothing away.

1. In the case map's top bar choose “Brief”. For one branch, select an item and choose “Brief of this branch” in the inspector; “Brief of the whole case” goes back.
2. Each entry has “Show on map”: the map opens the record wherever it is — out of a frame, a collapsed group or a folded branch — and selects it. “Set aside from the brief…” leaves the record and its evidence in the case and lists it under “Set aside”; “Bring back” returns it.
3. “Where the material stands” counts the material by evidential state (reported, supported, challenged, not yet assessed, reviewed, concluded) and, separately, the work (open, blocked, finished). There is no percentage: finishing work does not answer its question.
4. “Your brief” holds your own structured brief — purpose, current position, unresolved, alternatives, next work — in versions. “Save as a new version”, then “Accept this version”. An accepted version is never edited; when the case changes later, it says it was written before those changes.
5. “Briefings” builds a path for a handover or a review: “Create briefing”, then “Add step” (the selected item, the open branch or a saved view) or “Add note”. Each step opens into the map. A live briefing marks steps that changed since they were added; “Freeze this briefing” keeps every step exactly as it is now.
6. “Since you were here” shows where you were (“Resume”), what is new to you, what is waiting for a review decision, work due and blocked work. Seeing a change is not reviewing it.

Briefs, briefings and set-aside decisions are kept in the case's encrypted ledger, erased with the case and carried in its backup. A frozen briefing is refused if the case changed after the map was read — choose Refresh and freeze again.

Screen: **Cases**.

### Shape the map: fold branches, place items in frames, choose several, revise links

Fold what hangs under an item into its card, put an item into another item's branch, choose several items to arrange or pin together, see the same records as a table or a timeline, and correct a link without losing its history. None of these changes evidence.

1. Select an item and choose “Fold branch” (on the map's controls or the list's menu). Its card then counts what it holds and how many are new, blocked or waiting for review; folds nest, and “Unfold branch” opens one level.
2. “Place in frame…” puts the selected item into another item's branch. It stays one record and appears in every branch it is placed in; a branch can never end up inside itself. Select the “placed here” link and choose “Remove from this branch…” to undo it with a reason.
3. ⌘-click items on the map, or choose “Choose with others” in the list, then use Arrange ▸ “Arrange the chosen items”, “Pin the chosen items” or “Unpin the chosen items”. Undo puts them back.
4. “Show as” switches between Map, List, Table and Timeline. In the timeline, choose a date or amount band: the same records are highlighted in all four; “Clear range” stops it. Dates keep their recorded precision and amounts their own currency.
5. Select a link you drew and choose “Revise link…” to correct its type, reason, certainty or period: the earlier link is kept, withdrawn with your reason, and “Show revision history” lists the chain. For two people with the same name choose “Record as the same person…” or “Record as different people…”; neither merges them, and “Withdraw decision…” undoes it.
6. Zoom in for more on each card (state, date, amount, sources, first line); zoom out for less. “Coverage” lists every store of the case with how many of its records are on the map, and a person, an interview or the case lists its “Other records” in the inspector, read when you open them. “Save view…” also keeps the frames that are open.

Screen: **Cases**.

### Work from a supplied report: points, questions, actions and results

Record a supplied report (a laboratory, expert or audit report) as a report of the case, take its points one by one with the exact words from the source, and open questions and actions from each point. A completed action's result is recorded as a result report with its own points, so the work can go as deep as the case needs. Everything works with AI off.

1. Select the report's document on the map and choose “Record as a supplied report…”: its title, producer, author, material examined, date as written, methods and stated limitations.
2. Select the report and choose “Add point…”: the kind (claim, finding, recommendation or allegation), your statement of the point, and the exact words you selected in the source. The words are checked in the report's own document and pinned to their passage; words that do not verify are kept and labelled unverified.
3. Select a point and choose “Add qualification…” for an uncertainty, limitation, exclusion or condition. It is shown with the point everywhere, so a conditional result does not read as unconditional.
4. From a point choose “Ask a question about this point…” (an open question of the case) or “Create action…” (a task with its purpose, expected result, responsible person and reviewer). From an action, “Create child action…” adds work under it.
5. When the work is done choose “Record result…”; add the result's points and open deeper work from them. “Submit result for review”, then “Accept result” or “Return for more work”, and “Record outcome…”.
6. “Add section…” records a heading of the report so points can sit where the report put them. “Suggest points (rule-based, AI off)” reads the report's own passages by fixed rules and lists candidate sentences: “Accept as a point” records it with its exact words, checked in the document; “Dismiss” sets it aside. Suggesting again never repeats a sentence and never changes a point you accepted.
7. From a point, “Request evidence about this point…” opens an evidence request linked to it. The same point can be used in a question, a person, a chronology entry, a money movement or a briefing without copying it; each use says when the point changed since.
8. On an amendment, “Compare with the earlier report” lists changed wording, added and removed qualifications and changed details, and marks the work resting on a changed point as needing review. Nothing you decided is changed.
9. “Add supplied table, figure or media…” keeps what the specialist supplied with the report. It is shown as supplied: the app did not perform the acquisition or the analysis and cannot reproduce it.

A point is what the report says, not that it is true. “Accept point” records your decision; an accepted point is not changed by any later step — reopen its review first.

The outcome is separate from the task's status: a completed action can leave its question open. If you review your own work, it is recorded as self-review; working alone needs no second name.

When the report's document is read again, its points stay and are marked “Needs review — changed since” until you check the passage in the new version. An amendment is recorded as a new report (“Record an amendment or supplement…”); the first report is kept.

Screen: **Cases**.

### Reset the case map view

“Reset view” puts the current view's zoom, filters, hidden items and collapsed groups, and the map's positions and pins, back to their starting state. It removes or changes no case record, decision, link or document.

1. At the foot of the map choose “Reset view”. The items are placed afresh around their questions; your saved views and your links stay.

Screen: **Cases**.

### What changed in a case since you last looked

The case map's “What changed” lists this case's own changes since your seen position — documents admitted, excluded, revised, readable or not; links added or withdrawn; reviews decided or reopened; request receipts and decisions; tasks; questions, hypotheses and findings revised; outputs released; stage changes; detections that appeared or are no longer detected. Each says where it comes from. Seeing a change is not reviewing it.

1. Turn on “Case map (preview)” in a case, then choose “What changed” in the case map's header (the number is how many changes are new). The case overview also shows “What changed since you last looked”; “Show what changed…” opens the same list.
2. Each entry names its kind, when it was recorded, who made it and where it comes from: “Recorded when it happened” (written with the change itself — the case log, the scope log, the request history, a review decision) or “Derived from …” (worked out from the records, such as a newer version of a document or a task's status compared with your seen position).
3. For a changed document, “What rests on it” lists the items that cite or link to it, with how they depend on it, and the items linked to those as “may need review”. Their decisions stay as recorded; review them yourself.
4. “Show on map” selects the item. “Show the Changes view” opens the map's Changes view, which shows the changed items and those resting on changed evidence.
5. “Mark as seen” moves your seen position for this case to now. It does not review, accept or decide anything, and it writes nothing in the case record.

A possible contradiction that disappears is shown as “No longer detected — not resolved”: nobody decided it. If the changes cannot be read, the list says so — it does not show “nothing changed”. If a part cannot be read, the list names it as incomplete.

Screen: **Cases**.

### Case history: recorded states, milestones and comparing them

The case map keeps recorded states of a case — once a day when the case changed, on request, and as named milestones. A recorded state can be opened read-only and compared with another or with the case now. History starts when this version was installed: earlier map states were not recorded and are not reconstructed.

1. Choose “History” in the case map's header. The first line says from when map states are recorded (“Full map state not recorded before …”).
2. “Record the current state” keeps the map as it is now — its items, links, review states and layout. Type a name and choose “Name a milestone” to keep it as a milestone (for example “Interviews done”).
3. “Open (read-only)” shows that state on the map and in the list with a banner. Nothing can be changed while it is shown — not positions, pins, links, reviews or views. “Return to current” brings back the case as it is.
4. “Compare” on one state and then on another lists what was Added, Changed, Withdrawn and what Needs review between them; “Compare with current” compares a state with the case now. Items are matched by their record, not by their title.

Only recorded states can be opened. A recorded state holds what was recorded by then: evidence recorded later is not in it, even when the event it describes is earlier — the item keeps its event date and, separately, when it was recorded. If a source version a state cited is no longer in the ledger, its words are not shown and the current version is not shown in its place.

A recorded state keeps the names and quoted passages of the documents it cited. If you later remove a document with “Stop and forget”, the state hides its words on screen, but they stay in the recorded state in the case's encrypted ledger — and in backups — until you erase the case, a person it names, or all data.

Recorded states are kept in the case's encrypted ledger; erasing the case removes them, and erasing a person clears the states that name them (in their content or their milestone name), keeping only a note that a state existed.

Screen: **Cases**.

### Readiness: the state of a case's work, without a percentage

“Readiness” in the case map's header counts the case's recorded work states: questions unresolved, being investigated, answered with a recorded basis or needing review; documents read, partly read or not read; reviews pending, deferred, reopened or decided; requests by status; findings draft, outdated, reviewed or approved; tasks overdue, outstanding, completed or not applicable with a reason. “Needs attention” lists what is open.

1. Choose “Readiness” in the case map's header. Each line counts items in one state; “Show” selects the first of them on the map.
2. A decided question moves back to “needs review” when its basis is missing, contrary evidence was recorded after the decision, or a source behind it changed.

There is no completion percentage and no verdict. A bigger map is not a more finished case, ten citations of one source are not ten sources, and a count of supporting and opposing links decides nothing. The case's stage and approvals stay where you recorded them.

Screen: **Cases**.

### Export the case map with its sources

“Export” in the case map's footer releases what the view shows — the items and links, the selection, the legend, the case, the moment or recorded state, the scope and every source — through the same checks as every case export. A picture alone cannot be traced to its sources, so a map export always comes with a relationship and evidence table.

1. Choose “Export” in the case map's footer: “Export map as PDF (with its relationship table)…”, “Export map as PNG and the table as CSV…” (two files: the image, then its table) or “Export the relationship table (CSV)…”. “Copy the relationship table” and “Print the relationship table” release the table's text.
2. The table has one row per link — from, relationship, to, why the link exists, who asserted it, its state and its sources — and one row per item with its state and sources.
3. Before anything leaves, every cited source is checked against the case's export policy as it is now (a source taken out of the case or labelled privileged refuses the export), protected source identities are removed, and the case's legal holds are stated as they are now. The release is recorded in the case log with the digest of what left.

Exporting while a recorded state is open says which recorded state it depicts and that it is not the case as it is now; today's restrictions apply to it. There is no screenshot or copy command on the map itself: use Export.

Screen: **Cases**.

### First use of the case map: items, links, review state and what changed

Four things to know before you start. An item is one of the case's own records — a question, a document, a statement, an event, a contradiction, a request, a report item or your note. A link says how two items relate and why: the record it comes from, or the reason you gave. A review state says what a person decided, which is separate from what the documents say. “What changed” lists this case's changes since you last marked them as seen; seeing a change is not reviewing it.

1. Start with the header: the question the case is to answer, what the app could read, and the counts. Choose a count to see exactly those items in the list.
2. Choose an item on the map or in the list. The inspector shows its sources (“Open source” opens each one), its state, its review history and the actions the case already has for it.
3. Read a link before you rely on it: its line style and arrow say its type, and the inspector says who asserted it — you, a rule, or the AI reading (a proposal checked against the documents, never a decision).
4. Review states: “Not reviewed yet”, “Pending review”, “Deferred” and “Reopened — a source changed” wait for you (“Waiting for me” keeps only those). “Confirmed”, “Dismissed”, “Accepted on review” and “Rejected on review” are decisions someone recorded.
5. When you come back, choose “What changed”. New items appear beside what they link to; nothing you placed moves. “Mark as seen” only moves your seen position.
6. The legend (“Legend” at the foot of the map) explains every icon, line and state at any time; Help ▸ Case Map Keyboard Shortcuts lists the keys; Help ▸ Replay the Case Map Tutorial walks a sample case step by step.

Empty, failed and incomplete are different: “Nothing to map yet” names the next thing to do; “Incomplete” names the part that could not be read; a failed read says so and shows nothing as if it were the case.

Screen: **Cases**.

### Case map keyboard shortcuts and the list path

Everything the map does can be done from the list with the keyboard: the list, the header, the view strip, the inspector and the footer are the same in both. Choose “List” in the strip (or use VoiceOver), then select with the arrow keys.

1. Tab and Shift-Tab move between the header, the view strip, the map or list, the inspector and the footer.
2. ⌃⌘← and ⌃⌘→: previous and next view in the strip. ⌃⌘[: Back to the previous view and selection.
3. In the list, ↑ and ↓ select an item or a link; the inspector shows it. Space or Return on a collapsed group opens it.
4. ⌃⌘I: show or hide the details drawer when the window is narrow.
5. ⌃⌘= and ⌃⌘-: zoom the map in and out. ⌃⌘Z: Undo a move, pin or Arrange.
6. ⌘⎋: Return to current from a recorded state.
7. Every action on the map is also in the inspector, the header, the strip or the footer, so the list with the keyboard does everything the map does.

The map path and the list path run the same commands: review — inspector; link — inspector; request — inspector; chronology — inspector; report — inspector; openSource — inspector; viewStrip — view strip (⌃⌘← / ⌃⌘→); back — view strip (⌃⌘[); resetView — footer; history — header; returnToCurrent — history banner (⌘⎋); pin — inspector; hide — inspector; select — list (↑ ↓ in the list); searchEvidence — header; export — footer; showDetails — content (⌃⌘I).

Screen: **Cases**.

### The case map tutorial: question to report in the sample case

Help ▸ Replay the Case Map Tutorial opens the isolated sample case and walks one real workflow on the map, one step at a time: the question, a document, a passage, a review, a request, new evidence, the revised view and the report. Nothing moves on its own: Back and Next are yours, and you can work at any step.

1. Open the sample case on the map: Open Cases and open the sample matter (start one first with “Start matter” in Professional Jobs if the sample has none). Turn on “Case map (preview)” in the case's top bar.
2. The question: Read the question in the header (“More” shows all of it). If none is recorded, the header says where to record it. Choose a count — for example the open questions — to see exactly those items in the list.
3. A document: Choose “List” in the strip and select a document, for example amendment-7.md (or choose it on the map). In the inspector press “Open source”.
4. A passage: Choose “Search this case” ▸ “Search case evidence” and search for “Amendment 7”. On a match choose “Add to chronology…”.
5. A review: Choose the “Questions” view. Select a contradiction (the first-lot delivery date) and, in the inspector, record “Confirm”, “Dismiss” (choose a reason) or “Defer”.
6. A request: Select the case's question and press “Create evidence request…”. Type what is requested (for example “Proof of payment of invoice 432”) and the custodian, then “Create request”.
7. New evidence: Select a document that answers part of the request and choose “Received for request…” ▸ the request.
8. The revised view: Choose “What changed” in the header, read the list, then “Mark as seen”. Choose “Back” to return to where you were.
9. The report: Select the confirmed contradiction and press “Include in report”. Then choose “Export” at the foot of the map ▸ “Export map as PDF (with its relationship table)…”, or the case's “Case file report…”.
10. What you did, and back to your own archive: Question, document, passage, review, request, new evidence, revised view, report — the whole path on the map, with the list doing the same. “Reset view” tidies the map without changing the case. Press “Back to my archive” in the banner when you are done.

Screen: **Cases**.

### Search case evidence: search this case's documents, with what was and was not searched

A word-for-word search of one case's documents only — never the rest of the archive. It lists every matching document (in pages), shows each match in its passage with the rules it met, counts documents, occurrences and passages separately, and says exactly what it searched and what it could not. It finds words; it does not decide what they mean, and no AI is involved.

1. Open a case and choose “Search case evidence” in its top bar (on the case map: “Search this case” ▸ “Search case evidence”; “Find on this map” only finds items on the map).
2. Build the search with rules: choose “All of these”, “At least one of these” or “None of these” for a group, “Add rule” for words, a word starting with, exact characters, near each other, a person or organisation, the document type, the file name, a tag or a date, and “Add group” for a group inside it. “Use these rules” writes them as search text. Or type the search text yourself: operators in capitals — AND, OR, NOT, NEAR/5 — brackets, "a phrase", invoic*, -draft, person:"Jane Doe", type:email, file:report, tag:contract, exact:"A-17/B".
3. Dates say which date they mean: modified- (the file's modified date), stated- (the date the document states, such as an email's Date) or event- (an event in its text), then before, on or after — stated-on:2024-03, modified-before:2024-01-31, event-after:2023. Before and after leave out the day, month or year you name. A plain before: or after: is not taken as it stands; choose which date.
4. Read “What will be searched” before you run: it is the search exactly as it will run, with its grouping. If the search cannot be read, it is not run; where possible a repaired search is offered — “Use the repaired query” puts it in the text field, and it still runs only when you choose “Search”. It says when the repair searches more broadly.
5. Results: every matching document, page by page (“Previous page”, “Next page”), in name order. Each shows the passages with the words marked, which rules it met (and which words it lacks, as asked), and whether a match runs across two passages. From a match: “Open source”, “Add to chronology…” or “Select for report” — the passage goes into the case with its citation, checked against the document.
6. “What was searched” lists the case's documents searched in full, searched in part (and why), not searched (could not be read, no text, beyond a limit of the run) and excluded from the case, and the passages you set aside. No match means no match in what was searched — nothing more.
7. “Save search…” keeps the search in this case's encrypted ledger as a live search (it runs again on the case's documents as they are then) or as a frozen result (this result as it is). For a live search, “Check for new matches” lists what is new since you last looked, and “Mark as seen” starts counting from now. It never adds a document to the case.
8. Amounts: amount:>=50000 finds an amount written with a currency (₹, Rs, INR, $, USD, €, £ …) of at least 50,000 in any currency; amount:INR>=50000 only in rupees; amount:1000..5000 a range; currency:USD any amount in dollars. A bare number is not an amount, amounts in words or lakh/crore are not read, and currencies are never converted. In the rules, choose “Amount (with currency)”.
9. The same search also reads the case's own records — questions, chronology entries and notes, report points with their qualifications, tasks and actions, people, requests, contradictions, hypotheses and money movements — under “Case records”. It lists how many of each were searched and names the kinds of case data it does not read. Clauses about a file (its name, tag or dates) do not apply to a record.
10. Above the counts, the scope lists the mother case, that no other case is read, what each date clause means and the limits of the run. Each result says what kind of match it is — exact text, a value the reader extracted (a recorded mention is not a verified identity) or a recorded field — where it sits (an attachment of, a member of), and its exact characters in the searched text. Documents with the same text are counted as repeated copies.
11. While a search runs it shows how many documents it has searched. Cancel or a time limit leaves an incomplete result that says so; “Continue” searches the rest, and is refused if the case's documents were read again meanwhile. For a live saved search, tick “Re-run when the case changes”: it runs again when you open Search after the case's documents change and tells you once about new matches, with the version each was read from.

Matching: letter case and accents are ignored unless you tick “Match case” or “Match accents”; ligatures and full-width letters match their plain letters. A word is matched whole (invoice does not find invoices; invoic* does). Punctuation between the words of a phrase is ignored; exact: keeps it. Word endings, approximate and meaning-based matching are off. A run stops at its time limit or document limit and lists what it did not reach. The archive's Search (sidebar) is a separate, archive-wide search and works as before.

Screen: **Cases**.

### What the app could read, what an AI read costs, and what to do when it fails

The case overview, the AI permission sheet and the case report say which documents were read, partly read or not read and why; an AI read shows its cost and can be cancelled; a failed read names its cause and one fix.

1. Cases ▸ open a case ▸ Overview ▸ “This case at a glance” ▸ “What the app could read”: how many documents were read, partly read or not read, each with its reason (password-protected, unsupported file type, too large, text recognition failed, waiting to be read). “Show all” lists every one. A document not read was not searched, quoted or sent to an AI.
2. The AI permission sheet of a case lists the same documents under “Not read, or read only in part, on this Mac”, beside the documents that would go, the estimate of the first read and, on an AI plan, the credits you have left.
3. While a case question runs (Professional Jobs ▸ Ask ▸ “Run”), a line says the AI is reading the case, with “Cancel”. Cancel stops waiting: nothing more is sent; if the AI had started, only what it used is charged and the rest of what was held is returned. After the read the cost charged is shown.
4. If the read fails, the cause is named with one fix: not enough credits → “Buy credits…” (or “See plans…”); the network → “Try again”; your Anthropic key refused or out of credit → “Open Settings”; the service paused for the month or today's limit reached → later. A failed request is not charged; after a timeout it may have been, and the meter shows it after the next request.
5. The case file report (Log & exports ▸ “Case file report…”) has a “What the app could read” section and an “Evidence requests” section (each request's recorded status, what arrived by source version, what is missing); the export notice repeats the coverage line.

Screen: **Cases**.

### What every case has, and the optional tools

Every case has the same core: bring records in, search them exactly, open the original, review and connect the evidence, track what is still open, and export a cited report — with no AI, no add-on and no connector needed. Optional tools are for specific kinds of work; they are off until a case needs them.

1. Core, always there: intake with visible failures; exact search with dates, people and types; the case file with chronology, people, contradictions, evidence requests and findings; Tools ▸ Export (PDF, Word and CSV); Tools ▸ Legal holds (“Place hold”, “Release”); Tools ▸ Documents ▸ Saved searches (“Save search”); backup, restore and erasure in Settings ▸ Your data.
2. Optional tools: Settings ▸ Modules lists them by the task they support — professional workflows (Bates productions, review coding, case slices), advanced analysis (account changes, watchlists, who wrote to whom, “Order by review priority” for documents), media and places, connections and automation (DEVONthink, notes apps, Shortcuts, Spotlight, rules, sync), AI assistance, and presentation. Each says what stays when it is off.
3. Turning a tool off hides it and keeps everything it made. A hold, an export check, erasure, a case's AI permission and the record of what could not be read are not switches: no tool, profession or plan turns them off.
4. Retired features (generic briefings, FAQs and mind maps; the Content creator persona) are under Settings ▸ Modules ▸ Retired, so work made with them earlier stays reachable.
5. Settings ▸ Modules ▸ “Show engine components” holds the engine's internal switches, for troubleshooting with support. A case does not need any of them changed.

Screen: **Settings**.

### Private and Online modes, and what a provider may charge

Private (the default) opens no connection for your documents. Online is optional and uses the credits of an AI plan (AI Included or AI Pro) or your own Anthropic key (the only own key the app accepts).

1. The easy way: after buying AI Included or AI Pro, or after saving your Anthropic key in Settings ▸ Online, the app shows “Turn on AI”: read the AI's terms and choose “Allow AI to read case documents you permit”. That one step turns on Online mode, “Use AI to write answers” and AI reading of case documents. If you chose Not now, Ask names what is missing and offers “Turn on AI…”. Not available where Online AI is blocked for the App Store country. A badge shows while Online is on; one click returns to Private.
2. Inside a case you allow the AI once for that case: the sheet lists the documents that would go (and those that never go — privileged or restricted material) and names where they go; your questions in that case are then sent without a further prompt, and you can stop it in the case file (“Stop AI for this case”). Outside a case, a send carrying document text is always previewed and approved; a question alone is previewed too, unless “Ask before every send” is off and you chose “Send and don’t ask again this session”. Document text goes only to providers whose terms you accepted; protected identities are masked.
3. Each send is recorded before it leaves; the estimate is shown before a case is first read. Providers may retain what they receive under their own terms. With your own key they bill your account (set a monthly limit for your own Claude key in Settings ▸ Online); on an AI plan each request is charged in credits at its actual cost.
4. Subscribing never turns Online on. The test host and the sample case never send anything.

Screen: **Settings**.

### AI credits: AI Included and AI Pro without an AI account of your own

AI Included gives 2,000 AI credits a month; AI Pro 6,000 a month on the monthly plan and 5,400 a month on the yearly plan (1 credit = US$0.01 of Claude cost); each request is charged what it actually cost. Credit packs of 500 or 2,000 never expire.

1. Choose AI Included or AI Pro on the subscription screen (neither has a free trial; the 14-day trial is Workbench's).
2. Right after the purchase (or Restore purchases) the app shows “Turn on AI for your AI plan”: the AI's terms and where case documents go (Anthropic, through the publisher's relay, which keeps only counts and credits). Choose “Allow AI to read case documents you permit” — this turns on Online mode, “Use AI to write answers” and AI reading of case documents; nothing is sent yet. If you chose Not now, Ask shows search results that name what is missing, with “Turn on AI…”.
3. Open a case and ask a question. The first time, the case's permission sheet lists the documents that would be read and what it costs; choose “Allow for this case”. Questions in that case are then answered by the AI without a further prompt, each statement checked against its quote, and every send is recorded. The relay checks the plan with Apple, holds the request's worst-case cost, passes it to Anthropic and charges only the actual cost (whole credits, at least 1); a failed request costs nothing. It keeps only counts and credits.
4. Settings ▸ Online ▸ “Check credits” shows this month's credits used and left, your credit packs, the reset date and the last request's cost. Before reading a whole case the app shows the estimate (for example “about 120 credits; you have 840”) and reads it only after you confirm.
5. Reading a case the first time costs about 1–2 credits per 1,000 words of its text; a question within an hour of the last one usually costs 5–30 credits, because the AI re-uses the case it already read. After an idle hour the first question costs about the first-read amount again.
6. The month's credits renew on the day of your purchase each month — yearly plans too (AI Pro yearly: 5,400 credits a month) — and do not carry over. Credit packs (500 or 2,000, bought in Settings ▸ Online) never expire, are spent after the month's credits, work while an AI plan is active and stay with your Apple account on every Mac.
7. One request may use up to 400 credits; a confirmed whole-case read up to 600 (AI Included) or 3,000 (AI Pro); there is a daily limit. If the service's monthly capacity is reached it pauses until the 1st and says so; nothing is charged and your own key can be used meanwhile.
8. Online AI is not offered in mainland China, Hong Kong, Macao, Russia, Belarus, Venezuela, Afghanistan, Myanmar, Yemen, Iran, North Korea, Syria or Cuba, judged by the App Store account's country: there only Workbench is sold — no AI plan, no credit pack — and an own key cannot be used either. You must be 18 or older to use it.

Screen: **Settings**.

### Read a scan, translate, challenge or draft with AI

Online helps that work only from your documents and always say what they are: AI output is marked and is never the original or a finding.

1. Sources ▸ Needs attention ▸ “Read with AI…” sends the page images of a scan the Mac could not read; the transcription is added as its own document that names the original.
2. In a document's details, “Translate into English with AI…” adds a marked English translation; quote the original, not the translation.
3. Right-click an answer: “Challenge this answer with AI…” lists weaknesses, other explanations and missing evidence from the answer's own passages; “Draft a report paragraph with AI…” writes a cited paragraph to edit.
4. Every point the AI makes is checked against the passages sent; invented passage labels and uncited sentences are flagged.

Screen: **Sources**.

### Keep a confidential source's name out of everything you export or send

Record the person once; their name and aliases are then replaced in every export, refused in sealed files, and masked in every Online send.

1. Professional Jobs ▸ the Journalist profession ▸ run “Source-document vault” (or “Source map”) for the case.
2. In the vault result, set Protected identity to yes on the source's row and enter the person's name and any aliases in the Identity column (separate several with ;). In the Source map, set Protection to confidential source and fill “Identity to protect”.
3. From then on every report, copy and export replaces the name with [PROTECTED SOURCE] and checks that it is gone; a sealed or signed file (a receipt, a slice, a proof bundle) that would contain it is not exported at all.
4. Online sends mask the name whatever the masking setting; a send in which it would still be recoverable is refused.

Screen: **Professional Jobs**.

### Online tools: exchange rates, sanctions, registries, courts, web capture, transcription

Public-record lookups and captures in Online mode, each shown to you before it is sent and recorded; results are leads, not findings.

1. Sources ▸ “Online tools…” (Online mode only).
2. Exchange rate: an amount converted at the European Central Bank reference rate of a date, with a citation line.
3. Sanctions lists: the complete OFAC and UN lists are downloaded and searched on this Mac — the name you check is not sent. A match on a name is a possible match until identifiers agree.
4. Company registry (GLEIF) and court records (CourtListener): the name you search is sent to that service.
5. Capture a web page: the page as the site returned it, with a record of address, time, status and SHA-256, added to your archive.
6. Transcribe a recording: speaker labels and timecodes through an AI plan's credits (AI Included or AI Pro; Google Gemini through the publisher's service); the transcript is marked as AI output.

Screen: **Sources**.

### Encryption, backup, recovery key, erasure and holds

The ledger is encrypted on this Mac; a complete backup carries everything with a recovery key; erasure is complete or refused, and a hold you created blocks it.

1. The ledger is encrypted (SQLCipher, AES-256) with a key in this Mac’s Keychain. Copies of your original files are kept by default (Settings ▸ Optional ingest ▸ Managed evidence copies) so a citation always opens the exact version it cites; new copies are encrypted with a key derived from the ledger key. Copies kept by older versions of the app, the temporary copy opened for viewing, and your own files rely on FileVault — turn FileVault on.
2. Settings ▸ Your data ▸ “Complete backup”: the ledger and every original, each with its SHA-256. Keep the recovery key shown there; a backup cannot be opened without it. Restore checks integrity and refuses a backup made by a newer version.
3. Erase a case, a person or everything: the app either completes the erasure and verifies it empty, or refuses and says why. A legal hold, a draft, or a document that another case still needs blocks the erasure until released.
4. Ask keeps each case's questions with that case: erasing a case also removes the questions asked in it and every answer given there, including answers it could not give and answers quoting documents other cases share. Questions asked across the whole library or in another case are kept.
5. Backups you made still hold what you erased later — delete or overwrite them yourself. Restoring one does not bring the erasure back undone: the app keeps a small erasure register beside the ledger (identifiers only, never names or content), erases again any case or person that comes back with the backup, and refuses a backup made before you erased everything.
6. Case reminders never show a task or case title, only that a case task is due; erasing a case removes its reminders, and erasing a person or everything removes any reminder an older version wrote with titles.
7. Not reached by erasure: your original files outside the app, the backup files themselves, exports, sync folders and Spotlight entries — delete those yourself.

Screen: **Settings**.

### Get support without sending your documents

Support never needs your archive. Diagnostics stay on this Mac until you choose to share them.

1. Settings ▸ Help & feedback shows the diagnostics the app keeps (counts, errors, timings — no document text) and lets you save them to a file you can inspect before sending.
2. The support page (Help ▸ Support) lists what to include in a report: the version, what you did, what you expected, what happened, and the saved diagnostics file.
3. Never paste document text or names into a bug report; a description of the shape of the problem is enough.

Screen: **Settings**.

## By profession

Each recipe is derived from the jobs the profession ships with and their documentation. Content Creator ships behind its own module and is not one of the nine.

### Recipe — Investigator

Who did what, when — with custody of every source. Intake, triage, plan, interviews, evidence per allegation, findings and closure.

1. Open Professional Jobs and choose “Investigator”; press “Start matter”, name it and choose its workspace.
2. Press “Add documents to this case” and confirm the scope preview — only documents in scope are read.
3. Run “Case intake & scope”: Create a case and set its authorized evidence scope. Needs: Mandate text; scope; sources; date range.
4. Run “Ask (case-scoped)”: Answer a question over the case's authorized evidence only.
5. Run “Professional methods”: Run a professional method over case-authorized evidence.
6. Run “DataLab”: Prepare authorized-only datasets over the shared Workbench.
7. Run “Subject workup”: Work up a subject — the background dossier, citing exact in-scope evidence. Needs: Subject identity; sources.
8. Run “Identity resolution”: Resolve identity via the shared reversible merge, human-gated. Needs: Candidate identifiers; mentions.
9. Run “Analysis worksheet”: Brainstorm, 5W1H, evidence plan, and hypothesis matrix.
10. Run “Source reliability”: Assess case source reliability (rating ≠ fact). Needs: Sources; custody.
11. Run “Contradiction & gap desk”: Review in-scope contradictions and gaps (absence ≠ proof). Needs: Claims; contradictions; gaps.
12. Run “Causal analysis”: Five Whys / Fishbone / Root-cause over the shared method engine.
13. Run “Timeline & link analysis”: Timeline, link chart (people–objects–locations–events), and transaction/asset flow.
14. Run “CAPA register”: Corrective/preventive action register (human-closed). Needs: Confirmed/candidate causes.
15. Run “Effectiveness review”: Review CAPA effectiveness (human decision required). Needs: CAPA actions; new evidence.
16. Run “Chain of custody”: The evidence locker — the case custody manifest over authorized versions. Needs: Sources; custody events.
17. Run “Case report & export”: Assemble the case report — findings with a sealed receipt.
18. Run “Closure & reopen”: Close or reopen the case by an explicit human decision.
19. Review each result (“Open result”, decide the rows, “Save review”), choose what the report carries (“Include in report”), then export it from the case file (“Case file report…”) and reopen the file.

Work products: Investigation Plan; Subject Dossier; Identity Resolution Decision log; Source Reliability Schedule; Contradiction Schedule; Missing-Evidence Register; CAPA Register; Effectiveness Review; Evidence/Custody Manifest.

Your decisions (the app waits for them): Confirm scope; Confirm subject identity; Confirm/reject merge; Confirm reliability rating; Confirm/dismiss; Confirm owner/due/action; Confirm effectiveness; Confirm custody entries.

Professional limits: The app records the investigation; it does not decide guilt, intent or disciplinary outcome. An uncorroborated statement stays uncorroborated however often it is repeated. Decide case merits Assert guilt Auto-merge without review Auto-rate as fact Average conflicting accounts Close CAPA autonomously Declare effective w/o evidence Break custody silently

Job descriptions and limits come from the job documentation of the 16 jobs this profession ships with; a job without documentation is listed from its card only.

Screen: **Professional Jobs**.

### Recipe — Lawyer / Professional Reviewer

Fact-finding, chronology, review coding, privilege log and production — every event linked to its source, every conflict preserved.

1. Open Professional Jobs and choose “Lawyer / Professional Reviewer”; press “Start matter”, name it and choose its workspace.
2. Press “Add documents to this case” and confirm the scope preview — only documents in scope are read.
3. Run “Matter intake”: Open the matter and set its authorized, privilege-sensitive scope. Needs: Matter facts; scope; sources.
4. Run “Parties & issues”: Identify parties and issues linked to canonical objects. Needs: Parties; issues.
5. Run “Case chronology”: Build the case chronology — the spine of the matter (undated labelled, each fact cited). Needs: Events; dates.
6. Run “Fact–evidence matrix”: Map facts to evidence — both sides preserved, cites reopen. Needs: Claims; evidence.
7. Run “Witness profiles”: Profile witnesses; contradictions cite both sides. Needs: Transcripts; testimony.
8. Run “Document coding”: Code documents by recorded, reversible decisions. Needs: Documents; codebook.
9. Run “Privilege log”: Build the privilege log — candidates recorded with basis; privilege is NEVER auto-established. Needs: Documents.
10. Run “Obligations & clauses”: Compare obligations/clauses, each cell citing a clause locator. Needs: Contracts.
11. Run “Damages ledger”: Build a damages ledger; amounts cite source cells. Needs: Financial documents.
12. Run “Deadlines”: Track deadlines — a candidate until a human confirms it. Needs: Documents with dates.
13. Run “Deposition outline”: Draft a deposition outline; questions cite the record. Needs: Transcripts; Claims.
14. Run “Exhibit list & binder”: Assemble the exhibit list and trial binder; each exhibit cites its source version. Needs: Selected documents.
15. Run “Document production”: Produce the export set — every document carries a Bates-style number; report == receipt with custody hashes. Needs: Selected docs; scope.
16. Run “Redaction validation”: Validate text + visual redaction before production. Needs: Documents; redactions.
17. Run “Ask the case file”: Ask a question over the matter's record — every claim cited. Needs: Question; matter scope.
18. Run “Method workbench”: Run structured methods (5W1H, hypothesis matrix…) over the matter. Needs: Matter; method choice.
19. Run “Party & alias resolution”: Unify party names and aliases (reversible, human-reviewed). Needs: Candidate names; mentions.
20. Run “Source reliability desk”: Assess reliability and independence of record sources. Needs: Sources.
21. Run “Causation analysis”: Trace causation step by step — Five Whys / Fishbone over the record. Needs: Event; record.
22. Run “Remediation register”: Track remediation/undertaking actions to closure. Needs: Identified issues.
23. Run “Remediation effectiveness”: Verify a completed remediation actually resolved the issue. Needs: Closed remediation.
24. Run “Matter closure & reopen”: Close the matter (sealed); reopen preserves full history. Needs: Matter; open items.
25. Review each result (“Open result”, decide the rows, “Save review”), choose what the report carries (“Include in report”), then export it from the case file (“Case file report…”) and reopen the file.

Work products: Matter profile; Issue register; Chronology / statement of facts; Fact-evidence matrix; Witness summaries; impeachment pack; Coding log; Privilege log; Obligations schedule; Damages ledger; Deadline calendar; Deposition outline; Exhibit list; binder; Production set; receipt; Redaction validation record; Cited answer; Method run record; Identity decision log; Reliability record; Causal chain record; Remediation record; Effectiveness record; Closure record.

Your decisions (the app waits for them): Confirm scope; Confirm parties/issues; Confirm facts; Confirm mappings; Confirm profile; Confirm codes; Confirm privilege; Confirm comparisons; Confirm figures; Confirm each deadline; Confirm outline; Confirm exhibits; Approve production; Confirm redactions; Accept/refine answer; Human review gates; Confirm/reject merge; Confirm assessment; Confirm root cause; Close each action; Effectiveness decision; Confirm closure.

Professional limits: No legal conclusion is stated by the app; privilege and responsiveness are your calls, the app only applies and records them. Produced sets exclude withheld documents by rule, not by promise — check the production log. Give legal advice Decide liability Assert disputed fact as settled Average disputed facts Assert credibility verdict Auto-exclude relevant docs App marks privilege established Interpret contract as advice Assert legal damages Fire unconfirmed deadline Assert answers Alter an exhibit Produce out-of-scope material Disclose redacted content Answer beyond the record Auto-confirm findings Auto-merge without review Declare a source true Assert legal causation as fact Mark remediated without evidence Infer effectiveness from closure Destroy history on close

Job descriptions and limits come from the job documentation of the 22 jobs this profession ships with; a job without documentation is listed from its card only.

Screen: **Professional Jobs**.

### Recipe — Compliance / HR Investigator

A workplace complaint handled by a fair, documented process: scope, interviews, policy mapping, findings and the file that shows the process.

1. Open Professional Jobs and choose “Compliance / HR Investigator”; press “Start matter”, name it and choose its workspace.
2. Press “Add documents to this case” and confirm the scope preview — only documents in scope are read.
3. Run “Complaint intake”: Open the case and set the authorized evidence scope.
4. Run “Ask the case file”: Ask a question over the case's documents — every answer cited.
5. Run “Allegation worksheet”: Frame each allegation (5W1H) — an allegation is unproven until found.
6. Run “Party profiles”: Profile complainant, respondent, and witnesses from cited evidence.
7. Run “Name resolution”: Confirm names and accounts belong to the same person (reversible).
8. Run “Incident timeline”: The incident chronology with relationship links, every event cited.
9. Run “Documentary evidence register”: Emails, records, and policies in a register with cited cells.
10. Run “Statement comparison”: Compare accounts — conflicts preserved so due process holds.
11. Run “Credibility assessment”: Assess reliability and independence of each account (rating ≠ fact).
12. Run “Interview preparation”: Prepare interview questions over the cited record.
13. Run “Root-cause analysis”: Why did it happen — Five Whys / Fishbone for systemic causes.
14. Run “Evidence log & custody”: Chain-of-custody log for collected evidence with integrity hashes.
15. Run “Findings memo”: Findings on the balance of probabilities, with a sealed receipt.
16. Run “Corrective actions”: Track corrective and preventive actions to closure.
17. Run “Action effectiveness”: Verify a completed action actually fixed the issue.
18. Run “Close the case”: Close or reopen the case by an explicit human decision.
19. Run “Endorsement & disclosure review (FTC)”: Check posts, ads and sponsored material for undisclosed material connections — sponsorships, affiliate links, gifts, AI-generated content — against the FTC Endorsement Guides; every finding cited to the material.
20. Review each result (“Open result”, decide the rows, “Save review”), choose what the report carries (“Include in report”), then export it from the case file (“Case file report…”) and reopen the file.

Professional limits: Findings are about the evidence, not about a person’s character; no disciplinary decision is made by the app. A policy breach is recorded only where the policy text and the evidence are both cited.

Job descriptions and limits come from the job documentation of the 17 jobs this profession ships with; a job without documentation is listed from its card only.

Screen: **Professional Jobs**.

### Recipe — Forensic Accountant

Funds tracing, net worth, duplicate and refund analysis — the schedule behind every figure, with the rows it rests on.

1. Open Professional Jobs and choose “Forensic Accountant”; press “Start matter”, name it and choose its workspace.
2. Press “Add documents to this case” and confirm the scope preview — only documents in scope are read.
3. Run “Engagement intake”: Open the engagement and set the authorized records scope.
4. Run “Ask the records”: Ask a question over the engagement's records — every answer cited.
5. Run “Funds tracing & flow”: Follow the money — transaction flow, timelines, and relationship links.
6. Run “Tracing schedules”: Build tracing schedules (payments, transfers) — every cell cites its source.
7. Run “Payee / entity workup”: Work up a payee, vendor, or counterparty, citing exact in-scope evidence.
8. Run “Entity & alias resolution”: Resolve shell names and aliases to one entity (reversible, human-gated).
9. Run “Discrepancies & missing records”: Where the records disagree or are absent (absence ≠ proof).
10. Run “Record reliability”: Assess origin and reliability of ledgers, invoices, and statements.
11. Run “Analysis worksheet”: Hypotheses, 5W1H, and the evidence plan for the engagement.
12. Run “Method workbench”: Run structured methods over the engagement's cited record.
13. Run “Root-cause analysis”: Trace how the loss or misstatement occurred — Five Whys / Fishbone.
14. Run “Workpapers & custody”: The workpaper vault — custody-tracked originals with integrity hashes.
15. Run “Expert report & exhibits”: Assemble the expert report with cited exhibits and a sealed receipt.
16. Run “Recovery actions”: Track recovery and remediation actions to closure.
17. Run “Recovery effectiveness”: Verify a completed action actually recovered or remediated.
18. Run “Close the engagement”: Close or reopen the engagement by an explicit human decision.
19. Review each result (“Open result”, decide the rows, “Save review”), choose what the report carries (“Include in report”), then export it from the case file (“Case file report…”) and reopen the file.

Professional limits: A matching amount is a candidate, not a finding; the app never labels a transaction fraudulent. Amounts are not converted between currencies; balances follow only the rows you include.

Job descriptions and limits come from the job documentation of the 16 jobs this profession ships with; a job without documentation is listed from its card only.

Screen: **Professional Jobs**.

### Recipe — Insurance Fraud (SIU)

A suspicious claim worked to a referral: red flags, the claim chronology, statements compared, and the SIU report.

1. Open Professional Jobs and choose “Insurance Fraud (SIU)”; press “Start matter”, name it and choose its workspace.
2. Press “Add documents to this case” and confirm the scope preview — only documents in scope are read.
3. Run “Claim file intake”: Open the claim file and set the authorized document scope.
4. Run “Ask the claim file”: Ask a question over the claim's documents — every answer cited.
5. Run “Red-flag worksheet”: Record fraud indicators (5W1H) — red flags are indicators, never proof.
6. Run “Claimant workup”: The claimant/provider background workup, citing exact in-scope evidence.
7. Run “Identity resolution”: Confirm names, aliases, and entities are the same party (reversible, human-gated).
8. Run “Loss chronology & links”: The loss timeline, relationship links, and payment flow.
9. Run “Prior-claims register”: A register of prior/related claims with cited cells.
10. Run “Statement comparison”: Compare statements — conflicting accounts preserved, never averaged.
11. Run “Source vetting”: Assess reliability and independence of statements and documents.
12. Run “EUO / interview prep”: Prepare examination-under-oath questions over the cited record.
13. Run “Causation analysis”: Trace how the loss occurred — Five Whys / Fishbone over cited evidence.
14. Run “Chain of custody”: The claim evidence locker — custody manifest with integrity hashes.
15. Run “SIU report & referral”: Assemble the referral-ready SIU report with a sealed receipt.
16. Run “Recovery & referral actions”: Track recovery, NICB/DOI referral, and follow-up actions to closure.
17. Run “Action effectiveness”: Verify a completed action actually resolved the exposure.
18. Run “Close the claim file”: Close or reopen the file by an explicit human decision.
19. Review each result (“Open result”, decide the rows, “Save review”), choose what the report carries (“Include in report”), then export it from the case file (“Case file report…”) and reopen the file.

Professional limits: Red flags are indicators for review, not evidence of fraud; the referral decision is the person’s. The report states what the documents show and what they do not.

Job descriptions and limits come from the job documentation of the 16 jobs this profession ships with; a job without documentation is listed from its card only.

Screen: **Professional Jobs**.

### Recipe — Journalist

Claims checked to sources, right of reply recorded, a fact-check that shows what is supported, what conflicts and what is missing.

1. Open Professional Jobs and choose “Journalist”; press “Start matter”, name it and choose its workspace.
2. Press “Add documents to this case” and confirm the scope preview — only documents in scope are read.
3. Run “Story intake”: Define the story question, scope, and authorized sources. Needs: Story premise; scope; sources.
4. Run “Fact-check board”: Track every claim and its verification status — checked, unchecked, disputed. Needs: Claims; sources.
5. Run “Source map”: Map sources, people, and relationships. Needs: Sources; Claims.
6. Run “Source reliability”: Assess source reliability and independence. Needs: Sources.
7. Run “Interview plan”: Identify reporting gaps to fill by interview. Needs: Gaps; Claims.
8. Run “Quote book”: Collect quotes cited to their exact source. Needs: Sources; transcripts.
9. Run “Transcript correction”: Correct transcripts with locators; unheard words never asserted. Needs: Audio/transcripts.
10. Run “Tick-tock (timeline)”: Build the story's tick-tock — the reconstructed timeline (undated labelled, cited). Needs: Events; dates.
11. Run “Fact verification”: Verify claims; conflicting accounts preserved. Needs: Claims; evidence.
12. Run “Open questions”: The open-questions list — what's still unanswered (absence ≠ proof). Needs: Gaps.
13. Run “Right of reply”: Log subjects and their responses. Needs: Correspondence; Claims.
14. Run “Publication decision”: Record the human publication decision (never automated). Needs: Verification; legal review.
15. Run “Correction history”: Track post-publication corrections. Needs: Published items; new evidence.
16. Run “Publication package”: Assemble the verified publication package + sealed receipt. Needs: Verified claims; quotes.
17. Run “Ask the story file”: Ask a question over the story's sources — every claim cited. Needs: Question; story scope.
18. Run “Method workbench”: Run structured methods (5W1H, hypothesis matrix…) over the story. Needs: Story; method choice.
19. Run “Story data desk”: Build datasets over documents (logs, filings) with cited cells. Needs: Documents; fields.
20. Run “Who's who resolution”: Unify names and aliases to one subject (reversible, human-reviewed). Needs: Candidate names; mentions.
21. Run “Causal analysis”: Trace why events unfolded — Five Whys / Fishbone over cited evidence. Needs: Event; evidence.
22. Run “Source-document vault”: Custody-tracked vault for source documents with integrity hashes. Needs: Documents.
23. Run “Correction actions”: Track corrective actions on published errors to closure. Needs: Published error.
24. Run “Correction effectiveness”: Verify a published correction actually resolved the error. Needs: Closed correction.
25. Review each result (“Open result”, decide the rows, “Save review”), choose what the report carries (“Include in report”), then export it from the case file (“Case file report…”) and reopen the file.

Work products: Story brief; Claim board export; Source map; Source reliability schedule; Interview plan; Quote book; Corrected transcript; Chronology; Verification log; Reporting-gap register; Right-of-reply log; Publication decision record; Correction log; Publication package; receipt; Cited answer; Method run record; Cited dataset; Identity decision log; Causal chain record; Custody log; Correction action record; Effectiveness record.

Your decisions (the app waits for them): Confirm premise; Confirm claim status; Confirm links; Confirm rating; Confirm questions; Confirm quote/context; Confirm corrections; Confirm inclusion; Confirm verification; Confirm gaps; Confirm responses; Human publication decision; Approve package; Accept/refine answer; Human review gates; Review derived values; Confirm/reject merge; Confirm root cause; Confirm custody events; Close each action; Effectiveness decision.

Professional limits: Shared wording between sources is not independent confirmation. Publication, naming and legal risk are editorial decisions outside the app. Decide truth of story Publish unverified claim Expose confidential source Auto-rate as fact Assert answers Alter a quote Invent speech Invent dates Mark verified w/o evidence Imply wrongdoing from absence Omit a reply silently App approves publication Rewrite record silently Include unverified fact Answer beyond sources Auto-confirm findings Fabricate a value Auto-merge without review Unsupported causal leap Alter originals Silently unpublish Infer effectiveness from closure

Job descriptions and limits come from the job documentation of the 22 jobs this profession ships with; a job without documentation is listed from its card only.

Screen: **Professional Jobs**.

### Recipe — Researcher / Historian

What the papers and data actually show: an evidence review with dates at their real precision and uncertainty kept visible.

1. Open Professional Jobs and choose “Researcher / Historian”; press “Start matter”, name it and choose its workspace.
2. Press “Add documents to this case” and confirm the scope preview — only documents in scope are read.
3. Run “Research protocol”: Define the research question, scope, and authorized corpus. Needs: Question; corpus; scope.
4. Run “Corpus catalogue”: Catalogue every authorized source with provenance. Needs: Sources.
5. Run “Metadata & finding aid”: Record structured metadata per source — your working finding aid, cited to the source. Needs: Sources.
6. Run “Transcription & coding”: Code passages into structured findings with locators. Needs: Audio/image sources.
7. Run “Authority control”: Unify names/terms to canonical authorities (reversible, human-reviewed). Needs: Entities; aliases.
8. Run “Source criticism”: Assess origin, bias, and reliability of sources. Needs: Sources.
9. Run “Screening (include / exclude)”: Screen sources in or out by recorded, reversible criteria — PRISMA-style. Needs: Corpus; criteria.
10. Run “Extraction & coding”: Extract coded findings, each citing an evidence block. Needs: Sources; codebook.
11. Run “Chronology & periodisation”: Build a periodised timeline (undated labelled, cited). Needs: Events; dates.
12. Run “Prosopography”: Compile a collective biography of a group, each cell cited. Needs: Entities; events.
13. Run “Interpretation comparison”: Compare competing interpretations — both accounts preserved. Needs: Claims; interpretations.
14. Run “Alternative histories”: Explore evidence-bounded counterfactuals (never mutates the ledger). Needs: Events; causal links.
15. Run “Bibliography & citation audit”: Verify every citation reopens its exact source. Needs: Citations; sources.
16. Run “Annotated edition”: Assemble an annotated edition/report with a sealed receipt. Needs: Selected sources; notes.
17. Run “Ask the corpus”: Ask a question over the authorized corpus — every claim cited. Needs: Question; matter scope.
18. Run “Method workbench”: Run structured methods (5W1H, hypothesis matrix, root cause…) over the matter. Needs: Matter; method choice.
19. Run “Causal analysis”: Trace why an event unfolded — Five Whys / Fishbone over cited evidence. Needs: Event; evidence.
20. Run “Errata register”: Track corrections to the edition as corrective actions to closure. Needs: Identified errors.
21. Run “Errata effectiveness review”: Verify a published correction actually resolved the issue. Needs: Closed erratum.
22. Run “Matter closure”: Close the research matter (sealed, reopenable with history). Needs: Matter; open items.
23. Review each result (“Open result”, decide the rows, “Save review”), choose what the report carries (“Include in report”), then export it from the case file (“Case file report…”) and reopen the file.

Work products: Research Protocol; Corpus Catalogue; Metadata export; Corrected transcript; Authority file; Source Criticism notes; Screening log; Coded dataset; Chronology; Prosopography table; Interpretation comparison; Alternative-history note; Bibliography; citation audit; Annotated edition; receipt; Cited answer; Method run record; Causal chain record; Errata record; Effectiveness record; Closure record.

Your decisions (the app waits for them): Confirm protocol; Confirm inclusion; Confirm metadata; Confirm corrections; Confirm authority; Confirm assessment; Confirm screening; Confirm codes; Confirm periods; Confirm entries; Confirm interpretation; Confirm scenario scope; Confirm citations; Approve edition; Accept/refine answer; Human review gates; Confirm root cause; Close each erratum; Effectiveness decision; Confirm closure.

Professional limits: Date precision is preserved; the app never sharpens an approximate date. Inferred items are leads for the archive, not findings. Decide findings Assert authenticity Invent metadata Assert unheard words Auto-unify w/o review Declare truth from one source Auto-exclude silently Fabricate coded content Invent dates/periods Assert unknown biography Pick a winner Present scenario as fact Assert unresolved cite Alter source text silently Answer beyond the corpus Auto-confirm findings Unsupported causal leap Silently rewrite the edition Infer effectiveness from closure Destroy history on close

Job descriptions and limits come from the job documentation of the 20 jobs this profession ships with; a job without documentation is listed from its card only.

Screen: **Professional Jobs**.

### Recipe — Genealogist / Family Historian

Who is who, worked to the Genealogical Proof Standard: sources cited, conflicts resolved in writing, a proof argument.

1. Open Professional Jobs and choose “Genealogist / Family Historian”; press “Start matter”, name it and choose its workspace.
2. Press “Add documents to this case” and confirm the scope preview — only documents in scope are read.
3. Run “Research question & plan”: Fix the research question and the record scope before searching.
4. Run “Ask the family records”: Ask a question over your records — every answer cites its document.
5. Run “Research log”: The classic research log — what was searched, where, what it yielded.
6. Run “Ancestor profile”: Everything known about one ancestor, each fact cited.
7. Run “Same person?”: Resolve name variants to one person (reversible, you decide).
8. Run “Family lines & timeline”: Family relationships and life timelines, every event cited.
9. Run “Conflicting evidence”: Resolve records that disagree — both kept on file (GPS element 4).
10. Run “Source analysis”: Original or derivative? Primary or secondary information? (rating ≠ fact).
11. Run “Evidence correlation”: Correlate evidence across records (5W1H worksheets).
12. Run “Guided methods”: Structured checklists for reasonably exhaustive research.
13. Run “Why did they move?”: Trace causes — migration, name changes — step by step over cited records.
14. Run “Source citations & originals”: Custody-tracked originals; every citation reopens its exact source.
15. Run “Proof argument (GPS)”: The written, soundly-reasoned conclusion with a sealed receipt.
16. Run “Research to-dos”: Track follow-up searches and record orders to closure.
17. Run “Did it answer?”: Verify a completed search actually answered the question.
18. Run “Close the question”: Close or reopen the research question by explicit decision.
19. Review each result (“Open result”, decide the rows, “Save review”), choose what the report carries (“Include in report”), then export it from the case file (“Case file report…”) and reopen the file.

Professional limits: Two records with the same name are not the same person until the proof argument says so. A derived date (for example from an age at death) is shown as derived.

Job descriptions and limits come from the job documentation of the 16 jobs this profession ships with; a job without documentation is listed from its card only.

Screen: **Professional Jobs**.

### Recipe — Individual

A personal dispute — an insurance claim, a deposit, a job — your own file in order, with the documents behind each point.

1. Open Professional Jobs and choose “Individual”; press “Start matter”, name it and choose its workspace.
2. Press “Add documents to this case” and confirm the scope preview — only documents in scope are read.
3. Run “Personal records”: Bring in and organize your documents and records. Needs: Personal documents.
4. Run “Official-document versions”: Track versions of official documents. Needs: Documents.
5. Run “Career & education”: Summarize your career and education over time. Needs: Resumes; certificates.
6. Run “Family records”: Organize family members and relationships. Needs: Family documents.
7. Run “Property”: Keep a register of property and assets. Needs: Deeds; bills.
8. Run “Insurance”: Keep a register of insurance policies. Needs: Policies; correspondence.
9. Run “Health-record scope”: Summarize health records you choose to include. Needs: Health documents.
10. Run “Applications & cases”: Track applications and open cases. Needs: Application documents.
11. Run “Important dates & renewals”: Keep the confirmed dates that matter — renewals, expiries, deadlines. Needs: Documents with dates.
12. Run “Emergency binder (ICE)”: Assemble your in-case-of-emergency binder — what loved ones need, in one place. Needs: Key documents.
13. Run “Share safely (redacted)”: Prepare a sharing copy: only the items you clear are included, email addresses and phone numbers are masked, and you list any other redactions yourself. Needs: Documents; recipients.
14. Run “Personal chronology”: See your personal timeline (undated labelled). Needs: Events; dates.
15. Run “Legacy binder”: Assemble the legacy binder — your records for the next generation, with a sealed receipt. Needs: Selected documents.
16. Run “Ask my records”: Ask a question over your records — every answer cites its document. Needs: Question.
17. Run “Guided methods”: Step-by-step structured methods (5W1H, checklists) over your records. Needs: Topic; method choice.
18. Run “Name & alias resolution”: Confirm two names are the same person/company (reversible, you decide). Needs: Candidate names.
19. Run “Document reliability”: Assess how reliable a document or its source is. Needs: Document.
20. Run “Conflicts & gaps”: See where your records disagree or are missing (absence ≠ proof). Needs: Records scope.
21. Run “Why did this happen?”: Trace causes step by step over your cited records. Needs: Event; records.
22. Run “Fix-it list”: Track corrective actions (renewals, disputes, fixes) to closure. Needs: Identified problems.
23. Run “Did the fix work?”: Verify a completed fix actually resolved the problem. Needs: Closed action.
24. Run “Document vault”: Custody-tracked vault for originals with integrity hashes. Needs: Documents.
25. Run “Close a matter”: Close a personal matter (sealed, reopenable with history). Needs: Matter; open items.
26. Review each result (“Open result”, decide the rows, “Save review”), choose what the report carries (“Include in report”), then export it from the case file (“Case file report…”) and reopen the file.

Work products: Records index; Version history; Career/education summary; Family record; Property register; Insurance register; Health summary; Application tracker; Reminder list; Emergency pack; Redacted export; Personal chronology; Legacy archive; receipt; Cited answer; Method run record; Identity decision log; Reliability record; Conflict/gap register; Causal chain record; Action record; Effectiveness record; Custody log; Closure record.

Your decisions (the app waits for them): Confirm categories; Confirm current version; Confirm entries; Confirm relationships; Confirm ownership; Confirm renewals; Confirm scope; Confirm submissions; Confirm each reminder; Confirm pack; Confirm redactions; Confirm inclusion; Approve archive; Accept/refine answer; Human review gates; You confirm/reject; Confirm assessment; Review each conflict; Confirm root cause; Close each action; You decide effectiveness; Confirm custody events; Confirm closure.

Professional limits: The app is not legal, financial or medical advice; it organises your documents so you and your advisers can see them. What the documents do not say is listed as missing, not filled in. Expose sensitive data Discard old version Invent credentials Assert relationship w/o evidence Assert title Auto-file a claim Diagnose leak health data Submit on user's behalf Fire unconfirmed reminder Expose data insecurely Leak redacted content Invent dates Alter records silently Answer beyond your records Auto-confirm findings Auto-merge without review Declare a document true Average conflicts away Unsupported causal leap Mark fixed without doing it Infer effectiveness from closure Alter originals Destroy history on close

Job descriptions and limits come from the job documentation of the 23 jobs this profession ships with; a job without documentation is listed from its card only.

Screen: **Professional Jobs**.

## The screens

### Cases — every investigation, intake to closure

Your caseload: what needs you next is at the top (overdue tasks, untriaged cases, holds not acknowledged). Open a case for its file: intake and triage, the plan and allegations with the evidence for and against each, tasks with due dates, people and interviews with confirmed statements, exhibits, holds, redactions, your chronology and notes, and a log of everything done. You record each finding; the app keeps the record.

Screen: **Cases**.

### Ask — cited answers from your evidence

Ask lives in Search (“Ask a question”, ⌘5) and in the case file (“Ask about this case”). With a case open, the question is asked in that case only; choose “Whole library” to ask across everything. Type a question in plain language. The answer is built only from your ingested sources: every claim cites its evidence, the badge shows how strongly it is established, and anything your sources don’t cover is listed as a gap instead of being guessed. With “Answer general questions too” on (Settings), questions outside your documents get a separate block marked “Not from your documents” — general knowledge from the on-device AI, no sources, may be wrong, and never part of your evidence or exports.

Screen: **Ask**.

### Findings — every fact by status

Four tabs: Timeline (events labelled by how they are known, with accept/reject review), Evidence (extracted claims with citations), Contradictions (where sources disagree — both sides kept), and Missing Proof (what the record does not establish).

Screen: **Findings**.

### History — the evidence-backed narrative

A readable reconstruction of what happened, composed from the dated events in your ledger, with every claim traceable to its source.

Screen: **History**.

### Sources — what the ledger knows

Add folders and files here. Text extracts directly from PDF, Word, Excel/CSV, PowerPoint (PPTX), EPUB, email (EML, MBOX, Apple Mail, MSG, PST, NSF), HTML, Markdown, and text. ZIP archives are opened and read file by file within safety limits; RAR and 7z archives are kept but not opened. Images and scans are read by OCR, so accuracy depends on the scan. With “Transcribe audio & video” on (the default), recordings are transcribed on-device while importing (Apple Speech, English). Reading is tuned for English: other languages are kept and keyword-searchable, but names, dates and facts in them may be missed. Every file is hashed, parsed into cited evidence, and indexed; duplicates are detected. Anything unreadable is recorded honestly — never faked.

Screen: **Sources**.

### Timeline — your documents as dated events

Every dated fact extracted from your sources, in order. Filter by date range, entity, or event kind. Open an event to see its participants, source document, and causal links.

Screen: **Timeline**.

### Search — exact or by meaning

With a case open, Search looks only in that case's documents (“This case”), word for word, and says what it could not search; choose “Whole library” to search everything — nothing widens by itself. In the whole library, keyword mode finds exact terms, names, and numbers. Semantic mode finds passages that mean the same thing even with different words (needs an embedding model).

Screen: **Search**.

### Explore — the connection graph

Pick a person or organization and see who and what it is connected to. Select any node to re-center on it.

Screen: **Explore**.

### Dossier — everything about one entity

Search for a person or organization to get its full profile: timeline of events, relationships, aliases, distilled memory, and when it first and last appears in your sources.

Screen: **Dossier**.

### Insights — gaps, contradictions and patterns

Auto-surfaced signals the ledger found: missing-evidence gaps, conflicts between sources, and recurring patterns worth a look.

Screen: **Insights**.

### Knowledge — the structured base

Canonical people, organizations, projects, events, and distilled memory, with corpus-wide counts.

Screen: **Knowledge**.

### Assertions — claims with their evidence

Extracted subject-predicate-object claims, each carrying the specific evidence that backs it.

Screen: **Assertions**.

### Library — every document you’ve ingested

Browse the source files, their summaries, and distilled memories.

Screen: **Library**.

### Completeness — how fully your archive is processed

How much of your corpus is parsed, indexed, and searchable, with what remains.

Screen: **Completeness**.

### Convert — files between formats

Read PDF/Office/images/audio and write txt, md, json, html, csv, pdf, rtf, docx, xlsx, png.

Screen: **Convert**.

### Professional Jobs — the matter, its documents and the jobs

Choose your profession, start a matter (or resume one), bring documents into its scope with “Add documents to this case”, then run the jobs in their phases. Each card says what the job needs, what it produces, and — when it cannot run — why and what to do. Progress counts reviewed results and blockers, not clicks. Every run, review and document decision is in the work log.

Screen: **Professional Jobs**.

### Work Center — guided workflows

Step-by-step workflows for the jobs, with the fields each step needs and the work product at the end. The same jobs as Professional Jobs, laid out as a walkthrough.

Screen: **Work Center**.

### Logs & Trackers — the registers

The case’s structured registers: tasks, custody, exhibits, holds and the other trackers, each row cited to its source.

Screen: **Logs & Trackers**.

### DataLab — structured results you can query

A job result as a table: the question once above it, sort and filter, “Unresolved only”, a source pane for the selected row, and re-run with your edited query.

Screen: **DataLab**.

### Handoff & Review — carrying results into the case

Reviewed rows travel with every citation, their revision digest and their review state into the case question, the chronology or the report. A row whose source changed since is shown as stale.

Screen: **Handoff & Review**.

### Competing Hypotheses — weigh explanations

An Analysis of Competing Hypotheses matrix: evidence rows against hypotheses, each cell consistent, inconsistent or not assessed. Ranks by fewest inconsistencies, says when there is no preference, and cites each cell’s evidence.

Screen: **Competing Hypotheses**.

### Review — what waits for your decision

Results, links and documents that need a human decision before they count.

Screen: **Review**.

### Transcripts — recordings as text

Transcripts made on this Mac (Apple Speech, English): quotable, searchable, and marked as a speech model’s reading, not a certified transcript.

Screen: **Transcripts**.

### What Changed — differences between versions

What a later version of a document, result or account added, removed or changed.

Screen: **What Changed**.

### Settings — modes, privacy, data and subscription

System mode, Private/Online, the optional tools (Modules, listed by the task each supports), ingest options, Your data (backup, recovery key, erasure), Help & feedback, legal notices and the subscription.

Screen: **Settings**.

### Evidence — add and review documents

Sources (add folders and files; what was read, partly read or not read, each with its reason), Library (every document), Completeness (how much is processed) and Processing (what runs now), with the import queue. The line at the top says whether a case is open: with one, it counts the case's documents in scope and those excluded, which stay excluded. The lists are the whole library; “Open this case's evidence” opens the case's own Evidence section.

Screen: **Evidence**.

### Outputs — saved work and exports

Saved answers (replayable, with their evidence), saved questions, the Notebook and work products (Handoff & Review), and “Export timeline, people or documents…” for CSV, Word and PDF with a receipt. A case's report and its exports are in its file ▸ Log & exports — “Open this case's report and exports” goes there.

Screen: **Outputs**.

### More tools — every specialist screen

Case analysis views (timeline, dossier, connections, findings, comparisons — these read the whole library), professional workspaces (Professional Jobs, Work Center, registers, DataLab and the profession studios), records and checks (audit, receipts, authenticity, citations, redaction, conversion) and archive analysis (knowledge, trends, freshness, query). None is needed for an ordinary case; every one is also in the ⌘K palette.

Screen: **More tools**.

### Guide — this help

Searchable offline help: Get started, tasks, recipes by profession, the screens, the words the app uses, reading results carefully, subscription and troubleshooting.

Screen: **Guide**.

### Home — Start here — pick the lens that fits your work

Start here — pick the lens that fits your work

Screen: **Home**.

### Workspaces — Organize a matter, case, or project — a filtered view over your evidence

Organize a matter, case, or project — a filtered view over your evidence

Screen: **Workspaces**.

### Caseload — Every matter triaged by how much attention it needs

Every matter triaged by how much attention it needs

Screen: **Caseload**.

### Live — Live pipeline and background activity

Live pipeline and background activity

Screen: **Live**.

### Answers — Past answers with their evidence — replayable and auditable

Past answers with their evidence — replayable and auditable

Screen: **Answers**.

### Saved — Your bookmarked questions

Your bookmarked questions

Screen: **Saved**.

### Notebook — Your saved notes and working pages

Your saved notes and working pages

Screen: **Notebook**.

### Case Story — The whole cited story of a subject — timeline, parties, clauses, roadblocks, gaps

The whole cited story of a subject — timeline, parties, clauses, roadblocks, gaps

Screen: **Case Story**.

### Connections — Find the shortest chain of relationships linking two people or organizations

Find the shortest chain of relationships linking two people or organizations

Screen: **Connections**.

### Cross-Doc Matrix — Ask one question across every document — what each source says, cited

Ask one question across every document — what each source says, cited

Screen: **Cross-Doc Matrix**.

### Compare Documents — Compare two or more documents field by field — agreements, disagreements, and what no source settles

Compare two or more documents field by field — agreements, disagreements, and what no source settles

Screen: **Compare Documents**.

### Fund Flow — See how money moved between parties — payer to payee — drawn from your evidence

See how money moved between parties — payer to payee — drawn from your evidence

Screen: **Fund Flow**.

### Email Threads — A big email dump, deduplicated and grouped into conversations

A big email dump, deduplicated and grouped into conversations

Screen: **Email Threads**.

### Reasoning Studio — Run a root-cause investigation start to finish — brainstorm, 5 Whys, a fishbone diagram, a conclusion, and an approval-ready report

Run a root-cause investigation start to finish — brainstorm, 5 Whys, a fishbone diagram, a conclusion, and an approval-ready report

Screen: **Reasoning Studio**.

### HR Investigation — Run a workplace investigation the real-life way — mandate, allegations, evidence, credibility, classified findings — and produce the exact report an investigator signs

Run a workplace investigation the real-life way — mandate, allegations, evidence, credibility, classified findings — and produce the exact report an investigator signs

Screen: **HR Investigation**.

### Privilege Log — Build an FRCP 26(b)(5) privilege log — describe each withheld document enough to test the claim without revealing it, QC, and serve the exact table

Build an FRCP 26(b)(5) privilege log — describe each withheld document enough to test the claim without revealing it, QC, and serve the exact table

Screen: **Privilege Log**.

### SIU Report — Work a referred claim the SIU way — red flags against objective criteria, loss chronology, investigation, discrepancies, and the exact disposition report

Work a referred claim the SIU way — red flags against objective criteria, loss chronology, investigation, discrepancies, and the exact disposition report

Screen: **SIU Report**.

### Expert Report — Follow the money like a testifying expert — named tracing method, sourced schedule, findings distinct from opinion, and the FRCP 26(a)(2)(B) report

Follow the money like a testifying expert — named tracing method, sourced schedule, findings distinct from opinion, and the FRCP 26(a)(2)(B) report

Screen: **Expert Report**.

### Fact-Check — Prepare a contested story the newsroom way — claim-by-claim verification, a right-of-reply log with deadlines, and the pre-publication memo

Prepare a contested story the newsroom way — claim-by-claim verification, a right-of-reply log with deadlines, and the pre-publication memo

Screen: **Fact-Check**.

### Evidence Review — Run a review the published way — PRISMA screening counts, one extraction row per included study, and a GRADE-rated synthesis

Run a review the published way — PRISMA screening counts, one extraction row per included study, and a GRADE-rated synthesis

Screen: **Evidence Review**.

### Proof Argument — Answer a genealogical question to the Genealogical Proof Standard — research log with nil results, conflicts resolved, written proof argument

Answer a genealogical question to the Genealogical Proof Standard — research log with nil results, conflicts resolved, written proof argument

Screen: **Proof Argument**.

### Emergency Binder — Build the family emergency binder — key people, where every document and account lives, your instructions, printable

Build the family emergency binder — key people, where every document and account lives, your instructions, printable

Screen: **Emergency Binder**.

### Dispute File — Put a personal dispute on paper — insurance claim, deposit, employment or refund — with the timeline and the document behind each line, filled from your case

Put a personal dispute on paper — insurance claim, deposit, employment or refund — with the timeline and the document behind each line, filled from your case

Screen: **Dispute File**.

### Audit — Chain-of-custody and every human decision — the append-only record

Chain-of-custody and every human decision — the append-only record

Screen: **Audit**.

### Verify Receipt — Open an exported receipt and re-check its hash chain — genuine or tampered

Open an exported receipt and re-check its hash chain — genuine or tampered

Screen: **Verify Receipt**.

### Authenticity — Check a file's provenance — fingerprint, capture metadata, editing traces, PDF edit markers

Check a file's provenance — fingerprint, capture metadata, editing traces, PDF edit markers

Screen: **Authenticity**.

### Citations — Build layered Evidence Explained citations — full note, short note, bibliography

Build layered Evidence Explained citations — full note, short note, bibliography

Screen: **Citations**.

### Redaction — Remove text from a PDF for real — flattened and verified, not just a black box

Remove text from a PDF for real — flattened and verified, not just a black box

Screen: **Redaction**.

### Trends — Patterns across everything — activity over time, event types, entity makeup

Patterns across everything — activity over time, event types, entity makeup

Screen: **Trends**.

### Freshness — Confirmed facts ranked by how long since they were checked — catch stale ones before they're reused

Confirmed facts ranked by how long since they were checked — catch stale ones before they're reused

Screen: **Freshness**.

### Query — Ask a precise question of your ledger — pick a subject, add filters, run. No SQL to write; see the SQL if you want

Ask a precise question of your ledger — pick a subject, add filters, run. No SQL to write; see the SQL if you want

Screen: **Query**.

### Constitution — The constitution the app runs on — every phase, the tooling it earns, its obligations, human decisions, and prohibited conclusions

The constitution the app runs on — every phase, the tooling it earns, its obligations, human decisions, and prohibited conclusions

Screen: **Constitution**.

### Compliance Board — Every external SOP the app implements, at the edition verified, with periodic re-checks so compliance is maintained over time

Every external SOP the app implements, at the edition verified, with periodic re-checks so compliance is maintained over time

Screen: **Compliance Board**.

## Words the app uses

- **Case map legend: icons, lines and states** — “Legend” at the foot of the map is always available. Each kind of item has its own icon; each kind of link its own line — solid, dashed or dotted — with an arrow for its direction; each state its own symbol. Every item has the same size: size, position, the number of links and how tidy the map looks say nothing about whether something is proved. Ten citations of one source are not ten sources.
- **Original words, recognized text, your statement — and copies of one source** — Every cited passage says what kind of text it is, so the source's own wording is never confused with a reading of it or with your summary of it. Copies of one document count as one source.
- **Disagreement, alternatives and time in a case** — How the case keeps who said what, how each piece of evidence relates to a question, how two accounts are compared, and when things happened — kept apart from when the case learned of them.
- **What changed, what rests on it, and the people in a case** — How a change travels to the work that depends on it, how your own review of changes is kept apart from seeing them, and how people, their roles, profiles, statements and work histories are recorded without merging or blaming anyone.
- **Money in a case, and earlier cases** — How accounts, who holds them, statements and money records are kept exact and counted once, which figures the app shows and what it never concludes — and how another case can be compared or reviewed without its material leaking or being changed.
- **Actions, results and case automation** — How work in a case is planned, assigned, done, reviewed and reopened — and what the case's automation may do by itself, within its policy and budgets, without ever being permission to send anything to an AI.
- **Observed** — Directly visible in a structured source — an email header, a log entry, a timestamp. Highest trust.
- **Asserted** — Stated in a document’s text with an explicit date. True that it was said; the statement itself may still be wrong.
- **Derived** — Computed deterministically from stated facts (e.g. invoice date + 30-day term).
- **Inferred** — Reconstructed from indirect evidence only (e.g. a file’s modification time). A lead, not a fact.
- **Contradicted** — Another source states a conflicting version. Both sides are preserved — check Contradictions.
- **Corroborated** — The same fact appears in two or more independent source documents.
- **Confidence** — The evidence gate’s own grading of how well the passages support this item, from 0 to 100. Not calibrated until validated on your archive: read 80 as “stronger than 60”, not as “right four times in five” — check the citations.
- **Citation** — The exact source (file, page, row) a statement came from. Open it to verify.
- **Missing Proof** — Evidence that would be needed to establish a claim but is absent from your sources.
- **Ingest** — Reading and filing your documents into searchable, dated, cited facts. Runs automatically when you add files — you don't press anything.
- **Distill memory** — Sums up where each main person and company stands right now, from all their scattered mentions. Optional; the app answers fine without it.
- **Background maintenance** — Lets the app tidy summaries and memory while your Mac is idle, and stop the moment you return. Off by default.
- **Private / Online** — Private (the default) runs everything on your Mac and makes no connection. Online is optional: Settings → Modules → Connection, with an AI plan (AI Included or AI Pro) or your own Anthropic (Claude) key. You see what will be sent first, a badge shows while it is on, and one click returns to Private.
- **Modules** — Every feature is a switch in Settings → Modules. Switched-off features disappear; stand-alone tools appear in the sidebar Tools menu while switched on.
- **Keep each email thread as one document** — Treats a whole email reply-chain as one item instead of one per message — cleaner memory. Needs a re-import to take effect.
- **Show low-quality names in results** — Also shows the shaky, low-trust items. Off = cleaner answers; on = see everything, including weak guesses.
- **Ledger** — The app's structured memory — the one database where every fact, date, person, and source lives. The intelligence is here, not in the AI model.
- **Knowledge Object** — One document (or email) after the app has read and normalized it.
- **Chunk** — A small slice of a document, so search and the AI can handle it a piece at a time.
- **Entity** — A real-world thing the app recognizes: a person, company, place, phone number, or amount. Spellings and aliases are combined into one. Every merge is listed under Knowledge → Merged and can be undone with Unmerge; nothing is deleted.
- **Event** — A dated thing that happened ("invoice sent on 4 May"), placed on your Timeline.
- **Relationship** — A link between two entities ("Person A works at Company B"), shown in the connection graph.
- **Distilled memory** — A one-paragraph "where things stand now" for a person or company, rolled up from all their mentions and updated over time. Also called the subject's state.
- **Assertion** — A single claim in subject–verb–object form ("Contract → signed by → Party X"), each carrying the evidence that backs it.
- **Provenance** — The paper trail — exactly where in which file each fact came from. It's what makes every answer verifiable.
- **Keyword search** — Finds exact words, names, and numbers. Use it when you know the exact term.
- **Semantic search** — Finds passages that mean the same thing even in different words. Use it when you remember the idea, not the wording.
- **Reconstruct** — Rebuilds the story of what happened, in order, from your dated events — with every claim traceable to its source.
- **Evidence gate** — Before showing an answer the app decides: show it, soften it, refuse, or flag a conflict — based on how good the evidence is. It won't overclaim.
- **Ledger mode** — Fastest: rule-based reading and indexing with almost no AI at import. The default — you can search right away.
- **Hot / Warm / Cold** — Reads everything lightly, then spends extra AI effort only on the important ("hot") part.
- **Full AI** — Runs the AI over every slice of every document. Deepest, but can take hours on big archives.
- **Quality costs time** — Deeper analysis takes longer. The app defaults to fast and on-device (Private mode), and lets you opt into more depth.
- **OCR** — Reads text out of scanned pages and photos. Slower; used automatically for scans and images.
- **Transcription** — Turns audio and video into text on this Mac (Apple Speech, English). Runs while importing when “Transcribe audio & video” is on in Settings → Modules (the default); with it off, recordings are kept and can be transcribed later in Transcripts. A transcript is what the speech model heard, not a certified record.
- **Your database** — Tools → Import a DEVONthink database reads the documents stored in a .dtBase2 where they are, and turns Finder tags into tags. Groups are not read; add indexed folders in Sources.
- **Groups** — Use tags, saved searches or case slices — a document can carry many tags.
- **Saved searches / rules** — Tools → Documents → Saved searches. Saved searches stay up to date; with “Automatic rules” on (Settings → Modules), a rule is saved only after a dry run.
- **See Also** — Source counts and near-duplicates: how many documents an answer cites and which are copies of one another. A count is not an assessment — review each source.
- **Annotations** — Highlights and notes, stored beside the source and never written into it.
- **Item links** — kalsmritikosh:// links open the exact passage.
- **Stamps / Bates** — Tools → Legal review → Production sets: Bates PDFs, load files and the privilege log. Legal holds are always in Tools → Legal holds.
- **Sync** — None, by design. Your archive stays on this Mac; move it with a complete backup and its recovery key.
- **AI chat** — Ask answers only from your documents, each claim cited; conflicts are shown, never averaged.
- **Multilingual archives** — One semantic index that understands your documents' own languages — no translate-to-English shortcut.
- **Deeper story review** — Approve, correct, or reject story beats inline; your review feeds the next reconstruction.
- **More formats** — PowerPoint 97–2003 (PPT) and Keynote, which are kept but not read today.
- **Better transcription** — On-demand transcription improvements for long audio and video.
- **The promise that doesn't change** — Private mode stays the default: your documents are read on this Mac, and nothing is sent anywhere unless you turn on Online mode and approve each send.
- **Case map link: supports** — The item at the start supports the one the arrow points to, as recorded in the case (an evidence-grid row, a hypothesis citation or your link). Support is a recorded stance, not proof. Drawn as a solid line with an arrow.
- **Case map link: challenges** — The item at the start challenges the one the arrow points to — contrary evidence, kept beside the supporting material and never averaged away. Drawn as a dashed line with an arrow.
- **Case map link: mentions** — The item mentions the other without a stance for or against it. Drawn as a dotted line with an arrow.
- **Case map link: attributed to** — A statement or document is attributed to this person or organisation, as the record states it. Drawn as a solid line with an arrow.
- **Case map link: occurred before** — One recorded event is dated before the other. The order comes from the recorded dates, not from an inference. Drawn as a dashed line with an arrow.
- **Case map link: occurred after** — One recorded event is dated after the other. The order comes from the recorded dates, not from an inference. Drawn as a dashed line with an arrow.
- **Case map link: possibly the same person (pending review)** — Two people with the same name, offered as possibly the same person. It stays pending until you decide; the same name is not the same person. Drawn as a dotted line without an arrow.
- **Case map link: depends on** — The item rests on the other: if the other changes, this one may need review. Drawn as a dotted line with an arrow.
- **Case map link: requests evidence for** — An evidence request asks for material about this question. The request records what you will ask for; the app sends nothing. Drawn as a dotted line with an arrow.
- **Case map link: received in response to** — A document received for an evidence request. Arriving does not fulfil the request — only your recorded decision changes its status. Drawn as a solid line with an arrow.
- **Case map link: derived from** — The item was carried from this passage (a chronology entry or report item citing it), with its citation. Drawn as a solid line with an arrow.
- **Case map link: supersedes** — A later record replaces an earlier one — for example a correction to an attested statement. The earlier one is kept. Drawn as a dashed line with an arrow.
- **Case map link: selected for report** — You selected this item for the case report under that question. Drawn as a solid line with an arrow.
- **Case map link: placed here** — You placed this item in that branch with Place in frame. The item is stored once; the same record appears in every branch it is placed in, and withdrawing the placement keeps its history. Drawn as a dotted line with an arrow.
- **Case map link: money sent by (as recorded)** — The money movement names this person or organisation as the payer, as the documents record it. It is what a document states — not a verified payment and not proof of wrongdoing. Drawn as a solid line with an arrow.
- **Case map link: money received by (as recorded)** — The money movement names this person or organisation as the payee, as the documents record it. Amounts stay in their own currency and are never added across currencies. Drawn as a solid line with an arrow.
- **Case map link: the same person (your recorded decision)** — You recorded that these two rows are the same person, with your reason. The rows are not merged — each keeps its statements, links and history — and withdrawing the decision puts the pair back to pending. Drawn as a solid line without an arrow.
- **Case map link: qualifies** — The item limits or conditions the one the arrow points to — an exception, a condition or a narrower reading. It is contrary material kept beside the support, not support. Drawn as a dashed line with an arrow.
- **Case map link: linked — relevance not assessed** — An evidence row is linked to the question, but nobody has said whether it supports, challenges, mentions or qualifies it. A link alone is not support. Drawn as a dotted line with an arrow.
- **Case map link: held, signed for, owned or controlled by (as recorded)** — The account is recorded as held, signed for, owned or controlled by this person or organisation, with the period and where that comes from. A relationship to an account does not by itself mean authorising any payment from it, or being liable for one. Drawn as a solid line with an arrow.
- **Case map state: Recorded** — Recorded as stated in the case. It is what the record says, not a judgement that it is true.
- **Case map state: Not yet assessed** — Not yet assessed: recorded before passage checking existed, or never checked. Select a passage to check it.
- **Case map state: Not supported by a verified source** — Not supported by a verified source — for example an investigator's note or an entry with no cited passage. A note is never documentary support.
- **Case map state: Source unavailable** — The source is not in this case (it was taken out of the case scope or withdrawn). Bring it back with “Review new documents”, or cite another source.
- **Case map state: Restricted** — The source is in the case but cannot be read under the current access policy (for example labelled privileged). It is not shown or exported.
- **Case map state: Needs review — changed since** — Needs review — a source behind it changed since it was decided or carried. The decision stays as recorded until you review it.
- **Case map state: Could not be read** — The source could not be read (damaged, password-protected or unsupported). It was not searched or quoted; Sources ▸ Needs attention says why.
- **Case map review state: No review needed** — No review is needed for this kind of record.
- **Case map review state: Not reviewed yet** — Nobody has reviewed it yet. It waits for you.
- **Case map review state: Pending review** — Waiting for a decision (for example an open evidence request or a possible same person).
- **Case map review state: Accepted on review** — A reviewer accepted it. Its citations and revision are kept.
- **Case map review state: Completed result** — A completed result carried from a job.
- **Case map review state: Confirmed** — Confirmed by a reviewer, with the reason and the versions of the sources it rests on.
- **Case map review state: Dismissed** — Dismissed by a reviewer, with a reason. Both sources are kept.
- **Case map review state: Deferred** — Deferred: the reviewer chose to decide later. It still waits.
- **Case map review state: Reopened — a source changed** — Reopened because a source changed. The earlier decision stays in the history.
- **Case map review state: Rejected on review** — Rejected on review. It is kept, and not carried as accepted.
- **Case map review state: Withdrawn** — Withdrawn with a reason. It stays in the record and is no longer drawn.
- **Case map review state: Explained — a real difference** — Explained: the reviewer recorded why the two accounts differ without contradicting each other (for example two separate payments). Both accounts are kept.
- **Case map review state: Unresolved — cannot be settled on the case material** — Unresolved: the reviewer examined it and it cannot be settled on what is in the case. It stays an open conflict, with the reason.

## Reading results carefully

### Quotations are checked; sources can still be wrong

Every citation is re-verified against the document before it is shown or exported, so the quote is really there. The document itself can be mistaken, out of date, one side of a dispute, or written to mislead. Open the source and judge it as you would any document.

### Shared text is not independent corroboration

When two documents share wording — a forwarded email, a copied paragraph, a template — they count as one source. The source map labels this “shared text / possible relationship” and leaves independence unassessed rather than counting two.

### A repeated amount proves neither agreement nor fraud

The same figure in two places may be an instalment, a refund, a duplicate payment, a quote repeated in a reply, or a coincidence. The app shows the match and its two sources; the classification and its reason are recorded by you.

### A confidence figure is not calibrated until it has been validated

The confidence shown with an item is the evidence gate’s own grading of how well the passages support it. It has not been validated against outcomes for your archive, so treat 80 as “stronger than 60”, not as “right four times in five”. The citations, not the number, are what to check.

### The app documents and finds; the person decides

No job states a legal, accounting, medical or disciplinary conclusion. Results are drafts until reviewed; adverse findings are recorded with your reasons; exports carry what you selected. Professional training and judgement are not replaced by this app.

### What the on-device AI does and does not do

In Private mode the AI runs on this Mac and is used to read, extract and phrase. It can misread a document; that is why every claim carries a citation you can open and why answers outside your documents are marked “Not from your documents”. It does not add facts that are not in your documents to the evidence, and anything it wrote that a document does not support is shown as unsupported.

## Subscription and access

### Plans, the free trial, renewal and cancelling

Three plans, each monthly or yearly, all with the nine personas (the professions listed under “By profession”): Workbench (Online AI with your own Anthropic key), AI Included (2,000 AI credits a month) and AI Pro (6,000 a month; 5,400 a month on the yearly plan). Prices are shown by the App Store for your country; the app never shows a made-up price.

1. Workbench has a 14-day free introductory trial when Apple finds your account eligible (one per account); the AI plans have none. The subscription screen shows the price that follows the trial and when it will be charged.
2. The subscription renews automatically unless cancelled at least a day before the period ends. Cancel in your Apple Account (Help ▸ Manage subscription, or the “Manage subscription” link on the subscription screen); Apple’s instructions are linked there.
3. The three plans are one subscription, never two: moving up (Workbench → AI Included → AI Pro) starts at once and Apple refunds the unused part; moving down or between monthly and yearly takes effect at the next renewal. Monthly and yearly give the same access and the same monthly credits, except AI Pro yearly: 5,400 credits a month instead of 6,000.
4. Payment, renewal, refunds and restore are handled by Apple. The app opens no connection for them and never sees your payment details. Subscribing does not turn on Online mode.

Screen: **Settings**.

### Restore purchases, another Mac, and being offline

Your subscription follows your Apple account; your archive does not.

1. On a new Mac, or after reinstalling, press “Restore purchases” (subscription screen or Settings ▸ Subscription). The App Store confirms what your account holds.
2. Offline, the last verified state is kept until its own verified end (for example the end of the paid period). The app never extends access beyond what was verified and never removes still-valid access because the store could not be reached.
3. AI credit packs are kept by the AI service for your Apple account's subscription, not on the Mac: they are there after reinstalling or on another Mac once the plan is restored.
4. Your documents and the ledger stay on this Mac. Move them with a complete backup and the recovery key (Settings ▸ Your data).

Screen: **Settings**.

### After the trial or subscription ends

Your work is never locked away or deleted by billing.

1. Every case stays readable. Exports, complete backups, recovery, Help, the sample case and the privacy and erasure controls keep working.
2. Creating, editing and analysing — adding documents, starting a matter, running jobs, asking, writing in the case file, drafting, editing a hypotheses matrix — open the subscription screen instead of running. Nothing is changed by the refusal.
3. A payment that did not go through keeps access during Apple’s verified grace period; after it, the app says plainly that payment failed and what to do.

Screen: **Settings**.

## When something goes wrong

### “The documents don’t say” when you believe they do

The evidence gate found no supporting passage in the documents in scope.

1. Check the case scope: press “Add documents to this case” and look at the counts — a document outside the scope is not read for this case.
2. Check Sources: a file that “could not be read” has no text to search; a scan with little text needs better OCR.
3. Try Search with the exact word or number; if Search finds it and Ask does not, the passage exists but does not support the question as asked — rephrase it.
4. Open Findings ▸ Missing Proof for what would be needed to establish the claim.

Screen: **Sources**.

### The case map or case search shows an error, or something was not saved

Every case map and case search error says what failed and one thing to do next, and keeps what you typed or moved on screen.

1. “The case map could not be read”: choose “Refresh”. If it fails again, use “Case sections” — they hold the same records.
2. “Incomplete: … could not be read”: the named part is missing from the map, not empty. Choose “Refresh”; the rest of the map can be used meanwhile.
3. “The new position was not saved” or “The view was not saved”: the change stays on screen; choose “Try again”. Your saved views, links and records are unchanged.
4. “Not marked as seen”: nothing was reviewed either way; choose “Try again”.
5. A search that cannot be read is not run; “Use the repaired query” offers a repair when one exists. A search that stopped at its limit lists what it did not reach under “What was searched”.
6. A map that looks messy: “Reset view” resets the zoom, filters, hidden items and positions only — no case record, decision, link or saved view is changed.

Screen: **Cases**.

### A document was not read, has pages with no text, or needs a password

“Where this came from” in the source inspector shows how a passage reached the case (the email it was attached to, the archive path it came from, the file you supplied), how each page was read, and whether the original is protected. No text on a page is never proof that the page holds nothing.

1. Open the passage or document in the source inspector and read “Where this came from”: each line runs from the document up to the file that was actually received, with the date it was received.
2. Pages listed as “No text found” or “Recognised from an image” may hold material the text does not show. Choose “Re-read this document” to read the exact original again with the current reader, or “Open the original” to look at the page yourself.
3. “Needs a password”: choose “Enter password”, type it and choose “Open”. A readable copy is added, linked to the original, which is kept unchanged. The password is used once and is not saved or logged.
4. “Wrong password” lets you try again. “Protected in a way the app cannot open” (for example a password-protected Word file or an encrypted ZIP), “Damaged” and “Locked by the file system” each say what to do instead; the original is kept in every case.

A copy made from an original (an opened PDF, a converted image) shows “A copy made from …” with how it was made; the original shows its copies. Neither replaces the other.

### A button is greyed out

A disabled control carries the reason and the remedy as its tooltip and in its accessibility description; empty screens say which of five things is true.

1. Hover the control (or read it with VoiceOver): the reason — no documents in scope, nothing selected, a review not saved, no subscription, a hold in force — and the next safe action.
2. An empty screen distinguishes: no files added; files added but unreadable; files outside this case’s scope; evidence insufficient for the question; results waiting for review; an export blocked by a hold or an unverified citation.
3. A failure message says what failed, whether your work was saved, and the next safe action. Work in progress is saved as you go; a save that fails is named, not lost silently.

### Importing or answering is slow

First indexing of a large archive, OCR of scans and transcription of recordings take the longest; answers are faster once indexing has finished.

1. Sources shows what is still being read. Live shows the background pipeline.
2. Settings ▸ Your data ▸ File-type ingest guide estimates time per 100 MB for each file type and system mode.
3. Switch off “Transcribe audio & video” (Settings ▸ Modules) for a faster import; recordings are then kept and can be transcribed later in Transcripts.
4. Background maintenance (off by default) tidies summaries while the Mac is idle and stops the moment you return.

Screen: **Live**.

## The sample tutorial

Help ▸ Replay the Tutorial opens the isolated sample case (its own ledger, bundled Project Delta documents) and walks these steps; nothing touches your own archive.

1. **You are in the sample case.** The purple banner says this is the sample archive: its own ledger with eight bundled Project Delta documents (a supply contract, Amendment 7, two invoices, four emails). Open Evidence ▸ Sources to see them read. *You should see:* Sources lists the ProjectDelta folder, “8 file(s) ingested”, and the indicator reads “Ready”. Your own documents are not here and were not opened.
2. **Choose the investigation question.** Open Professional Jobs, choose the “Investigator” card and press “Start matter” after typing the title “Project Delta slip”. The question for this matter: why did the first delivery slip, and who approved the change? *You should see:* “Created case “Project Delta slip” … with 8 source(s) in scope”, the jobs grouped in phases, and “Start here — open a matter” done.
3. **Inspect and authorise the case documents.** Press “Add documents to this case” — or “Review new documents” when the matter already holds the workspace’s documents. Read the preview: how many are in scope now, how many are new, how many stay excluded. Nothing is added until you confirm. *You should see:* “Documents: 8 in scope”. Only these documents are read for this matter’s jobs and questions.
4. **See the case at a glance and what was read.** Open Cases and open the matter. Its Overview starts with “This case at a glance”: the question, what waits for you, the evidence requests and “What the app could read”. Choose a count or the “Next:” step to go where it is done. *You should see:* “What the app could read” gives the documents read, partly read and not read, each one counted once, every unread one with its reason. The case reopens here, on the tab you leave, after a restart too.
5. **Ask — one settled question, one the record cannot settle.** In the matter press “Ask about this case” (or open Search and choose “Ask a question”): with the matter open, the question is asked in it. Type “When was Amendment 7 approved, and who signed it?” and press “Send question”. Then ask “Was invoice 432 paid?”. *You should see:* The first answer quotes the amendment — effective 2 May 2024, signed by John Carter (Northwind) and Maria Lopez (Supplier ABC) — with a citation chip for it. The second quotes the record as it stands: invoice 432 issued 30 May 2024, due 29 June, “unpaid as of June 14, 2024”; no document records a payment and none is invented. The badge says how far the evidence goes.
6. **Open the exact citation.** Under the first answer press the numbered citation chip “1 amendment-7.md”. *You should see:* The amendment opens in a sheet with the cited passage highlighted. The quotation is checked against the document; whether the document is right is your judgement. “Done” closes it.
7. **Review conflicting accounts.** Open Findings ▸ Contradictions. The first-lot delivery date was given as about 13 May 2024 (8 April email), then 28 May 2024 (18 April email and the amendment). *You should see:* A row “Conflicting dates for “Delivery delayed”” — “Conflicts with a second source; both claims are preserved and not reconciled automatically”, 2 sources, “Review”. An estimate that was later revised is shown as a conflict to review, not labelled wrong — you decide what it means and record why.
8. **Decide a contradiction where it is shown.** In the matter: Overview ▸ Contradictions, press “Find contradictions”. Choose an item: its two passages are shown beside it, each with “Open source”. Record “Confirm”, “Dismiss” (choose a reason) or “Defer”. *You should see:* The item shows your decision and its reason, kept with the version of both documents; neither document is changed. If the check lists nothing for this matter, the list says so and there is nothing to decide.
9. **Save a reviewed result.** Back in Professional Jobs, press “Run” on a Collect & organize job that produces rows — “Documentary evidence register” — then “Open result”. Decide a row (Accepted or Rejected), type a note, press “Save review”. *You should see:* The result shows “Reviewed by me, <date>” and your decisions; the jobs summary counts “1 to review”. Unreviewed rows stay marked unreviewed wherever they are carried.
10. **Carry it into the report.** On the reviewed row press “Add to case…” and choose “Include in report”; then “Add to chronology”. *You should see:* “Row 1 selected for the case report (accepted on review; every citation and the revision kept).” and “Row 1 added to the case chronology …”. The case log records both.
11. **Ask a custodian for missing material.** In the matter: Evidence ▸ Evidence requests. Type what is requested (for example “Proof of payment of invoice 432”), the custodian (“Northwind accounts”), and press “Create request”. Then “Draft request text…” to see the letter you would send yourself, and “Record sent”. *You should see:* The request is listed as Open with “No expected items listed.” and its history shows it was sent. The app sends nothing; only “Record decision” ever changes its status.
12. **Export the report and reopen it.** Open Cases, open the matter, go to “Log & exports” and press “Case file report…”. Save the file, then open it from the Finder. *You should see:* The notice reads “Exported <name> (SHA-256 …), recorded.” and the case log gains an “exported” line. The report lists the reviewed rows you included with their sources, the chronology entry, and an “Unresolved questions and limitations” section, followed by “What the app could read” and “Evidence requests” with the request you created.
13. **What you saw, and back to your own archive.** A settled point (the amendment’s approval, quoted from the document) and one the record leaves open (the payment: unpaid as of 14 June 2024, nothing later). Press “Back to my archive” in the banner when you are done. *You should see:* The app relaunches on your own archive. Nothing from the sample was written to it; the tutorial can be replayed any time from Help ▸ Replay the Tutorial.

## The case map tutorial

Help ▸ Replay the Case Map Tutorial opens the same isolated sample case and walks the case map path, one step at a time, nothing advancing by itself: question → document → passage → review → request → new evidence → revised view → report.

1. **Open the sample case on the map.** Open Cases and open the sample matter (start one first with “Start matter” in Professional Jobs if the sample has none). Turn on “Case map (preview)” in the case's top bar. *You should see:* The case opens on the map. The header shows the case's title and stage, its question, what the app could read and the counts; the strip below starts on Overview. “Case sections” returns to the tabs at any time.
2. **The question.** Read the question in the header (“More” shows all of it). If none is recorded, the header says where to record it. Choose a count — for example the open questions — to see exactly those items in the list. *You should see:* The list shows the items the count names, under the same filters the map uses. Nothing is decided by opening them.
3. **A document.** Choose “List” in the strip and select a document, for example amendment-7.md (or choose it on the map). In the inspector press “Open source”. *You should see:* The inspector shows the document's version and where each citation points (“Position unavailable” when only the document is known). The source opens in a sheet; closing it brings you back to the same item.
4. **A passage.** Choose “Search this case” ▸ “Search case evidence” and search for “Amendment 7”. On a match choose “Add to chronology…”. *You should see:* Every matching document is listed with the matched words in their passage and what was searched. The passage goes into the case's chronology with its citation, checked against the document; on the map it appears next to the document it cites.
5. **A review.** Choose the “Questions” view. Select a contradiction (the first-lot delivery date) and, in the inspector, record “Confirm”, “Dismiss” (choose a reason) or “Defer”. *You should see:* The item shows your decision and its reason — the same decision as in the case's contradiction list, kept with the versions of both documents. Neither document changes.
6. **A request.** Select the case's question and press “Create evidence request…”. Type what is requested (for example “Proof of payment of invoice 432”) and the custodian, then “Create request”. *You should see:* A request item appears linked to the question, Open, with what is expected. The app sends nothing.
7. **New evidence.** Select a document that answers part of the request and choose “Received for request…” ▸ the request. *You should see:* The request shows what arrived, by source version, and what is still missing. It stays Open: arriving does not fulfil a request; only “Record decision” in Evidence requests changes its status.
8. **The revised view.** Choose “What changed” in the header, read the list, then “Mark as seen”. Choose “Back” to return to where you were. *You should see:* The receipt, the chronology entry and your review are listed, each with where it comes from. Items you saw before stayed where they were; new ones sit next to what they link to. Marking as seen reviews nothing.
9. **The report.** Select the confirmed contradiction and press “Include in report”. Then choose “Export” at the foot of the map ▸ “Export map as PDF (with its relationship table)…”, or the case's “Case file report…”. *You should see:* The item is selected for the report with both passages, nothing retyped. The export is checked against the case's sources as they are now and recorded in the case log; the relationship table lists every link with why it exists and its sources.
10. **What you did, and back to your own archive.** Question, document, passage, review, request, new evidence, revised view, report — the whole path on the map, with the list doing the same. “Reset view” tidies the map without changing the case. Press “Back to my archive” in the banner when you are done. *You should see:* The app relaunches on your own archive. Nothing from the sample was written to it; Help ▸ Replay the Case Map Tutorial plays this again.

