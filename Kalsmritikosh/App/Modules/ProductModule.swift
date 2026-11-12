//
//  ProductModule.swift
//  Kalsmritikosh
//
//  W0-M — the PRODUCT MODULE MATRIX (owner request 2026-10-15: "implement it as
//  module matrix so it will be easy on and off"). Every switchable feature of the
//  beat-DEVONthink plan (docs/BEAT_DEVONTHINK_FINAL_TODO.md) is one case here, with
//  its plan ID, its own persisted switch, declared dependencies and gates.
//
//  It sits beside KnowledgeModule (ledger/answer internals) rather than inside it:
//  product features span UI, routing and export, and KnowledgeModule's exhaustive
//  switches are pinned by tests. Settings ▸ Modules lists both.
//
//  Rules (mirroring KnowledgeModule and mailin's activation matrix):
//   * A module whose code has not landed is never on, whatever is stored.
//   * New and unproven defaults OFF — installing an update must not change how an
//     archive behaves; the owner promotes a module by flipping `defaultEnabled`.
//   * Off means dormant, never destructive — `whenOff` says what survives.
//   * Dependencies and gates are declared, and a greyed switch names the reason.
//   * Online modules run only in Online mode AND when this build bundles the
//     network helper (see ConnectivityMode); the main app never gains network.
//   * Some guarantees are deliberately NOT switchable (see `ModuleInvariant`).
//

import Foundation

nonisolated public enum ProductModule: String, CaseIterable, Sendable, Identifiable {
    // Wave 1 — table stakes
    case advancedSearchSyntax, searchCoverageBadge, signedReceipts, userTags, deepLinks,
         shortcutsActions, commandPalette, ledgerRelocation, importQueue
    // Wave I — innovation
    case proofBundles, gapMap, corroborationMeter, devilsAdvocate, timeTravel,
         liveFactCheck, archiveSelfScore, leastDataOnline, statementDrift, caseSlices,
         answerPath, livingDossiers
    // Wave 2 — evidence depth
    case annotations, emailAuthenticity, specPSTReader, nearDuplicates, legalProduction,
         exportFormats, appLock, byteRangeItems
    // Wave 3 — beat DEVONthink by a mile
    case devonthinkImport, sendToDevonthink, timelineGraph, proactiveAlerts,
         smartCollections, captureExtensions, spotlightIndex
    // Wave N — market gaps
    case issueChronology, communicationAnalysis, watchlists, reviewCoding, studioOutputs,
         menuBarAsk, imageIntelligence, locationMap, notesImport, onlinePIIMasking,
         questionMonitors, customEntityTypes, riskScore
    // Wave 4 — breadth
    case ocrUpgrade, extraParsers, mailRecovery, teamReview
    // Wave O — online
    case onlineAnswers
    // Wave P — using the app on its own
    case writtenNotes
    // Wave X — the last DEVONthink gaps, offline (docs/PARITY_SIX_TODO.md)
    case userGroups, filingSuggestions, richDocuments, folderSync
    // Investigation focus (docs/INVESTIGATION_FOCUS_TODO.md A5)
    case contentCreatorPersona

    public var id: String { rawValue }

    /// Companion positioning (owner decision 2026-10-15): Kalsmritikosh works beside DEVONthink —
    /// it fills DEVONthink's gaps and adds its own evidence features. Modules whose feature
    /// DEVONthink already has stay OFF until the person turns them on, and no role preset
    /// switches them on.
    public static let alsoInDevonthinkSet: Set<ProductModule> = [
        .advancedSearchSyntax, .userTags, .deepLinks, .shortcutsActions, .ledgerRelocation,
        .annotations, .exportFormats, .appLock, .smartCollections, .captureExtensions,
        .spotlightIndex, .timelineGraph, .notesImport, .menuBarAsk, .customEntityTypes,
        .ocrUpgrade, .extraParsers, .writtenNotes, .userGroups, .filingSuggestions,
        .richDocuments, .folderSync
    ]

    public var alsoInDevonthink: Bool { Self.alsoInDevonthinkSet.contains(self) }

    /// Everything that describes one module, in one place.
    public struct Spec: Sendable {
        public let planID: String
        public let group: String
        public let title: String
        public let detail: String
        /// What still exists when the module is switched off.
        public let whenOff: String
        public var implemented: Bool = false
        public var defaultEnabled: Bool = false
        public var requiresOnline: Bool = false
        public var requiresAI: Bool = false
        public var dependsOn: [ProductModule] = []
        /// Built but not yet verified on real data or hardware: unavailable unless
        /// "Show preview features" is on, and never part of a role preset.
        public var preview: Bool = false
    }

    public var spec: Spec {
        switch self {
        // ── Wave 1 ───────────────────────────────────────────────────────
        case .advancedSearchSyntax:
            return Spec(planID: "W1-1", group: "Search & organise", title: "Advanced search syntax",
                        detail: "AND, OR, NOT, \"exact phrase\", NEAR/5, wildcards and field filters such as from:, date:, type:, tag: and entity:. An operator the app does not understand is reported, never silently treated as a word.",
                        whenOff: "Plain keyword search, as before.",
                        implemented: true, defaultEnabled: true)
        case .searchCoverageBadge:
            return Spec(planID: "W1-2", group: "Search & organise", title: "Search coverage badge",
                        detail: "Under every result list: which fields matched and how much of the archive was searchable for this query, naming any source still being indexed.",
                        whenOff: "Results only; coverage is still recorded.",
                        implemented: true, defaultEnabled: true)
        case .signedReceipts:
            return Spec(planID: "W1-3", group: "Evidence & proof", title: "Signed import and export receipts",
                        detail: "Every import and export ends in a receipt listing what was read or written with its hashes, signed with this Mac's key so a changed byte or a different signer fails verification.",
                        whenOff: "Unsigned receipts as before.",
                        implemented: true)
        case .userTags:
            return Spec(planID: "W1-4", group: "Search & organise", title: "Tags",
                        detail: "Tag documents, facts and entities; use a tag as a search or question scope. Tags are your organisation only — they never change what the evidence says.",
                        whenOff: "Tags are hidden but kept; turning this back on restores them.",
                        implemented: true, defaultEnabled: true)
        case .deepLinks:
            return Spec(planID: "W1-5", group: "Integration", title: "Links to passages (kalsmritikosh://)",
                        detail: "Copy a link to a document, an exact passage, a citation or a saved answer and paste it into any app; opening it jumps to that place, or says plainly that it is no longer in this archive.",
                        whenOff: "Links are not offered; existing links show a 'links are off' message.",
                        implemented: true)
        case .shortcutsActions:
            return Spec(planID: "W1-6", group: "Integration", title: "Shortcuts actions",
                        detail: "Ask, Search, Add a folder, Open a source and Export a dossier from the Shortcuts app or the command line, and ask, search, add files and open links from AppleScript.",
                        whenOff: "Actions refuse with a message to turn them on.",
                        implemented: true)
        case .commandPalette:
            return Spec(planID: "W1-7", group: "Integration", title: "Command palette",
                        detail: "Reach every screen and main action from one search box (⌘K); press ? for the list of keyboard shortcuts. This existed before the module matrix, so it is on by default.",
                        whenOff: "Menus and toolbar only; ⌘K does nothing.",
                        implemented: true, defaultEnabled: true)
        case .ledgerRelocation:
            return Spec(planID: "W1-8", group: "Storage", title: "Move the ledger to another disk",
                        detail: "Copy the ledger to an external disk, verify the copy by hash, then use it from there; the app says clearly when the disk is not connected.",
                        whenOff: "Boot uses the copy on this Mac; a copy on another disk is left in place.",
                        implemented: true)
        case .importQueue:
            return Spec(planID: "W1-9", group: "Storage", title: "Import queue",
                        detail: "See pending, running and finished imports; pause, resume, stop one source or reorder. Resuming never processes a record twice.",
                        whenOff: "Imports run in the order added, with progress in the toolbar.",
                        implemented: true)

        // ── Wave I ───────────────────────────────────────────────────────
        case .proofBundles:
            return Spec(planID: "I-1", group: "Evidence & proof", title: "Proof bundles",
                        detail: "Export an answer as one signed file with every quote, its exact location and the fingerprint of each source. Anyone can check it offline with the included verifier page, without this app.",
                        whenOff: "Answers export as before, without a bundle.",
                        implemented: true)
        case .gapMap:
            return Spec(planID: "I-2", group: "Investigation", title: "What is missing",
                        detail: "Shows items your documents imply should exist but are absent: a missing number in a series, a missing month, a reply to an email you do not have, a referenced attachment. Each gap states the pattern behind it and is never presented as fact.",
                        whenOff: "The existing Insights gap list stays; the grouped map and per-answer gaps are hidden.",
                        implemented: true)
        case .corroborationMeter:
            return Spec(planID: "I-3", group: "Evidence & proof", title: "Source counts",
                        detail: "Beside each answer: how many documents it cites, how many of them are copies or forwards of another cited document (they count once), and how many could not be told apart. Counting is not assessing — separate documents can still repeat one original account, so the count says nothing about truth; review each source yourself.",
                        whenOff: "Citations only.",
                        implemented: true)
        case .devilsAdvocate:
            return Spec(planID: "I-4", group: "Evidence & proof", title: "Look for contradicting evidence",
                        detail: "Before an answer is shown, the app searches your archive for evidence against it and reports either the conflict, with both sources, or how many sources it checked.",
                        whenOff: "Contradictions are shown only when they are found during the normal search.",
                        implemented: true)
        case .timeTravel:
            return Spec(planID: "I-5", group: "Investigation", title: "Filter by document date",
                        detail: "Ask again using only documents whose file date is on or before a chosen day, and see which later-dated documents change the answer. This filters by the documents' own dates; it does not show what anyone knew on that day.",
                        whenOff: "Answers always use all evidence.",
                        implemented: true)
        case .liveFactCheck:
            return Spec(planID: "I-6", group: "Writing", title: "Fact-check my writing",
                        detail: "Write or paste a draft and each sentence is checked against your evidence after you pause: supported (with the source), contradicted (with the conflicting sentence) or unsupported.",
                        whenOff: "The fact-check tool is hidden.",
                        implemented: true)
        case .archiveSelfScore:
            return Spec(planID: "I-7", group: "Diagnostics", title: "Archive self-test (diagnostic)",
                        detail: "A troubleshooting check under Settings ▸ Advanced ▸ Diagnostics: the app asks itself questions whose answers your ledger already states, plus questions it must refuse, and reports how many it got right. The questions come from the same archive, so the result is not a measure of real-world accuracy and is not shown with answers.",
                        whenOff: "No self-test runs.",
                        implemented: true)
        case .leastDataOnline:
            return Spec(planID: "I-8", group: "Online (your own key)", title: "Send the least data",
                        detail: "Answers the ledger can give without AI never go online; for the rest, a daily limit on bytes sent (lower it to zero to send nothing), with every send measured and logged.",
                        whenOff: "Online answers send the passages the question needs, every send logged; no daily limit. No case document is sent until you allow AI for that case (questions inside an allowed case go without a further prompt).",
                        implemented: true, requiresOnline: true, dependsOn: [.onlineAnswers])
        case .statementDrift:
            return Spec(planID: "I-9", group: "Investigation", title: "How an account changed",
                        detail: "For one person, line up everything they said or wrote about a topic in date order and flag where dates, amounts, who was present or denials changed, with both quotes.",
                        whenOff: "Contradictions between documents only.",
                        implemented: true)
        case .caseSlices:
            return Spec(planID: "I-10", group: "Sharing", title: "Signed case slices",
                        detail: "Share a redacted, signed, read-only part of a case as one file that another Mac can open and verify. No server.",
                        whenOff: "Work products export as documents only.",
                        implemented: true, dependsOn: [.userTags])
        case .answerPath:
            return Spec(planID: "I-11", group: "Evidence & proof", title: "How this answer was found",
                        detail: "For every answer, which kinds of search ran, what each found, what the evidence check kept or dropped and why, and how many AI calls were used.",
                        whenOff: "The answer and its citations only.",
                        implemented: true)
        case .livingDossiers:
            return Spec(planID: "I-12", group: "Investigation", title: "Living dossiers",
                        detail: "A profile per person or organisation that updates after each import, with 'what changed since you last looked'.",
                        whenOff: "Dossiers are built when opened, without the since-last-time strip.",
                        implemented: true)

        // ── Wave 2 ───────────────────────────────────────────────────────
        case .userGroups:
            return Spec(planID: "X-2", group: "Search & organise", title: "Your own folders",
                        detail: "Arrange documents in groups and sub-groups of your own. One document can sit in several groups at once without being copied. Search or ask inside a group with group:Name. Optionally build groups from a source folder's sub-folders — files on disk are never moved.",
                        whenOff: "Groups are hidden but kept, with their members.",
                        implemented: true)
        case .filingSuggestions:
            return Spec(planID: "X-1", group: "Search & organise", title: "See Also and filing suggestions",
                        detail: "For any document: the documents most like it, and the groups and tags it most resembles, computed on this Mac from the documents' own meaning. Suggestions only — nothing is filed until you choose.",
                        whenOff: "No suggestions; groups and tags work as before.",
                        implemented: true, dependsOn: [.userGroups])
        case .richDocuments:
            return Spec(planID: "X-3", group: "Writing", title: "Rich text notes and PDF marks",
                        detail: "Write notes in rich text as well as Markdown, and highlight, underline, strike out or comment on PDFs. Marks are kept beside the PDF — the original file is never changed — and you can export an annotated copy.",
                        whenOff: "Rich notes and PDF marks are hidden but kept.",
                        implemented: true)
        case .contentCreatorPersona:
            return Spec(planID: "IF-A5", group: "Personas", title: "Content creator persona (retired)",
                        detail: "Retired from the investigation product: the Content creator persona and its Publish Package studio, kept so earlier saved publish packages stay readable. The creator's pre-publish disclosure check lives in Compliance (Endorsement & disclosure review).",
                        whenOff: "The persona and its studio are hidden; saved publish packages are kept and return when this is turned on.",
                        implemented: true)
        case .folderSync:
            return Spec(planID: "X-5", group: "Storage", title: "Sync through a folder",
                        detail: "Keep your notes, tags, groups, highlights, PDF marks and the files you added inside the app in step between your Macs and your iPhone or iPad, through a folder you choose (iCloud Drive, Dropbox, a shared or USB disk). Everything in the folder is encrypted with a passphrase you set; the app itself makes no connection — the folder's own service moves the files.",
                        whenOff: "Nothing is written to or read from the sync folder; everything stays on this Mac.",
                        implemented: true)
        case .writtenNotes:
            return Spec(planID: "P-2", group: "Writing", title: "Your own notes",
                        detail: "Write and edit notes in Markdown inside the app. Each note is read into your archive like any document, so you can search it and ask about it. Every save keeps the earlier version, which you can restore.",
                        whenOff: "Notes are hidden but kept, with their versions; what the archive learned from them stays.",
                        implemented: true, defaultEnabled: true)
        case .annotations:
            return Spec(planID: "W2-1", group: "Writing", title: "Highlights and notes",
                        detail: "Highlight and annotate any passage. Notes are stored beside the source, never written into it, and count as your own confirmed or corrected evidence.",
                        whenOff: "Highlights are hidden but kept.",
                        implemented: true, defaultEnabled: true)
        case .emailAuthenticity:
            return Spec(planID: "W2-2", group: "Email evidence", title: "Email authenticity checks",
                        detail: "Checks DKIM and ARC signatures and S/MIME, and reads hidden time values in message identifiers. No internet lookups: keys come from the message or from you.",
                        whenOff: "Emails are read as before; no authenticity result.",
                        implemented: true)
        case .specPSTReader:
            return Spec(planID: "W2-3", group: "Email evidence", title: "Outlook PST reader (MS-PST)",
                        detail: "Reads Outlook PST and OST files by Microsoft's published format: every folder, message, recipient and attachment.",
                        whenOff: "The current PST reader is used.",
                        implemented: true)
        case .nearDuplicates:
            return Spec(planID: "W2-4", group: "Search & organise", title: "Near-duplicates",
                        detail: "Links drafts, forwards and re-saved copies as versions of one another. Nothing is merged or deleted.",
                        whenOff: "Exact duplicates only.",
                        implemented: true)
        case .legalProduction:
            return Spec(planID: "W2-5", group: "Legal", title: "Production sets",
                        detail: "Bates-numbered production sets with slip sheets, a privilege log and Concordance/Relativity load files.",
                        whenOff: "No Bates numbering or load files. Legal holds are part of the core (Tools ▸ Legal holds): they can be created and released, and they block forgetting and erasing, with this switched off.",
                        implemented: true)
        case .exportFormats:
            return Spec(planID: "W2-6", group: "Sharing", title: "More export formats",
                        detail: "Specialist interchange formats for the timeline, entities and sources: mbox and EML of the original emails, TIFF page images, Excel, Markdown, JSON and HTML, with a check before export.",
                        whenOff: "Core exports stay: case reports in PDF, Word and CSV from the case file, and the timeline, entities and sources as CSV, Word or PDF from Tools ▸ Export.",
                        implemented: true)
        case .appLock:
            return Spec(planID: "W2-7", group: "Storage", title: "Lock with Touch ID",
                        detail: "Lock the app when the Mac sleeps or the screen locks, and when you come back after more than 5 minutes away; unlock with Touch ID or your Mac password. This controls who can open the app; separately, the ledger database is always encrypted on disk (AES-256, key in this Mac's Keychain), and copies of original files kept in the evidence vault are encrypted with a key derived from it.",
                        whenOff: "No app lock; the Mac's own login protects the data.",
                        implemented: true)
        case .byteRangeItems:
            return Spec(planID: "W2-8", group: "Storage", title: "Very large items",
                        detail: "A message or record larger than the per-record budget is read by byte range: only its leading part is decoded (memory stays flat), indexed with the exact byte range and marked partial, instead of being recorded as failed.",
                        whenOff: "Very large items are recorded as too large.",
                        implemented: true)

        // ── Wave 3 ───────────────────────────────────────────────────────
        case .devonthinkImport:
            return Spec(planID: "W3-1", group: "Integration", title: "Import a DEVONthink database",
                        detail: "Read the files stored in a DEVONthink database in place, keeping its groups as collections and its tags. Nothing is written into the database.",
                        whenOff: "DEVONthink databases are not recognised.",
                        implemented: true)
        case .sendToDevonthink:
            return Spec(planID: "W3-2", group: "Integration", title: "Send to DEVONthink",
                        detail: "Send an answer to DEVONthink as a Markdown note with a link back to each quoted passage; when DEVONthink is not installed the note is shown in Finder.",
                        whenOff: "Not offered.",
                        implemented: true)
        case .timelineGraph:
            return Spec(planID: "W3-3", group: "Investigation", title: "Timeline and relationship views",
                        detail: "An interactive timeline and a graph of people and organisations; every point and line opens its evidence.",
                        whenOff: "Lists only.",
                        implemented: true)
        case .proactiveAlerts:
            return Spec(planID: "W3-4", group: "Investigation", title: "Alerts",
                        detail: "Tells you when a new document contradicts what the ledger said, fills or opens a gap, or mentions someone you watch.",
                        whenOff: "No alerts; contradictions still appear in answers.",
                        implemented: true)
        case .smartCollections:
            return Spec(planID: "W3-5", group: "Search & organise", title: "Automatic rules",
                        detail: "Rules such as 'when a document from this sender arrives, tag it' that run on every new batch. Rules show a dry run first.",
                        whenOff: "Saved searches stay part of the core (Tools ▸ Documents ▸ Saved searches); rules are kept but do not run.",
                        implemented: true)
        case .captureExtensions:
            return Spec(planID: "W3-6", group: "Integration", title: "Import from iPhone or iPad",
                        detail: "File ▸ Import from iPhone or iPad takes a photo or scans a document with a nearby iPhone or iPad and puts it into the intake. (“Save to Investigations Made Easy” in the Share and Services menus — files, selected text and web addresses, with a custody record — is part of the core.) Nothing is downloaded — to keep a whole page, save it as PDF or web archive and share that.",
                        whenOff: "“Save to Investigations Made Easy” in the Share and Services menus stays part of the core unless you switched this off yourself; importing from an iPhone or iPad is off.",
                        implemented: true)
        case .spotlightIndex:
            return Spec(planID: "W3-7", group: "Integration", title: "Show in Spotlight",
                        detail: "Make document titles and summaries findable from Spotlight. This copies that text into macOS's own search index, so it is off by default.",
                        whenOff: "Nothing is given to Spotlight, and any earlier entries are removed.",
                        implemented: true)

        // ── Wave N ───────────────────────────────────────────────────────
        case .issueChronology:
            return Spec(planID: "N-1", group: "Legal", title: "Issues and chronology",
                        detail: "Tag facts and events with the issues of a matter, read the chronology by issue and draft a statement of facts or deposition outline in which every sentence is cited.",
                        whenOff: "Chronology without issues.",
                        implemented: true)
        case .communicationAnalysis:
            return Spec(planID: "N-2", group: "Email evidence", title: "Who talks to whom",
                        detail: "A communication graph with message counts and volume over time, and a marker on any reply whose original message is not in your archive.",
                        whenOff: "Threads only.",
                        implemented: true)
        case .watchlists:
            return Spec(planID: "N-3", group: "Investigation", title: "Watchlists",
                        detail: "Paste or import a list of names, phone numbers and email addresses and screen it against the whole archive or one case: per term, the documents and mentions found as a named entity (including other spellings) or as words in the text, the terms with no match, a passage per document that opens its source, and a CSV export.",
                        whenOff: "Lists are kept but not matched.",
                        implemented: true)
        case .reviewCoding:
            return Spec(planID: "N-4", group: "Legal", title: "Review coding",
                        detail: "Mark documents responsive, privileged or hot; suggestions learn from your choices and show why. Suggestions never change the evidence.",
                        whenOff: "No coding.",
                        implemented: true)
        case .studioOutputs:
            return Spec(planID: "N-5", group: "Writing", title: "Briefings, FAQs and mind maps (retired)",
                        detail: "Retired from the investigation product: generic briefing, FAQ, mind-map and spoken-briefing outputs. Kept only so earlier users can still make them; the cited case report and chronology are in the case file.",
                        whenOff: "Not offered. Files made earlier are yours and are not touched.",
                        implemented: true)
        case .menuBarAsk:
            return Spec(planID: "N-6", group: "Integration", title: "Ask from anywhere",
                        detail: "A menu-bar panel reachable from any app: ask or search, and the answer opens in the main window with its sources. (A system-wide keyboard shortcut would need Accessibility permission, which the app does not request.)",
                        whenOff: "Ask from the main window only.",
                        implemented: true)
        case .imageIntelligence:
            return Spec(planID: "N-7", group: "Investigation", title: "Similar images",
                        detail: "Find copies and crops of a photo across your archive, on this Mac. Face grouping is not part of this version.",
                        whenOff: "Images are searchable by their text only.",
                        implemented: true)
        case .locationMap:
            return Spec(planID: "N-8", group: "Investigation", title: "Places",
                        detail: "Photo locations and addresses found in documents: a list with coordinates and an offline plot on a latitude/longitude grid. Nothing is looked up online; in Online mode a place can be handed to Apple Maps.",
                        whenOff: "Not shown.",
                        implemented: true, preview: true)
        case .notesImport:
            return Spec(planID: "N-9", group: "Integration", title: "Import notes apps",
                        detail: "Read Obsidian vaults (links between notes become relations), Notion exports and notes exported from Apple Notes.",
                        whenOff: "These folders import as plain files.",
                        implemented: true)
        case .onlinePIIMasking:
            return Spec(planID: "N-10", group: "Online (your own key)", title: "Mask personal details before sending",
                        detail: "Before anything goes online, names, emails, phone numbers, addresses, ID and account numbers are replaced with placeholders; the answer is restored on your Mac.",
                        whenOff: "Passages are sent unmasked. No case document is sent until you allow AI for that case (questions inside an allowed case go without a further prompt); every send is logged.",
                        implemented: true, requiresOnline: true, dependsOn: [.onlineAnswers])
        case .questionMonitors:
            return Spec(planID: "N-11", group: "Investigation", title: "Watch a question",
                        detail: "Pin a question; after each import it is asked again and you are told when the answer, its sources or a contradiction changes, with the old and new answers.",
                        whenOff: "Pinned questions are kept but not re-asked.",
                        implemented: true)
        case .customEntityTypes:
            return Spec(planID: "N-12", group: "Search & organise", title: "Your own record types",
                        detail: "Define types such as 'Contract: parties, value, start date'. Fields fill from your documents where the value is written, and show where it was found.",
                        whenOff: "Types are kept but not filled.",
                        implemented: true)
        case .riskScore:
            return Spec(planID: "N-13", group: "Investigation", title: "Review priority (documents)",
                        detail: "In Review coding, documents can be ordered for review by the signals on each one — contradictions citing it, possible gaps found on it, watchlist names it mentions, added this week — each signal listed. It orders reading only; it never scores or ranks people and says nothing about anyone's conduct.",
                        whenOff: "Documents are listed in the order they were added.",
                        implemented: true, dependsOn: [.reviewCoding])

        // ── Wave 4 ───────────────────────────────────────────────────────
        case .ocrUpgrade:
            return Spec(planID: "W4-1", group: "Reading files", title: "Improved text recognition",
                        detail: "Reads scanned PDF pages at 300 dpi instead of 144, re-reads earlier scans once on request (keeping the earlier reading if the new one is worse), shows scans whose recognised text is thin, and saves searchable PDF copies.",
                        whenOff: "The current text recognition.",
                        implemented: true)
        case .extraParsers:
            return Spec(planID: "W4-2", group: "Reading files", title: "More file types",
                        detail: "Reads Messages history, Safari and Chrome history, PowerPoint 97–2003 (.ppt) and Keynote text (partial). Takes effect the next time the app starts.",
                        whenOff: "These files are kept but not read.",
                        implemented: true)
        case .mailRecovery:
            return Spec(planID: "W4-3", group: "Email evidence", title: "Deleted email recovery",
                        detail: "Finds deleted mail that is still present: files in Deleted Items / Trash / Bin folders and messages whose headers mark them deleted or trashed. Shown as recovered and partial, never mixed with live mail. Carving unlisted messages out of Outlook/Notes free space is not included.",
                        whenOff: "Only live mail is read.",
                        implemented: true)
        case .teamReview:
            return Spec(planID: "W4-4", group: "Sharing", title: "Team review over a shared folder",
                        detail: "Reviewers work on one case through a shared folder with signed logs; tampering is reported at the exact entry. No server.",
                        whenOff: "Single-user cases.",
                        implemented: true, preview: true)

        // ── Wave O ───────────────────────────────────────────────────────
        case .onlineAnswers:
            return Spec(planID: "O-4", group: "Online (your own key)", title: "Answers with your own cloud AI key",
                        detail: "Use an AI plan, or Claude with your own Anthropic key. No case document is sent until you allow AI for that case (questions inside an allowed case go without a further prompt), every send is logged, and answers pass the same evidence check as private ones.",
                        whenOff: "All answers are made on your Mac.",
                        implemented: true, requiresOnline: true)
        }
    }

    // Convenience accessors used by the UI and the flags.
    public var title: String { spec.title }
    public var detail: String { spec.detail }
    public var group: String { spec.group }
    public var planID: String { spec.planID }
    public var implemented: Bool { spec.implemented }

    fileprivate var storageKey: String { "kalsmritikosh.product.\(rawValue)" }
}

// MARK: - Scope (owner decision 2026-11-06, docs/IME_Core_and_Add_On_Scope_2026-11-06.md §6)
//
// Four concerns are kept apart, each with its own authority:
//   * core capability   — `disposition` / `coreRetained` below (what the base workflow always has);
//   * optional visibility — the module switch (`ProductModuleFlags`);
//   * purchase entitlement — `entitlement` (no switch grants or revokes a purchase; PurchaseGate decides);
//   * diagnostic / preview — `spec.preview` and the INTERNAL disposition.
// A preset or pack only ever switches modules ON (ModulePreset), and the core safeguards listed in
// `ModuleInvariant` are not switches at all, so no persona or pack can turn one off.

nonisolated public enum ModuleDisposition: String, CaseIterable, Sendable {
    /// Available in the base workflow.
    case core = "CORE"
    /// The capability lives inside a core surface.
    case merge = "MERGE"
    /// The essential part is core (`coreRetained`); the specialist part is the switch.
    case split = "SPLIT"
    /// Revealed on demand.
    case optional = "OPTIONAL"
    /// Diagnostic, not a product promise.
    case `internal` = "INTERNAL"
    /// Removed from the product surface; saved work is preserved.
    case retire = "RETIRE"
    /// Not a v1 offering.
    case deferred = "DEFER"

    /// Shown in the beginner path / main catalog.
    public var isProductSurface: Bool { self != .internal && self != .retire && self != .deferred }
}

/// The §4 families the capability catalog (Settings ▸ Modules) groups optional tools into.
nonisolated public enum CapabilityFamily: String, CaseIterable, Sendable {
    case core, professional, analysis, media, connections, ai, presentation, diagnostics, retired, notInThisVersion

    public var title: String {
        switch self {
        case .core: return "Core investigation workflow"
        case .professional: return "Professional workflows"
        case .analysis: return "Advanced analysis"
        case .media: return "Media and geography"
        case .connections: return "Connections and automation"
        case .ai: return "AI assistance"
        case .presentation: return "Presentation and history exploration"
        case .diagnostics: return "Diagnostics"
        case .retired: return "Retired — kept for earlier work"
        case .notInThisVersion: return "Not in this version"
        }
    }

    /// The investigative task the family supports (the catalog's explanation).
    public var task: String {
        switch self {
        case .core: return "Collect records, find exact evidence, review it, track what is unresolved and export a source-backed report. Always available; these switches only change how much detail is shown."
        case .professional: return "When the matter needs a formal legal work product: Bates-numbered productions, bulk review coding, signed read-only case slices and portable proof packages."
        case .analysis: return "When the evidence is large or contested: compare a person's accounts over time, screen a list of names, see who wrote to whom, define your own record types, and order documents for review."
        case .media: return "When photos, places or unusual file types matter: similar images, a places list, and browser, Messages and older presentation formats."
        case .connections: return "When you work with other apps or several Macs: DEVONthink, notes apps, Shortcuts, the menu bar, Spotlight, rules, watched questions and folder sync. Each one is off until you turn it on."
        case .ai: return "When you want an AI to help read: an AI plan or your own Anthropic key, with per-case consent, masking and spending limits. The manual workflow never depends on it."
        case .presentation: return "When you want to look at the record another way: filter answers by document date, and rich notes with PDF marks."
        case .diagnostics: return "For troubleshooting only; not a measure of how well the app works for your case."
        case .retired: return "No longer part of the investigation product. Turn one on only to reach work you made with it earlier; nothing you saved was deleted."
        case .notInThisVersion: return "Planned for a later version; not available in this one."
        }
    }
}

/// How far a module has actually been verified (docs/IME_Core_and_Add_On_Scope_2026-11-06.md §9.9:
/// recommended, built, integration-tested and signed-app-verified are different states).
nonisolated public enum ModuleVerification: String, CaseIterable, Sendable {
    /// Code has landed; no dedicated automated test found.
    case built
    /// Its engine has unit tests in KalsmritikoshTests (evidence: `verificationEvidence`).
    case unitTested = "unit-tested"
    /// Exercised end to end through AppState in the test host.
    case integrationTested = "integration-tested"
    /// Verified by a person in a signed build. No module claims this from the agent side.
    case signedAppVerified = "signed-app-verified"
}

/// Whether a module is something bought. No module switch is a purchase: subscriptions are decided by
/// PurchaseGate (creating/editing/analysing), and AI credits by the AI plan.
nonisolated public enum ModuleEntitlement: String, Sendable {
    case none
    /// Uses an AI plan's credits or the person's own Anthropic key; the switch itself sells nothing.
    case aiPlanOrOwnKey = "ai-plan-or-own-key"
}

extension ProductModule {

    /// §6 — the scope decision for every module. The single authority for disposition.
    public var disposition: ModuleDisposition {
        switch self {
        case .advancedSearchSyntax, .searchCoverageBadge, .signedReceipts, .userTags, .deepLinks,
             .commandPalette, .importQueue, .leastDataOnline, .answerPath, .annotations, .specPSTReader,
             .appLock, .byteRangeItems, .onlinePIIMasking, .ocrUpgrade, .writtenNotes:
            return .core
        case .gapMap, .corroborationMeter, .devilsAdvocate, .liveFactCheck, .livingDossiers, .timelineGraph,
             .issueChronology, .userGroups:
            return .merge
        case .proofBundles, .timeTravel, .caseSlices, .emailAuthenticity, .nearDuplicates, .legalProduction,
             .exportFormats, .smartCollections, .captureExtensions, .reviewCoding, .riskScore, .extraParsers,
             .richDocuments:
            return .split
        case .shortcutsActions, .ledgerRelocation, .statementDrift, .devonthinkImport, .sendToDevonthink,
             .proactiveAlerts, .communicationAnalysis, .watchlists, .menuBarAsk, .imageIntelligence, .locationMap,
             .notesImport, .questionMonitors, .customEntityTypes, .mailRecovery, .onlineAnswers, .filingSuggestions,
             .folderSync, .spotlightIndex:
            return .optional
        case .archiveSelfScore:
            return .internal
        case .studioOutputs, .contentCreatorPersona:
            return .retire
        case .teamReview:
            return .deferred
        }
    }

    /// The catalog family (§4).
    public var family: CapabilityFamily {
        switch disposition {
        case .internal: return .diagnostics
        case .retire: return .retired
        case .deferred: return .notInThisVersion
        case .core, .merge:
            return [.leastDataOnline, .onlinePIIMasking].contains(self) ? .ai : .core
        case .split, .optional:
            switch self {
            case .legalProduction, .reviewCoding, .caseSlices, .proofBundles, .exportFormats:
                return .professional
            case .statementDrift, .communicationAnalysis, .watchlists, .customEntityTypes, .riskScore,
                 .nearDuplicates, .emailAuthenticity, .mailRecovery:
                return .analysis
            case .imageIntelligence, .locationMap, .extraParsers:
                return .media
            case .onlineAnswers:
                return .ai
            case .timeTravel, .richDocuments:
                return .presentation
            default:
                return .connections
            }
        }
    }

    /// For SPLIT (and MERGE) modules: what stays available in the core with the switch OFF. Each
    /// statement is backed by code that does not read this module's switch (tested in ScopeCoreTests).
    public var coreRetained: String? {
        switch self {
        case .legalProduction: return "Legal holds: create, release, and block forgetting and erasing (Tools ▸ Legal holds)."
        case .exportFormats: return "Case reports in PDF, Word and CSV, and timeline/entity/source tables as CSV, Word or PDF."
        case .smartCollections: return "Saved searches (Tools ▸ Documents ▸ Saved searches)."
        case .reviewCoding: return "Privileged documents are withheld from every export; manual review states in the case."
        case .extraParsers: return "Common Office, PDF, email, image (OCR) and archive formats."
        case .captureExtensions: return "“Save to Investigations Made Easy” in the Share and Services menus, unless switched off by you."
        case .caseSlices: return "Redacted case reports through the one export route."
        case .proofBundles: return "Export receipts and the re-check of every citation on export."
        case .nearDuplicates: return "Exact duplicates are recognised; stored version groups still count once in source counts."
        case .emailAuthenticity: return "Email headers and provenance are kept with every message."
        case .timeTravel: return "Dates and date filters in search (before:, after:)."
        case .richDocuments: return "Markdown notes with versions, and highlights on any passage."
        case .riskScore: return "Contradictions, gaps and watchlist matches stay visible where they are found."
        case .corroborationMeter: return "Citations, and copies counted once, are always kept."
        case .timelineGraph: return "Chronology and people lists in the case file."
        case .livingDossiers: return "People and organisations in the case."
        case .gapMap: return "Unanswered questions and the gap list in the case."
        case .issueChronology: return "The ordinary chronology."
        case .userGroups: return "Case scope and tags organise case evidence."
        case .devilsAdvocate: return "Contradictions found during the normal search are always shown."
        case .liveFactCheck: return "Citations are re-checked on every report export."
        default: return nil
        }
    }

    public var entitlement: ModuleEntitlement { self == .onlineAnswers ? .aiPlanOrOwnKey : .none }

    /// Search tokens that prove a `unitTested` claim: each must occur in a KalsmritikoshTests source
    /// (ScopeInventoryDriftTests checks this, so the level can never be claimed without the test).
    public var verificationEvidence: [String] {
        switch self {
        case .advancedSearchSyntax: return ["AdvancedSearchCompiler"]
        case .userTags: return ["TagsRepository"]
        case .commandPalette: return ["PaletteCatalog"]
        case .gapMap: return ["GapDetector"]
        case .corroborationMeter: return ["CorroborationMeter", "SourceIndependenceGrouper"]
        case .riskScore: return ["ReviewPriority"]
        case .onlinePIIMasking: return ["PIIMasker"]
        case .userGroups: return ["X-2 Your own folders"]
        case .filingSuggestions: return ["X-1 See Also"]
        case .richDocuments: return ["X-3 Rich text notes"]
        case .folderSync: return ["X-5 Sync"]
        case .writtenNotes: return ["P-2 Your own notes"]
        case .annotations: return ["W2-1 highlights"]
        case .nearDuplicates: return ["NearDuplicateFinder"]
        case .legalProduction: return ["ProductionBuilder"]
        case .exportFormats: return ["LedgerExportRenderer"]
        case .appLock: return ["AppLock"]
        case .byteRangeItems: return ["W2-8 very large items"]
        case .devonthinkImport: return ["DevonthinkPackage"]
        case .captureExtensions: return ["ShareInbox"]
        case .imageIntelligence: return ["N-7 image grouping"]
        case .notesImport: return ["N-9 notes formats"]
        case .extraParsers: return ["W4-2 Keynote"]
        case .teamReview: return ["W4-4 team review"]
        case .shortcutsActions: return ["P-4 AppleScript dictionary"]
        case .reviewCoding: return ["ReviewCodesRepository"]
        default: return []
        }
    }

    /// Honest verification level: unit-tested only where test evidence exists; nothing is claimed as
    /// integration-tested or signed-app-verified here.
    public var verification: ModuleVerification {
        guard spec.implemented else { return .built }
        return verificationEvidence.isEmpty ? .built : .unitTested
    }

    /// Privacy-sensitive connections: never switched on by a preset, a pack or a migration — only by
    /// the person (docs/IME_Core_and_Add_On_Scope_2026-11-06.md §9.2 / §9.5).
    public static let neverSwitchedOnAutomatically: Set<ProductModule> = [
        .onlineAnswers, .spotlightIndex, .folderSync, .questionMonitors
    ]
}

/// Guarantees that exist so the switches stay safe. They are listed in the
/// matrix so nobody mistakes them for missing switches.
nonisolated public enum ModuleInvariant: String, CaseIterable, Sendable {
    case sendPreview, outboundLog, evidenceGate, noSilentModeFallback, privateIsDefault, mainAppHasNoNetwork
    // Core safeguards (owner decision 2026-11-06): no module, persona or pack switches these off.
    case legalHoldsBlockErasure, exportRechecks, erasureAlwaysAvailable, coverageRecorded, perCaseAIConsent, presetsOnlySwitchOn

    public var statement: String {
        switch self {
        case .legalHoldsBlockErasure: return "Legal holds can be created and released with every module off, and a hold always blocks forgetting and erasing."
        case .exportRechecks:       return "Every case export re-checks its citations, privilege and access, whatever is switched on."
        case .erasureAlwaysAvailable: return "Backup, restore and erasure (Settings ▸ Your data) are never behind a module or a purchase."
        case .coverageRecorded:     return "What each search and case could and could not read is always recorded; a switch only changes how much is shown."
        case .perCaseAIConsent:     return "No case document goes to an AI without that case's permission, whatever module is on."
        case .presetsOnlySwitchOn:  return "A persona preset or pack only switches modules on — never a safeguard off — and never switches on Online, Spotlight, sync or watched questions."
        case .sendPreview:          return "Nothing goes online without the user seeing what will be sent (O-5)."
        case .outboundLog:          return "Every online send is recorded with a receipt (O-5)."
        case .evidenceGate:         return "Online answers pass the same claim–evidence check as private ones; cloud text is never primary evidence (O-6)."
        case .noSilentModeFallback: return "If Online fails the app says so and offers a private answer; it never switches mode on its own (O-7)."
        case .privateIsDefault:     return "A new user starts in Private mode (owner decision 2026-10-15)."
        case .mainAppHasNoNetwork:  return "The main app keeps no network permission; only the network helper has it (O-2, W0-C)."
        }
    }
}

/// Thread-safe, nonisolated accessor over UserDefaults (FeatureFlags convention).
nonisolated public enum ProductModuleFlags {

    /// Modules built but outside the locked v1 contract (single user, no team features).
    public nonisolated static let outOfV1Scope: Set<ProductModule> = [.teamReview]

    public nonisolated static func isEnabled(_ m: ProductModule) -> Bool {
        disabledReason(m) == nil && storedOrDefault(m)
    }

    /// Why the module cannot run now, or nil when it is freely switchable. The
    /// stored choice is never erased by a gate.
    public nonisolated static func disabledReason(_ m: ProductModule) -> String? {
        let s = m.spec
        guard s.implemented else { return "Coming in a later build (\(s.planID))" }
        // F6 listing audit — the v1 contract is single-user (SHIP_DECISIONS §0): team features are
        // not offered in this version, even as a preview.
        if outOfV1Scope.contains(m) { return "Not part of this version (single-user)" }
        if s.preview, !showPreviewFeatures { return "Preview — not yet verified; turn on “Show preview features” to try it" }
        if s.requiresOnline {
            if !ConnectivityMode.onlineAvailableInThisBuild { return "Online mode is not available in this build" }
            if ConnectivityMode.current != .online { return "Needs Online mode" }
        }
        if s.requiresAI, !FeatureFlags.aiRegimeValue().allowsAI {
            return EvidenceOnlyRelease.enforced ? "Not in this version — answers are evidence-only (no AI model)" : "Needs AI — choose “AI · evidence-gated” or “AI · free”"
        }
        for dep in s.dependsOn where !isEnabled(dep) {
            return "Requires “\(dep.title)”"
        }
        return nil
    }

    static let showPreviewKey = "kalsmritikosh.product.showPreview"

    /// Preview features (built, not yet verified on real data/hardware) are hidden unless this is on.
    public nonisolated static var showPreviewFeatures: Bool {
        get { AppDefaults.store.bool(forKey: showPreviewKey) }
        set { AppDefaults.store.set(newValue, forKey: showPreviewKey) }
    }

    public nonisolated static func setEnabled(_ m: ProductModule, _ on: Bool) {
        AppDefaults.store.set(on, forKey: m.storageKey)
        if m == .captureExtensions { ShareInbox.mirrorSwitch() }   // the Share extension reads the copy
    }

    #if DEBUG
    /// Per-task module switches for tests (Debug builds only), the same pattern as `PaidUse.TestOverride`.
    /// The preference store is one per test host, and suites run in parallel: a suite that wrote its
    /// switches there and put them back afterwards undid another suite's switches while that suite was
    /// still running (found 2026-11-12: the base-case journey saw the import queue come back on, and the
    /// lapsed-boundary suite saw a pack it had switched off come back on). A test sets these for its own
    /// task tree instead; nothing global changes.
    public enum TestOverride {
        @TaskLocal public static var modules: [ProductModule: Bool]?
    }
    #endif

    private nonisolated static func storedOrDefault(_ m: ProductModule) -> Bool {
        #if DEBUG
        if let o = TestOverride.modules?[m] { return o }
        #endif
        let d = AppDefaults.store
        if d.object(forKey: m.storageKey) == nil { return m.spec.defaultEnabled }
        return d.bool(forKey: m.storageKey)
    }

    /// The person's own stored choice for a module, or nil when they never set it.
    public nonisolated static func explicitChoice(_ m: ProductModule, store: UserDefaults = AppDefaults.store) -> Bool? {
        #if DEBUG
        if store === AppDefaults.store, let o = TestOverride.modules?[m] { return o }   // a test's own switches
        #endif
        return store.object(forKey: m.storageKey) == nil ? nil : store.bool(forKey: m.storageKey)
    }

    /// SPLIT captureExtensions — the core part: "Save to Investigations Made Easy" in the Share and
    /// Services menus works unless the person switched “Import from iPhone or iPad” off themselves
    /// (an explicit choice made when the switch still covered the Share menu is kept).
    public nonisolated static var shareMenuCaptureAvailable: Bool {
        explicitChoice(.captureExtensions) ?? true
    }

    /// The storage key of a module (for migrations and tests).
    public nonisolated static func storageKey(_ m: ProductModule) -> String { m.storageKey }
}

/// Scope migration (owner decision 2026-11-06). New installs get the new defaults; an install that
/// existed before keeps exactly what it had: for every module whose default changed, the OLD default is
/// written as its stored value when the person never chose one. It never switches on anything listed in
/// `ProductModule.neverSwitchedOnAutomatically`, and explicit choices are never touched.
nonisolated public enum ModuleScopeMigration {
    static let revisionKey = "kalsmritikosh.product.scopeRevision"
    static let revision = 1

    /// Modules whose `defaultEnabled` changed on 2026-11-06, with the default they had before.
    public static let previousDefaults: [ProductModule: Bool] = [
        .devonthinkImport: true, .sendToDevonthink: true,
        .searchCoverageBadge: false, .writtenNotes: false
    ]

    /// True when this preference store belongs to an install that ran before (onboarding seen, a role
    /// chosen, or any module switch stored).
    public static func isPriorInstall(_ store: UserDefaults) -> Bool {
        if store.object(forKey: "kalsmritikosh.onboarding.shown") != nil { return true }
        if store.object(forKey: ModulePreset.personaKey) != nil { return true }
        return ProductModule.allCases.contains { store.object(forKey: ProductModuleFlags.storageKey($0)) != nil }
    }

    /// Run once at launch, before anything reads a module switch. Returns the modules it pinned.
    @discardableResult
    public static func run(_ store: UserDefaults = AppDefaults.store) -> [ProductModule] {
        guard store.integer(forKey: revisionKey) < revision else { return [] }
        var pinned: [ProductModule] = []
        if isPriorInstall(store) {
            for (m, old) in previousDefaults.sorted(by: { $0.key.rawValue < $1.key.rawValue })
            where store.object(forKey: ProductModuleFlags.storageKey(m)) == nil {
                // Never switch on a privacy-sensitive connection, even to restore an old default.
                if old && ProductModule.neverSwitchedOnAutomatically.contains(m) { continue }
                store.set(old, forKey: ProductModuleFlags.storageKey(m))
                pinned.append(m)
            }
        }
        store.set(revision, forKey: revisionKey)
        return pinned
    }
}

/// Role presets: choosing a role in onboarding or on Home switches ON the modules
/// that role needs. A preset only turns modules on — it never turns off anything
/// the person chose — and never includes preview modules or modules whose feature
/// DEVONthink already has (those stay off until the person turns them on).
nonisolated public enum ModulePreset {
    /// Core review aids every role gets (2026-11-06: connectors and near-duplicate grouping left this
    /// list — they are optional; DEVONthink users get theirs from the "devonthink" role).
    public static let everyone: [ProductModule] = [
        .searchCoverageBadge, .signedReceipts, .corroborationMeter, .devilsAdvocate,
        .answerPath, .gapMap
    ]

    public static func modules(forPersona id: String) -> [ProductModule] {
        let extra: [ProductModule]
        switch id {
        case "legal":
            extra = [.reviewCoding, .issueChronology, .legalProduction, .caseSlices, .proofBundles, .gapMap, .exportFormats]
        case "investigation":
            // Owner decision 2026-11-06 (scope): the investigator starts with the core workflow only —
            // specialist tools (email forensics, recovery, communication graph, watchlists, alerts,
            // similar images) are in the capability catalog, switched on when needed.
            extra = [.timelineGraph, .livingDossiers, .deepLinks, .importQueue, .writtenNotes] + investigatorBasics
        case "journalism":
            extra = [.liveFactCheck, .statementDrift, .gapMap, .proofBundles, .watchlists, .proactiveAlerts]
        case "research":
            extra = [.notesImport, .smartCollections, .exportFormats, .timeTravel]
        case "devonthink":
            extra = [.devonthinkImport, .sendToDevonthink, .proofBundles, .timeTravel, .livingDossiers]
        default:
            extra = []
        }
        // The investigation role is the main app (owner decision 2026-11-03): its own tools are switched
        // on even where DEVONthink has a similar feature. Other roles keep the companion rule.
        let companionExempt: Set<ProductModule> = id == "investigation" ? Set(extra) : []
        return (everyone + extra).filter {
            !$0.spec.preview && $0.spec.implemented && (!$0.alsoInDevonthink || companionExempt.contains($0))
                && $0.disposition.isProductSurface && !ProductModule.neverSwitchedOnAutomatically.contains($0)
        }
    }

    /// Owner decision 2026-11-03: investigators get search syntax, tags and highlights by default — the
    /// basics competing investigation tools (Datashare, Magnet Review, Casefleet) treat as standard.
    public static let investigatorBasics: [ProductModule] = [.advancedSearchSyntax, .userTags, .annotations]

    /// Switch on the persona's modules (never switches anything off).
    public static func apply(persona id: String) {
        for m in modules(forPersona: id) { ProductModuleFlags.setEnabled(m, true) }
    }

    static let personaKey = "kalsmritikosh.persona"
    static let investigationPresetRevisionKey = "kalsmritikosh.preset.investigation.revision"
    /// Raised when the investigation role gains tools (2026-11-03: its listed relationship/timeline views were
    /// never switched on, and search syntax, tags and highlights joined it).
    static let investigationPresetRevision = 2

    /// Someone who chose the investigation role before its tools changed gets them once, at launch — the same
    /// switch-on-only preset as choosing the role again. Anything they turn off afterwards stays off.
    @discardableResult
    public static func refreshInvestigationRole(_ store: UserDefaults = AppDefaults.store) -> Bool {
        guard store.string(forKey: personaKey) == "investigation",
              store.integer(forKey: investigationPresetRevisionKey) < investigationPresetRevision else { return false }
        apply(persona: "investigation")
        store.set(investigationPresetRevision, forKey: investigationPresetRevisionKey)
        return true
    }

    /// For someone using Kalsmritikosh on its own, without DEVONthink: the features DEVONthink
    /// also has (tags, highlights, smart collections, capture, Spotlight and the rest), which the
    /// companion positioning otherwise leaves off. Built, non-preview modules only.
    /// Privacy-sensitive connections (Spotlight, folder sync) are never part of it: they copy text out of
    /// the app, so they stay an explicit choice of their own (2026-11-06).
    public static var standalone: [ProductModule] {
        ProductModule.allCases.filter { $0.alsoInDevonthink && $0.spec.implemented && !$0.spec.preview
            && !ProductModule.neverSwitchedOnAutomatically.contains($0) }
            .sorted { $0.rawValue < $1.rawValue }
    }

    /// Switch on the standalone set (never switches anything off).
    public static func applyStandalone() {
        for m in standalone { ProductModuleFlags.setEnabled(m, true) }
    }
}

