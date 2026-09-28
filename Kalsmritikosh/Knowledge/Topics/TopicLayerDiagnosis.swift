//
//  TopicLayerDiagnosis.swift
//  Kalsmritikosh
//
//  B-1 — WHY is the topic layer empty?
//
//  An empty topic layer is the single most misleading state this app can be in.
//  The user sees no topics and concludes the product does not work. In fact
//  there are at least seven distinct causes, and they demand completely
//  different responses:
//
//    1. nothing is ingested yet                      → ingest something
//    2. no entities were recognised                  → extraction problem
//    3. the community detector has not run            → wait, or rebuild
//    4. every document is a singleton — no shared     → CORRECT BEHAVIOUR, and
//       terms, so nothing legitimately groups            nothing to fix
//    5. document_terms has no corroborated terms      → the salience pass has
//       (the level-1 builder's only signal)              not run
//    6. the tree built but nothing was labelled       → labels failed
//    7. `autoTopics` is switched off                  → a setting, not a fault
//
//  `TopicTreeBuilder.run()` returns a Receipt of zeros and exits at
//  `guard !members.isEmpty` without saying which of these happened. That guard
//  is correct — there is genuinely nothing to build — but the SILENCE is the
//  defect. A receipt of zeros is indistinguishable across causes 1, 2, 3 and 4,
//  and one of those four is the app working exactly as intended.
//
//  So this walks the chain of preconditions IN DEPENDENCY ORDER and reports the
//  FIRST link that is missing. Order matters: without it, a diagnosis would
//  report five simultaneous problems when there is one cause and four
//  consequences, which is how a report becomes noise the user learns to ignore.
//
//  Read-only. Touches nothing, rebuilds nothing.
//

import Foundation
import os

public struct TopicLayerDiagnosis: Sendable {

    /// The links, as a closed set. An enum rather than free strings because the
    /// UI needs to branch on WHICH link failed — the Library only offers "Add
    /// your files" when adding files is genuinely the answer — and comparing a
    /// display name to a string literal at the call site is a coupling that
    /// breaks silently the first time the wording is improved.
    public enum LinkID: String, Sendable, CaseIterable {
        case autoBuildSetting
        case documents
        case entities
        case levelZeroGroups
        case sharedTerms
        case levelOneTopics
        case labels

        public var displayName: String {
            switch self {
            case .autoBuildSetting: return "auto-build setting"
            case .documents:        return "documents"
            case .entities:         return "entities"
            case .levelZeroGroups:  return "groups (level 0)"
            case .sharedTerms:      return "shared terms"
            case .levelOneTopics:   return "topics (level 1)"
            case .labels:           return "topic names"
            }
        }
    }

    public struct Link: Sendable {
        public let id: LinkID
        public let outcome: PipelineStageOutcome
        /// What the user should do when THIS is the first missing link. Empty
        /// when the link is populated, or when the honest answer is "nothing".
        public let remedy: String

        public var name: String { id.displayName }
    }

    public let links: [Link]
    /// The first missing link — the CAUSE. Everything after it is consequence.
    public let firstMissing: Link?
    /// True when the layer is legitimately empty and no action is warranted.
    /// Distinguished from a defect because telling a user to fix correct
    /// behaviour is worse than saying nothing.
    public let emptyButCorrect: Bool

    public var headline: String {
        if let firstMissing {
            if emptyButCorrect {
                return "No topics — and that is correct here: \(firstMissing.name)"
            }
            return "No topics — the chain stops at “\(firstMissing.name)”"
        }
        return "Topics are built and labelled"
    }

    public func renderLines() -> String {
        var out = "TOPIC LAYER\n  \(headline)\n"
        for l in links {
            out += "  \(l.outcome.symbol) \(l.name): \(l.outcome.line)\n"
        }
        if let firstMissing, !firstMissing.remedy.isEmpty {
            out += "\n  WHAT TO DO: \(firstMissing.remedy)\n"
        }
        return out
    }

    // MARK: - Build

    public static func run(database: Database) async -> TopicLayerDiagnosis {
        var links: [Link] = []
        func add(_ id: LinkID, _ outcome: PipelineStageOutcome, remedy: String = "") {
            links.append(Link(id: id, outcome: outcome, remedy: remedy))
        }
        /// nil means the probe FAILED — never folded into zero.
        func scalar(_ sql: String) async -> Int? {
            guard let rows = try? await database.query(sql, []) else { return nil }
            return Int(rows.first?.int(0) ?? 0)
        }

        // ── 0. the setting, first, because it is not a fault ─────────────────
        let autoOn = KnowledgeModuleFlags.isEnabled(.autoTopics)
        add(.autoBuildSetting, autoOn
            ? .present(count: 1, detail: "topics rebuild automatically while the Mac is idle")
            : .absentExpected(reason: "“Auto-build topics” is switched OFF, so topics only change when rebuilt by hand. Nothing is broken"),
            remedy: autoOn ? "" : "Turn on “Auto-build topics” in Settings → Modules, or rebuild topics manually.")

        // ── 1. documents ─────────────────────────────────────────────────────
        guard let docs = await scalar("SELECT COUNT(*) FROM knowledge_objects;") else {
            add(.documents, .couldNotCheck(why: "the document count query failed"),
                remedy: "The database could not be read. Check the Ingestion Report for database errors.")
            return finish(links)
        }
        guard docs > 0 else {
            add(.documents, .absentExpected(reason: "nothing is ingested yet, so there is nothing to group"),
                remedy: "Add a folder in Sources. Topics appear after the first ingest completes.")
            return finish(links, emptyButCorrect: true)
        }
        add(.documents, .present(count: docs, detail: "ingested documents"))

        // ── 2. entities — topics group ENTITIES, not documents ───────────────
        guard let entities = await scalar(
            "SELECT COUNT(*) FROM entities WHERE merged_into IS NULL;") else {
            add(.entities, .couldNotCheck(why: "the entity count query failed"))
            return finish(links)
        }
        guard entities > 0 else {
            add(.entities, .absentUnexpected(reason: "\(docs) document(s) are ingested but NO named things were recognised in any of them. Topics group entities, so there is nothing to group"),
                remedy: "This is an extraction gap, not a topic problem. Check the Ingestion Report's language section — extraction is English-only in this version — and its failure section for parse errors.")
            return finish(links)
        }
        add(.entities, .present(count: entities, detail: "named things"))

        // ── 3. level-0 communities (the detector's output) ───────────────────
        guard let levelZero = await scalar(
            "SELECT COUNT(DISTINCT community_id) FROM entity_communities WHERE level = 0;") else {
            add(.levelZeroGroups, .couldNotCheck(why: "the community query failed"))
            return finish(links)
        }
        guard levelZero > 0 else {
            add(.levelZeroGroups, .absentUnexpected(reason: "\(entities) entities exist but none were grouped. The community detector has not run, or every insert it attempted failed"),
                remedy: "Restart the app and let the background passes finish — the detector runs at boot. If it stays empty, the log (subsystem ecosanskritiinnovation.Kalsmritikosh, category knowledge) records insert failures with their reason.")
            return finish(links)
        }
        add(.levelZeroGroups, .present(count: levelZero, detail: "entity groups the detector found"))

        // ── 4. corroborated terms — the ONLY signal level-1 nesting has ──────
        //
        // TopicTreeBuilder joins two level-0 nodes when they share an anchor or
        // ≥3 terms with corroboration ≥ 2. With no corroborated terms it can
        // still run and will simply nest nothing — a real, silent dead end.
        guard let corroborated = await scalar(
            "SELECT COUNT(*) FROM document_terms WHERE corroboration >= 2;") else {
            add(.sharedTerms, .couldNotCheck(why: "the document_terms query failed"))
            return finish(links)
        }
        if corroborated == 0 {
            if docs == 1 {
                add(.sharedTerms, .absentExpected(reason: "a term is “corroborated” when it appears in at least two documents, and there is only one document"),
                    remedy: "Add more documents. Grouping needs at least two that share vocabulary.")
                return finish(links, emptyButCorrect: true)
            }
            add(.sharedTerms, .absentUnexpected(reason: "no term appears in two or more documents with enough weight to link them. Either the term-salience pass has not run, or these documents genuinely share no vocabulary"),
                remedy: "Restart the app so the term-salience pass runs. If it stays at zero and your documents are genuinely unrelated to each other, no grouping is possible and that is the correct result.")
            return finish(links)
        }
        add(.sharedTerms, .present(count: corroborated, detail: "terms shared across documents"))

        // ── 5. level-1 parents (the tree) ────────────────────────────────────
        guard let levelOne = await scalar(
            "SELECT COUNT(DISTINCT community_id) FROM entity_communities WHERE level = 1;") else {
            add(.levelOneTopics, .couldNotCheck(why: "the level-1 query failed"))
            return finish(links)
        }
        if levelOne == 0 {
            // NOT a defect. One parent per group means no group shared enough
            // with another to justify nesting, and inventing a parent anyway
            // would be a fabricated topic.
            add(.levelOneTopics, .absentExpected(reason: "the \(levelZero) group(s) did not overlap enough to nest under shared parents. Each stands alone, which is the honest outcome — a parent topic invented over unrelated groups would be a fiction"),
                remedy: "")
            return finish(links, emptyButCorrect: true)
        }
        add(.levelOneTopics, .present(count: levelOne, detail: "parent topics over those groups"))

        // ── 6. labels — an unlabelled topic is unusable even when it exists ──
        guard let labels = await scalar("SELECT COUNT(*) FROM community_summaries;") else {
            add(.labels, .couldNotCheck(why: "the label query failed"))
            return finish(links)
        }
        add(.labels, labels > 0
            ? .present(count: labels, detail: "named topics")
            : .absentUnexpected(reason: "\(levelZero + levelOne) topic node(s) exist with NO names. They cannot be shown or chosen, so the layer is effectively empty from the user's side even though the rows are there"),
            remedy: labels > 0 ? "" : "Rebuild topics. If names stay empty, labelling is failing — the knowledge log records the reason.")

        return finish(links)
    }

    private static func finish(_ links: [Link], emptyButCorrect: Bool = false) -> TopicLayerDiagnosis {
        // The cause is the first link that is NOT populated — including
        // `couldNotCheck`, because an unverified link cannot be treated as
        // satisfied just for being unproven.
        let firstMissing = links.first { !$0.outcome.isPopulated }
        return TopicLayerDiagnosis(links: links, firstMissing: firstMissing,
                                   emptyButCorrect: emptyButCorrect)
    }
}
