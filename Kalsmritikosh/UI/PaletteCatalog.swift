//
//  PaletteCatalog.swift
//  Kalsmritikosh
//
//  D-10 (completion instructions §1.8b) — the ⌘K palette's ONE catalog:
//  every screen, every Settings group, and a registry of app actions, each
//  findable by real-life words ("delete", "sop", "subtitles"). Coverage is
//  enforced by ci/guards/palette-coverage.sh (a settingsGroup without an
//  anchor entry fails CI), and the safety rule is test-enforced: a
//  DESTRUCTIVE entry may only NAVIGATE and anchor — the type-to-confirm
//  sheet in Settings remains the sole trigger for the erase. There is no
//  code path from palette Enter to AppState's erase.
//

import Foundation

/// Registry of app actions reachable from the palette / menu bar.
/// One case per line — palette-coverage.sh extracts them by grep.
public enum PaletteActionID: String, CaseIterable, Sendable {
    case addFolder
    case ingestAll
    case deleteAllData
    case exportHandoff
    case copySignerFingerprint
    case newWorkspace
    case transcribeFile
    case openGuide
    case openSOPRegister
}

/// Navigable Settings groups — one case per `settingsGroup` in SettingsView
/// (palette-coverage.sh fails CI when they drift apart).
public enum SettingsAnchor: String, CaseIterable, Sendable {
    case localModelSetup
    case answeringModes
    case privacy
    case backgroundMaintenance
    case ingestOptions
    case yourData
    case helpFeedback
    case legalPrivacy
}

public extension Notification.Name {
    /// Menu-bar → palette channel: object is a PaletteEntry id string
    /// (e.g. "act.addFolder"); RootView resolves it against the catalog,
    /// so menu items and palette rows can never diverge in behavior.
    static let kalsmritikoshPaletteEntry = Notification.Name("kalsmritikosh.paletteEntry")
}

/// What selecting a palette entry does. Destructive actions map to
/// `.settingsAnchor` — navigation only, never execution.
public enum PaletteTarget: Sendable, Equatable {
    case screen(Destination)
    case settingsAnchor(SettingsAnchor)
    case action(PaletteActionID)
}

public struct PaletteEntry: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let icon: String
    public let keywords: [String]
    public let target: PaletteTarget
}

public enum PaletteCatalog {

    /// Entries that erase or destroy: they may only navigate + anchor.
    public static let destructive: Set<PaletteActionID> = [.deleteAllData]

    /// Synonyms for screens whose names aren't daily words.
    static let screenKeywords: [Destination: [String]] = [
        .sutra:        ["workflow rules", "sop", "constitution"],
        .findings:     ["facts", "conclusions"],
        .dossier:      ["report", "profile"],
        .dataLab:      ["tables", "spreadsheet"],
        .handoff:      ["approve", "certificate", "deliverable"],
        .registers:    ["registers"],
        .transcripts:  ["subtitles", "speech to text"],
        .convert:      ["export format"],
        .redaction:    ["black out", "remove text"],
        .authenticity: ["tamper", "forged"],
        .assertions:   ["claims"],
        .freshness:    ["stale", "re-check"],
    ]

    /// The complete catalog: screens + Settings anchors + actions.
    public static func entries() -> [PaletteEntry] {
        var out: [PaletteEntry] = Destination.allCases.map { dest in
            PaletteEntry(id: "go.\(dest.rawValue)", title: dest.title,
                         subtitle: dest.blurb, icon: dest.icon,
                         keywords: screenKeywords[dest] ?? [],
                         target: .screen(dest))
        }
        // Settings anchors (yourData is the deleteAllData action below —
        // titled by what the user wants, not by where it lives).
        out += [
            PaletteEntry(id: "set.localModelSetup", title: "Local model setup",
                         subtitle: "Settings — dev-build model install guidance", icon: "cpu",
                         keywords: ["model", "ollama"], target: .settingsAnchor(.localModelSetup)),
            PaletteEntry(id: "set.answeringModes", title: "Answering & modes",
                         subtitle: "Settings — answer depth, Fast vs Full Evidence", icon: "slider.horizontal.3",
                         keywords: ["depth", "fast", "full evidence", "modes"], target: .settingsAnchor(.answeringModes)),
            PaletteEntry(id: "set.privacy", title: "Privacy settings",
                         subtitle: "Settings — on-device guarantees and options", icon: "hand.raised",
                         keywords: ["private", "cloud", "threads", "t3"], target: .settingsAnchor(.privacy)),
            PaletteEntry(id: "set.backgroundMaintenance", title: "Background maintenance",
                         subtitle: "Settings — idle tidying, memory distillation", icon: "moon.zzz",
                         keywords: ["idle", "maintenance", "distill"], target: .settingsAnchor(.backgroundMaintenance)),
            PaletteEntry(id: "set.ingestOptions", title: "Ingest options",
                         subtitle: "Settings — optional loaders and ingest behavior", icon: "tray.and.arrow.down",
                         keywords: ["import", "loaders", "imessage", "browser"], target: .settingsAnchor(.ingestOptions)),
            PaletteEntry(id: "set.helpFeedback", title: "Help & feedback",
                         subtitle: "Settings — report a problem, send an idea", icon: "envelope",
                         keywords: ["support", "contact", "bug", "problem"], target: .settingsAnchor(.helpFeedback)),
            PaletteEntry(id: "set.legalPrivacy", title: "Legal & privacy notices",
                         subtitle: "Settings — terms, disclaimers, acknowledgments", icon: "checkmark.shield",
                         keywords: ["terms", "license", "disclaimer", "eula"], target: .settingsAnchor(.legalPrivacy)),
        ]
        // Actions. deleteAllData NAVIGATES to the Your-data group only —
        // the type-to-confirm sheet there is the single erase trigger.
        out += [
            PaletteEntry(id: "act.addFolder", title: "Add Folder…",
                         subtitle: "Watch a new folder", icon: "folder.badge.plus",
                         keywords: ["import", "watch", "open"], target: .action(.addFolder)),
            PaletteEntry(id: "act.ingestAll", title: "Ingest All",
                         subtitle: "Re-scan every watched folder now", icon: "arrow.triangle.2.circlepath",
                         keywords: ["rescan", "reindex", "refresh"], target: .action(.ingestAll)),
            PaletteEntry(id: "act.deleteAllData", title: "Delete all my data",
                         subtitle: "Erase the entire ledger — your original files are never touched", icon: "trash",
                         keywords: ["delete", "erase", "wipe", "clear", "remove", "reset", "privacy"],
                         target: .settingsAnchor(.yourData)),
            PaletteEntry(id: "act.exportHandoff", title: "Export a work product",
                         subtitle: "Handoff & Review — build, approve, export", icon: "square.and.arrow.up",
                         keywords: ["export", "pdf", "docx", "deliverable"], target: .screen(.handoff)),
            PaletteEntry(id: "act.copySignerFingerprint", title: "Copy my signer fingerprint",
                         subtitle: "Compliance Board — bundle identity", icon: "key",
                         keywords: ["fingerprint", "signature", "verify", "key"], target: .screen(.sopBoard)),
            PaletteEntry(id: "act.newWorkspace", title: "New workspace",
                         subtitle: "Create a workspace for a matter", icon: "plus.rectangle.on.folder",
                         keywords: ["matter", "case", "project"], target: .screen(.workspaces)),
            PaletteEntry(id: "act.transcribeFile", title: "Transcribe an audio file",
                         subtitle: "Transcripts — on-demand, on-device", icon: "waveform",
                         keywords: ["speech", "audio", "subtitles", "dictation"], target: .screen(.transcripts)),
            PaletteEntry(id: "act.openGuide", title: "Open the guide",
                         subtitle: "How Kalsmritikosh works, term by term", icon: "book",
                         keywords: ["manual", "docs", "glossary"], target: .screen(.guide)),
            PaletteEntry(id: "act.openSOPRegister", title: "Open the SOP register",
                         subtitle: "Sūtra — every standing procedure the app binds itself to", icon: "list.bullet.rectangle",
                         keywords: ["sop", "standards", "rules", "register"], target: .screen(.sutra)),
        ]
        return out
    }

    // MARK: - Matching & ranking

    /// Fuzzy subsequence primitive (the palette's original matcher).
    public static func fuzzySubsequence(_ needle: String, _ haystack: String) -> Bool {
        let n = Array(needle.lowercased()), h = Array(haystack.lowercased())
        guard !n.isEmpty else { return true }
        var i = 0
        for c in h where c == n[i] {
            i += 1
            if i == n.count { return true }
        }
        return false
    }

    /// Score: 4 = title prefix, 3 = word-boundary match in title OR an exact
    /// keyword word ("erase" must surface Delete-all-my-data above an entry
    /// whose TITLE merely contains e-r-a-s-e as a subsequence), 2 = subsequence
    /// in title, 1 = subsequence in keywords + subtitle, 0 = miss.
    public static func score(query: String, entry: PaletteEntry) -> Int {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return 0 }
        let title = entry.title.lowercased()
        if title.hasPrefix(q) { return 4 }
        if title.split(separator: " ").contains(where: { $0.hasPrefix(q) }) { return 3 }
        if entry.keywords.contains(where: { kw in
            kw.lowercased().split(separator: " ").contains(where: { $0.hasPrefix(q) })
        }) { return 3 }
        if fuzzySubsequence(q, title) { return 2 }
        let rest = entry.keywords.joined(separator: " ") + " " + entry.subtitle
        if rest.lowercased().contains(q) || fuzzySubsequence(q, rest) { return 1 }
        return 0
    }

    /// Ranked matches: score descending, then title, so results are stable.
    public static func matches(query: String, in entries: [PaletteEntry]? = nil) -> [PaletteEntry] {
        let all = entries ?? Self.entries()
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return all }
        var scored: [(entry: PaletteEntry, score: Int)] = []
        for entry in all {
            let s = score(query: q, entry: entry)
            if s > 0 { scored.append((entry, s)) }
        }
        scored.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            return a.entry.title < b.entry.title
        }
        return scored.map(\.entry)
    }
}
