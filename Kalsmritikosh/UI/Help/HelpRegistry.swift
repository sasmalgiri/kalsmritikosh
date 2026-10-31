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
        [getStarted] + tasks + personaRecipes + screens + concepts + safety + subscription + troubleshooting

    private static let byID: [String: HelpTopic] = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

    // MARK: - Get started

    /// §6.5 — the short offline Get started guide, with the exact current control names.
    public static let getStarted = HelpTopic(
        id: "get-started", kind: .getStarted, title: "Get started: from documents to an exported report",
        summary: "Ten steps that take a folder of documents to a cited, reviewed, exported report. Each step names the exact control. The isolated sample case (Help ▸ Replay the tutorial) walks the same path on bundled documents.",
        steps: [
            "Add documents. Open Sources and press “Add Folder…”. Files are read where they are; nothing is moved or copied. Supported: PDF, Word (DOCX), text and Markdown, RTF, ODT, EPUB, Excel (XLSX), CSV, ODS, PowerPoint (PPTX), email (EML, EMLX, MBOX), HTML, images and scans (PNG, JPG, HEIC, TIFF, WebP — read by OCR), audio and video (transcribed on your Mac while importing while “Transcribe audio & video” is on in Settings ▸ Modules, which it is by default), and ZIP archives. Older Office formats (DOC, XLS, PPT), Outlook stores (MSG, PST), RAR and 7z are kept but not read. The indicator reads “Ready” when every file has been processed; a count “could not be read — see Needs attention” lists the files that failed and why.",
            "Start a matter. Open Professional Jobs, choose your profession, and press “Start matter”. Name the matter and choose its workspace.",
            "Bring documents into the case. Press “Add documents to this case” (or “Review new documents” when the matter already holds its workspace’s documents). The preview shows how many documents are in scope now, how many are new, and how many stay excluded — nothing is included until you confirm. Jobs and answers read only the documents in the case’s scope.",
            "Run the first job. Each job card says what it needs and what it produces; press “Run”. A job that cannot run says why and what to do (for example, no documents in scope yet).",
            "Ask a question. Open Ask, type the question and press “Send question”. The answer is built only from the documents in scope; each claim carries a citation, and a question the documents do not answer is said to be unanswered rather than guessed.",
            "Open the exact citation. Press the numbered citation chip under an answer (or “Open source” on a result row, “Open at this passage” under a closest-passage note) to open the original document with the cited passage highlighted. Read it: the quotation is checked against the document, but the document itself can be wrong, out of date or one side of a dispute.",
            "Review the result. Press “Open result” on the job card; decide each row (Accepted / Rejected), or “Accept shown” / “Reject shown” where the job allows one decision over the rows shown, add a note, then “Save review”; “Mark completed” closes the review once every row is decided. Unreviewed rows are marked as such wherever they are carried.",
            "Choose what goes in the report. Press “Include in report” on a reviewed row (or “Exclude from report (reason = your note)”). Rows can also go to the case with “Add to case…” or “Add to chronology”.",
            "Export. In the case file’s “Log & exports” section press “Case file report…” and choose where to save it. The report is checked once more against the current evidence as it is written, protected identities are kept out, and the export is recorded in the case log with its digest (the notice under the button says so). Reopen the exported file to confirm what the reader will see.",
            "Make a complete backup and keep the recovery key. Settings ▸ Your data: “Complete backup” writes the ledger and every original with its SHA-256; the recovery key shown there unlocks the backup on another Mac. Without the key an encrypted backup cannot be opened by anyone, including us."
        ],
        notes: [
            "Private mode is the default: the app opens no connection for your documents. Online AI is optional, uses your own provider account (which may charge you), shows every send before it leaves, and is never switched on by subscribing.",
            "Before a subscription, and after one ends, every case stays readable and exports, backups, recovery, Help and the privacy controls keep working; only creating, editing and analysing wait for a subscription."
        ],
        controls: ["Add Folder…", "Ready", "Start matter", "Add documents to this case", "Review new documents", "Run", "Send question", "Open source", "Open at this passage", "Open result", "Accept shown", "Reject shown", "Save review", "Mark completed", "Include in report", "Exclude from report (reason = your note)", "Add to case…", "Add to chronology", "Case file report…", "Complete backup"],
        destination: .work,
        keywords: ["quick start", "first steps", "tutorial", "beginner", "how to begin"]
    )

    // MARK: - Tasks (§6.6)

    public static let tasks: [HelpTopic] = [
        HelpTopic(
            id: "task-import-failures", kind: .task, title: "A file could not be read, a scan has no text, or a recording was not transcribed",
            summary: "Every file ends in one recorded state: read, kept but not read, or failed with a reason. Nothing is silently skipped and nothing is invented for an unreadable file.",
            steps: [
                "Open Sources. The indicator reads “Ready” when the folder is fully processed; a line “could not be read — see Needs attention” counts the failures.",
                "Open Needs attention for the file’s reason: corrupt or password-protected file, an unsupported format (DOC, XLS, PPT, MSG, PST, RAR, 7z are kept but not read), a scan with too little text for OCR, or a recording that could not be transcribed.",
                "Scans: OCR quality follows scan quality. Tools ▸ Documents ▸ Improved text recognition lists weak scans and can save a searchable copy.",
                "Recordings: with “Transcribe audio & video” on (Settings ▸ Modules, the default) recordings are transcribed on your Mac while importing (Apple Speech, English). With it off, recordings are catalogued and kept, and can be transcribed on demand in Transcripts. Transcripts are evidence of what the speech model heard, not a certified transcript.",
                "Fix the file (open it in its own app and re-save, remove the password, re-scan) and press “Ingest All”, or leave it: a failed file stays listed as failed so the gap is visible in the case."
            ],
            controls: ["Ready", "Ingest All", "Transcribe audio & video"], destination: .sources,
            keywords: ["ocr", "transcription", "unreadable", "password", "corrupt", "needs attention", "failed"]),
        HelpTopic(
            id: "task-search-and-refusals", kind: .task, title: "Search, ask, and understand an honest refusal",
            summary: "Search finds passages; Ask builds a cited answer from the documents in scope. When the documents do not support an answer the app says so instead of guessing.",
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
                "Credibility notes (“Add credibility note”) are your assessment and are recorded as such, separate from the evidence."
            ],
            controls: ["Plan interview", "Record confirmation", "Export statement for signature…", "Add credibility note"], destination: .cases,
            keywords: ["interview", "statement", "witness", "speaker", "attribution"]),
        HelpTopic(
            id: "task-chronology-and-hypotheses", kind: .task, title: "Build a chronology and weigh alternative explanations",
            summary: "Timeline orders every dated fact; Findings shows the chronology by status; Competing Hypotheses ranks explanations by how much evidence is inconsistent with each.",
            steps: [
                "Timeline: filter by date, entity or event kind; open an event for its participants and source. Date precision travels with the event (a month-only date is shown as such).",
                "From a job result, “Add to chronology” carries a reviewed row, with its citations and review state, into the case chronology.",
                "Competing Hypotheses: list the explanations, mark each piece of evidence consistent, inconsistent or not assessed. The matrix prefers the hypothesis with the fewest inconsistencies and says when there is no preference; “not assessed” is never counted as neutral support.",
                "A gap in the timeline is a gap in the record, not proof that nothing happened; it tells you what to collect next."
            ],
            controls: ["Add to chronology"], destination: .timeline, keywords: ["ach", "hypotheses", "timeline", "chronology", "alternative explanation"]),
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
            id: "task-private-online", kind: .task, title: "Private and Online modes, and what a provider may charge",
            summary: "Private (the default) opens no connection for your documents. Online is optional and uses your own AI-provider account.",
            steps: [
                "Settings ▸ Modules ▸ Connection switches Online on with your own Claude, OpenAI or Gemini key. A badge shows while it is on; one click returns to Private.",
                "Before anything is sent you see exactly what will go, its size and destination, and must approve it. Document text goes only to providers whose terms you have confirmed; privileged or restricted passages are refused; protected identities are masked.",
                "Each send is recorded before it leaves. Providers may retain what they receive under their own terms, and they bill your account — the subscription to this app includes no provider usage.",
                "Subscribing never turns Online on. The test host and the sample case never send anything."
            ],
            destination: .settings, keywords: ["cloud", "api key", "claude", "openai", "gemini", "network", "consent"]),
        HelpTopic(
            id: "task-keys-backup-erase", kind: .task, title: "Encryption, backup, recovery key, erasure and holds",
            summary: "The ledger is encrypted on this Mac; a complete backup carries everything with a recovery key; erasure is complete or refused, and a hold you created blocks it.",
            steps: [
                "The ledger is encrypted (SQLCipher, AES-256) with a key in this Mac’s Keychain. Original files in the vault rely on FileVault for encryption at rest — turn FileVault on.",
                "Settings ▸ Your data ▸ “Complete backup”: the ledger and every original, each with its SHA-256. Keep the recovery key shown there; a backup cannot be opened without it. Restore checks integrity and refuses a backup made by a newer version.",
                "Erase a case, a person or everything: the app either completes the erasure and verifies it empty, or refuses and says why. A legal hold, a draft, or a document that another case still needs blocks the erasure until released.",
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
            (.settings, "Settings — modes, privacy, data and subscription", "System mode, Private/Online, modules, ingest options, Your data (backup, recovery key, erasure), Help & feedback, legal notices and the subscription."),
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
                  summary: "One edition with all nine personas (the professions listed under “By profession”), as a monthly or annual subscription. Prices and periods are shown by the App Store for your country; the app never shows a made-up price.",
                  steps: [
                    "A 14-day free introductory trial is offered when Apple finds your account eligible (one per account). The subscription screen shows the price that follows the trial and when it will be charged.",
                    "The subscription renews automatically unless cancelled at least a day before the period ends. Cancel in your Apple Account (Help ▸ Manage subscription, or the “Manage subscription” link on the subscription screen); Apple’s instructions are linked there.",
                    "Monthly and annual give the same access. Switching plan takes effect at the next renewal; Apple shows the details.",
                    "Payment, renewal, refunds and restore are handled by Apple. The app opens no connection for them and never sees your payment details. Subscribing does not turn on Online mode."
                  ],
                  controls: ["Manage subscription", "Restore purchases"], destination: .settings,
                  keywords: ["price", "trial", "renew", "cancel", "monthly", "annual", "apple account"]),
        HelpTopic(id: "subscription-restore-offline", kind: .subscription, title: "Restore purchases, another Mac, and being offline",
                  summary: "Your subscription follows your Apple account; your archive does not.",
                  steps: [
                    "On a new Mac, or after reinstalling, press “Restore purchases” (subscription screen or Settings ▸ Subscription). The App Store confirms what your account holds.",
                    "Offline, the last verified state is kept until its own verified end (for example the end of the paid period). The app never extends access beyond what was verified and never removes still-valid access because the store could not be reached.",
                    "The permanent unlock bought under the earlier plan is honoured for good and is never asked to subscribe. The earlier free 14-day product is a trial, not consent to billing.",
                    "Your documents and the ledger stay on this Mac. Move them with a complete backup and the recovery key (Settings ▸ Your data)."
                  ],
                  controls: ["Restore purchases", "Complete backup"], destination: .settings, keywords: ["restore", "offline", "new mac", "reinstall", "legacy", "unlock"]),
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
