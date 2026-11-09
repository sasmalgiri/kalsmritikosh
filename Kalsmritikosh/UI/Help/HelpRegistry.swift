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
            id: "task-case-intake", kind: .task, title: "What a case takes in, and from where",
            summary: "Every item a case takes in has one intake record: how it arrived, who supplied it, who entered it, who it says wrote it, when it was captured and when it was received. Documents come in only by your decision or by a trusted-source policy that is named on each inclusion.",
            steps: [
                "Opening a case over a workspace includes what the workspace holds at that moment, under the policy “Documents in the case's workspace when the case was opened”. A document added to the workspace later, or a new version read later, waits in “Review new documents”.",
                "Items shared to the app from another app, captured, or imported from an iPhone or iPad after the case was opened are offered in the review too, unticked. Adding one also adds it to the case's workspace.",
                "To keep a document out, tick it, write the reason and press “Exclude ticked”. The exclusion is recorded in the case and stays: the review and the policies leave it out.",
                "A typed entry records separately who supplied it and who it says wrote it (open “Where it came from (optional)”). It stays your typed entry; it becomes verified only when a person marks it verified.",
                "Each read of your folders is an intake batch. Its receipt lists every file selected: received, already held, an exact duplicate, failed or not finished. The case overview shows how many of the case's documents trace to a batch, and which files of the latest batch could not be taken in."
            ],
            controls: ["Review new documents", "Exclude ticked", "Where it came from (optional)"], destination: .cases,
            keywords: ["intake", "import", "share", "duplicate", "version", "exclude", "policy", "supplied", "receipt", "batch"]),
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
            id: "task-case-map-views", kind: .task, title: "Case map views: Overview, Questions, People, Evidence, Money, Chronology, Work, Findings, Changes",
            summary: "The strip above the map holds focused views of the same case. You move between them yourself; nothing moves on its own. Each keeps its own zoom, hidden items and collapsed groups, and Back returns to where you were.",
            steps: [
                "Choose a view in the strip, or “Previous view” and “Next view” (⌃⌘← and ⌃⌘→). Overview starts with the questions and what is unresolved; Questions adds the supporting and challenging material; People, statements and events; Evidence, documents, reports, points and exhibits; Money, money movements read from the documents (each in its own currency, not verified payments); Chronology, events with their evidence; Work, actions and requests with what they serve and wait for; Findings, report items and decided questions; Changes, items that changed since they were decided or carried.",
                "“Back” (⌃⌘[) returns to the previous view and selection, and “Forward” (⌃⌘]) goes where Back left. The line beside it shows where you are, for example Overview › A1 › Approval email.",
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
            id: "task-case-map-frames", kind: .task, title: "Open an item as a frame: go deeper and come back exactly",
            summary: "Any item on the map — a report, a point, a question, an action, a person, an event or a document — can be opened as a frame. The frame shows the item and everything it is related to: what it was taken from, its points, the questions and work raised from it and the results returned. There is no depth limit, and the breadcrumb returns you exactly to where you were.",
            steps: [
                "Select an item and choose “Open as frame” in the inspector (⌃⌘↩), or in the list choose “Open as frame” from the item's menu.",
                "Inside the frame, select any related item and open it as the next frame. The breadcrumb above the map lists every level.",
                "Choose “Case map” or an earlier frame in the breadcrumb, or “Up one frame” (⌃⌘↑), to return: the selection and the view of that level are put back as you left them.",
                "Each frame keeps its own positions. The same record can appear in several frames; it is one record, so a change to it shows in every frame."
            ],
            notes: ["A frame is a way of looking at the case's records; it copies nothing. A long frame lists its items a page at a time, and nothing is dropped.",
                    "When an item you are looking for is in a collapsed group, choose “Show on map” in What changed, or the “match(es) are in collapsed groups” link under Find: the group opens, the item is selected and the map is centred on it."],
            controls: ["Open as frame", "Up one frame", "Case map"],
            destination: .cases,
            keywords: ["frame", "drill down", "deeper", "breadcrumb", "return", "nested", "recursive", "reveal", "collapsed", "show on map"]),
        HelpTopic(
            id: "task-case-map-brief", kind: .task, title: "Brief the case: the recorded position, what is open, briefings and handover",
            summary: "“Brief” sums up the case — or one branch — from its own records: its purpose and scope, the current recorded position, what is unresolved, contrary material and open alternatives beside the position, material changes and next work. Every entry says why it is there and opens on the map. It works with AI off and ranks nothing away.",
            steps: [
                "In the case map's top bar choose “Brief”. For one branch, select an item and choose “Brief of this branch” in the inspector; “Brief of the whole case” goes back.",
                "Each entry has “Show on map”: the map opens the record wherever it is — out of a frame, a collapsed group or a folded branch — and selects it. “Set aside from the brief…” leaves the record and its evidence in the case and lists it under “Set aside”; “Bring back” returns it.",
                "“Where the material stands” counts the material by evidential state (reported, supported, challenged, not yet assessed, reviewed, concluded) and, separately, the work (open, blocked, finished). There is no percentage: finishing work does not answer its question.",
                "“Your brief” holds your own structured brief — purpose, current position, unresolved, alternatives, next work — in versions. “Save as a new version”, then “Accept this version”. An accepted version is never edited; when the case changes later, it says it was written before those changes.",
                "“Briefings” builds a path for a handover or a review: “Create briefing”, then “Add step” (the selected item, the open branch or a saved view) or “Add note”. Each step opens into the map. A live briefing marks steps that changed since they were added; “Freeze this briefing” keeps every step exactly as it is now.",
                "“Since you were here” shows where you were (“Resume”), what is new to you, what is waiting for a review decision, work due and blocked work. Seeing a change is not reviewing it."
            ],
            notes: ["Briefs, briefings and set-aside decisions are kept in the case's encrypted ledger, erased with the case and carried in its backup. A frozen briefing is refused if the case changed after the map was read — choose Refresh and freeze again."],
            controls: ["Brief", "Brief of this branch", "Brief of the whole case", "Show on map", "Set aside from the brief…", "Bring back", "Save as a new version",
                       "Accept this version", "Create briefing", "Add step", "Add note", "Freeze this briefing", "Resume"],
            destination: .cases,
            keywords: ["brief", "summary", "orientation", "handover", "briefing", "dossier", "position", "alternatives", "contrary", "since last", "return", "resume"]),
        HelpTopic(
            id: "task-case-map-arrange", kind: .task, title: "Shape the map: fold branches, place items in frames, choose several, revise links",
            summary: "Fold what hangs under an item into its card, put an item into another item's branch, choose several items to arrange or pin together, see the same records as a table or a timeline, and correct a link without losing its history. None of these changes evidence.",
            steps: [
                "Select an item and choose “Fold branch” (on the map's controls or the list's menu). Its card then counts what it holds and how many are new, blocked or waiting for review; folds nest, and “Unfold branch” opens one level.",
                "“Place in frame…” puts the selected item into another item's branch. It stays one record and appears in every branch it is placed in; a branch can never end up inside itself. Select the “placed here” link and choose “Remove from this branch…” to undo it with a reason.",
                "⌘-click items on the map, or choose “Choose with others” in the list, then use Arrange ▸ “Arrange the chosen items”, “Pin the chosen items” or “Unpin the chosen items”. Undo puts them back.",
                "“Show as” switches between Map, List, Table and Timeline. In the timeline, choose a date or amount band: the same records are highlighted in all four; “Clear range” stops it. Dates keep their recorded precision and amounts their own currency.",
                "Select a link you drew and choose “Revise link…” to correct its type, reason, certainty or period: the earlier link is kept, withdrawn with your reason, and “Show revision history” lists the chain. For two people with the same name choose “Record as the same person…” or “Record as different people…”; neither merges them, and “Withdraw decision…” undoes it.",
                "Zoom in for more on each card (state, date, amount, sources, first line); zoom out for less. “Coverage” lists every store of the case with how many of its records are on the map, and a person, an interview or the case lists its “Other records” in the inspector, read when you open them. “Save view…” also keeps the frames that are open."
            ],
            controls: ["Fold branch", "Unfold branch", "Place in frame…", "Remove from this branch…", "Choose with others", "Arrange the chosen items", "Pin the chosen items",
                       "Unpin the chosen items", "Clear range", "Revise link…", "Show revision history", "Record as the same person…", "Record as different people…",
                       "Withdraw decision…", "Coverage", "Forward"],
            destination: .cases,
            keywords: ["fold", "nest", "branch", "place in frame", "multi-select", "table", "timeline", "distribution", "amount", "revise", "certainty", "coverage", "same person"]),
        HelpTopic(
            id: "task-case-map-report-points", kind: .task, title: "Work from a supplied report: points, questions, actions and results",
            summary: "Record a supplied report (a laboratory, expert or audit report) as a report of the case, take its points one by one with the exact words from the source, and open questions and actions from each point. A completed action's result is recorded as a result report with its own points, so the work can go as deep as the case needs. Everything works with AI off.",
            steps: [
                "Select the report's document on the map and choose “Record as a supplied report…”: its title, producer, author, material examined, date as written, methods and stated limitations.",
                "Select the report and choose “Add point…”: the kind (claim, finding, recommendation or allegation), your statement of the point, and the exact words you selected in the source. The words are checked in the report's own document and pinned to their passage; words that do not verify are kept and labelled unverified.",
                "Select a point and choose “Add qualification…” for an uncertainty, limitation, exclusion or condition. It is shown with the point everywhere, so a conditional result does not read as unconditional.",
                "From a point choose “Ask a question about this point…” (an open question of the case) or “Create action…” (a task with its purpose, expected result, responsible person and reviewer). From an action, “Create child action…” adds work under it.",
                "When the work is done choose “Record result…”; add the result's points and open deeper work from them. “Submit result for review”, then “Accept result” or “Return for more work”, and “Record outcome…”.",
                "“Add section…” records a heading of the report so points can sit where the report put them. “Suggest points (rule-based, AI off)” reads the report's own passages by fixed rules and lists candidate sentences: “Accept as a point” records it with its exact words, checked in the document; “Dismiss” sets it aside. Suggesting again never repeats a sentence and never changes a point you accepted.",
                "From a point, “Request evidence about this point…” opens an evidence request linked to it. The same point can be used in a question, a person, a chronology entry, a money movement or a briefing without copying it; each use says when the point changed since.",
                "On an amendment, “Compare with the earlier report” lists changed wording, added and removed qualifications and changed details, and marks the work resting on a changed point as needing review. Nothing you decided is changed.",
                "“Add supplied table, figure or media…” keeps what the specialist supplied with the report. It is shown as supplied: the app did not perform the acquisition or the analysis and cannot reproduce it."
            ],
            notes: ["A point is what the report says, not that it is true. “Accept point” records your decision; an accepted point is not changed by any later step — reopen its review first.",
                    "The outcome is separate from the task's status: a completed action can leave its question open. If you review your own work, it is recorded as self-review; working alone needs no second name.",
                    "When the report's document is read again, its points stay and are marked “Needs review — changed since” until you check the passage in the new version. An amendment is recorded as a new report (“Record an amendment or supplement…”); the first report is kept."],
            controls: ["Record as a supplied report…", "Add point…", "Add qualification…", "Ask a question about this point…", "Create action…",
                       "Create child action…", "Record result…", "Submit result for review", "Accept result", "Return for more work", "Record outcome…",
                       "Accept point", "Reject point", "Record an amendment or supplement…", "Add section…", "Suggest points (rule-based, AI off)",
                       "Accept as a point", "Dismiss", "Request evidence about this point…", "Compare with the earlier report", "Add supplied table, figure or media…"],
            destination: .cases,
            keywords: ["report", "forensic report", "expert report", "point", "finding", "claim", "recommendation", "qualification", "condition",
                       "limitation", "child action", "result", "outcome", "self-review", "solo", "amendment", "supplement"]),
        HelpTopic(
            id: "concept-case-map-legend", kind: .concept, title: "Case map legend: icons, lines and states",
            summary: "“Legend” at the foot of the map is always available. Each kind of item has its own icon; each kind of link its own line — solid, dashed or dotted — with an arrow for its direction; each state its own symbol. Every item has the same size: size, position, the number of links and how tidy the map looks say nothing about whether something is proved. Ten citations of one source are not ten sources.",
            controls: ["Legend"],
            destination: .cases,
            keywords: ["legend", "icons", "lines", "dashed", "dotted", "arrow", "states", "colour", "color"]),
        HelpTopic(
            id: "concept-source-words-and-copies", kind: .concept, title: "Original words, recognized text, your statement — and copies of one source",
            summary: "Every cited passage says what kind of text it is, so the source's own wording is never confused with a reading of it or with your summary of it. Copies of one document count as one source.",
            steps: [],
            notes: [
                "The badge under a cited passage says how its words were obtained: “Original text” (the file's own text), “Recognized text (OCR)” (read from an image of the page — check the original image), “Transcribed” (from a recording), “Typed entry” or “From an external service”. Under it: the reader and its version, the recognition engine and its version, when the text was extracted, the source version and how completely the source was read.",
                "A point's statement is marked “Investigator's statement”: it is your wording of what the report says. The exact quoted words stay as they were recorded — rewording a statement, a chronology entry or a report item never changes its quotation or citation.",
                "Quoted words cut from a longer sentence are checked against that sentence. If the cut leaves out a “not”, who said it (“he said that…”), an uncertainty, a plan or a condition, the point shows it as a qualification with the full sentence, and it is not shown as a plain verified passage.",
                "A citation must support what it is attached to: when a chronology entry or report item is re-checked (before every export), an amount, a dated day or a name it states that the quoted words do not state, the opposite negation, or unrelated subject matter makes it unverified, with the reason. The quote being genuine is not enough.",
                "“Source dependence” in the inspector lists the other copies of the same document in the case (identical content, or one message thread with its forwards and replies) and every other record citing it. Copies and repeated references are one evidential origin — they are not independent corroboration."
            ],
            destination: .cases,
            keywords: ["provenance", "ocr", "recognized", "transcribed", "original text", "statement", "paraphrase", "summary", "quotation", "truncated",
                       "negation", "reported speech", "attribution", "qualifier", "copies", "duplicates", "corroboration", "independent", "occurrences", "dependence"]),
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
                "“Save search…” keeps the search in this case's encrypted ledger as a live search (it runs again on the case's documents as they are then) or as a frozen result (this result as it is). For a live search, “Check for new matches” lists what is new since you last looked, and “Mark as seen” starts counting from now. It never adds a document to the case.",
                "Amounts: amount:>=50000 finds an amount written with a currency (₹, Rs, INR, $, USD, €, £ …) of at least 50,000 in any currency; amount:INR>=50000 only in rupees; amount:1000..5000 a range; currency:USD any amount in dollars. A bare number is not an amount, amounts in words or lakh/crore are not read, and currencies are never converted. In the rules, choose “Amount (with currency)”.",
                "The same search also reads the case's own records — questions, chronology entries and notes, report points with their qualifications, tasks and actions, people, requests, contradictions, hypotheses and money movements — under “Case records”. It lists how many of each were searched and names the kinds of case data it does not read. Clauses about a file (its name, tag or dates) do not apply to a record.",
                "Above the counts, the scope lists the mother case, that no other case is read, what each date clause means and the limits of the run. Each result says what kind of match it is — exact text, a value the reader extracted (a recorded mention is not a verified identity) or a recorded field — where it sits (an attachment of, a member of), and its exact characters in the searched text. Documents with the same text are counted as repeated copies.",
                "While a search runs it shows how many documents it has searched. Cancel or a time limit leaves an incomplete result that says so; “Continue” searches the rest, and is refused if the case's documents were read again meanwhile. For a live saved search, tick “Re-run when the case changes”: it runs again when you open Search after the case's documents change and tells you once about new matches, with the version each was read from."
            ],
            notes: ["Matching: letter case and accents are ignored unless you tick “Match case” or “Match accents”; ligatures and full-width letters match their plain letters. A word is matched whole (invoice does not find invoices; invoic* does). Punctuation between the words of a phrase is ignored; exact: keeps it. Word endings, approximate and meaning-based matching are off. A run stops at its time limit or document limit and lists what it did not reach. The archive's Search (sidebar) is a separate, archive-wide search and works as before."],
            controls: ["Search case evidence", "Find on this map", "Search this case", "Add rule", "Add group", "Use these rules", "Search", "Use the repaired query",
                       "Match case", "Match accents", "Previous page", "Next page", "Open source", "Add to chronology…", "Select for report", "Save search…",
                       "Check for new matches", "Mark as seen", "Re-run when the case changes"],
            destination: .cases,
            keywords: ["amount", "currency", "money", "records", "resume", "continue", "progress", "copies", "attachment", "search", "find", "query", "boolean", "and", "or", "not", "near", "phrase", "exact", "wildcard", "date", "saved search", "receipt", "coverage", "not searched", "case search"]),
        HelpTopic(
            id: "concept-case-reasoning-time", kind: .concept, title: "Disagreement, alternatives and time in a case",
            summary: "How the case keeps who said what, how each piece of evidence relates to a question, how two accounts are compared, and when things happened — kept apart from when the case learned of them.",
            steps: [
                "Who said what: a statement is attributed to a speaker only when the words themselves say so (a speaker with “said”, “stated”, “denied” and the like, or “According to …”), or when you record the attribution with your reason. A name that only appears near the words is never made the speaker. Each attribution says whether it is firsthand, reported (and from whom) or not stated, and the time it applies to.",
                "Each evidence row of a question is one of: supports, challenges, mentions, qualifies (limits or conditions it) or linked with relevance not assessed. Only a verified supporting row counts as documentary support; a linked document is not support. Challenging and qualifying rows are kept beside the support as contrary material.",
                "Comparing two accounts shows both quoted passages with the words around them, the values, units and dates each states and the version each was read from. Notes beside the pair point out a denial, a quoted speaker, different definitions, different dates, different currencies or a correction — possible differences to check, never a decision.",
                "A contradiction can be confirmed, explained (a real difference, with the explanation), unresolved (examined, cannot be settled on the case material), dismissed with a reason, or deferred. Every decision is kept. An item the check no longer finds stays listed with its last decision. A new version of a document reopens an item only if the words it was decided on are no longer there.",
                "A follow-up raised from a contradiction is an action with the exact question, the result needed and both accounts as quoted. Its outcome may be that it supports one account, explains both, is inconclusive or could not be obtained.",
                "Copies and reports that share most of their wording are counted as one origin until you review them as independent. How many origins there are says nothing about whether any of them is true.",
                "Times have kinds — when it happened, was created, signed, collected, received, imported, assigned, done, submitted, reviewed, corrected or superseded — and a date keeps its precision, range or bound, time zone and wording. Where sources give different times, your interpretation is recorded with its reason and the times you chose between; they are kept as they were.",
                "The chronology in the report notes which entries cannot be put in order from their dates (for example two entries on the same day) and the time zone assumed for dates without one. The order of a list is not evidence of sequence."
            ],
            notes: ["Competing explanations are listed in the order they were recorded, with what is cited for and against each; nothing is counted, ranked or voted. In the hypothesis matrix a hypothesis is not shown as leading while its unrated cells could still change the result.",
                    "Each action keeps the name it was recorded under, this Mac's signed-in account (not an identity check), anyone reported as having done the work and the app part that did it automatically, and its place in this device's own recording order. Clock times are this Mac's clock and are not verified.",
                    "The integrity check is tamper-evident, not tamper-proof: it shows whether sealed records changed since they were sealed, using a key kept in this Mac's Keychain. It cannot show that what was recorded is true. A recorded state of the case map opened today withholds sources no longer in the case."],
            controls: [],
            destination: .cases,
            keywords: ["attribution", "speaker", "firsthand", "reported", "qualifies", "contrary", "contradiction", "explained", "unresolved", "follow-up", "inconclusive",
                       "copies", "derivative", "independent", "origin", "alternative", "hypothesis", "time", "date", "precision", "range", "time zone", "chronology",
                       "order", "interpretation", "audit", "tamper-evident", "device"]),
        HelpTopic(
            id: "concept-case-change-people", kind: .concept, title: "What changed, what rests on it, and the people in a case",
            summary: "How a change travels to the work that depends on it, how your own review of changes is kept apart from seeing them, and how people, their roles, profiles, statements and work histories are recorded without merging or blaming anyone.",
            steps: [
                "Each change in What changed has a kind — new material, an amendment or correction, the case's scope, a same-person decision, a link, an assignment or role, a review, access or the team, work, or an output. Moving cards, saved views and your briefs are presentation, not changes, and never appear there.",
                "“What rests on it” follows only real dependencies — evidence that supports, challenges or qualifies a question, records derived from a document or a report, results received for a request, work that depends on other work, items selected for the report and recorded derivations — to any depth, with the path that makes each item depend. A mention, a person a statement is attributed to, a same-person pairing, a money party, a time order or a placement is not followed: being next to something is not depending on it. Decisions stay as recorded; nothing is reversed.",
                "A summary, comparison, finding or output can record exactly what it was derived from. When one of those inputs changes, the item says which input changed and how — a newer source version, a changed review, changed wording, or an input that left the case.",
                "“Mark as seen” moves your own seen position only; it does not review or accept anything. A change that needs a look stays an obligation until someone acknowledges it with a note saying what they checked. Each person has their own seen position.",
                "A generated draft never replaces reviewed text. It is added as a new, unaccepted version beside the accepted one, and only if, at the moment it arrives, nobody wrote a newer version, the case's material is what it was produced from, the policy is unchanged, the person who asked is still on the team and the case is open. Otherwise it is refused and the refusal is kept. A person accepts a draft.",
                "Material or a result that arrives after a case is closed is queued, not added and not dropped. It can be declined with a reason, or admitted once the case has been reopened (reopening is its own recorded decision).",
                "A person is one record with every role they hold — witness, source of information, account holder, investigator, and so on — each with its context and period. “Subject” means the inquiry concerns them; no role implies wrongdoing. Adding someone already in the case through the same person in the documents adds a role instead of a second record.",
                "Every profile line says where it comes from: a cited source, who supplied it, your note, or unsourced. Notes on the old person card are shown as unsourced. A place a person was seen is always a past observation with its time, precision, basis and age — the app never shows where someone is now.",
                "An interview can hold its individual questions and responses with the recording time or transcript location. Once the statement is confirmed, a response changes only by a recorded correction: an addendum with the reason, and a new item that corrects the old one, which stays as it was confirmed.",
                "Two records that may be the same person are compared by a versioned rule that lists every reason they match or stay separate. A same name alone is never more than a weak candidate; nothing is merged — only your recorded same-person or different-people decision counts.",
                "Work is assigned to a named person; reassignment and handover on leaving the team keep who did what. Each person's work history lists assignments, work recorded, work reported as theirs, results submitted and reviews, each opening its record on the map. Capabilities are only those declared, and choosing who can take work lists every reason for and against, alphabetically — there are no scores."
            ],
            notes: ["Names here are names recorded on this Mac, not signed-in accounts: binding work to authenticated team accounts needs the team setup that is not part of this version.",
                    "A restricted profile withholds its attributes, observations and statement items from the profile and statement history and says how many were withheld; per-viewer restrictions for search, the map and exports need team accounts and are not part of this version.",
                    "Impact notifications are written again from the case's records when needed, so an interrupted run neither loses nor repeats them."],
            controls: ["Mark as seen", "What rests on it", "Show what changed…"],
            destination: .cases,
            keywords: ["change", "changed", "impact", "depends", "dependency", "stale", "derived", "seen", "acknowledge", "review", "refresh", "draft", "proposal",
                       "late", "closed", "reopen", "person", "people", "role", "witness", "source", "account holder", "investigator", "profile", "unsourced",
                       "location", "whereabouts", "interview", "question", "response", "correction", "same person", "match", "assignment", "reassign",
                       "work history", "capability", "conflict", "team", "restricted"]),
        HelpTopic(
            id: "concept-case-money-history", kind: .concept, title: "Money in a case, and earlier cases",
            summary: "How accounts, who holds them, statements and money records are kept exact and counted once, which figures the app shows and what it never concludes — and how another case can be compared or reviewed without its material leaking or being changed.",
            steps: [
                "An account is recorded once, with its number as written. Who holds, signs for, owns or controls it is a separate, dated record that says where it comes from. Holding or controlling an account does not by itself mean authorising a payment from it, or being liable for one.",
                "Every money record keeps the amount exactly as written, its exact value and how it was read: “2.5 lakh” is read as 2.5 × 1,00,000 and the basis is shown; “Rupees fifty thousand only” is read from the words. An amount the app cannot read without guessing stays unreadable and is in no figure. A bare “$” is never assumed to be US dollars.",
                "Only a classified movement — a payment, receipt, transfer, refund, reversal or fee — enters a figure. An invoice, claim, balance, reserve, quotation, allegation, estimate or asset is a mention of money and is never added to paid or lost. A classified record changes only by an amendment; the original stays, inspectable, and leaves the figures.",
                "One real payment recorded on a statement, in its copy and in a report is one transaction, every record kept. The same reference is the same payment; different references or days are different payments. Records that look alike but lack a day or reference are counted once and flagged, with what the figure would be if they were separate, until you confirm or split them.",
                "Gross paid, received, returned, fees, outstanding (invoices not settled) and disputed are separate figures, each opening the records it is made of. Net outflow is gross paid plus fees less returned; it is arithmetic, not a finding that anything was lost. A payment by a party that had received the money earlier is an onward hop, and a transfer between one holder's accounts is internal: both are shown, neither is added again. Parties are matched through the accounts' recorded holders.",
                "A statement reconciles only when its balances are recorded, every record of the account in its period is on it, and opening plus money in less money out equals the closing balance. Otherwise it says what is missing. Gaps between statements and months no statement covers become one proposed request each, however many copies of a statement there are.",
                "Currencies are never added together. A conversion needs a recorded rate with its source, date and method, is shown beside the original figures, and says it is partial when a currency has no rate.",
                "Other cases can be looked at only through the case's history set: each other case, collection or configured external source is added with a purpose and a scope. What an AI remembers is not a source. Identifiers you choose (account numbers, references, phones, emails) are looked for in other cases as whole tokens; a pattern or a same-name match is only a candidate.",
                "A reference to another case's record names that case, the record and whether it follows the record or is pinned to a recorded state. It keeps no copy: it is read again each time under today's access, and becomes unavailable when access is withdrawn, the case is erased or its source is labelled privileged. A link from this case's map to another case's record is still refused.",
                "A review case examines another investigation's records, actions and decisions and keeps its own findings, chronology and authorship. Reviewing never changes the original case. A pinned reference shows only what the other case had recorded then; later material is not shown as known. Each finding traces to the original record and its decision, and the original lists the reviews that refer to it.",
                "Comparing two cases shows shared exact identifiers, names that appear in both (candidates only), when their money records fall and what kinds they are, and the limits of the comparison. It records nothing: similarity is not a common cause and a same name is not the same person."
            ],
            notes: [CaseCrossCaseAccess.scopeNote,
                    "Statement rows are read from a table whose header names a date and a debit/credit column; only days written as yyyy-mm-dd become days, any other date stays as written.",
                    "Fund flow sets aside an amount whose own words say it is an invoice total, a balance or an estimate, and leaves a negative-only amount unassigned; it can only see the words the extractor kept.",
                    "Who may see another case is decided on this Mac by whoever adds it to the history set; per-person access for teams is not part of this version."],
            controls: [],
            destination: .cases,
            keywords: ["money", "account", "holder", "signatory", "owner", "beneficial owner", "control", "statement", "reconcile", "transaction", "duplicate",
                       "same payment", "split", "confirm", "refund", "reversal", "fee", "outstanding", "disputed", "net", "loss", "currency", "conversion",
                       "exchange rate", "lakh", "crore", "words", "amendment", "gap", "missing statement", "prior case", "history", "review", "cross-case",
                       "reference", "overlap", "identifier", "pattern", "compare", "privileged", "known at the time"]),
        HelpTopic(
            id: "concept-case-actions-automation", kind: .concept, title: "Actions, results and case automation",
            summary: "How work in a case is planned, assigned, done, reviewed and reopened — and what the case's automation may do by itself, within its policy and budgets, without ever being permission to send anything to an AI.",
            steps: [
                "An action belongs to the case and says what it is for: its type (an interview, a reconciliation, an identity check…), the question or point it serves, its parent action, what started it (the records and the exact document versions), the result expected, who does it, who helps and who reviews. A task with none of that is listed as untraceable.",
                "Templates give an editable draft for each kind of work. A template's “in 14 days” is a proposed target, never a deadline. A date you set says what it is: your own target, a reminder, or an external deadline — which needs the notice, rule or order that sets it — with its time zone. Applying a case template twice adds nothing the second time.",
                "Work moves through assigned, in progress, waiting and blocked (each with a reason, and for waiting or blocked what would unblock it), and ends completed, cancelled or superseded by another action that is named. An action that waits for other work cannot be completed until that work is finished. Completing work never answers its question: the question keeps its own decision.",
                "Routing picks an owner by rule and says why: the designated person, otherwise an eligible person with the least open work (alphabetical on a tie), otherwise — in a case with no team — the case owner. Nobody eligible means the action goes to the unassigned list with what to do. An assignment you make yourself is kept until you release it, or until the person leaves the team, has a conflict recorded or is unavailable. Changes to several actions at once report a result for each.",
                "A result names what was examined and says whether the work succeeded, partly succeeded, was unsuccessful or was inconclusive. It is returned to every question and point the action serves and to its parent. A review accepts or returns one exact revision; a new revision after acceptance needs review again. Results are never edited — a new revision is recorded.",
                "A parent action shows how many children are blocked, waiting, unassigned, unresolved or waiting for review, and each child's outcome as recorded — nothing is averaged. Optional children never hold the parent; it closes when every required child is finished or has a recorded exception.",
                "Working alone, you hold every role and your review of your own work is recorded as self-review. If the case's policy requires independent review, that stays shown as unmet until another reviewer is recorded.",
                "When a document that finished work examined gets a newer version, one proposal appears to reopen the work, supersede it with new work, or dismiss it with a reason. The same unchanged issue is never proposed twice.",
                "Case automation has three modes: Manual (nothing runs by itself; queued work waits), Suggestions (rules propose actions you accept) and Configured execution (allowed rules create and route actions). The mode is not AI permission: changing either one never changes the other. Each policy is a new version; every automatic run records its recipe and policy versions, the document versions it used and what it was allowed to do.",
                "Automatic work is queued with the change that caused it and survives a crash: an interrupted run is resumed and finds what it already made. The same work is never created twice for an unchanged reason, cosmetic changes (layout, views) start nothing, and work caused by automation needs a genuinely new condition. Budgets limit new actions, compute, AI spending and external requests; a budget stop leaves the work held with the reason, to resume.",
                "Just before acting, automation checks again that the case is open, the person who started it is still on the team, its documents are still the current versions, no one's data was erased since, the policy still allows it and — for anything that would send content to an AI — that the case's AI permission is in force. Otherwise the work is refused with the reason. Failed work says whether retrying can help; you can retry or cancel it.",
                "Letters, emails and disclosures go only to recipients you configured for that channel, and the same message is prepared once. A hand-over whose outcome is unknown must be confirmed (sent or not) before it can be handed over again. Assigning an interview never contacts the witness. Undoing an automatic run cancels what nobody has worked on yet and keeps the record; work a person did and anything handed over stay, and the undo record says so."
            ],
            notes: ["Team members are names recorded on this Mac, not signed-in accounts; routing between separate people's devices needs the team service, which this version does not have.",
                    "Nothing here uses AI: rules and recipes are deterministic and work with AI off."],
            controls: [],
            destination: .cases,
            keywords: ["action", "task", "child action", "mother case", "template", "target", "deadline", "reminder", "external deadline", "assign", "routing",
                       "unassigned", "reassign", "delegate", "defer", "bulk", "waiting", "blocked", "superseded", "result", "revision", "review", "self-review",
                       "solo", "parent", "rollup", "exception", "reopen", "automation", "policy", "manual", "suggestions", "execute", "outbox", "budget",
                       "retry", "cancel", "recipient", "disclosure", "undo", "compensation"]),
        HelpTopic(
            id: "concept-case-roles-access", kind: .concept, title: "Who may do what in a case: roles, access and erasure",
            summary: "A case worked alone needs no setup: you hold every role. When you give someone a role, the case becomes a team case and every change and every look at it is checked against the roles recorded — by the app's services, not only by hiding buttons.",
            steps: [
                "Working alone, nothing changes: you hold every role (owner, investigator, reviewer) and the names on changes are only who did them.",
                "Giving a person a role makes the case a team case and makes you its owner. Roles are per case: a role in one case gives nothing in another. One person may hold several roles.",
                "Owner: everything, including who may do what, the case's policies, holds, closing, reopening and erasing. Investigator: opens the case, records and changes work and records, returns material and exports. Reviewer: opens the case and reviews, accepts, returns or decides, but does not change the work. Contributor: returns requested material and sees only the requests shared with them — not the case list, its titles, counts or anything else. Viewer: reads and changes nothing.",
                "Every change is checked at the moment it is saved, against the roles recorded then. A change refused says who may not do what, why, and who can fix it. A change cannot be recorded in someone else's name.",
                "No one can give themselves a role, and the case's last owner cannot be removed. Removing a person's role takes effect at once — for their next change, their next look at the case and any automatic work they started. If they still hold open work, choose who takes it over; what they recorded keeps their name.",
                "An export, a print or a copy is checked again just before it leaves: if the person's role was removed, or the case erased, after it was prepared, nothing leaves and the refusal is recorded.",
                "Every role given or removed is kept in the case's access history: who gave which role to whom, when and why, and who removed it.",
                "Erasing a case or a person records an erasure generation. The tags, groups, notes and other synchronised items it removed leave a tombstone that holds only identifiers, so another device's copy cannot bring them back, and a late change to the erased case is refused.",
                "Notifications never show case content: a reminder or an answer notice says only that something is due or new."
            ],
            notes: ["People are names recorded on this Mac, not signed-in accounts: anyone using this Mac account can act as this Mac's owner. Signing in, invitations and sharing a case between separate people's devices need the team service (planned on Apple's CloudKit), which this version does not have.",
                    "Erasure cannot reach copies already exported, backups kept elsewhere, or another person's device."],
            controls: [],
            destination: .cases,
            keywords: ["role", "roles", "access", "permission", "owner", "investigator", "reviewer", "contributor", "viewer", "team", "solo", "grant",
                       "remove", "revoke", "transfer", "departure", "access history", "audit", "erasure", "tombstone", "generation", "notification", "privacy",
                       "export", "refused"]),
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
                "The ledger is encrypted (SQLCipher, AES-256) with a key in this Mac’s Keychain. Copies of your original files are kept by default (Settings ▸ Optional ingest ▸ Managed evidence copies) so a citation always opens the exact version it cites; new copies are encrypted with a key derived from the ledger key. Copies kept by older versions of the app, the temporary copy opened for viewing, and your own files rely on FileVault — turn FileVault on.",
                "Settings ▸ Your data ▸ “Complete backup”: the ledger and every original, each with its SHA-256. Keep the recovery key shown there; a backup cannot be opened without it. Restore checks integrity and refuses a backup made by a newer version.",
                "Erase a case, a person or everything: the app either completes the erasure and verifies it empty, or refuses and says why. A legal hold, a draft, or a document that another case still needs blocks the erasure until released.",
                "Ask keeps each case's questions with that case: erasing a case also removes the questions asked in it and every answer given there, including answers it could not give and answers quoting documents other cases share. Questions asked across the whole library or in another case are kept.",
                "Backups you made still hold what you erased later — delete or overwrite them yourself. Restoring one does not bring the erasure back undone: the app keeps a small erasure register beside the ledger (identifiers only, never names or content), erases again any case or person that comes back with the backup, and refuses a backup made before you erased everything.",
                "Case reminders never show a task or case title, only that a case task is due; erasing a case removes its reminders, and erasing a person or everything removes any reminder an older version wrote with titles.",
                "Not reached by erasure: your original files outside the app, the backup files themselves, exports, sync folders and Spotlight entries — delete those yourself."
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
        case .placedIn: return "You placed this item in that branch with Place in frame. The item is stored once; the same record appears in every branch it is placed in, and withdrawing the placement keeps its history."
        case .moneyFrom: return "The money movement names this person or organisation as the payer, as the documents record it. It is what a document states — not a verified payment and not proof of wrongdoing."
        case .moneyTo: return "The money movement names this person or organisation as the payee, as the documents record it. Amounts stay in their own currency and are never added across currencies."
        case .qualifies: return "The item limits or conditions the one the arrow points to — an exception, a condition or a narrower reading. It is contrary material kept beside the support, not support."
        case .relevanceUnassessed: return "An evidence row is linked to the question, but nobody has said whether it supports, challenges, mentions or qualifies it. A link alone is not support."
        case .accountRelation: return "The account is recorded as held, signed for, owned or controlled by this person or organisation, with the period and where that comes from. A relationship to an account does not by itself mean authorising any payment from it, or being liable for one."
        case .samePersonDecided: return "You recorded that these two rows are the same person, with your reason. The rows are not merged — each keeps its statements, links and history — and withdrawing the decision puts the pair back to pending."
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
        case .explained: return "Explained: the reviewer recorded why the two accounts differ without contradicting each other (for example two separate payments). Both accounts are kept."
        case .unresolved: return "Unresolved: the reviewer examined it and it cannot be settled on what is in the case. It stays an open conflict, with the reason."
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
        HelpTopic(id: "trouble-unread-protected", kind: .troubleshooting,
                  title: "A document was not read, has pages with no text, or needs a password",
                  summary: "“Where this came from” in the source inspector shows how a passage reached the case (the email it was attached to, the archive path it came from, the file you supplied), how each page was read, and whether the original is protected. No text on a page is never proof that the page holds nothing.",
                  steps: [
                    "Open the passage or document in the source inspector and read “Where this came from”: each line runs from the document up to the file that was actually received, with the date it was received.",
                    "Pages listed as “No text found” or “Recognised from an image” may hold material the text does not show. Choose “Re-read this document” to read the exact original again with the current reader, or “Open the original” to look at the page yourself.",
                    "“Needs a password”: choose “Enter password”, type it and choose “Open”. A readable copy is added, linked to the original, which is kept unchanged. The password is used once and is not saved or logged.",
                    "“Wrong password” lets you try again. “Protected in a way the app cannot open” (for example a password-protected Word file or an encrypted ZIP), “Damaged” and “Locked by the file system” each say what to do instead; the original is kept in every case."
                  ],
                  notes: ["A copy made from an original (an opened PDF, a converted image) shows “A copy made from …” with how it was made; the original shows its copies. Neither replaces the other."],
                  controls: ["Re-read this document", "Open the original", "Enter password", "Open"],
                  keywords: ["password", "protected", "encrypted", "locked", "OCR", "scanned", "blank page", "no text", "provenance", "attachment", "archive", "where did this come from", "copy", "converted"]),
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
