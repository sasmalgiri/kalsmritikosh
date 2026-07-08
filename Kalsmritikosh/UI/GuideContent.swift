//
//  GuideContent.swift
//  Kalsmritikosh
//
//  User-facing guidance copy in one place — the Swift counterpart of
//  ReCreateHistory's guide.ts, so both products show the same options and
//  wording: the 5 home-screen personas, the per-screen guides, and the
//  epistemic-status glossary. Editing copy = editing this file.
//

import Foundation

/// A home-screen persona card — a use-case lens with example questions and the
/// screens that matter most for it.
struct GuidePersona: Identifiable, Sendable {
    let id: String
    let emoji: String
    let title: String
    let tagline: String
    let examples: [String]
    /// The destinations most useful for this persona + why.
    let keyScreens: [(dest: Destination, label: String, why: String)]
    let tips: [String]
}

enum GuideContent {
    static let personas: [GuidePersona] = [
        GuidePersona(
            id: "legal", emoji: "⚖️", title: "For Lawyers",
            tagline: "Build a defensible case chronology — every event linked to its source, every conflict preserved.",
            examples: [
                "Reconstruct the timeline of the contract between the parties",
                "What evidence shows when payment was due and when it was made?",
                "Which facts are contradicted across the documents?",
                "What obligations appear in the documents and is there proof they were fulfilled?"
            ],
            keyScreens: [
                (.findings, "Findings", "the case chronology by status, with review controls"),
                (.timeline, "Timeline", "filter events by date, entity, or kind"),
                (.assertions, "Assertions", "record your own claims with confidence levels")
            ],
            tips: [
                "An event marked “observed” came from a structured source (an email header, a timestamp). “Inferred” means indirect evidence only — treat it as a lead, not a fact.",
                "The report never asserts beyond the evidence; “Missing Proof” lists exactly what would strengthen the case."
            ]
        ),
        GuidePersona(
            id: "investigation", emoji: "🔍", title: "For Investigators",
            tagline: "Who knew what, and when — connections, corroboration, and the gaps in the record.",
            examples: [
                "Who communicated with whom, and when did each exchange happen?",
                "What is the full timeline of events involving [person or company]?",
                "Which events rest on a single source with no corroboration?",
                "What happened in the weeks before [event]?"
            ],
            keyScreens: [
                (.dossier, "Dossier", "the complete profile of any person or organization"),
                (.explore, "Explore", "the connection graph between entities"),
                (.findings, "Findings", "proof status, contradictions, and evidence gaps")
            ],
            tips: [
                "Corroboration counts matter: “2 sources” means two independent documents state the same fact.",
                "Timeline gaps (months with no evidence) often point to what to collect next."
            ]
        ),
        GuidePersona(
            id: "journalism", emoji: "📰", title: "For Journalists",
            tagline: "Verify claims across a document dump — what is supported, what conflicts, what is missing.",
            examples: [
                "What claims do the documents make about [topic], and who asserted each?",
                "Which statements are corroborated by more than one source?",
                "Where do the sources contradict each other?",
                "What is the chronology of decisions described in these documents?"
            ],
            keyScreens: [
                (.findings, "Findings", "claims, contradictions, and missing evidence in one place"),
                (.search, "Search", "exact-phrase and semantic search across everything"),
                (.saved, "Saved", "bookmark the questions you will re-run as new documents arrive")
            ],
            tips: [
                "Answers never invent facts: if the documents don’t say it, the answer says so.",
                "Re-ask saved questions after each new ingest — answers update as evidence grows."
            ]
        ),
        GuidePersona(
            id: "research", emoji: "🏺", title: "For Researchers",
            tagline: "Reconstruct past periods from archives — with honest uncertainty, not false precision.",
            examples: [
                "What is the chronological sequence of events described in the corpus?",
                "Which dates are uncertain or only approximately known?",
                "What sources mention [entity or place], and what do they say?",
                "Summarize what is known versus what is inferred about [topic]"
            ],
            keyScreens: [
                (.timeline, "Timeline", "date-precision-aware event view"),
                (.library, "Library", "browse documents, summaries, and distilled memories"),
                (.knowledge, "Knowledge", "corpus-wide statistics and entity breakdowns")
            ],
            tips: [
                "Date precision travels with every event — “derived” status means computed from stated facts.",
                "The Completeness screen shows how much of your corpus is actually indexed and searchable."
            ]
        ),
        GuidePersona(
            id: "general", emoji: "🧠", title: "For Everyone",
            tagline: "Your private, searchable memory — ask anything about your own documents.",
            examples: [
                "What did I agree to in my rental contract?",
                "When did I last correspond with [person] and about what?",
                "Summarize everything about [project or topic]",
                "What deadlines or amounts appear in my documents?"
            ],
            keyScreens: [
                (.ask, "Ask", "the fastest way to an answer"),
                (.search, "Search", "keyword and meaning-based lookup"),
                (.sources, "Sources", "manage what’s ingested")
            ],
            tips: [
                "The answer card shows its classification — “Proven by direct evidence” means exactly that.",
                "Open Findings to see every fact by status — proven, inferred, contradicted, or missing."
            ]
        )
    ]

    /// Per-screen one-paragraph explainers (the Guide screen + info popovers).
    static let screenGuides: [(dest: Destination, title: String, body: String)] = [
        (.ask, "Ask — cited answers from your evidence",
         "Type a question in plain language. The answer is built only from your ingested sources: every claim cites its evidence, the badge shows how strongly it is established, and anything your sources don’t cover is listed as a gap instead of being guessed."),
        (.findings, "Findings — every fact by status",
         "Four tabs: Timeline (events labelled by how they are known, with accept/reject review), Evidence (extracted claims with citations), Contradictions (where sources disagree — both sides kept), and Missing Proof (what the record does not establish)."),
        (.history, "History — the evidence-backed narrative",
         "A readable reconstruction of what happened, composed from the dated events in your ledger, with every claim traceable to its source."),
        (.sources, "Sources — what the ledger knows",
         "Add folders and files here. Text extracts directly from PDF, Word, Excel/CSV, PowerPoint, EPUB, email (EML/MBOX), HTML, Markdown, text, and ZIP; images/scans are read by OCR and audio is transcribed on-device. Every file is hashed, parsed into cited evidence, and indexed; duplicates are detected. Anything unreadable is recorded honestly — never faked."),
        (.timeline, "Timeline — your documents as dated events",
         "Every dated fact extracted from your sources, in order. Filter by date range, entity, or event kind. Open an event to see its participants, source document, and causal links."),
        (.search, "Search — exact or by meaning",
         "Keyword mode finds exact terms, names, and numbers. Semantic mode finds passages that mean the same thing even with different words (needs an embedding model)."),
        (.explore, "Explore — the connection graph",
         "Pick a person or organization and see who and what it is connected to. Select any node to re-center on it."),
        (.dossier, "Dossier — everything about one entity",
         "Search for a person or organization to get its full profile: timeline of events, relationships, aliases, distilled memory, and when it first and last appears in your sources."),
        (.insights, "Insights — gaps, contradictions and patterns",
         "Auto-surfaced signals the ledger found: missing-evidence gaps, conflicts between sources, and recurring patterns worth a look."),
        (.knowledge, "Knowledge — the structured base",
         "Canonical people, organizations, projects, events, and distilled memory, with corpus-wide counts."),
        (.assertions, "Assertions — claims with their evidence",
         "Extracted subject-predicate-object claims, each carrying the specific evidence that backs it."),
        (.library, "Library — every document you’ve ingested",
         "Browse the source files, their summaries, and distilled memories."),
        (.completeness, "Completeness — how fully your archive is processed",
         "How much of your corpus is parsed, indexed, and searchable, with what remains."),
        (.convert, "Convert — files between formats",
         "Read PDF/Office/images/audio and write txt, md, json, html, csv, pdf, rtf, docx, xlsx, png.")
    ]

    /// Glossary of the epistemic statuses (hover / info tips).
    static let glossary: [(term: String, definition: String)] = [
        ("Observed", "Directly visible in a structured source — an email header, a log entry, a timestamp. Highest trust."),
        ("Asserted", "Stated in a document’s text with an explicit date. True that it was said; the statement itself may still be wrong."),
        ("Derived", "Computed deterministically from stated facts (e.g. invoice date + 30-day term)."),
        ("Inferred", "Reconstructed from indirect evidence only (e.g. a file’s modification time). A lead, not a fact."),
        ("Contradicted", "Another source states a conflicting version. Both sides are preserved — check Contradictions."),
        ("Corroborated", "The same fact appears in two or more independent source documents."),
        ("Confidence", "How strongly the evidence supports this item, from 0 to 100%. Calibrated, not a guess."),
        ("Citation", "The exact source (file, page, row) a statement came from. Open it to verify."),
        ("Missing Proof", "Evidence that would be needed to establish a claim but is absent from your sources.")
    ]
}
