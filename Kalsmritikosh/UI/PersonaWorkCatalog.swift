//
//  PersonaWorkCatalog.swift
//  Kalsmritikosh
//
//  Task-oriented "work cards" per persona. Each card is one job the user came
//  to do ("Build a case chronology", "Verify a claim"), with a one-line what-it-
//  does and an action that takes them straight there — either opening the right
//  screen or seeding a starter question into Ask. Surfaced on the Home screen
//  for the chosen persona, searchable, so a user picks their job and goes.
//
//  One shared engine, per-persona lens: the actions all route into the same
//  screens; the catalog just curates + names them per role.
//

import Foundation

enum PersonaWorkAction: Sendable {
    /// Jump to a screen.
    case open(Destination)
    /// Seed a starter question into Ask and go there.
    case ask(String)
}

struct PersonaWork: Identifiable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String
    let action: PersonaWorkAction
    /// Extra search terms beyond title/subtitle.
    var extraKeywords: String = ""

    var searchText: String { "\(title) \(subtitle) \(extraKeywords)".lowercased() }
}

enum PersonaWorkCatalog {
    /// The work cards for a persona id (matches GuideContent.personas ids).
    /// Falls back to the general set for an unknown / empty persona.
    static func works(for personaID: String) -> [PersonaWork] {
        switch personaID {
        case "legal":         return legal
        case "investigation": return investigation
        case "journalism":    return journalism
        case "research":      return research
        default:              return general
        }
    }

    // MARK: - Per-persona work

    private static let legal: [PersonaWork] = [
        .init(id: "legal.chronology", title: "Build a case chronology",
              subtitle: "Every dated event in order, each linked to its source.",
              icon: "calendar.day.timeline.left", action: .open(.timeline),
              extraKeywords: "timeline dates sequence"),
        .init(id: "legal.findings", title: "See what's proven vs missing",
              subtitle: "Facts by status — proven, inferred, contradicted, missing proof.",
              icon: "checkmark.seal", action: .open(.findings)),
        .init(id: "legal.contradictions", title: "Resolve contradictions",
              subtitle: "Where sources disagree — both sides kept for review.",
              icon: "checkmark.bubble", action: .open(.review),
              extraKeywords: "conflict disagree"),
        .init(id: "legal.workspace", title: "Open a case workspace",
              subtitle: "Gather evidence for a matter and export a cited work product.",
              icon: "folder.badge.gearshape", action: .open(.workspaces)),
        .init(id: "legal.ask", title: "Ask about obligations & proof",
              subtitle: "e.g. what was promised, and is there proof it was done?",
              icon: "bubble.left.and.text.bubble.right",
              action: .ask("What obligations appear in the documents and is there proof they were fulfilled?")),
        .init(id: "legal.sources", title: "Add case documents",
              subtitle: "Point the app at the folder of case files to ingest.",
              icon: "folder.badge.plus", action: .open(.sources)),
    ]

    private static let investigation: [PersonaWork] = [
        .init(id: "inv.dossier", title: "Profile a person or organization",
              subtitle: "Everything known about one entity, in one place.",
              icon: "person.text.rectangle", action: .open(.dossier)),
        .init(id: "inv.graph", title: "See who connects to whom",
              subtitle: "The relationship graph between people and organizations.",
              icon: "point.3.connected.trianglepath.dotted", action: .open(.explore),
              extraKeywords: "network connections links"),
        .init(id: "inv.timeline", title: "Full timeline of events",
              subtitle: "Who did what, when — filter by person or company.",
              icon: "calendar.day.timeline.left", action: .open(.timeline)),
        .init(id: "inv.singlesource", title: "Find single-source claims",
              subtitle: "Facts resting on one uncorroborated source.",
              icon: "checkmark.seal", action: .open(.findings),
              extraKeywords: "corroboration gaps"),
        .init(id: "inv.ask", title: "Ask who knew what, when",
              subtitle: "Trace communications and their timing.",
              icon: "bubble.left.and.text.bubble.right",
              action: .ask("Who communicated with whom, and when did each exchange happen?")),
        .init(id: "inv.sources", title: "Add sources",
              subtitle: "Ingest the folder of material to investigate.",
              icon: "folder.badge.plus", action: .open(.sources)),
    ]

    private static let journalism: [PersonaWork] = [
        .init(id: "jour.verify", title: "Verify a claim",
              subtitle: "Which statements are backed by more than one source?",
              icon: "checkmark.seal", action: .ask("Which statements are corroborated by more than one source?"),
              extraKeywords: "fact check corroborate"),
        .init(id: "jour.conflict", title: "Where sources conflict",
              subtitle: "Contradictions across the document dump, both sides shown.",
              icon: "checkmark.bubble", action: .open(.review)),
        .init(id: "jour.corroborated", title: "What's corroborated vs missing",
              subtitle: "Claims by status; what the record does and doesn't support.",
              icon: "checkmark.seal.fill", action: .open(.findings)),
        .init(id: "jour.search", title: "Search everything",
              subtitle: "Exact-phrase or meaning-based search across the dump.",
              icon: "magnifyingglass", action: .open(.search)),
        .init(id: "jour.saved", title: "Save & re-run questions",
              subtitle: "Bookmark questions to re-ask as new documents arrive.",
              icon: "bookmark", action: .open(.saved)),
        .init(id: "jour.sources", title: "Add the document dump",
              subtitle: "Ingest the leak / release / archive.",
              icon: "folder.badge.plus", action: .open(.sources)),
    ]

    private static let research: [PersonaWork] = [
        .init(id: "res.history", title: "Reconstruct a period",
              subtitle: "A readable, cited narrative built from the dated events.",
              icon: "book.closed", action: .open(.history)),
        .init(id: "res.library", title: "Browse documents & summaries",
              subtitle: "Every ingested source with its summary and distilled memory.",
              icon: "books.vertical", action: .open(.library)),
        .init(id: "res.dates", title: "Uncertain or approximate dates",
              subtitle: "Date-precision-aware timeline — honest about what's fuzzy.",
              icon: "calendar.badge.clock", action: .open(.timeline)),
        .init(id: "res.knowledge", title: "Corpus statistics",
              subtitle: "Entities, events, and how much is indexed.",
              icon: "chart.bar.doc.horizontal", action: .open(.knowledge)),
        .init(id: "res.ask", title: "Ask what's known vs inferred",
              subtitle: "Separate direct evidence from reconstruction.",
              icon: "bubble.left.and.text.bubble.right",
              action: .ask("Summarize what is known versus what is inferred about this topic.")),
        .init(id: "res.sources", title: "Add the archive",
              subtitle: "Ingest the collection to study.",
              icon: "folder.badge.plus", action: .open(.sources)),
    ]

    private static let general: [PersonaWork] = [
        .init(id: "gen.ask", title: "Ask a question",
              subtitle: "Ask in plain language; answers cite their sources.",
              icon: "bubble.left.and.text.bubble.right", action: .open(.ask)),
        .init(id: "gen.search", title: "Search my documents",
              subtitle: "Find exact words or by meaning.",
              icon: "magnifyingglass", action: .open(.search)),
        .init(id: "gen.sources", title: "Add documents",
              subtitle: "Point the app at a folder to ingest.",
              icon: "folder.badge.plus", action: .open(.sources)),
        .init(id: "gen.timeline", title: "See my timeline",
              subtitle: "Everything dated, in order.",
              icon: "calendar.day.timeline.left", action: .open(.timeline)),
        .init(id: "gen.knowledge", title: "Browse what was found",
              subtitle: "People, companies, and topics extracted from your files.",
              icon: "books.vertical", action: .open(.knowledge)),
        .init(id: "gen.answers", title: "Review past answers",
              subtitle: "Every answer with its evidence, replayable.",
              icon: "text.bubble", action: .open(.answers)),
    ]
}
