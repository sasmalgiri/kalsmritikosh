//
//  HelpRegistry.swift
//  Kalsmritikosh
//
//  ONE help registry (App Store completion instructions §6.12): every piece of guidance the app shows —
//  the Get started guide, the searchable offline help, the nine persona recipes, the screen guides, the
//  evidence vocabulary, the safety explanations, the subscription help and troubleshooting — is a
//  `HelpTopic` defined here, with a stable id. The Guide screen renders and searches this list; the
//  Help menu, the ⓘ information buttons (`InfoPopoverButton(topic:)`), the tutorial and the generated
//  `docs/USER_MANUAL.md` / `docs/HELP_COVERAGE_MATRIX.md` all read the same definitions, so a wording
//  fixed here is fixed everywhere and nothing drifts.
//
//  Every control name quoted in a topic (`controls`) must exist as a literal in the UI sources —
//  `HelpRegistryTests` scans for it — so help never names a button that is not there. Persona recipes
//  are derived from the real job catalogue and job documentation rather than written by hand.
//
//  Wording rules (§6.10): quotations are checked, but a source can be wrong; shared text is not
//  independent corroboration; a repeated amount proves neither agreement nor fraud; a confidence figure
//  is not calibrated until it has been validated; the app documents and finds, the person decides.
//

import Foundation

/// What kind of help a topic is; the Guide groups by this.
public nonisolated enum HelpKind: String, CaseIterable, Sendable {
    case getStarted, task, persona, screen, concept, safety, subscription, troubleshooting

    public var title: String {
        switch self {
        case .getStarted: return "Get started"
        case .task: return "How do I…"
        case .persona: return "By profession"
        case .screen: return "The screens"
        case .concept: return "Words the app uses"
        case .safety: return "Reading results carefully"
        case .subscription: return "Subscription and access"
        case .troubleshooting: return "When something goes wrong"
        }
    }

    public var symbol: String {
        switch self {
        case .getStarted: return "flag.checkered"
        case .task: return "list.bullet.rectangle"
        case .persona: return "person.2"
        case .screen: return "square.grid.2x2"
        case .concept: return "character.book.closed"
        case .safety: return "exclamationmark.shield"
        case .subscription: return "creditcard"
        case .troubleshooting: return "wrench.and.screwdriver"
        }
    }
}

/// One help topic. `id` is stable (used by Help links, ⓘ buttons and the coverage matrix); `controls`
/// are the exact button/menu names the topic tells the person to use.
public nonisolated struct HelpTopic: Identifiable, Sendable, Equatable {
    public let id: String
    public let kind: HelpKind
    public let title: String
    /// One or two sentences: what this is for.
    public let summary: String
    /// Numbered steps, in order (empty for concepts).
    public var steps: [String] = []
    /// Further paragraphs under the steps.
    public var notes: [String] = []
    /// Exact names of the controls the topic refers to (verified against the UI sources).
    public var controls: [String] = []
    /// The screen to open for this topic, when one applies.
    public var destination: Destination? = nil
    /// Extra search words beyond the title and text.
    public var keywords: [String] = []
    /// Persona recipes: the profession this is for (the persona application label).
    public var persona: String? = nil

    /// Everything searchable, lowercased.
    var searchText: String {
        ([title, summary] + steps + notes + controls + keywords + [persona ?? ""]).joined(separator: " ").lowercased()
    }
}

public nonisolated enum HelpRegistry {

    // MARK: - Lookup and search

    public static func topic(_ id: String) -> HelpTopic? { byID[id] }

    public static func topics(of kind: HelpKind) -> [HelpTopic] { all.filter { $0.kind == kind } }

    /// Task search: every word typed must appear somewhere in the topic; titles rank first.
    public static func search(_ query: String) -> [HelpTopic] {
        let words = query.lowercased().split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init)
        guard !words.isEmpty else { return all }
        return all.filter { t in
            let text = t.searchText
            return words.allSatisfy { text.contains($0) }
        }.sorted { a, b in
            let at = words.allSatisfy { a.title.lowercased().contains($0) }
            let bt = words.allSatisfy { b.title.lowercased().contains($0) }
            if at != bt { return at }
            return a.kind.rawValue < b.kind.rawValue
        }
    }

    /// The screen topic for a destination (every sidebar destination has one).
    public static func screenTopic(for destination: Destination) -> HelpTopic? {
        all.first { $0.kind == .screen && $0.destination == destination }
    }

    public static let all: [HelpTopic] =
        [getStarted] + tasks + personaRecipes + screens + concepts + caseMapContext + safety + subscription + troubleshooting

    private static let byID: [String: HelpTopic] = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

    // MARK: - Get started

    /// §6.5 — the short offline Get started guide, with the exact current control names.
    public static let getStarted = HelpTopic(
        id: "get-started", kind: .getStarted, title: "Get started: from documents to an exported report",
        summary: "Ten steps that take a folder of documents to a cited, reviewed, exported report. Each step names the exact control. The isolated sample case (Help ▸ Replay the tutorial) walks the same path on bundled documents.",
        steps: [
            "Add documents. Open Evidence ▸ Sources and press “Add Folder…”. Files are read where they are; nothing is moved or copied. Supported: PDF, Word (DOCX), text and Markdown, RTF, ODT, EPUB, Excel (XLSX), CSV, ODS, PowerPoint (PPTX), email (EML, EMLX, MBOX), HTML, images and scans (PNG, JPG, HEIC, TIFF, WebP — read by OCR), audio and video (transcribed on your Mac while importing while “Transcribe audio & video” is on in Settings ▸ Modules, which it is by default), and ZIP archives. Older Office formats (DOC, XLS, PPT), Outlook stores (MSG, PST), RAR and 7z are kept but not read. The indicator reads “Ready” when every file has been processed; a count “could not be read — see Needs attention” lists the files that failed and why.",
            "Start a matter. Open Professional Jobs, choose your profession, and press “Start matter”. Name the matter and choose its workspace.",
            "Bring documents into the case. Press “Add documents to this case” (or “Review new documents” when the matter already holds its workspace’s documents). The preview shows how many documents are in scope now, how many are new, and how many stay excluded — nothing is included until you confirm. Jobs and answers read only the documents in the case’s scope.",
            "Run the first job. Each job card says what it needs and what it produces; press “Run”. A job that cannot run says why and what to do (for example, no documents in scope yet).",
            "Ask a question. Open Search and choose “Ask a question” (or “Ask about this case” in the case file), type the question and press “Send question”. With a case open the question is asked in that case; “Whole library” asks across everything. The answer is built only from the documents in scope; each claim carries a citation, and a question the documents do not answer is said to be unanswered rather than guessed.",
            "Open the exact citation. Press the numbered citation chip under an answer (or “Open source” on a result row, “Open at this passage” under a closest-passage note) to open the original document with the cited passage highlighted. Read it: the quotation is checked against the document, but the document itself can be wrong, out of date or one side of a dispute.",
            "Review the result. Press “Open result” on the job card; decide each row (Accepted / Rejected), or “Accept shown” / “Reject shown” where the job allows one decision over the rows shown, add a note, then “Save review”; “Mark completed” closes the review once every row is decided. Unreviewed rows are marked as such wherever they are carried.",
            "Choose what goes in the report. Press “Include in report” on a reviewed row (or “Exclude from report (reason = your note)”). Rows can also go to the case with “Add to case…” or “Add to chronology”.",
            "Export. In the case file’s “Log & exports” section press “Case file report…” and choose where to save it. The report is checked once more against the current evidence as it is written, protected identities are kept out, and the export is recorded in the case log with its digest (the notice under the button says so). Reopen the exported file to confirm what the reader will see.",
            "Make a complete backup and keep the recovery key. Settings ▸ Your data: “Complete backup” writes the ledger and every original with its SHA-256; the recovery key shown there unlocks the backup on another Mac. Without the key an encrypted backup cannot be opened by anyone, including us."
        ],
        notes: [
            "Private mode is the default: the app opens no connection for your documents. Online AI is optional — an AI plan (credits) or your own Anthropic key (billed by Anthropic) — asks once per case before that case's documents go, then sends your questions in that case without a further prompt, and is never switched on by subscribing alone.",
            "Before a subscription, and after one ends, every case stays readable and exports, backups, recovery, Help and the privacy controls keep working; only creating, editing and analysing wait for a subscription."
        ],
        controls: ["Add Folder…", "Ready", "Start matter", "Ask a question", "Ask about this case", "Whole library", "Add documents to this case", "Review new documents", "Run", "Send question", "Open source", "Open at this passage", "Open result", "Accept shown", "Reject shown", "Save review", "Mark completed", "Include in report", "Exclude from report (reason = your note)", "Add to case…", "Add to chronology", "Case file report…", "Complete backup"],
        destination: .work,
        keywords: ["quick start", "first steps", "tutorial", "beginner", "how to begin"]
    )

    // MARK: - Tasks (§6.6)

    public static let tasks: [HelpTopic] = [
        HelpTopic(
            id: "task-find-your-way", kind: .task, title: "Where things are: Cases, Evidence, Search and Outputs",
            summary: "Four areas hold an ordinary case from intake to report; Settings and Help sit under them, and every specialist screen is in More tools and the ⌘K palette. Nothing was taken away — a screen you used before opens in its new place.",
            steps: [
                "Cases (⌘1): start a case with “New case”, or open one to resume it. A case open here is the active case for Evidence, Search and Outputs. Projects that group several cases, and the caseload triage, are under “Projects”.",
                "Evidence (⌘2): add and review documents — Sources, Library, Completeness and Processing, with the import queue. The line at the top says whether a case is open and how many of its documents are in scope or excluded; excluded documents stay excluded.",
                "Search (⌘3): “Find words” or “Ask a question”. With a case open both look only in that case (“This case”); choose “Whole library” to look everywhere. Nothing widens by itself. ⌘5 opens “Ask a question” directly.",
                "Outputs (⌘4): saved answers, saved questions, the Notebook and work products, and “Export timeline, people or documents…”. A case's own report is in its file ▸ Log & exports.",
                "More tools (⌘6): timelines, dossiers, connections, findings, comparisons, Professional Jobs, Work Center, the registers and studios, audit and receipts, and archive analysis. ⌘7 opens the Timeline, ⌘8 Processing, ⌘9 Settings."
            ],
            notes: [
                "Screens you knew by their old names keep them in the ⌘K palette (for example “Sources”, “Library”, “Answers”, “Ask”), and a saved Back/Forward history or a link opens the same screen inside its area.",
                "A screen whose optional tool is switched off still opens, says that it is off and offers “Turn on in Settings ▸ Modules”; work made with it stays readable.",
                "Keyboard shortcuts before this change: ⌘1 Ask, ⌘2 Search, ⌘3 Timeline, ⌘4 Insights, ⌘5 Knowledge, ⌘6 Sources, ⌘7 Convert, ⌘8 Live, ⌘9 Settings. Insights, Knowledge and Convert are now in More tools and the palette."
            ],
            controls: ["New case", "Projects", "Find words", "Ask a question", "This case", "Whole library", "Export timeline, people or documents…", "Open this case's evidence", "Turn on in Settings ▸ Modules"],
            destination: .moreTools,
            keywords: ["navigation", "sidebar", "where is", "moved", "menu", "keyboard", "shortcut", "home", "files", "projects", "outputs", "more tools"]
        ),
        HelpTopic(
            id: "task-import-failures", kind: .task, title: "A file could not be read, a scan has no text, or a recording was not transcribed",
            summary: "Every file ends in one recorded state: read, kept but not read, or failed with a reason. Nothing is silently skipped and nothing is invented for an unreadable file.",
            steps: [
                "Open Evidence ▸ Sources. The indicator reads “Ready” when the folder is fully processed; a line “could not be read — see Needs attention” counts the failures.",
                "Open Needs attention for the file’s reason: corrupt or password-protected file, an unsupported format (PPT, RAR and 7z are kept but not read; DOC, XLS, MSG and PST are read), a scan with too little text for OCR, or a recording that could not be transcribed.",
                "Scans: OCR quality follows scan quality. Tools ▸ Documents ▸ Improved text recognition lists weak scans and can save a searchable copy.",
                "Recordings: with “Transcribe audio & video” on (Settings ▸ Modules, the default) recordings are transcribed on your Mac while importing (Apple Speech, English). With it off, recordings are catalogued and kept, and can be transcribed on demand in Transcripts. Transcripts are evidence of what the speech model heard, not a certified transcript.",
                "Fix the file (open it in its own app and re-save, remove the password, re-scan) and press “Ingest All”, or leave it: a failed file stays listed as failed so the gap is visible in the case."
            ],
            controls: ["Ready", "Ingest All", "Transcribe audio & video"], destination: .sources,
            keywords: ["ocr", "transcription", "unreadable", "password", "corrupt", "needs attention", "failed"]),
        HelpTopic(
            id: "task-search-and-refusals", kind: .task, title: "Search, ask, and understand an honest refusal",
            summary: "Search finds passages; Ask builds a cited answer from the documents in scope. When no passage supports an answer the app says so and shows the closest passage. Answers can still be incomplete or wrong — check the cited source.",
            steps: [
                "Search: plain words or the syntax `type:email`, `file:report`, `before:2024-06-01`, `after:2023-01-01`, `person:\"Ann Lee\"`, `org:acme`, `tag:urgent`, quoted phrases, `-word` to exclude. The coverage badge says how much of the archive the search covered.",
                "Ask: type the question and press “Send question”. The badge under the answer gives its status; “Evidence for this answer” lists each cited passage.",
                "A refusal (“Not an answer — the closest passage in your documents”) means no passage supported an answer. The closest passage is shown so you can judge for yourself; it is not presented as an answer.",
                "With “Answer general questions too” on (Settings), general knowledge appears in a separate block marked “Not from your documents” — no sources, may be wrong, never part of the evidence or any export."
            ],
            controls: ["Send question", "Evidence for this answer", "Not from your documents"], destination: .ask,
            keywords: ["refusal", "no answer", "search syntax", "coverage", "general knowledge"]),
        HelpTopic(
            id: "task-evidence-status", kind: .task, title: "Read an evidence status",
            summary: "Every fact carries how it is known. The statuses are explained under “Words the app uses”; this topic says what to do with each.",
            steps: [
                "Observed and Asserted: open the citation and read the passage; an asserted statement is proof that it was said, not that it is true.",
                "Derived: check the inputs (for example the invoice date and the payment term) — a derived date is only as good as them.",
                "Inferred: treat as a lead. Look for a document that states it directly before relying on it.",
                "Contradicted: both versions are kept; open Findings ▸ Contradictions and decide, recording why.",
                "Corroborated: counts independent documents. Copies, forwards and near-duplicates count once, and shared wording between two documents does not make them independent.",
                "Unverified evidence link: the quoted passage could not be found again in the current version of the source. It is shown as unverified and never carried into a report as verified."
            ],
            destination: .findings, keywords: ["observed", "asserted", "derived", "inferred", "contradicted", "corroborated", "unverified"]),
        HelpTopic(
            id: "task-people-and-namesakes", kind: .task, title: "People, organisations and namesakes",
            summary: "Spellings and aliases of one real person or company are combined into one entity; two different people with the same name must stay apart.",
            steps: [
                "Knowledge lists canonical people and organisations with their aliases and counts; Dossier shows everything about one of them.",
                "Every automatic merge is listed under Knowledge ▸ Merged. If two namesakes were combined, press “Unmerge” — nothing is deleted, the split is recorded.",
                "A merge is a judgement about identity, not a fact in the documents; the audit log records who merged or unmerged and when.",
                "Erasing a person from a case keeps namesakes and evidence shared with other people (see “Erase, holds and what stays”)."
            ],
            controls: ["Unmerge"], destination: .knowledge, keywords: ["merge", "alias", "identity", "same name", "entity"]),
        HelpTopic(
            id: "task-statements-and-interviews", kind: .task, title: "Statements, interviews and who said what",
            summary: "Interviews are planned and recorded in the case file; statements carry the speaker only when the document attributes them.",
            steps: [
                "In the case file press “Plan interview”, then after the interview “Record confirmation” for the confirmed statement, and “Export statement for signature…” when a signature is needed.",
                "Speaker attribution follows the reporting verb in the document (“Lopez wrote…”). Where attribution is ambiguous the speaker is left unassigned rather than guessed.",
                "“How an account changed” (Tools ▸ Writing & checking) compares what a person said at different times; a changed account is shown as a change, not labelled a lie.",
                "Credibility notes (“Add credibility note”) are your assessment and are recorded as such, separate from the evidence.",
                "Case file ▸ Overview ▸ Drafts ▸ Interview plan: choose a person and press “Draft questions” (or “Draft questions with AI” in Online mode with document reading on). Each question rests on a quoted passage or on two documents that disagree; leading or accusatory questions are never proposed. “Add to interview” puts the question, with its quote, in the person's planned interview."
            ],
            controls: ["Plan interview", "Record confirmation", "Export statement for signature…", "Add credibility note", "Draft questions", "Draft questions with AI", "Add to interview"], destination: .cases,
            keywords: ["interview", "statement", "witness", "speaker", "attribution"]),
        HelpTopic(
            id: "task-chronology-and-hypotheses", kind: .task, title: "Build a chronology and weigh alternative explanations",
            summary: "Timeline orders every dated fact; Findings shows the chronology by status; Competing Hypotheses ranks explanations by how much evidence is inconsistent with each.",
            steps: [
                "Timeline: filter by date, entity or event kind; open an event for its participants and source. Date precision travels with the event (a month-only date is shown as such).",
                "From a job result, “Add to chronology” carries a reviewed row, with its citations and review state, into the case chronology.",
                "From a cited passage or a search hit, “Add to case chronology…” makes an entry in the case you choose, with the passage as its citation; the date is filled in only when the passage states one full date. A source the case does not include is refused, and the same passage is not added twice. In the case file's chronology, “Open source” opens the entry's passage.",
                "In the case file's chronology, the label beside the source (“quote found in source”, or why not) is the app's check of the citation; it is not a person's verification. “Mark verified…” records that you checked the entry yourself (your name, the date and the entry as it stood); “Withdraw…” takes the mark back with a reason. If the entry changes afterwards, the mark reads “Verified on an earlier version — check again”. Every mark and withdrawal stays in the entry's verification history and in the case log.",
                "Competing Hypotheses: list the explanations, mark each piece of evidence consistent, inconsistent or not assessed. The matrix prefers the hypothesis with the fewest inconsistencies and says when there is no preference; “not assessed” is never counted as neutral support.",
                "A gap in the timeline is a gap in the record, not proof that nothing happened; it tells you what to collect next.",
                "Case file ▸ Overview ▸ Drafts: “Draft from the documents” proposes a chronology of the defendants' dated steps, a cast of characters (officials listed apart from defendants and subjects, each role with its quote), and gaps and next leads (what the documents do not establish yet and the records that would settle it), from this case's documents only. In Online mode with document reading on, “Draft with AI” also has your AI reader read the passages cleared for the case; a proposal whose quote, date, person or role does not check out against the documents is not shown. Each item shows its quote and “Open source”; “Add to chronology” makes your chronology entry citing the passage (the same passage is not added twice), “Add to people” adds the person, “Add as task” makes a case task, “Reject” sets the item aside. Nothing is added until you accept it."
            ],
            controls: ["Add to chronology", "Add to case chronology…", "Open source", "Mark verified…", "Withdraw…", "Draft from the documents", "Draft with AI", "Add to people", "Add as task", "Reject"], destination: .timeline, keywords: ["ach", "hypotheses", "timeline", "chronology", "alternative explanation"]),
        HelpTopic(
            id: "task-money", kind: .task, title: "Money: amounts, duplicates, refunds and currencies",
            summary: "Amounts are read with their currency and the document they came from; matching figures are shown as matches for you to classify, never as proof.",
            steps: [
                "Fund Flow and DataLab show amounts with their source rows; the query above a DataLab table can be edited and re-run, and “Unresolved only” narrows to what still needs a decision.",
                "The same amount in two documents is a candidate duplicate, refund, instalment or coincidence. The app marks it as a match; you record which it is and why.",
                "Currencies are kept as written. Amounts are not converted between currencies, so a USD figure and an INR figure are never summed.",
                "Balances and tracing follow the rows you include; a tracing schedule lists the inputs it rests on so an omitted document is visible."
            ],
            controls: ["Unresolved only"], destination: .fundFlow, keywords: ["duplicate", "refund", "payment", "currency", "invoice", "tracing", "net worth"]),
        HelpTopic(
            id: "task-review-approve-export", kind: .task, title: "Review, approve, redact and export",
            summary: "Nothing is a finding until you review it; nothing leaves the case except through the one output route that re-checks citations and keeps protected identities out.",
            steps: [
                "Review each result (“Save review”); an unreviewed row carried anywhere stays marked unreviewed.",
                "“Include in report” (from “Add to case…” on a reviewed row) selects what the report contains; the case file report is built from the current evidence and lists its sources.",
                "Redaction removes text from a PDF for real (flattened and verified); if anything is still readable, no file is produced.",
                "Every export, copy and print of case content goes through one route: the content is frozen, each citation is re-verified, access is re-checked after the save dialog, protected identities are scrubbed, the file is written and read back, and the case log records it with its digest. A refused output is recorded too.",
                "Print is available only when the build is entitled to print; otherwise the app says so plainly and records nothing."
            ],
            controls: ["Save review", "Include in report", "Add to case…", "Case file report…"], destination: .cases,
            keywords: ["approve", "redact", "print", "copy", "report", "output"]),
        HelpTopic(
            id: "task-case-review-and-requests", kind: .task, title: "Work a case: review contradictions in place and follow up evidence requests",
            summary: "The case file keeps your place, shows what is waiting for you, lets you decide each contradiction where it is shown, and tracks what you asked custodians for until you decide it is complete.",
            steps: [
                "Cases ▸ open a case. Its Overview starts with “This case at a glance”: the question the investigation is to answer, what limits what the app could read (documents not allowed for the AI, references that no longer resolve, a check not yet run), how many contradictions and result rows wait for a decision, the open evidence requests with their missing items, and the next step. Choose a count or a next step to go where it is done: the contradictions count goes to the contradiction list, the job-result count opens Professional Jobs, the evidence-request count opens the Evidence tab. The case reopens on the tab, item, filter and search you left, after a restart too; “Return to the last source” opens the passage you last opened.",
                "Overview ▸ Contradictions: “Find contradictions”, then choose an item in the list; its two passages, each with “Open source”, are shown beside it. Choose a reason when needed and “Confirm”, “Dismiss” or “Defer”. Dismissing needs a reason (different event, different person, changed estimate, transcription error, not enough context, or other with a note). Keys (also in the Case Review menu, and while you type a note): ⌥⌘↓ and ⌥⌘↑ move through the list; ⌥⌘Y confirms, ⌥⌘N dismisses, ⌥⌘L defers.",
                "A decision is kept with the version of both documents. Running the check again over the same documents keeps it; when one of the documents is revised the item comes back as “Reopened because … changed”, and the earlier decisions stay in its decision history. A dismissal changes neither document.",
                "A confirmed contradiction can be carried with “Add to chronology” or “Include in report”: both passages travel as citations with the decision they came from; nothing is retyped.",
                "Evidence ▸ Evidence requests: “Create request” with what is requested, the custodian, the allegation or question it serves, the expected items (one per month gives three monthly statements as three items) and a due date. When a document arrives, “Link received document” (or “Link” on a suggestion whose date or name fits a missing item); a copy of a document already received is shown as a duplicate and not counted. The row says what is still missing.",
                "“Record sent” and “Record reply” keep the history of asking and answering; “Draft request text…” prepares a letter to copy and send yourself — the app sends nothing. “Record decision” sets the request to fulfilled, partly provided, refused, cannot be obtained or cancelled; an arrival does not change it, and fulfilled with items still missing needs your reason. When material arrives after the linked allegation was decided, the request says it may need revisiting; the finding is not changed.",
                "Professional Jobs: the jobs of the next step are shown and the other phases are one click away; “Find a job” (⌥⌘F) searches every job by name, and “Show all jobs” lists the whole catalogue."
            ],
            controls: ["Find contradictions", "Open source", "Confirm", "Dismiss", "Defer", "Add to chronology", "Include in report", "Return to the last source",
                       "Create request", "Link received document", "Link", "Record sent", "Record reply", "Draft request text…", "Record decision",
                       "Find a job", "Show all jobs"],
            destination: .cases,
            keywords: ["contradiction", "conflict", "dismiss", "reopen", "resume", "evidence request", "custodian", "statement", "missing", "due", "collection plan", "jobs"]),
        HelpTopic(
            id: "task-case-map", kind: .task, title: "The case map (preview): see a case's questions, evidence and decisions together",
            summary: "A map of one case: its question, allegations, hypotheses, documents, statements, events, contradictions, requests and report items, with the links between them and where each came from. It shows the case's own records — it decides nothing and copies nothing. It is a preview: it is off until you turn it on, and the case sections stay available.",
            steps: [
                "Cases ▸ open a case ▸ turn on “Case map (preview)” in the case's top bar. The case opens on the map; “Case sections” returns to the tabs for this case (and “Case map” comes back). Turning the switch off returns every case to its sections; nothing in any case changes.",
                "The top of the map stays in place: the case's title and stage, the question it is to answer (“More” shows it all), what the app could read, and counts — open questions, items awaiting review, outstanding requests, overdue actions. Choose a count to open exactly those items in the list. “What changed”, “Next action”, “Search this case” and “Return to overview” are beside them.",
                "Choose “Map” or “List” at any time: the list shows the same items with the same filters, and what you selected stays selected. The list works with the keyboard and VoiceOver.",
                "On the map: drag the background to move around, pinch or use “Zoom in” and “Zoom out”, “Fit all” to see everything shown, “Fit selection” for the selected item and what links to it. Drag an item to move it; “Pin” keeps it where you put it. A collapsed group shows how many items it holds; choose it to open it. Material nothing links to is listed under “Unlinked material”.",
                "When new material arrives, items already on the map stay where they are; new ones appear next to what they link to, or beside the map. “Arrange” tidies the selected item's branch or the whole view — it asks first, leaves pinned items alone, and “Undo” puts everything back.",
                "Opening, moving around or switching views reads this Mac's ledger only: nothing is sent anywhere."
            ],
            notes: ["The map shows at most 400 items in the visible area at once and says how many more there are; zoom in or use the list to reach the rest. The footer always counts what is shown, in collapsed groups, filtered out and hidden, against everything in the case. If a part of the case could not be read, the map says “Incomplete” and names it — that is never shown as an empty case."],
            controls: ["Case map (preview)", "Case sections", "Case map", "What changed", "Next action", "Search this case", "Return to overview",
                       "Zoom in", "Zoom out", "Fit all", "Fit selection", "Pin", "Arrange", "Undo", "Refresh"],
            destination: .cases,
            keywords: ["map", "graph", "canvas", "board", "visual", "relationships", "links", "layout", "preview", "list", "table"]),
        HelpTopic(
            id: "task-case-map-views", kind: .task, title: "Case map views: Overview, Questions, People, Chronology, Findings, Changes",
            summary: "The strip above the map holds focused views of the same case. You move between them yourself; nothing moves on its own. Each keeps its own zoom, hidden items and collapsed groups, and Back returns to where you were.",
            steps: [
                "Choose a view in the strip, or “Previous view” and “Next view” (⌃⌘← and ⌃⌘→). Overview starts with the questions and what is unresolved; Questions adds the supporting and challenging material; People, statements and events; Chronology, events with their evidence; Findings, report items and decided questions; Changes, items that changed since they were decided or carried.",
                "“Back” (⌃⌘[) returns to the previous view and selection. The line beside it shows where you are, for example Overview › A1 › Approval email.",
                "“Find on this map” finds items of the whole case by their words, including those in collapsed groups; “Waiting for me” keeps only items not yet reviewed, deferred, reopened or pending. It does not search inside documents — “Search this case” ▸ “Search case evidence” does.",
                "“Save view…” keeps the current view's kinds, filters, hidden items and collapsed groups under a name in the case's encrypted ledger; it appears at the end of the strip. Right-click a saved view to remove it. A view keeps references and settings only; it never copies the case."
            ],
            controls: ["Previous view", "Next view", "Back", "Find on this map", "Waiting for me", "Save view…", "Save view"],
            destination: .cases,
            keywords: ["view strip", "carousel", "overview", "questions", "people", "chronology", "findings", "changes", "saved view", "breadcrumb", "back"]),
        HelpTopic(
            id: "task-case-map-inspector", kind: .task, title: "The case map inspector: sources, state and actions for one item or link",
            summary: "Selecting an item or a link opens one panel: what it is, its recorded state, its exact wording, every source with its version and position, who recorded or proposed it, its review history, and the actions the case already has for it.",
            steps: [
                "Each source shows the document, the version and where in it (“Position unavailable” when only the document is known), with “Open source”. Every citation is listed, not only the first.",
                "A link says why it exists — the record it comes from, or the reason you gave — and who asserted it: you, a rule, or the AI reading (a proposal checked against the documents, never a decision).",
                "Contradictions: choose a reason when needed and “Confirm”, “Dismiss” or “Defer” — the same decision as in the case's contradiction list, kept with both documents' versions. A confirmed one can be carried with “Add to chronology” or “Include in report”, both passages included, nothing retyped.",
                "Documents: “Link to allegation…” (supports, challenges or mentions), “Link to hypothesis…” (for or against) and “Received for request…”. A whole document links without a passage and shows as unverified until a passage is chosen. Questions and hypotheses: “Create evidence request…”. Requests, entries and report items open in their case section.",
                "“Link to another item…” draws a typed link with your reason, for a connection no other record holds; “Withdraw link…” withdraws it with a reason and keeps it in the record. “Hide from this view” hides an item from this view only."
            ],
            notes: ["States are kept apart: not yet assessed, not supported by a verified source, source unavailable, restricted, needs review (changed since), could not be read. An investigator's note is always labelled a note and is never documentary support. Same name is not the same person: two people with one name stay two items, offered as “possibly the same person” until you decide."],
            controls: ["Open source", "Confirm", "Dismiss", "Defer", "Add to chronology", "Include in report", "Link to allegation…", "Link to hypothesis…",
                       "Received for request…", "Create evidence request…", "Link to another item…", "Withdraw link…", "Hide from this view", "Record link"],
            destination: .cases,
            keywords: ["inspector", "provenance", "source", "version", "locator", "position unavailable", "link", "rationale", "asserted", "note", "namesake"]),
        HelpTopic(
            id: "concept-case-map-legend", kind: .concept, title: "Case map legend: icons, lines and states",
            summary: "“Legend” at the foot of the map is always available. Each kind of item has its own icon; each kind of link its own line — solid, dashed or dotted — with an arrow for its direction; each state its own symbol. Every item has the same size: size, position, the number of links and how tidy the map looks say nothing about whether something is proved. Ten citations of one source are not ten sources.",
            controls: ["Legend"],
            destination: .cases,
            keywords: ["legend", "icons", "lines", "dashed", "dotted", "arrow", "states", "colour", "color"]),
        HelpTopic(
            id: "task-case-map-reset-view", kind: .task, title: "Reset the case map view",
            summary: "“Reset view” puts the current view's zoom, filters, hidden items and collapsed groups, and the map's positions and pins, back to their starting state. It removes or changes no case record, decision, link or document.",
            steps: ["At the foot of the map choose “Reset view”. The items are placed afresh around their questions; your saved views and your links stay."],
            controls: ["Reset view"],
            destination: .cases,
            keywords: ["reset", "layout", "positions", "start again", "messy"]),
        HelpTopic(
            id: "task-case-changes", kind: .task, title: "What changed in a case since you last looked",
            summary: "The case map's “What changed” lists this case's own changes since your seen position — documents admitted, excluded, revised, readable or not; links added or withdrawn; reviews decided or reopened; request receipts and decisions; tasks; questions, hypotheses and findings revised; outputs released; stage changes; detections that appeared or are no longer detected. Each says where it comes from. Seeing a change is not reviewing it.",
            steps: [
                "Turn on “Case map (preview)” in a case, then choose “What changed” in the case map's header (the number is how many changes are new). The case overview also shows “What changed since you last looked”; “Show what changed…” opens the same list.",
                "Each entry names its kind, when it was recorded, who made it and where it comes from: “Recorded when it happened” (written with the change itself — the case log, the scope log, the request history, a review decision) or “Derived from …” (worked out from the records, such as a newer version of a document or a task's status compared with your seen position).",
                "For a changed document, “What rests on it” lists the items that cite or link to it, with how they depend on it, and the items linked to those as “may need review”. Their decisions stay as recorded; review them yourself.",
                "“Show on map” selects the item. “Show the Changes view” opens the map's Changes view, which shows the changed items and those resting on changed evidence.",
                "“Mark as seen” moves your seen position for this case to now. It does not review, accept or decide anything, and it writes nothing in the case record."
            ],
            notes: ["A possible contradiction that disappears is shown as “No longer detected — not resolved”: nobody decided it. If the changes cannot be read, the list says so — it does not show “nothing changed”. If a part cannot be read, the list names it as incomplete."],
            controls: ["What changed", "Show what changed…", "What rests on it", "Show on map", "Show the Changes view", "Mark as seen", "Refresh"],
            destination: .cases,
            keywords: ["changes", "what changed", "new", "since", "seen", "acknowledge", "revised", "reopened", "no longer detected", "impact", "depends"]),
        HelpTopic(
            id: "task-case-history", kind: .task, title: "Case history: recorded states, milestones and comparing them",
            summary: "The case map keeps recorded states of a case — once a day when the case changed, on request, and as named milestones. A recorded state can be opened read-only and compared with another or with the case now. History starts when this version was installed: earlier map states were not recorded and are not reconstructed.",
            steps: [
                "Choose “History” in the case map's header. The first line says from when map states are recorded (“Full map state not recorded before …”).",
                "“Record the current state” keeps the map as it is now — its items, links, review states and layout. Type a name and choose “Name a milestone” to keep it as a milestone (for example “Interviews done”).",
                "“Open (read-only)” shows that state on the map and in the list with a banner. Nothing can be changed while it is shown — not positions, pins, links, reviews or views. “Return to current” brings back the case as it is.",
                "“Compare” on one state and then on another lists what was Added, Changed, Withdrawn and what Needs review between them; “Compare with current” compares a state with the case now. Items are matched by their record, not by their title."
            ],
            notes: ["Only recorded states can be opened. A recorded state holds what was recorded by then: evidence recorded later is not in it, even when the event it describes is earlier — the item keeps its event date and, separately, when it was recorded. If a source version a state cited is no longer in the ledger, its words are not shown and the current version is not shown in its place.", "A recorded state keeps the names and quoted passages of the documents it cited. If you later remove a document with “Stop and forget”, the state hides its words on screen, but they stay in the recorded state in the case's encrypted ledger — and in backups — until you erase the case, a person it names, or all data.", "Recorded states are kept in the case's encrypted ledger; erasing the case removes them, and erasing a person clears the states that name them (in their content or their milestone name), keeping only a note that a state existed."],
            controls: ["History", "Record the current state", "Name a milestone", "Open (read-only)", "Compare", "Compare with current", "Return to current"],
            destination: .cases,
            keywords: ["history", "checkpoint", "milestone", "snapshot", "past", "earlier", "compare", "read-only", "baseline", "what was known", "return to current"]),
        HelpTopic(
            id: "task-case-readiness", kind: .task, title: "Readiness: the state of a case's work, without a percentage",
            summary: "“Readiness” in the case map's header counts the case's recorded work states: questions unresolved, being investigated, answered with a recorded basis or needing review; documents read, partly read or not read; reviews pending, deferred, reopened or decided; requests by status; findings draft, outdated, reviewed or approved; tasks overdue, outstanding, completed or not applicable with a reason. “Needs attention” lists what is open.",
            steps: [
                "Choose “Readiness” in the case map's header. Each line counts items in one state; “Show” selects the first of them on the map.",
                "A decided question moves back to “needs review” when its basis is missing, contrary evidence was recorded after the decision, or a source behind it changed."
            ],
            notes: ["There is no completion percentage and no verdict. A bigger map is not a more finished case, ten citations of one source are not ten sources, and a count of supporting and opposing links decides nothing. The case's stage and approvals stay where you recorded them."],
            controls: ["Readiness", "Show"],
            destination: .cases,
            keywords: ["readiness", "maturity", "progress", "complete", "done", "outstanding", "overdue", "needs attention", "work states"]),
        HelpTopic(
            id: "task-case-map-export", kind: .task, title: "Export the case map with its sources",
            summary: "“Export” in the case map's footer releases what the view shows — the items and links, the selection, the legend, the case, the moment or recorded state, the scope and every source — through the same checks as every case export. A picture alone cannot be traced to its sources, so a map export always comes with a relationship and evidence table.",
            steps: [
                "Choose “Export” in the case map's footer: “Export map as PDF (with its relationship table)…”, “Export map as PNG and the table as CSV…” (two files: the image, then its table) or “Export the relationship table (CSV)…”. “Copy the relationship table” and “Print the relationship table” release the table's text.",
                "The table has one row per link — from, relationship, to, why the link exists, who asserted it, its state and its sources — and one row per item with its state and sources.",
                "Before anything leaves, every cited source is checked against the case's export policy as it is now (a source taken out of the case or labelled privileged refuses the export), protected source identities are removed, and the case's legal holds are stated as they are now. The release is recorded in the case log with the digest of what left."
            ],
            notes: ["Exporting while a recorded state is open says which recorded state it depicts and that it is not the case as it is now; today's restrictions apply to it. There is no screenshot or copy command on the map itself: use Export."],
            controls: ["Export", "Export map as PDF (with its relationship table)…", "Export map as PNG and the table as CSV…", "Export the relationship table (CSV)…",
                       "Copy the relationship table", "Print the relationship table"],
            destination: .cases,
            keywords: ["export", "map export", "pdf", "png", "csv", "relationship table", "print", "copy", "sources", "historical export"]),
        HelpTopic(
            id: "task-case-map-first-use", kind: .task, title: "First use of the case map: items, links, review state and what changed",
            summary: "Four things to know before you start. An item is one of the case's own records — a question, a document, a statement, an event, a contradiction, a request, a report item or your note. A link says how two items relate and why: the record it comes from, or the reason you gave. A review state says what a person decided, which is separate from what the documents say. “What changed” lists this case's changes since you last marked them as seen; seeing a change is not reviewing it.",
            steps: [
                "Start with the header: the question the case is to answer, what the app could read, and the counts. Choose a count to see exactly those items in the list.",
                "Choose an item on the map or in the list. The inspector shows its sources (“Open source” opens each one), its state, its review history and the actions the case already has for it.",
                "Read a link before you rely on it: its line style and arrow say its type, and the inspector says who asserted it — you, a rule, or the AI reading (a proposal checked against the documents, never a decision).",
                "Review states: “Not reviewed yet”, “Pending review”, “Deferred” and “Reopened — a source changed” wait for you (“Waiting for me” keeps only those). “Confirmed”, “Dismissed”, “Accepted on review” and “Rejected on review” are decisions someone recorded.",
                "When you come back, choose “What changed”. New items appear beside what they link to; nothing you placed moves. “Mark as seen” only moves your seen position.",
                "The legend (“Legend” at the foot of the map) explains every icon, line and state at any time; Help ▸ Case Map Keyboard Shortcuts lists the keys; Help ▸ Replay the Case Map Tutorial walks a sample case step by step."
            ],
            notes: ["Empty, failed and incomplete are different: “Nothing to map yet” names the next thing to do; “Incomplete” names the part that could not be read; a failed read says so and shows nothing as if it were the case."],
            controls: ["Open source", "Waiting for me", "What changed", "Mark as seen", "Legend"],
            destination: .cases,
            keywords: ["first use", "introduction", "nodes", "items", "links", "edges", "review state", "what changed", "beginner", "start"]),
        HelpTopic(
            id: "task-case-map-keyboard", kind: .task, title: "Case map keyboard shortcuts and the list path",
            summary: "Everything the map does can be done from the list with the keyboard: the list, the header, the view strip, the inspector and the footer are the same in both. Choose “List” in the strip (or use VoiceOver), then select with the arrow keys.",
            steps: CaseMapKeyboard.lines,
            notes: ["The map path and the list path run the same commands: " + CaseMapCommand.allCases.map { c in
                "\(c.rawValue) — \(c.listSurface)" + (c.shortcut.map { " (\($0))" } ?? "") }.joined(separator: "; ") + "."],
            controls: ["Previous view", "Next view", "Back", "Show details", "Zoom in", "Zoom out", "Undo", "Return to current"],
            destination: .cases,
            keywords: ["keyboard", "shortcuts", "keys", "voiceover", "accessibility", "list", "table", "tab", "arrow"]),
        HelpTopic(
            id: "task-case-map-tutorial", kind: .task, title: "The case map tutorial: question to report in the sample case",
            summary: "Help ▸ Replay the Case Map Tutorial opens the isolated sample case and walks one real workflow on the map, one step at a time: the question, a document, a passage, a review, a request, new evidence, the revised view and the report. Nothing moves on its own: Back and Next are yours, and you can work at any step.",
            steps: HelpTutorial.caseMapSteps.map { "\($0.title): \($0.instruction)" },
            controls: Array(Set(HelpTutorial.caseMapSteps.flatMap(\.controls))).sorted(),
            destination: .cases,
            keywords: ["tutorial", "sample", "walkthrough", "learn", "case map", "practice"]),
        HelpTopic(
            id: "task-case-search", kind: .task, title: "Search case evidence: search this case's documents, with what was and was not searched",
            summary: "A word-for-word search of one case's documents only — never the rest of the archive. It lists every matching document (in pages), shows each match in its passage with the rules it met, counts documents, occurrences and passages separately, and says exactly what it searched and what it could not. It finds words; it does not decide what they mean, and no AI is involved.",
            steps: [
                "Open a case and choose “Search case evidence” in its top bar (on the case map: “Search this case” ▸ “Search case evidence”; “Find on this map” only finds items on the map).",
                "Build the search with rules: choose “All of these”, “At least one of these” or “None of these” for a group, “Add rule” for words, a word starting with, exact characters, near each other, a person or organisation, the document type, the file name, a tag or a date, and “Add group” for a group inside it. “Use these rules” writes them as search text. Or type the search text yourself: operators in capitals — AND, OR, NOT, NEAR/5 — brackets, \"a phrase\", invoic*, -draft, person:\"Jane Doe\", type:email, file:report, tag:contract, exact:\"A-17/B\".",
                "Dates say which date they mean: modified- (the file's modified date), stated- (the date the document states, such as an email's Date) or event- (an event in its text), then before, on or after — stated-on:2024-03, modified-before:2024-01-31, event-after:2023. Before and after leave out the day, month or year you name. A plain before: or after: is not taken as it stands; choose which date.",
                "Read “What will be searched” before you run: it is the search exactly as it will run, with its grouping. If the search cannot be read, it is not run; where possible a repaired search is offered — “Use the repaired query” puts it in the text field, and it still runs only when you choose “Search”. It says when the repair searches more broadly.",
                "Results: every matching document, page by page (“Previous page”, “Next page”), in name order. Each shows the passages with the words marked, which rules it met (and which words it lacks, as asked), and whether a match runs across two passages. From a match: “Open source”, “Add to chronology…” or “Select for report” — the passage goes into the case with its citation, checked against the document.",
                "“What was searched” lists the case's documents searched in full, searched in part (and why), not searched (could not be read, no text, beyond a limit of the run) and excluded from the case, and the passages you set aside. No match means no match in what was searched — nothing more.",
                "“Save search…” keeps the search in this case's encrypted ledger as a live search (it runs again on the case's documents as they are then) or as a frozen result (this result as it is). For a live search, “Check for new matches” lists what is new since you last looked, and “Mark as seen” starts counting from now. It never adds a document to the case."
            ],
            notes: ["Matching: letter case and accents are ignored unless you tick “Match case” or “Match accents”; ligatures and full-width letters match their plain letters. A word is matched whole (invoice does not find invoices; invoic* does). Punctuation between the words of a phrase is ignored; exact: keeps it. Word endings, approximate and meaning-based matching are off. A run stops at its time limit or document limit and lists what it did not reach. The archive's Search (sidebar) is a separate, archive-wide search and works as before."],
            controls: ["Search case evidence", "Find on this map", "Search this case", "Add rule", "Add group", "Use these rules", "Search", "Use the repaired query",
                       "Match case", "Match accents", "Previous page", "Next page", "Open source", "Add to chronology…", "Select for report", "Save search…",
                       "Check for new matches", "Mark as seen"],
            destination: .cases,
            keywords: ["search", "find", "query", "boolean", "and", "or", "not", "near", "phrase", "exact", "wildcard", "date", "saved search", "receipt", "coverage", "not searched", "case search"]),
        HelpTopic(
            id: "task-case-coverage-cost-recovery", kind: .task, title: "What the app could read, what an AI read costs, and what to do when it fails",
            summary: "The case overview, the AI permission sheet and the case report say which documents were read, partly read or not read and why; an AI read shows its cost and can be cancelled; a failed read names its cause and one fix.",
            steps: [
                "Cases ▸ open a case ▸ Overview ▸ “This case at a glance” ▸ “What the app could read”: how many documents were read, partly read or not read, each with its reason (password-protected, unsupported file type, too large, text recognition failed, waiting to be read). “Show all” lists every one. A document not read was not searched, quoted or sent to an AI.",
                "The AI permission sheet of a case lists the same documents under “Not read, or read only in part, on this Mac”, beside the documents that would go, the estimate of the first read and, on an AI plan, the credits you have left.",
                "While a case question runs (Professional Jobs ▸ Ask ▸ “Run”), a line says the AI is reading the case, with “Cancel”. Cancel stops waiting: nothing more is sent; if the AI had started, only what it used is charged and the rest of what was held is returned. After the read the cost charged is shown.",
                "If the read fails, the cause is named with one fix: not enough credits → “Buy credits…” (or “See plans…”); the network → “Try again”; your Anthropic key refused or out of credit → “Open Settings”; the service paused for the month or today's limit reached → later. A failed request is not charged; after a timeout it may have been, and the meter shows it after the next request.",
                "The case file report (Log & exports ▸ “Case file report…”) has a “What the app could read” section and an “Evidence requests” section (each request's recorded status, what arrived by source version, what is missing); the export notice repeats the coverage line."
            ],
            controls: ["Show all", "Cancel", "Try again", "Buy credits…", "See plans…", "Open Settings", "Case file report…"],
            destination: .cases,
            keywords: ["coverage", "not read", "password", "unsupported", "ocr", "credits", "cost", "cancel", "retry", "failed", "balance"]),
        HelpTopic(
            id: "task-core-and-optional-tools", kind: .task, title: "What every case has, and the optional tools",
            summary: "Every case has the same core: bring records in, search them exactly, open the original, review and connect the evidence, track what is still open, and export a cited report — with no AI, no add-on and no connector needed. Optional tools are for specific kinds of work; they are off until a case needs them.",
            steps: [
                "Core, always there: intake with visible failures; exact search with dates, people and types; the case file with chronology, people, contradictions, evidence requests and findings; Tools ▸ Export (PDF, Word and CSV); Tools ▸ Legal holds (“Place hold”, “Release”); Tools ▸ Documents ▸ Saved searches (“Save search”); backup, restore and erasure in Settings ▸ Your data.",
                "Optional tools: Settings ▸ Modules lists them by the task they support — professional workflows (Bates productions, review coding, case slices), advanced analysis (account changes, watchlists, who wrote to whom, “Order by review priority” for documents), media and places, connections and automation (DEVONthink, notes apps, Shortcuts, Spotlight, rules, sync), AI assistance, and presentation. Each says what stays when it is off.",
                "Turning a tool off hides it and keeps everything it made. A hold, an export check, erasure, a case's AI permission and the record of what could not be read are not switches: no tool, profession or plan turns them off.",
                "Retired features (generic briefings, FAQs and mind maps; the Content creator persona) are under Settings ▸ Modules ▸ Retired, so work made with them earlier stays reachable.",
                "Settings ▸ Modules ▸ “Show engine components” holds the engine's internal switches, for troubleshooting with support. A case does not need any of them changed."
            ],
            controls: ["Place hold", "Release", "Save search", "Order by review priority", "Show engine components"],
            destination: .settings,
            keywords: ["modules", "optional", "add-on", "pack", "core", "features", "tools", "turn on", "retired", "catalog", "capability"]),
        HelpTopic(
            id: "task-private-online", kind: .task, title: "Private and Online modes, and what a provider may charge",
            summary: "Private (the default) opens no connection for your documents. Online is optional and uses the credits of an AI plan (AI Included or AI Pro) or your own Anthropic key (the only own key the app accepts).",
            steps: [
                "The easy way: after buying AI Included or AI Pro, or after saving your Anthropic key in Settings ▸ Online, the app shows “Turn on AI”: read the AI's terms and choose “Allow AI to read case documents you permit”. That one step turns on Online mode, “Use AI to write answers” and AI reading of case documents. If you chose Not now, Ask names what is missing and offers “Turn on AI…”. Not available where Online AI is blocked for the App Store country. A badge shows while Online is on; one click returns to Private.",
                "Inside a case you allow the AI once for that case: the sheet lists the documents that would go (and those that never go — privileged or restricted material) and names where they go; your questions in that case are then sent without a further prompt, and you can stop it in the case file (“Stop AI for this case”). Outside a case, a send carrying document text is always previewed and approved; a question alone is previewed too, unless “Ask before every send” is off and you chose “Send and don’t ask again this session”. Document text goes only to providers whose terms you accepted; protected identities are masked.",
                "Each send is recorded before it leaves; the estimate is shown before a case is first read. Providers may retain what they receive under their own terms. With your own key they bill your account (set a monthly limit for your own Claude key in Settings ▸ Online); on an AI plan each request is charged in credits at its actual cost.",
                "Subscribing never turns Online on. The test host and the sample case never send anything."
            ],
            destination: .settings, keywords: ["cloud", "api key", "claude", "anthropic", "own key", "network", "consent"]),
        HelpTopic(
            id: "task-ai-included", kind: .task, title: "AI credits: AI Included and AI Pro without an AI account of your own",
            summary: "AI Included gives 2,000 AI credits a month; AI Pro 6,000 a month on the monthly plan and 5,400 a month on the yearly plan (1 credit = US$0.01 of Claude cost); each request is charged what it actually cost. Credit packs of 500 or 2,000 never expire.",
            steps: [
                "Choose AI Included or AI Pro on the subscription screen (neither has a free trial; the 14-day trial is Workbench's).",
                "Right after the purchase (or Restore purchases) the app shows “Turn on AI for your AI plan”: the AI's terms and where case documents go (Anthropic, through the publisher's relay, which keeps only counts and credits). Choose “Allow AI to read case documents you permit” — this turns on Online mode, “Use AI to write answers” and AI reading of case documents; nothing is sent yet. If you chose Not now, Ask shows search results that name what is missing, with “Turn on AI…”.",
                "Open a case and ask a question. The first time, the case's permission sheet lists the documents that would be read and what it costs; choose “Allow for this case”. Questions in that case are then answered by the AI without a further prompt, each statement checked against its quote, and every send is recorded. The relay checks the plan with Apple, holds the request's worst-case cost, passes it to Anthropic and charges only the actual cost (whole credits, at least 1); a failed request costs nothing. It keeps only counts and credits.",
                "Settings ▸ Online ▸ “Check credits” shows this month's credits used and left, your credit packs, the reset date and the last request's cost. Before reading a whole case the app shows the estimate (for example “about 120 credits; you have 840”) and reads it only after you confirm.",
                "Reading a case the first time costs about 1–2 credits per 1,000 words of its text; a question within an hour of the last one usually costs 5–30 credits, because the AI re-uses the case it already read. After an idle hour the first question costs about the first-read amount again.",
                "The month's credits renew on the day of your purchase each month — yearly plans too (AI Pro yearly: 5,400 credits a month) — and do not carry over. Credit packs (500 or 2,000, bought in Settings ▸ Online) never expire, are spent after the month's credits, work while an AI plan is active and stay with your Apple account on every Mac.",
                "One request may use up to 400 credits; a confirmed whole-case read up to 600 (AI Included) or 3,000 (AI Pro); there is a daily limit. If the service's monthly capacity is reached it pauses until the 1st and says so; nothing is charged and your own key can be used meanwhile.",
                "Online AI is not offered in mainland China, Hong Kong, Macao, Russia, Belarus, Venezuela, Afghanistan, Myanmar, Yemen, Iran, North Korea, Syria or Cuba, judged by the App Store account's country: there only Workbench is sold — no AI plan, no credit pack — and an own key cannot be used either. You must be 18 or older to use it."
            ],
            controls: ["Check credits", "Turn on AI…", "Allow for this case", "Stop AI for this case"],
            destination: .settings, keywords: ["opus", "relay", "turn on ai", "use ai to write answers", "no ai is set up", "credits", "credit pack", "top-up", "ai pro", "balance", "paused", "subscription", "country"]),
        HelpTopic(
            id: "task-online-ai-helps", kind: .task, title: "Read a scan, translate, challenge or draft with AI",
            summary: "Online helps that work only from your documents and always say what they are: AI output is marked and is never the original or a finding.",
            steps: [
                "Sources ▸ Needs attention ▸ “Read with AI…” sends the page images of a scan the Mac could not read; the transcription is added as its own document that names the original.",
                "In a document's details, “Translate into English with AI…” adds a marked English translation; quote the original, not the translation.",
                "Right-click an answer: “Challenge this answer with AI…” lists weaknesses, other explanations and missing evidence from the answer's own passages; “Draft a report paragraph with AI…” writes a cited paragraph to edit.",
                "Every point the AI makes is checked against the passages sent; invented passage labels and uncited sentences are flagged."
            ],
            controls: ["Read with AI…", "Translate into English with AI…", "Challenge this answer with AI…", "Draft a report paragraph with AI…"],
            destination: .sources, keywords: ["ocr", "scan", "translation", "devil's advocate", "review", "draft", "report"]),
        HelpTopic(
            id: "task-protect-source", kind: .task, title: "Keep a confidential source's name out of everything you export or send",
            summary: "Record the person once; their name and aliases are then replaced in every export, refused in sealed files, and masked in every Online send.",
            steps: [
                "Professional Jobs ▸ the Journalist profession ▸ run “Source-document vault” (or “Source map”) for the case.",
                "In the vault result, set Protected identity to yes on the source's row and enter the person's name and any aliases in the Identity column (separate several with ;). In the Source map, set Protection to confidential source and fill “Identity to protect”.",
                "From then on every report, copy and export replaces the name with [PROTECTED SOURCE] and checks that it is gone; a sealed or signed file (a receipt, a slice, a proof bundle) that would contain it is not exported at all.",
                "Online sends mask the name whatever the masking setting; a send in which it would still be recoverable is refused."
            ],
            destination: .work, keywords: ["confidential", "source", "protect", "anonymous", "whistleblower", "redact", "identity", "journalist", "vault"]),
        HelpTopic(
            id: "task-online-tools", kind: .task, title: "Online tools: exchange rates, sanctions, registries, courts, web capture, transcription",
            summary: "Public-record lookups and captures in Online mode, each shown to you before it is sent and recorded; results are leads, not findings.",
            steps: [
                "Sources ▸ “Online tools…” (Online mode only).",
                "Exchange rate: an amount converted at the European Central Bank reference rate of a date, with a citation line.",
                "Sanctions lists: the complete OFAC and UN lists are downloaded and searched on this Mac — the name you check is not sent. A match on a name is a possible match until identifiers agree.",
                "Company registry (GLEIF) and court records (CourtListener): the name you search is sent to that service.",
                "Capture a web page: the page as the site returned it, with a record of address, time, status and SHA-256, added to your archive.",
                "Transcribe a recording: speaker labels and timecodes through an AI plan's credits (AI Included or AI Pro; Google Gemini through the publisher's service); the transcript is marked as AI output."
            ],
            controls: ["Online tools…"],
            destination: .sources, keywords: ["fx", "currency", "ofac", "un", "sanctions", "lei", "company", "court", "capture", "web", "transcribe", "audio", "speakers"]),
        HelpTopic(
            id: "task-keys-backup-erase", kind: .task, title: "Encryption, backup, recovery key, erasure and holds",
            summary: "The ledger is encrypted on this Mac; a complete backup carries everything with a recovery key; erasure is complete or refused, and a hold you created blocks it.",
            steps: [
                "The ledger is encrypted (SQLCipher, AES-256) with a key in this Mac’s Keychain. Original files in the vault rely on FileVault for encryption at rest — turn FileVault on.",
                "Settings ▸ Your data ▸ “Complete backup”: the ledger and every original, each with its SHA-256. Keep the recovery key shown there; a backup cannot be opened without it. Restore checks integrity and refuses a backup made by a newer version.",
                "Erase a case, a person or everything: the app either completes the erasure and verifies it empty, or refuses and says why. A legal hold, a draft, or a document that another case still needs blocks the erasure until released.",
                "Ask keeps each case's questions with that case: erasing a case also removes the questions asked in it and every answer given there, including answers it could not give and answers quoting documents other cases share. Questions asked across the whole library or in another case are kept.",
                "Not reached by erasure: your original files outside the app, backups you made, exports, sync folders and Spotlight entries — delete those yourself."
            ],
            controls: ["Complete backup"], destination: .settings, keywords: ["encryption", "sqlcipher", "filevault", "backup", "restore", "recovery key", "erase", "hold", "forget"]),
        HelpTopic(
            id: "task-support", kind: .task, title: "Get support without sending your documents",
            summary: "Support never needs your archive. Diagnostics stay on this Mac until you choose to share them.",
            steps: [
                "Settings ▸ Help & feedback shows the diagnostics the app keeps (counts, errors, timings — no document text) and lets you save them to a file you can inspect before sending.",
                "The support page (Help ▸ Support) lists what to include in a report: the version, what you did, what you expected, what happened, and the saved diagnostics file.",
                "Never paste document text or names into a bug report; a description of the shape of the problem is enough."
            ],
            destination: .settings, keywords: ["bug", "report", "diagnostics", "contact", "help desk"])
    ]

    // MARK: - Persona recipes (§6.7), derived from the real job catalogue

    /// The nine active professions, in the order the mandate lists them. Content Creator ships behind its
    /// own module and is not part of the nine.
    public static let personaOrder: [(applicationID: ApplicationDefinitionID, label: String, intro: String, limits: [String])] = [
        (InvestigatorPersonaPackage.applicationID, "Investigator",
         "Who did what, when — with custody of every source. Intake, triage, plan, interviews, evidence per allegation, findings and closure.",
         ["The app records the investigation; it does not decide guilt, intent or disciplinary outcome.", "An uncorroborated statement stays uncorroborated however often it is repeated."]),
        (LawyerPersonaPackage.applicationID, "Lawyer / Professional Reviewer",
         "Fact-finding, chronology, review coding, privilege log and production — every event linked to its source, every conflict preserved.",
         ["No legal conclusion is stated by the app; privilege and responsiveness are your calls, the app only applies and records them.", "Produced sets exclude withheld documents by rule, not by promise — check the production log."]),
        (CompliancePersonaPackage.applicationID, "Compliance / HR Investigator",
         "A workplace complaint handled by a fair, documented process: scope, interviews, policy mapping, findings and the file that shows the process.",
         ["Findings are about the evidence, not about a person’s character; no disciplinary decision is made by the app.", "A policy breach is recorded only where the policy text and the evidence are both cited."]),
        (ForensicAccountantPersonaPackage.applicationID, "Forensic Accountant",
         "Funds tracing, net worth, duplicate and refund analysis — the schedule behind every figure, with the rows it rests on.",
         ["A matching amount is a candidate, not a finding; the app never labels a transaction fraudulent.", "Amounts are not converted between currencies; balances follow only the rows you include."]),
        (SIUPersonaPackage.applicationID, "Insurance Fraud (SIU)",
         "A suspicious claim worked to a referral: red flags, the claim chronology, statements compared, and the SIU report.",
         ["Red flags are indicators for review, not evidence of fraud; the referral decision is the person’s.", "The report states what the documents show and what they do not."]),
        (JournalistPersonaPackage.applicationID, "Journalist",
         "Claims checked to sources, right of reply recorded, a fact-check that shows what is supported, what conflicts and what is missing.",
         ["Shared wording between sources is not independent confirmation.", "Publication, naming and legal risk are editorial decisions outside the app."]),
        (ResearcherPersonaPackage.applicationID, "Researcher / Historian",
         "What the papers and data actually show: an evidence review with dates at their real precision and uncertainty kept visible.",
         ["Date precision is preserved; the app never sharpens an approximate date.", "Inferred items are leads for the archive, not findings."]),
        (GenealogistPersonaPackage.applicationID, "Genealogist / Family Historian",
         "Who is who, worked to the Genealogical Proof Standard: sources cited, conflicts resolved in writing, a proof argument.",
         ["Two records with the same name are not the same person until the proof argument says so.", "A derived date (for example from an age at death) is shown as derived."]),
        (IndividualPersonaPackage.applicationID, "Individual",
         "A personal dispute — an insurance claim, a deposit, a job — your own file in order, with the documents behind each point.",
         ["The app is not legal, financial or medical advice; it organises your documents so you and your advisers can see them.", "What the documents do not say is listed as missing, not filled in."])
    ]

    public static var personaRecipes: [HelpTopic] {
        personaOrder.map { p in
            let jobs = PersonaJobCatalogComposer.jobs(forPersona: p.applicationID)
            var steps: [String] = [
                "Open Professional Jobs and choose “\(p.label)”; press “Start matter”, name it and choose its workspace.",
                "Press “Add documents to this case” and confirm the scope preview — only documents in scope are read."
            ]
            var products: [String] = []
            var decisions: [String] = []
            var prohibited: [String] = []
            for job in jobs {
                let doc = JobDocumentationCatalog.doc(personaLabel: p.label, jobTitle: job.title)
                var line = "Run “\(job.title)”: \(job.detail)"
                if let doc, !doc.requiredInputs.isEmpty { line += " Needs: \(doc.requiredInputs.joined(separator: "; "))." }
                steps.append(line)
                if let doc {
                    products.append(contentsOf: doc.workProducts)
                    decisions.append(contentsOf: doc.humanDecisions)
                    prohibited.append(contentsOf: doc.prohibitedConclusions)
                }
            }
            steps.append("Review each result (“Open result”, decide the rows, “Save review”), choose what the report carries (“Include in report”), then export it from the case file (“Case file report…”) and reopen the file.")
            func unique(_ a: [String]) -> [String] { var seen = Set<String>(); return a.filter { seen.insert($0.lowercased()).inserted } }
            var notes: [String] = []
            let prods = unique(products)
            if !prods.isEmpty { notes.append("Work products: " + prods.joined(separator: "; ") + ".") }
            let decs = unique(decisions)
            if !decs.isEmpty { notes.append("Your decisions (the app waits for them): " + decs.joined(separator: "; ") + ".") }
            notes.append("Professional limits: " + (p.limits + unique(prohibited)).joined(separator: " ") )
            notes.append("Job descriptions and limits come from the job documentation of the \(jobs.count) jobs this profession ships with; a job without documentation is listed from its card only.")
            return HelpTopic(
                id: "persona-" + slug(p.applicationID.rawValue),
                kind: .persona, title: "Recipe — \(p.label)", summary: p.intro,
                steps: steps, notes: notes,
                controls: ["Start matter", "Add documents to this case", "Open result", "Save review", "Include in report", "Case file report…"],
                destination: .work,
                keywords: [p.label.lowercased(), "recipe", "profession", "persona"] + jobs.map { $0.title.lowercased() },
                persona: p.label)
        }
    }

    // MARK: - Screens

    /// Every sidebar destination has a screen topic: the explicit guide where one is written, the
    /// destination’s own subtitle otherwise, so no screen is undocumented.
    public static var screens: [HelpTopic] {
        var out: [HelpTopic] = []
        var seen = Set<Destination>()
        // Written guides first.
        for g in GuideContent.screenGuides {
            seen.insert(g.dest)
            out.append(HelpTopic(id: "screen-\(g.dest.rawValue.lowercased())", kind: .screen, title: g.title, summary: g.body, destination: g.dest))
        }
        // The current journey’s own screens.
        let written: [(Destination, String, String)] = [
            (.work, "Professional Jobs — the matter, its documents and the jobs",
             "Choose your profession, start a matter (or resume one), bring documents into its scope with “Add documents to this case”, then run the jobs in their phases. Each card says what the job needs, what it produces, and — when it cannot run — why and what to do. Progress counts reviewed results and blockers, not clicks. Every run, review and document decision is in the work log."),
            (.workCenter, "Work Center — guided workflows",
             "Step-by-step workflows for the jobs, with the fields each step needs and the work product at the end. The same jobs as Professional Jobs, laid out as a walkthrough."),
            (.registers, "Logs & Trackers — the registers",
             "The case’s structured registers: tasks, custody, exhibits, holds and the other trackers, each row cited to its source."),
            (.dataLab, "DataLab — structured results you can query",
             "A job result as a table: the question once above it, sort and filter, “Unresolved only”, a source pane for the selected row, and re-run with your edited query."),
            (.handoff, "Handoff & Review — carrying results into the case",
             "Reviewed rows travel with every citation, their revision digest and their review state into the case question, the chronology or the report. A row whose source changed since is shown as stale."),
            (.hypotheses, "Competing Hypotheses — weigh explanations",
             "An Analysis of Competing Hypotheses matrix: evidence rows against hypotheses, each cell consistent, inconsistent or not assessed. Ranks by fewest inconsistencies, says when there is no preference, and cites each cell’s evidence."),
            (.review, "Review — what waits for your decision", "Results, links and documents that need a human decision before they count."),
            (.transcripts, "Transcripts — recordings as text", "Transcripts made on this Mac (Apple Speech, English): quotable, searchable, and marked as a speech model’s reading, not a certified transcript."),
            (.changes, "What Changed — differences between versions", "What a later version of a document, result or account added, removed or changed."),
            (.settings, "Settings — modes, privacy, data and subscription", "System mode, Private/Online, the optional tools (Modules, listed by the task each supports), ingest options, Your data (backup, recovery key, erasure), Help & feedback, legal notices and the subscription."),
            (.evidence, "Evidence — add and review documents",
             "Sources (add folders and files; what was read, partly read or not read, each with its reason), Library (every document), Completeness (how much is processed) and Processing (what runs now), with the import queue. The line at the top says whether a case is open: with one, it counts the case's documents in scope and those excluded, which stay excluded. The lists are the whole library; “Open this case's evidence” opens the case's own Evidence section."),
            (.outputs, "Outputs — saved work and exports",
             "Saved answers (replayable, with their evidence), saved questions, the Notebook and work products (Handoff & Review), and “Export timeline, people or documents…” for CSV, Word and PDF with a receipt. A case's report and its exports are in its file ▸ Log & exports — “Open this case's report and exports” goes there."),
            (.moreTools, "More tools — every specialist screen",
             "Case analysis views (timeline, dossier, connections, findings, comparisons — these read the whole library), professional workspaces (Professional Jobs, Work Center, registers, DataLab and the profession studios), records and checks (audit, receipts, authenticity, citations, redaction, conversion) and archive analysis (knowledge, trends, freshness, query). None is needed for an ordinary case; every one is also in the ⌘K palette."),
            (.guide, "Guide — this help", "Searchable offline help: Get started, tasks, recipes by profession, the screens, the words the app uses, reading results carefully, subscription and troubleshooting.")
        ]
        for (dest, title, body) in written where !seen.contains(dest) {
            seen.insert(dest)
            out.append(HelpTopic(id: "screen-\(dest.rawValue.lowercased())", kind: .screen, title: title, summary: body, destination: dest))
        }
        for group in Destination.Group.allCases {
            for dest in group.items where !seen.contains(dest) {
                seen.insert(dest)
                out.append(HelpTopic(id: "screen-\(dest.rawValue.lowercased())", kind: .screen, title: "\(dest.title) — \(dest.blurb)", summary: dest.blurb, destination: dest))
            }
        }
        return out
    }

    // MARK: - Concepts

    public static var concepts: [HelpTopic] {
        GuideContent.glossary.map { g in
            HelpTopic(id: "concept-" + slug(g.term), kind: .concept, title: g.term, summary: g.definition, keywords: ["glossary", "status"])
        } + GuideContent.termGroups.flatMap { group in
            // Developer-only switches are not help for the person (and would make the generated manual
            // differ between Debug and Release builds).
            group.items.filter { !$0.term.contains("(dev builds)") }.map { item in
                HelpTopic(id: "concept-" + slug(item.term), kind: .concept, title: item.term, summary: item.definition, keywords: [group.title.lowercased()])
            }
        }
    }

    // MARK: - Case map context help (M9, plan §10): one topic per link type, item state and review state

    public static func caseMapLinkHelp(_ t: CaseMapLinkType) -> String {
        switch t {
        case .supports: return "The item at the start supports the one the arrow points to, as recorded in the case (an evidence-grid row, a hypothesis citation or your link). Support is a recorded stance, not proof."
        case .challenges: return "The item at the start challenges the one the arrow points to — contrary evidence, kept beside the supporting material and never averaged away."
        case .mentions: return "The item mentions the other without a stance for or against it."
        case .attributedTo: return "A statement or document is attributed to this person or organisation, as the record states it."
        case .occurredBefore: return "One recorded event is dated before the other. The order comes from the recorded dates, not from an inference."
        case .occurredAfter: return "One recorded event is dated after the other. The order comes from the recorded dates, not from an inference."
        case .possibleSamePerson: return "Two people with the same name, offered as possibly the same person. It stays pending until you decide; the same name is not the same person."
        case .dependsOn: return "The item rests on the other: if the other changes, this one may need review."
        case .requestsEvidenceFor: return "An evidence request asks for material about this question. The request records what you will ask for; the app sends nothing."
        case .receivedInResponseTo: return "A document received for an evidence request. Arriving does not fulfil the request — only your recorded decision changes its status."
        case .derivedFrom: return "The item was carried from this passage (a chronology entry or report item citing it), with its citation."
        case .supersedes: return "A later record replaces an earlier one — for example a correction to an attested statement. The earlier one is kept."
        case .selectedForReport: return "You selected this item for the case report under that question."
        }
    }

    public static func caseMapStatusHelp(_ k: CaseMapStatus.Kind) -> String {
        switch k {
        case .recorded: return "Recorded as stated in the case. It is what the record says, not a judgement that it is true."
        case .unassessed: return "Not yet assessed: recorded before passage checking existed, or never checked. Select a passage to check it."
        case .unsupported: return "Not supported by a verified source — for example an investigator's note or an entry with no cited passage. A note is never documentary support."
        case .unavailable: return "The source is not in this case (it was taken out of the case scope or withdrawn). Bring it back with “Review new documents”, or cite another source."
        case .restricted: return "The source is in the case but cannot be read under the current access policy (for example labelled privileged). It is not shown or exported."
        case .stale: return "Needs review — a source behind it changed since it was decided or carried. The decision stays as recorded until you review it."
        case .failed: return "The source could not be read (damaged, password-protected or unsupported). It was not searched or quoted; Sources ▸ Needs attention says why."
        }
    }

    public static func caseMapReviewHelp(_ r: CaseMapReviewState) -> String {
        switch r {
        case .notApplicable: return "No review is needed for this kind of record."
        case .unreviewed: return "Nobody has reviewed it yet. It waits for you."
        case .pendingReview: return "Waiting for a decision (for example an open evidence request or a possible same person)."
        case .accepted: return "A reviewer accepted it. Its citations and revision are kept."
        case .completed: return "A completed result carried from a job."
        case .confirmed: return "Confirmed by a reviewer, with the reason and the versions of the sources it rests on."
        case .dismissed: return "Dismissed by a reviewer, with a reason. Both sources are kept."
        case .deferred: return "Deferred: the reviewer chose to decide later. It still waits."
        case .reopened: return "Reopened because a source changed. The earlier decision stays in the history."
        case .rejected: return "Rejected on review. It is kept, and not carried as accepted."
        case .withdrawn: return "Withdrawn with a reason. It stays in the record and is no longer drawn."
        }
    }

    public static var caseMapContext: [HelpTopic] {
        CaseMapLinkType.allCases.map { t in
            HelpTopic(id: "concept-case-map-link-" + slug(t.rawValue), kind: .concept, title: "Case map link: \(t.label)",
                      summary: caseMapLinkHelp(t) + " Drawn as a \(t.stroke.rawValue) line" + (t.directed ? " with an arrow." : " without an arrow."),
                      keywords: ["case map", "link", "edge", "line"])
        } + CaseMapStatus.Kind.allCases.map { k in
            HelpTopic(id: "concept-case-map-state-" + slug(k.rawValue), kind: .concept, title: "Case map state: \(k.label)",
                      summary: caseMapStatusHelp(k), keywords: ["case map", "state", "status"])
        } + CaseMapReviewState.allCases.map { r in
            HelpTopic(id: "concept-case-map-review-" + slug(r.rawValue), kind: .concept, title: "Case map review state: \(r.label)",
                      summary: caseMapReviewHelp(r), keywords: ["case map", "review", "decision"])
        }
    }

    /// Stable lowercase-kebab id fragment from a title.
    static func slug(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    // MARK: - Safety (§6.10)

    public static let safety: [HelpTopic] = [
        HelpTopic(id: "safety-quotations", kind: .safety, title: "Quotations are checked; sources can still be wrong",
                  summary: "Every citation is re-verified against the document before it is shown or exported, so the quote is really there. The document itself can be mistaken, out of date, one side of a dispute, or written to mislead. Open the source and judge it as you would any document."),
        HelpTopic(id: "safety-shared-text", kind: .safety, title: "Shared text is not independent corroboration",
                  summary: "When two documents share wording — a forwarded email, a copied paragraph, a template — they count as one source. The source map labels this “shared text / possible relationship” and leaves independence unassessed rather than counting two.",
                  keywords: ["corroboration", "independence", "forward", "copy"]),
        HelpTopic(id: "safety-amounts", kind: .safety, title: "A repeated amount proves neither agreement nor fraud",
                  summary: "The same figure in two places may be an instalment, a refund, a duplicate payment, a quote repeated in a reply, or a coincidence. The app shows the match and its two sources; the classification and its reason are recorded by you.",
                  keywords: ["duplicate", "money", "match"]),
        HelpTopic(id: "safety-confidence", kind: .safety, title: "A confidence figure is not calibrated until it has been validated",
                  summary: "The confidence shown with an item is the evidence gate’s own grading of how well the passages support it. It has not been validated against outcomes for your archive, so treat 80 as “stronger than 60”, not as “right four times in five”. The citations, not the number, are what to check.",
                  keywords: ["confidence", "calibration", "percentage", "score"]),
        HelpTopic(id: "safety-decisions", kind: .safety, title: "The app documents and finds; the person decides",
                  summary: "No job states a legal, accounting, medical or disciplinary conclusion. Results are drafts until reviewed; adverse findings are recorded with your reasons; exports carry what you selected. Professional training and judgement are not replaced by this app."),
        HelpTopic(id: "safety-ai", kind: .safety, title: "What the on-device AI does and does not do",
                  summary: "In Private mode the AI runs on this Mac and is used to read, extract and phrase. It can misread a document; that is why every claim carries a citation you can open and why answers outside your documents are marked “Not from your documents”. It does not add facts that are not in your documents to the evidence, and anything it wrote that a document does not support is shown as unsupported.",
                  keywords: ["hallucination", "invent", "model", "apple intelligence"])
    ]

    // MARK: - Subscription (§6.6, §11)

    public static let subscription: [HelpTopic] = [
        HelpTopic(id: "subscription-plans", kind: .subscription, title: "Plans, the free trial, renewal and cancelling",
                  summary: "Three plans, each monthly or yearly, all with the nine personas (the professions listed under “By profession”): Workbench (Online AI with your own Anthropic key), AI Included (2,000 AI credits a month) and AI Pro (6,000 a month; 5,400 a month on the yearly plan). Prices are shown by the App Store for your country; the app never shows a made-up price.",
                  steps: [
                    "Workbench has a 14-day free introductory trial when Apple finds your account eligible (one per account); the AI plans have none. The subscription screen shows the price that follows the trial and when it will be charged.",
                    "The subscription renews automatically unless cancelled at least a day before the period ends. Cancel in your Apple Account (Help ▸ Manage subscription, or the “Manage subscription” link on the subscription screen); Apple’s instructions are linked there.",
                    "The three plans are one subscription, never two: moving up (Workbench → AI Included → AI Pro) starts at once and Apple refunds the unused part; moving down or between monthly and yearly takes effect at the next renewal. Monthly and yearly give the same access and the same monthly credits, except AI Pro yearly: 5,400 credits a month instead of 6,000.",
                    "Payment, renewal, refunds and restore are handled by Apple. The app opens no connection for them and never sees your payment details. Subscribing does not turn on Online mode."
                  ],
                  controls: ["Manage subscription", "Restore purchases"], destination: .settings,
                  keywords: ["price", "trial", "renew", "cancel", "monthly", "annual", "yearly", "upgrade", "downgrade", "workbench", "ai pro", "apple account"]),
        HelpTopic(id: "subscription-restore-offline", kind: .subscription, title: "Restore purchases, another Mac, and being offline",
                  summary: "Your subscription follows your Apple account; your archive does not.",
                  steps: [
                    "On a new Mac, or after reinstalling, press “Restore purchases” (subscription screen or Settings ▸ Subscription). The App Store confirms what your account holds.",
                    "Offline, the last verified state is kept until its own verified end (for example the end of the paid period). The app never extends access beyond what was verified and never removes still-valid access because the store could not be reached.",
                    "AI credit packs are kept by the AI service for your Apple account's subscription, not on the Mac: they are there after reinstalling or on another Mac once the plan is restored.",
                    "Your documents and the ledger stay on this Mac. Move them with a complete backup and the recovery key (Settings ▸ Your data)."
                  ],
                  controls: ["Restore purchases", "Complete backup"], destination: .settings, keywords: ["restore", "offline", "new mac", "reinstall", "credits"]),
        HelpTopic(id: "subscription-expiry", kind: .subscription, title: "After the trial or subscription ends",
                  summary: "Your work is never locked away or deleted by billing.",
                  steps: [
                    "Every case stays readable. Exports, complete backups, recovery, Help, the sample case and the privacy and erasure controls keep working.",
                    "Creating, editing and analysing — adding documents, starting a matter, running jobs, asking, writing in the case file, drafting, editing a hypotheses matrix — open the subscription screen instead of running. Nothing is changed by the refusal.",
                    "A payment that did not go through keeps access during Apple’s verified grace period; after it, the app says plainly that payment failed and what to do."
                  ],
                  destination: .settings, keywords: ["expired", "read-only", "lapsed", "grace", "billing"])
    ]

    // MARK: - Troubleshooting

    public static let troubleshooting: [HelpTopic] = [
        HelpTopic(id: "trouble-nothing-found", kind: .troubleshooting, title: "“The documents don’t say” when you believe they do",
                  summary: "The evidence gate found no supporting passage in the documents in scope.",
                  steps: [
                    "Check the case scope: press “Add documents to this case” and look at the counts — a document outside the scope is not read for this case.",
                    "Check Sources: a file that “could not be read” has no text to search; a scan with little text needs better OCR.",
                    "Try Search with the exact word or number; if Search finds it and Ask does not, the passage exists but does not support the question as asked — rephrase it.",
                    "Open Findings ▸ Missing Proof for what would be needed to establish the claim."
                  ],
                  controls: ["Add documents to this case"], destination: .sources, keywords: ["no answer", "missing", "not found"]),
        HelpTopic(id: "trouble-case-map", kind: .troubleshooting, title: "The case map or case search shows an error, or something was not saved",
                  summary: "Every case map and case search error says what failed and one thing to do next, and keeps what you typed or moved on screen.",
                  steps: [
                    "“The case map could not be read”: choose “Refresh”. If it fails again, use “Case sections” — they hold the same records.",
                    "“Incomplete: … could not be read”: the named part is missing from the map, not empty. Choose “Refresh”; the rest of the map can be used meanwhile.",
                    "“The new position was not saved” or “The view was not saved”: the change stays on screen; choose “Try again”. Your saved views, links and records are unchanged.",
                    "“Not marked as seen”: nothing was reviewed either way; choose “Try again”.",
                    "A search that cannot be read is not run; “Use the repaired query” offers a repair when one exists. A search that stopped at its limit lists what it did not reach under “What was searched”.",
                    "A map that looks messy: “Reset view” resets the zoom, filters, hidden items and positions only — no case record, decision, link or saved view is changed."
                  ],
                  controls: ["Refresh", "Case sections", "Try again", "Use the repaired query", "Reset view"],
                  destination: .cases, keywords: ["case map", "error", "not saved", "failed", "incomplete", "retry", "case search"]),
        HelpTopic(id: "trouble-disabled", kind: .troubleshooting, title: "A button is greyed out",
                  summary: "A disabled control carries the reason and the remedy as its tooltip and in its accessibility description; empty screens say which of five things is true.",
                  steps: [
                    "Hover the control (or read it with VoiceOver): the reason — no documents in scope, nothing selected, a review not saved, no subscription, a hold in force — and the next safe action.",
                    "An empty screen distinguishes: no files added; files added but unreadable; files outside this case’s scope; evidence insufficient for the question; results waiting for review; an export blocked by a hold or an unverified citation.",
                    "A failure message says what failed, whether your work was saved, and the next safe action. Work in progress is saved as you go; a save that fails is named, not lost silently."
                  ],
                  keywords: ["disabled", "greyed", "empty", "cannot", "why"]),
        HelpTopic(id: "trouble-slow", kind: .troubleshooting, title: "Importing or answering is slow",
                  summary: "First indexing of a large archive, OCR of scans and transcription of recordings take the longest; answers are faster once indexing has finished.",
                  steps: [
                    "Sources shows what is still being read. Live shows the background pipeline.",
                    "Settings ▸ Your data ▸ File-type ingest guide estimates time per 100 MB for each file type and system mode.",
                    "Switch off “Transcribe audio & video” (Settings ▸ Modules) for a faster import; recordings are then kept and can be transcribed later in Transcripts.",
                    "Background maintenance (off by default) tidies summaries while the Mac is idle and stops the moment you return."
                  ],
                  controls: ["Transcribe audio & video"], destination: .live, keywords: ["performance", "slow", "indexing", "progress"])
    ]
}
