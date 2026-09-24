//
//  FixedPointCheck.swift
//  Kalsmritikosh
//
//  D-1 — THE FIXED-POINT LAW, checked against the live archive.
//
//  The law: every derived-data producer is idempotent, so running the whole
//  chain a second time on an unchanged ledger must change NOTHING. It matters
//  because the alternative is a ledger that drifts every launch — counts that
//  grow without new documents, facts that duplicate, topics that multiply. That
//  is not hypothetical here: the topic layer once grew 92 → 143 because a
//  rebuild appended instead of replacing, and four separate producers were each
//  found writing on every boot until their frontiers were drained in one pass.
//
//  `DoubleBootZeroWriteTests` already pins this for the producers a fixture
//  database can drive directly. What it CANNOT do is the thing that matters to
//  the owner: prove the property on THEIR archive, at its real size, with their
//  modules and their data shapes. A unit test over a two-document fixture and a
//  40,000-document archive exercise different code paths in the frontier
//  queries, and the drift found so far has always appeared at scale first.
//
//  HOW IT AVOIDS BLAMING LEGITIMATE FIRST-TIME WORK. The claim is about a
//  SECOND run, so the check runs the chain THREE times and compares only run 2
//  against run 3:
//
//    run 1 — settle. May legitimately do work: a frontier that has never
//            drained, a document class never stamped, an induction attempt
//            never made. Its writes prove nothing either way and are ignored.
//    run 2 — fingerprint after.
//    run 3 — fingerprint after. ANY DIFFERENCE IS THE VIOLATION.
//
//  Comparing run 1 to run 2 instead would report every archive with pending
//  work as broken, which is how a correct check gets ignored.
//
//  ⚠️ THIS ONE WRITES. Every other diagnostic in this app is read-only; this
//  cannot be, because the property under test is a property of writing. If a
//  producer is NOT idempotent, running this will have changed the ledger — that
//  is inseparable from the finding, and it is stated in the report and at the
//  button rather than buried. Nothing here deletes sources or evidence: the
//  passes it runs are the same ones every launch runs.
//

import Foundation
import os

public enum FixedPointCheck {

    /// One table's identity at a point in time.
    ///
    /// A row COUNT alone is not enough: a pass that deletes one row and inserts
    /// another leaves the count identical while having rewritten the ledger, and
    /// that is precisely the drift shape the topic rebuild had. So where a table
    /// has a TEXT `id`, the fingerprint also hashes its sorted ids.
    public struct TableFingerprint: Sendable, Equatable {
        public let table: String
        public let rowCount: Int
        /// nil when the table has no `id` column, or is larger than the hashing
        /// budget. A nil hash is reported as count-only rather than silently
        /// treated as "matches" — a weaker check must say it is weaker.
        public let idHash: Int?
        public let hashSkippedReason: String?

        public func differs(from other: TableFingerprint) -> Bool {
            if rowCount != other.rowCount { return true }
            if let a = idHash, let b = other.idHash { return a != b }
            return false
        }
    }

    public struct Change: Sendable {
        public let table: String
        public let before: TableFingerprint
        public let after: TableFingerprint

        public var describe: String {
            if before.rowCount != after.rowCount {
                let delta = after.rowCount - before.rowCount
                return "\(before.rowCount) → \(after.rowCount) rows (\(delta > 0 ? "+" : "")\(delta))"
            }
            return "\(before.rowCount) rows unchanged, but the ROW IDENTITIES changed — "
                 + "rows were replaced, not added"
        }
    }

    public struct Result: Sendable {
        public let reportURL: URL
        public let changes: [Change]
        public let tablesChecked: Int
        public let countOnlyTables: Int
        public let inductionRan: Bool

        public var holds: Bool { changes.isEmpty }

        public var summary: String {
            if holds {
                var s = "✓ Fixed point HOLDS — a second run of every pass changed nothing"
                s += "\n\(tablesChecked) tables compared"
                if countOnlyTables > 0 {
                    s += " (\(countOnlyTables) by row count only — a weaker check)"
                }
                return s
            }
            return "⚠️ FIXED POINT VIOLATED — \(changes.count) table(s) changed on an "
                 + "unchanged ledger\n"
                 + changes.prefix(4).map { "  \($0.table): \($0.describe)" }.joined(separator: "\n")
        }
    }

    /// Tables whose ids are hashed only up to this many rows. Above it the
    /// fingerprint is count-only: the `group_concat` needed to hash a
    /// million-row table would cost more than the check is worth, and a
    /// diagnostic that hangs is a diagnostic nobody runs.
    public nonisolated static let idHashRowBudget = 50_000

    // MARK: - Run

    @MainActor
    public static func run(_ state: AppState) async throws -> Result {
        guard let database = state.database,
              let objects = state.objects,
              let entities = state.entities,
              let events = state.events,
              let facts = state.genericFacts,
              let evidence = state.evidenceStore
        else {
            throw NSError(domain: "FixedPointCheck", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "AppState is not booted."])
        }

        let tables = await derivedTables(database)
        guard !tables.isEmpty else {
            throw NSError(domain: "FixedPointCheck", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Could not list the database's tables."])
        }

        // Induction is the one pass whose SECOND run is guaranteed silent by a
        // ledger rather than by determinism (v132 attempt rows). Noting whether
        // it ran at all lets the report say so, instead of the reader having to
        // wonder whether a clean result was clean because nothing happened.
        let attemptsBefore = (try? await database.query(
            "SELECT COUNT(*) FROM induced_schema_attempts;", []).first?.int(0)) ?? 0

        // run 1 — settle. Its writes are expected and ignored.
        await runEveryPass(state, database: database, objects: objects, entities: entities,
                           events: events, facts: facts, evidence: evidence)
        // run 2 — the baseline the law is about.
        await runEveryPass(state, database: database, objects: objects, entities: entities,
                           events: events, facts: facts, evidence: evidence)
        let before = await fingerprintAll(database, tables: tables)
        // run 3 — must change nothing.
        await runEveryPass(state, database: database, objects: objects, entities: entities,
                           events: events, facts: facts, evidence: evidence)
        let after = await fingerprintAll(database, tables: tables)

        let attemptsAfter = (try? await database.query(
            "SELECT COUNT(*) FROM induced_schema_attempts;", []).first?.int(0)) ?? 0

        var changes: [Change] = []
        for (table, b) in before.sorted(by: { $0.key < $1.key }) {
            guard let a = after[table] else { continue }
            if b.differs(from: a) { changes.append(Change(table: table, before: b, after: a)) }
        }

        let countOnly = before.values.filter { $0.idHash == nil }.count
        let result = Result(
            reportURL: try write(render(changes: changes, before: before, after: after,
                                        countOnly: countOnly,
                                        inductionRan: (attemptsAfter ?? 0) > (attemptsBefore ?? 0))),
            changes: changes,
            tablesChecked: before.count,
            countOnlyTables: countOnly,
            inductionRan: (attemptsAfter ?? 0) > (attemptsBefore ?? 0))

        if result.holds {
            KalsmritikoshLog.app.info("FixedPointCheck: HOLDS across \(before.count, privacy: .public) table(s)")
        } else {
            KalsmritikoshLog.app.fault("FixedPointCheck: VIOLATED — \(changes.count, privacy: .public) table(s) changed on an unchanged ledger: \(changes.map(\.table).joined(separator: ", "), privacy: .public)")
        }
        return result
    }

    /// Every derived-data pass a launch performs, in the launch's own order.
    ///
    /// Kept deliberately parallel to AppState's boot maintenance block: if the
    /// two drift, this check stops testing what actually runs. The drain is
    /// included because it is the biggest writer of all and its own header
    /// claims "a second run is a no-op by construction" — a claim worth
    /// checking rather than trusting.
    @MainActor
    private static func runEveryPass(
        _ state: AppState, database: Database, objects: KnowledgeObjectRepository,
        entities: EntitiesRepository, events: EventsRepository,
        facts: GenericFactRepository, evidence: EvidenceStore
    ) async {
        do {
            // No capability registry ⇒ no inducer, which is the same state the
            // drain runs in at boot when the registry is absent. Failing the
            // whole check instead would withhold the twelve other producers'
            // result over one optional pass.
            let inducer = state.capabilities.map { InducedSchemaExtractor(capabilities: $0) }
            let drain = LedgerDrainCoordinator(
                database: database, objects: objects, entities: entities, events: events,
                facts: facts, evidence: evidence,
                inducer: inducer,
                inductionAttempts: inducer == nil
                    ? nil : InducedSchemaAttemptRepository(database: database))
            _ = try await drain.drain()
            _ = try await ChunkReindexCoordinator(database: database).run()
            _ = try await TermSalienceComputer(database: database).run()
            _ = try await TopicTreeBuilder(database: database).run()
            // Same frontier-draining loops as boot: a per-pass BUDGET means the
            // producer writes until its frontier empties. Without looping here,
            // run 3 would legitimately continue draining and be misreported as
            // a violation — the budget, not the producer, would be the culprit.
            while (try await EntityPlausibilityTwin(database: database)
                .runOnce(gate: EntityQualityGate.bundled()).scanned) > 0 {}
            while (try await EventRecordTwin(database: database).runOnce()
                .documentsExamined) > 0 {}
        } catch {
            // A pass that THREW leaves the comparison meaningless rather than
            // clean, so it is logged loudly. It is not swallowed into a pass.
            KalsmritikoshLog.app.error(
                "FixedPointCheck: a maintenance pass threw — the comparison that follows is unreliable: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Fingerprinting

    /// Real tables, excluding sqlite internals, FTS shadow tables and the
    /// migration-scratch copies a table rebuild leaves behind.
    private static func derivedTables(_ db: Database) async -> [String] {
        guard let rows = try? await db.query("""
            SELECT name FROM sqlite_master
            WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE '%_fts%'
            ORDER BY name;
            """, []) else { return [] }
        return rows.compactMap { $0.string(0) }
            .filter { !$0.contains("__v") && !$0.hasSuffix("_old") }
    }

    private static func fingerprintAll(
        _ db: Database, tables: [String]
    ) async -> [String: TableFingerprint] {
        var out: [String: TableFingerprint] = [:]
        for t in tables {
            guard let countRows = try? await db.query("SELECT COUNT(*) FROM \"\(t)\";", []) else {
                continue   // unreadable table: omitted, never recorded as empty
            }
            let count = Int(countRows.first?.int(0) ?? 0)

            var hash: Int?
            var skipped: String?
            if count > idHashRowBudget {
                skipped = "over \(idHashRowBudget) rows — row count only"
            } else if let idRows = try? await db.query("""
                SELECT group_concat(id, '|') FROM (SELECT id FROM "\(t)" ORDER BY id);
                """, []), let joined = idRows.first?.string(0) {
                hash = joined.hashValue
            } else {
                // No `id` column (join tables, keyed tables). Row count is the
                // only signal available and the report says so.
                skipped = "no single `id` column — row count only"
            }
            out[t] = TableFingerprint(table: t, rowCount: count,
                                      idHash: hash, hashSkippedReason: skipped)
        }
        return out
    }

    // MARK: - Report

    private static func render(
        changes: [Change], before: [String: TableFingerprint],
        after: [String: TableFingerprint], countOnly: Int, inductionRan: Bool
    ) -> String {
        var md = "# Fixed-Point Check — does a second run change anything?\n\n"
        md += "Generated: \(Date().formatted(date: .abbreviated, time: .standard))\n"
        md += "Build `\(BuildIdentity.gitSHA)` · schema v\(SchemaMigrations.latestVersion)\n\n"
        md += "Every derived-data pass was run THREE times. Run 1 settles anything\n"
        md += "genuinely pending; only run 2 and run 3 are compared, so an archive with\n"
        md += "work outstanding is not reported as broken.\n\n"
        md += "⚠️ This check WRITES. It is the one diagnostic here that must, because\n"
        md += "the property being tested is a property of writing. If a producer is not\n"
        md += "idempotent, running this has changed your ledger — that is inseparable\n"
        md += "from the finding. No source or evidence is touched; the passes are the\n"
        md += "same ones every launch runs.\n\n"

        if changes.isEmpty {
            md += "## ✓ The fixed point holds\n\n"
            md += "\(before.count) table(s) compared; none changed between the second and\n"
            md += "third run. Your ledger does not drift on relaunch.\n\n"
            if countOnly > 0 {
                md += "**A weaker check for \(countOnly) of them.** Those tables were compared by\n"
                md += "ROW COUNT ONLY — they have no single `id` column, or they exceed the\n"
                md += "hashing budget. A pass that deleted one row and inserted another would\n"
                md += "not be caught in those. Stated because a partial check should not be\n"
                md += "read as a complete one.\n\n"
            }
        } else {
            md += "## ⚠️ The fixed point is VIOLATED\n\n"
            md += "\(changes.count) table(s) changed between two runs over an unchanged\n"
            md += "ledger. Each is a producer that writes every time it runs, which means\n"
            md += "this data grows or churns on every launch without new documents.\n\n"
            md += "| table | what changed |\n|---|---|\n"
            for c in changes { md += "| `\(c.table)` | \(c.describe) |\n" }
            md += "\n"
            md += "Note the second shape: a table whose row COUNT is stable while its row\n"
            md += "IDENTITIES change is being rewritten rather than appended to. That is\n"
            md += "the harder defect to see — every count on every dashboard looks correct\n"
            md += "while ids churn underneath, breaking anything that stored a reference.\n\n"
        }

        md += "## Induction\n\n"
        md += inductionRan
            ? "Schema induction DID attempt work during this check, and its attempt rows "
            + "were written. Those attempts are what make its second run silent, so a "
            + "clean result above is meaningful rather than a consequence of nothing "
            + "having happened.\n\n"
            : "Schema induction attempted nothing during this check — it is switched off, "
            + "or every candidate document had already been attempted. So this run says "
            + "nothing either way about induction's idempotence.\n\n"

        md += "## What this does NOT tell you\n\n"
        md += "- **That the derived data is CORRECT.** Stability and correctness are\n"
        md += "  different properties: a producer that consistently writes the same wrong\n"
        md += "  answer passes this check perfectly.\n"
        md += "- **Anything about tables compared by row count only** beyond their size.\n"
        md += "- **That the passes it ran are all of them.** This mirrors the launch\n"
        md += "  maintenance block; a producer added there and not here would go\n"
        md += "  unchecked.\n"
        return md
    }

    private static func write(_ md: String) throws -> URL {
        let documentsDir = try FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let reportDir = documentsDir.appendingPathComponent("EvalBaselines", isDirectory: true)
        try? FileManager.default.createDirectory(at: reportDir, withIntermediateDirectories: true)
        let url = reportDir.appendingPathComponent("fixed-point-check.md", isDirectory: false)
        try md.data(using: .utf8)?.write(to: url, options: .atomic)
        return url
    }
}
