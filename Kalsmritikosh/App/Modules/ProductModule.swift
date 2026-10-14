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

    public var id: String { rawValue }

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
    }

    public var spec: Spec {
        switch self {
        // ── Wave 1 ───────────────────────────────────────────────────────
        case .advancedSearchSyntax:
            return Spec(planID: "W1-1", group: "Search & organise", title: "Advanced search syntax",
                        detail: "AND, OR, NOT, \"exact phrase\", NEAR/5, wildcards and field filters such as from:, date:, type:, tag: and entity:. An operator the app does not understand is reported, never silently treated as a word.",
                        whenOff: "Plain keyword search, as before.",
                        implemented: true)
        case .searchCoverageBadge:
            return Spec(planID: "W1-2", group: "Search & organise", title: "Search coverage badge",
                        detail: "Under every result list: which fields matched and how much of the archive was searchable for this query, naming any source still being indexed.",
                        whenOff: "Results only; coverage is still recorded.",
                        implemented: true)
        case .signedReceipts:
            return Spec(planID: "W1-3", group: "Evidence & proof", title: "Signed import and export receipts",
                        detail: "Every import and export ends in a receipt listing what was read or written with its hashes, signed with this Mac's key so a changed byte or a different signer fails verification.",
                        whenOff: "Unsigned receipts as before.",
                        implemented: true)
        case .userTags:
            return Spec(planID: "W1-4", group: "Search & organise", title: "Tags",
                        detail: "Tag documents, facts and entities; use a tag as a search or question scope. Tags are your organisation only — they never change what the evidence says.",
                        whenOff: "Tags are hidden but kept; turning this back on restores them.",
                        implemented: true)
        case .deepLinks:
            return Spec(planID: "W1-5", group: "Integration", title: "Links to passages (kalsmritikosh://)",
                        detail: "Copy a link to a document, an exact passage, a citation or a saved answer and paste it into any app; opening it jumps to that place, or says plainly that it is no longer in this archive.",
                        whenOff: "Links are not offered; existing links show a 'links are off' message.",
                        implemented: true)
        case .shortcutsActions:
            return Spec(planID: "W1-6", group: "Integration", title: "Shortcuts actions",
                        detail: "Ask, Search, Add a folder, Open a source and Export a dossier from the Shortcuts app or the command line.",
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
            return Spec(planID: "I-3", group: "Evidence & proof", title: "Corroboration meter",
                        detail: "Beside each claim, how many INDEPENDENT sources support it. Copies and forwards of one message count once; a claim with a single source is marked as a lead, not a fact.",
                        whenOff: "Citations only.",
                        implemented: true)
        case .devilsAdvocate:
            return Spec(planID: "I-4", group: "Evidence & proof", title: "Look for contradicting evidence",
                        detail: "Before an answer is shown, the app searches your archive for evidence against it and reports either the conflict, with both sources, or how many sources it checked.",
                        whenOff: "Contradictions are shown only when they are found during the normal search.",
                        implemented: true)
        case .timeTravel:
            return Spec(planID: "I-5", group: "Investigation", title: "As of a date",
                        detail: "Ask again using only evidence whose file date is on or before a chosen day, and see which later documents changed the answer. Later material cannot enter the evidence or the citations.",
                        whenOff: "Answers always use all evidence.",
                        implemented: true)
        case .liveFactCheck:
            return Spec(planID: "I-6", group: "Writing", title: "Fact-check my writing",
                        detail: "Write or paste a draft and each sentence is checked against your evidence after you pause: supported (with the source), contradicted (with the conflicting sentence) or unsupported.",
                        whenOff: "The fact-check tool is hidden.",
                        implemented: true)
        case .archiveSelfScore:
            return Spec(planID: "I-7", group: "Evidence & proof", title: "Accuracy on your archive",
                        detail: "The app tests itself with questions whose answers your ledger already proves, plus questions it must refuse, and shows a personal accuracy score; displayed confidence is tuned to that score.",
                        whenOff: "No self-test runs; confidence uses the built-in scale.",
                        implemented: true)
        case .leastDataOnline:
            return Spec(planID: "I-8", group: "Online (your own key)", title: "Send the least data",
                        detail: "Answers the ledger can give without AI never go online; for the rest, a daily limit on bytes sent (lower it to zero to send nothing), with every send measured and logged.",
                        whenOff: "Online answers send the passages the question needs, still previewed and logged; no daily limit.",
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
        case .annotations:
            return Spec(planID: "W2-1", group: "Writing", title: "Highlights and notes",
                        detail: "Highlight and annotate any passage. Notes are stored beside the source, never written into it, and count as your own confirmed or corrected evidence.",
                        whenOff: "Highlights are hidden but kept.",
                        implemented: true)
        case .emailAuthenticity:
            return Spec(planID: "W2-2", group: "Email evidence", title: "Email authenticity checks",
                        detail: "Checks DKIM and ARC signatures and S/MIME, and reads hidden time values in message identifiers. No internet lookups: keys come from the message or from you.",
                        whenOff: "Emails are read as before; no authenticity result.",
                        implemented: true)
        case .specPSTReader:
            return Spec(planID: "W2-3", group: "Email evidence", title: "Outlook PST reader (MS-PST)",
                        detail: "Reads Outlook PST and OST files by Microsoft's published format: every folder, message, recipient and attachment.",
                        whenOff: "The current PST reader is used.")
        case .nearDuplicates:
            return Spec(planID: "W2-4", group: "Search & organise", title: "Near-duplicates",
                        detail: "Links drafts, forwards and re-saved copies as versions of one another. Nothing is merged or deleted.",
                        whenOff: "Exact duplicates only.",
                        implemented: true)
        case .legalProduction:
            return Spec(planID: "W2-5", group: "Legal", title: "Production sets",
                        detail: "Bates-numbered PDFs, Concordance/Relativity load files and legal holds that block removal.",
                        whenOff: "Exports without Bates numbers or load files. Existing holds still block removal.",
                        implemented: true)
        case .exportFormats:
            return Spec(planID: "W2-6", group: "Sharing", title: "More export formats",
                        detail: "mbox, EML, MSG, PDF, TIFF, CSV, Word, Markdown, JSON and HTML, with a check before export and resume after interruption.",
                        whenOff: "The current export formats.")
        case .appLock:
            return Spec(planID: "W2-7", group: "Storage", title: "Lock with Touch ID",
                        detail: "Lock the app when the Mac sleeps or the screen locks, and when you come back after more than 5 minutes away; unlock with Touch ID or your Mac password. Whole-database encryption is a separate decision.",
                        whenOff: "No app lock; the Mac's own login protects the data.",
                        implemented: true)
        case .byteRangeItems:
            return Spec(planID: "W2-8", group: "Storage", title: "Very large items",
                        detail: "Messages and attachments over 100 MB are read from the original file by byte range instead of being loaded whole.",
                        whenOff: "Very large items are recorded as too large.")

        // ── Wave 3 ───────────────────────────────────────────────────────
        case .devonthinkImport:
            return Spec(planID: "W3-1", group: "Integration", title: "Import a DEVONthink database",
                        detail: "Read the files stored in a DEVONthink database in place, keeping its groups as collections and its tags. Nothing is written into the database.",
                        whenOff: "DEVONthink databases are not recognised.")
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
            return Spec(planID: "W3-5", group: "Search & organise", title: "Smart collections and rules",
                        detail: "Saved searches that stay up to date, and rules such as 'when a document from this sender arrives, tag it'. Rules show a dry run first.",
                        whenOff: "Saved searches run only when opened; rules do not run.",
                        implemented: true)
        case .captureExtensions:
            return Spec(planID: "W3-6", group: "Integration", title: "Share and capture",
                        detail: "Send files and web pages to the import queue from the Share menu, the Services menu or Safari. Pages are saved on your Mac.",
                        whenOff: "Add files from inside the app only.")
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
                        detail: "Import a list of people or companies and find them in your archive, including other spellings; every match opens its source.",
                        whenOff: "Lists are kept but not matched.",
                        implemented: true)
        case .reviewCoding:
            return Spec(planID: "N-4", group: "Legal", title: "Review coding",
                        detail: "Mark documents responsive, privileged or hot; suggestions learn from your choices and show why. Suggestions never change the evidence.",
                        whenOff: "No coding.",
                        implemented: true)
        case .studioOutputs:
            return Spec(planID: "N-5", group: "Writing", title: "Briefings, FAQs and mind maps",
                        detail: "One-click briefing, FAQ and mind map built from the ledger (no AI writes them), and a spoken briefing read by your Mac's own voice. The cited chronology is in Issues and chronology.",
                        whenOff: "Not offered.",
                        implemented: true)
        case .menuBarAsk:
            return Spec(planID: "N-6", group: "Integration", title: "Ask from anywhere",
                        detail: "A menu-bar panel reachable from any app: ask or search, and the answer opens in the main window with its sources. (A system-wide keyboard shortcut would need Accessibility permission, which the app does not request.)",
                        whenOff: "Ask from the main window only.",
                        implemented: true)
        case .imageIntelligence:
            return Spec(planID: "N-7", group: "Investigation", title: "Similar images and faces",
                        detail: "Find copies and crops of a photo across your archive. Face grouping is a separate choice inside this module; groups are named by you and the app never claims who a person is.",
                        whenOff: "Images are searchable by their text only.")
        case .locationMap:
            return Spec(planID: "N-8", group: "Investigation", title: "Places",
                        detail: "Photo locations and addresses found in documents. Private mode shows a list; the map needs map tiles from the internet, so the map appears only in Online mode.",
                        whenOff: "Not shown.")
        case .notesImport:
            return Spec(planID: "N-9", group: "Integration", title: "Import notes apps",
                        detail: "Read Obsidian vaults (links between notes become relations), Notion exports and notes exported from Apple Notes.",
                        whenOff: "These folders import as plain files.")
        case .onlinePIIMasking:
            return Spec(planID: "N-10", group: "Online (your own key)", title: "Mask personal details before sending",
                        detail: "Before anything goes online, names, emails, phone numbers, addresses, ID and account numbers are replaced with placeholders; the answer is restored on your Mac.",
                        whenOff: "Passages are sent unmasked, still previewed first.",
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
            return Spec(planID: "N-13", group: "Investigation", title: "What to read first",
                        detail: "A score per document and person from contradictions, watchlist matches, failed authenticity checks and recency. Every point of the score is explained.",
                        whenOff: "No score.",
                        implemented: true, dependsOn: [.reviewCoding])

        // ── Wave 4 ───────────────────────────────────────────────────────
        case .ocrUpgrade:
            return Spec(planID: "W4-1", group: "Reading files", title: "Improved text recognition",
                        detail: "Re-reads scanned PDFs and photos page by page with Apple's on-device text recognition and records each file once.",
                        whenOff: "The current text recognition.")
        case .extraParsers:
            return Spec(planID: "W4-2", group: "Reading files", title: "More file types",
                        detail: "Keynote, older PowerPoint, Messages history, Safari and Chrome history, and 7z/RAR archives where a licence-clean reader exists.",
                        whenOff: "These files are kept but not read.")
        case .mailRecovery:
            return Spec(planID: "W4-3", group: "Email evidence", title: "Deleted email recovery",
                        detail: "Finds deleted mail that is still present: files in Deleted Items / Trash / Bin folders and messages whose headers mark them deleted or trashed. Shown as recovered and partial, never mixed with live mail. Carving unlisted messages out of Outlook/Notes free space is not included.",
                        whenOff: "Only live mail is read.",
                        implemented: true)
        case .teamReview:
            return Spec(planID: "W4-4", group: "Sharing", title: "Team review over a shared folder",
                        detail: "Reviewers work on one case through a shared folder with signed logs; tampering is reported at the exact entry. No server.",
                        whenOff: "Single-user cases.")

        // ── Wave O ───────────────────────────────────────────────────────
        case .onlineAnswers:
            return Spec(planID: "O-4", group: "Online (your own key)", title: "Answers with your own cloud AI key",
                        detail: "Use Claude, OpenAI or Gemini with your own key. You see exactly what will be sent before it goes, every send is logged, and answers pass the same evidence check as private ones.",
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

/// Guarantees that exist so the switches stay safe. They are listed in the
/// matrix so nobody mistakes them for missing switches.
nonisolated public enum ModuleInvariant: String, CaseIterable, Sendable {
    case sendPreview, outboundLog, evidenceGate, noSilentModeFallback, privateIsDefault, mainAppHasNoNetwork

    public var statement: String {
        switch self {
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

    public nonisolated static func isEnabled(_ m: ProductModule) -> Bool {
        disabledReason(m) == nil && storedOrDefault(m)
    }

    /// Why the module cannot run now, or nil when it is freely switchable. The
    /// stored choice is never erased by a gate.
    public nonisolated static func disabledReason(_ m: ProductModule) -> String? {
        let s = m.spec
        guard s.implemented else { return "Coming in a later build (\(s.planID))" }
        if s.requiresOnline {
            if !ConnectivityMode.onlineAvailableInThisBuild { return "Online mode is not available in this build" }
            if ConnectivityMode.current != .online { return "Needs Online mode" }
        }
        if s.requiresAI, !FeatureFlags.aiRegimeValue().allowsAI {
            return "Needs AI — choose “AI · evidence-gated” or “AI · free”"
        }
        for dep in s.dependsOn where !isEnabled(dep) {
            return "Requires “\(dep.title)”"
        }
        return nil
    }

    public nonisolated static func setEnabled(_ m: ProductModule, _ on: Bool) {
        UserDefaults.standard.set(on, forKey: m.storageKey)
    }

    private nonisolated static func storedOrDefault(_ m: ProductModule) -> Bool {
        let d = UserDefaults.standard
        if d.object(forKey: m.storageKey) == nil { return m.spec.defaultEnabled }
        return d.bool(forKey: m.storageKey)
    }
}
