//
//  HelpDocsRenderer.swift
//  Kalsmritikosh
//
//  Renders the two documents that must not drift from the help registry (App Store completion
//  instructions §6.5, §6.12): `docs/USER_MANUAL.md` (the manual is the registry, in Markdown) and
//  `docs/HELP_COVERAGE_MATRIX.md` (each active screen → its quick-start step, detailed topic, critical
//  explanations, accessibility identifiers and the UI journey that verified it, with gaps stated).
//  `HelpRegistryTests.generatedDocsMatch` fails when the committed files differ; regenerate by running
//  that test with HELP_DOCS_WRITE=1.
//

import Foundation

public nonisolated enum HelpDocsRenderer {

    static let banner = "<!-- GENERATED from Kalsmritikosh/UI/Help/HelpRegistry.swift by HelpDocsRenderer; do not edit by hand. Regenerate: HELP_DOCS_WRITE=1 HelpRegistryTests.generatedDocsMatch -->\n"

    // MARK: - Manual

    public static func manual() -> String {
        var out = banner
        out += "# Investigations Made Easy — user manual\n\n"
        out += "Investigations Made Easy reads the documents and email you already have, on your Mac, and builds a record of what they say: people and organisations, dated events, a timeline, and the exact passage each fact came from. You start a matter, bring documents into its scope, run the jobs of your profession, ask questions, review what you keep, and export a report whose every claim cites its source — or says honestly that the documents do not answer. This manual is the same text as Help inside the app (⌘?), which works offline.\n\n"
        out += "Single-user, English-language v1. The app documents and finds; the decisions are yours. It is not legal, accounting, medical or disciplinary advice.\n\n"
        for kind in HelpKind.allCases {
            let topics = HelpRegistry.topics(of: kind)
            if topics.isEmpty { continue }
            out += "## \(kind.title)\n\n"
            if kind == .persona {
                out += "Each recipe is derived from the jobs the profession ships with and their documentation. Content Creator ships behind its own module and is not one of the nine.\n\n"
            }
            for t in topics {
                out += (kind == .concept ? "- **\(t.title)** — \(t.summary)\n" : "### \(t.title)\n\n\(t.summary)\n\n")
                if kind == .concept { continue }
                for (i, s) in t.steps.enumerated() { out += "\(i + 1). \(s)\n" }
                if !t.steps.isEmpty { out += "\n" }
                for n in t.notes { out += "\(n)\n\n" }
                if let d = t.destination { out += "Screen: **\(d.title)**.\n\n" }
            }
            if kind == .concept { out += "\n" }
        }
        out += "## The sample tutorial\n\n"
        out += "Help ▸ Replay the Tutorial opens the isolated sample case (its own ledger, bundled Project Delta documents) and walks these steps; nothing touches your own archive.\n\n"
        for (i, s) in HelpTutorial.steps.enumerated() {
            out += "\(i + 1). **\(s.title).** \(s.instruction) *You should see:* \(s.expect)\n"
        }
        out += "\n"
        return out
    }

    // MARK: - Coverage matrix

    /// The UI journeys that verified a screen on the current code, by evidence folder under docs/evidence/.
    /// Only runs d–g (2026-10-30/31) ride on the current journey; earlier runs are not counted.
    static let verifiedJourneys: [Destination: String] = [
        .home: "ui-journeys-2026-10-31g (first screen; subscription screen leads when nothing is bought)",
        .work: "ui-journeys-2026-10-30d, -e (start matter, Add documents to this case, run, result, handoff)",
        .cases: "ui-journeys-2026-10-30d, -e (case file, evidence links, Open passage, exports, case log)",
        .hypotheses: "ui-journeys-2026-10-30d, -e (ACH filed under a case; copy/export recorded)",
        .sources: "ui-journeys-2026-10-30d, -e (folder picker reads at once; failed file stays failed; Ready)",
        .settings: "ui-journeys-2026-10-30f (Subscription section, Restore outcome)",
        .dataLab: "ui-journeys-2026-10-30d (query above the table, unresolved-only, source pane)"
    ]

    public static func coverageMatrix() -> String {
        var out = banner
        out += "# Help coverage matrix\n\n"
        out += "One row per active screen (every sidebar destination), linking its Get started step, its detailed help topic, the critical explanations (ⓘ information buttons reading the registry) on it, its accessibility identifiers for help controls, and the UI journey that verified it on the current code. “gap” means not yet verified through the UI — stated, not hidden.\n\n"
        out += "| Screen | Get started step | Detailed topic(s) | Critical explanations (ⓘ topics) | Accessibility ids | Verified journey |\n|---|---|---|---|---|---|\n"
        let quick = HelpRegistry.getStarted.steps
        for group in Destination.Group.allCases {
            for dest in group.items {
                let screen = HelpRegistry.screenTopic(for: dest)?.id ?? "—"
                let tasks = HelpRegistry.all.filter { $0.kind != .screen && $0.destination == dest }.map(\.id)
                let stepIdx = quick.firstIndex { $0.lowercased().contains(dest.title.lowercased()) }
                let step = stepIdx.map { "step \($0 + 1)" } ?? "—"
                let infos = infoTopics[dest]?.joined(separator: ", ") ?? "—"
                let ids = accessibility[dest]?.joined(separator: ", ") ?? "—"
                let journey = verifiedJourneys[dest] ?? "gap"
                out += "| \(dest.title) | \(step) | \(([screen] + tasks).joined(separator: ", ")) | \(infos) | \(ids) | \(journey) |\n"
            }
        }
        out += "\n## Critical actions and their explanations (§6.8)\n\n"
        out += "| Action | Hover (what it does) | ⓘ topic (prerequisites, consequences) | Where |\n|---|---|---|---|\n"
        for row in criticalActions { out += "| \(row.action) | \(row.hover) | \(row.topic) | \(row.where_) |\n" }
        out += "\n## Beginner acceptance targets (§6, pilot — not measured yet)\n\n"
        out += "- Open and check the first sample citation within 10 minutes of indexing.\n- Finish a small guided draft/export exercise within 20 minutes.\n- Complete without developer rescue; keyboard and VoiceOver findings recorded.\n\nThese are targets for the five-user evaluation on the distribution build; no result is claimed here.\n"
        return out
    }

    /// ⓘ buttons placed on screens, by the topic they read.
    static let infoTopics: [Destination: [String]] = [
        .work: ["task-review-approve-export (Add documents to this case)"],
        .cases: ["safety-decisions (Record finding)", "task-review-approve-export (Export)", "task-keys-backup-erase (Erase case)"],
        .knowledge: ["task-people-and-namesakes (Unmerge)"],
        .settings: ["task-keys-backup-erase (Your data)", "subscription-plans (Subscription)"],
        .ask: ["task-search-and-refusals"],
        .sources: ["task-import-failures"]
    ]

    static let accessibility: [Destination: [String]] = [
        .home: ["home.startInvestigation", "home.resumeCase", "purchase.screen", "purchase.strip"],
        .work: ["jobs.*", "result.*", "info.task-review-approve-export"],
        .cases: ["case.output.notice", "allegation.link.support", "info.safety-decisions", "info.task-keys-backup-erase"],
        .hypotheses: ["ach.*"],
        .sources: ["sources.*"],
        .settings: ["settings.subscription.status", "info.subscription-plans"],
        .guide: ["help.guide", "help.search", "help.topic.<id>", "help.replayTutorial", "help.replayIntro", "help.open.<screen>"],
        .knowledge: ["info.task-people-and-namesakes"]
    ]

    static let criticalActions: [(action: String, hover: String, topic: String, where_: String)] = [
        ("Add documents to this case", "scope preview: in scope / new / excluded; nothing added until confirmed", "task-review-approve-export, trouble-nothing-found", "Professional Jobs"),
        ("Send (Online)", "what is sent, to which host, with which key; bytes; masked details", "task-private-online", "Outbound consent sheet"),
        ("Accept shown / Save review", "one decision over the shown rows; each row records its own", "task-review-approve-export", "Job result"),
        ("Unmerge", "splits a merged identity; nothing deleted; recorded", "task-people-and-namesakes", "Knowledge ▸ Merged"),
        ("Record finding", "re-verifies every link before an adverse finding is written", "safety-decisions", "Case file ▸ Allegations"),
        ("Case file report… / Export…", "frozen, re-checked, scrubbed, written, read back, recorded", "task-review-approve-export", "Case file ▸ Export; Job result"),
        ("Erase case… / Delete All My Data…", "fail-closed; holds block; what is not reached", "task-keys-backup-erase", "Case file; Settings ▸ Your data"),
        ("Complete backup / recovery key", "ledger + originals with SHA-256; key shown once", "task-keys-backup-erase", "Settings ▸ Your data"),
        ("Subscribe / Restore purchases / Manage subscription", "storefront price and period, trial eligibility, renewal, cancel ≥ a day before", "subscription-plans, subscription-restore-offline", "Subscription screen; Settings ▸ Subscription")
    ]
}
