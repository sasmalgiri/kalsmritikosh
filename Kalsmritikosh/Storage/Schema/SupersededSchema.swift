//
//  SupersededSchema.swift
//  Kalsmritikosh
//
//  S-0b / T1 — the tables that have NO producer ON PURPOSE, and the invariant
//  that keeps it that way.
//
//  THE PROBLEM THIS SOLVES IS A FUTURE MISTAKE, including my own. The generated
//  PIPELINE_MATRIX lists six tables nothing writes. Read cold, that is an
//  obvious gap and the obvious response is to go and write a producer for each.
//  For four of them that response would be a serious defect: it would create a
//  SECOND source of truth for data the universal model already holds, breaking
//  the one-ledger invariant, and it would cost ingest-time writes for rows
//  nothing reads.
//
//  WHY THEY ARE SUPERSEDED, verified by reading the call sites rather than
//  assumed from their names:
//
//    people / companies / projects
//        The People, Companies and Projects surfaces the user actually sees are
//        `KnowledgeView` tabs, and each is a `KnowledgeListView(kind:)` served
//        by `entities.list(kind:)` — the canonical entity register, keyed by
//        `Entity.Kind`. The typed tables are the pre-universal shape of exactly
//        the same idea. Writing them would duplicate the register that already
//        backs the working UI.
//
//    timelines
//        Declared as "named views over events; the engine builds these on read"
//        — by its own schema comment, a cache for something computed. `events`
//        plus `event_entities` is the source, and the History/timeline surfaces
//        read those.
//
//  DELIBERATELY NOT IN THIS LIST:
//
//    vectors — no writer, but a migration READS it to backfill
//        chunk_embeddings. That is a legacy source kept on purpose, not dead
//        schema, and it must not be mistaken for either.
//    evidence_block_edges — declared and genuinely unused. It is NOT recorded
//        as superseded, because nothing replaced it; it is an unbuilt feature
//        (block-to-block relationships). Calling it "superseded" would claim a
//        replacement exists and quietly retire the idea.
//
//  THE OWNER'S RULING WAS "KEEP ALL 5 — NOTHING IS REMOVED", so no table is
//  dropped here and no migration is edited. What changes is that the state
//  becomes CHECKED instead of merely true: `unexpectedlyPopulated` fails if a
//  row ever appears. A row in one of these means someone has started writing a
//  parallel truth, and finding that out the moment it happens is worth far more
//  than a comment nobody reads.
//

import Foundation

public enum SupersededSchema {

    public struct Entry: Sendable {
        public let table: String
        /// What holds this data now. Named concretely so the claim is checkable.
        public let supersededBy: String
        /// The surface that reads the replacement — the evidence that the
        /// replacement is genuinely live and this table is genuinely redundant.
        public let liveConsumer: String
    }

    /// Tables kept for compatibility whose data lives elsewhere now.
    public nonisolated static let entries: [Entry] = [
        Entry(table: "people",
              supersededBy: "entities (kind = .person) + entity_aliases",
              liveConsumer: "KnowledgeView → KnowledgeListView(kind: .person) → entities.list(kind:)"),
        Entry(table: "companies",
              supersededBy: "entities (kind = .organization) + entity_aliases",
              liveConsumer: "KnowledgeView → KnowledgeListView(kind: .organization)"),
        Entry(table: "projects",
              supersededBy: "entities (kind = .project) + entity_aliases",
              liveConsumer: "KnowledgeView → KnowledgeListView(kind: .project)"),
        Entry(table: "timelines",
              supersededBy: "events + event_entities, composed on read",
              liveConsumer: "History / timeline surfaces read events directly"),
    ]

    public nonisolated static var tableNames: Set<String> { Set(entries.map(\.table)) }

    /// Superseded tables that are NOT empty — each one a second source of truth
    /// that has started to exist.
    ///
    /// Returns `nil` for a table whose count could not be read, and those are
    /// reported separately by the caller: an unreadable table is not a verified
    /// empty one, which is the distinction this codebase keeps having to
    /// re-learn.
    public nonisolated static func unexpectedlyPopulated(
        database: Database
    ) async -> (populated: [(table: String, rows: Int)], unreadable: [String]) {
        var populated: [(table: String, rows: Int)] = []
        var unreadable: [String] = []
        for entry in entries {
            guard let rows = try? await database.query(
                "SELECT COUNT(*) FROM \"\(entry.table)\";", []) else {
                unreadable.append(entry.table)
                continue
            }
            let n = Int(rows.first?.int(0) ?? 0)
            if n > 0 { populated.append((table: entry.table, rows: n)) }
        }
        return (populated, unreadable)
    }

    /// The report section. Written so a reader meeting these in the matrix for
    /// the first time gets the reason before the temptation.
    public nonisolated static func reportSection(
        populated: [(table: String, rows: Int)], unreadable: [String]
    ) -> String {
        var md = "### Tables with no producer BY DESIGN\n\n"
        md += "These four are kept for compatibility and are intentionally empty. "
        md += "Their data lives in the universal model, and the surfaces you use "
        md += "already read it from there. Writing them would create a second "
        md += "source of truth for the same facts.\n\n"
        md += "| table | superseded by | what reads the replacement |\n|---|---|---|\n"
        for e in entries {
            md += "| `\(e.table)` | \(e.supersededBy) | \(e.liveConsumer) |\n"
        }
        md += "\n"
        if populated.isEmpty && unreadable.isEmpty {
            md += "All four verified empty.\n\n"
        }
        if !populated.isEmpty {
            md += "**⚠️ NOT EMPTY** — something has begun writing a parallel copy:\n\n"
            for p in populated { md += "- `\(p.table)`: \(p.rows) row(s)\n" }
            md += "\nThis is a one-ledger violation. Find the writer before the two "
            md += "copies disagree, because once they do there is no way to tell which "
            md += "was right.\n\n"
        }
        if !unreadable.isEmpty {
            md += "Could not be read, so NOT verified empty: "
            md += unreadable.map { "`\($0)`" }.joined(separator: ", ") + "\n\n"
        }
        return md
    }
}
