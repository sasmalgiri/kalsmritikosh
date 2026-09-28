//
//  GoldenThread.swift
//  Kalsmritikosh
//
//  A-1 — ONE document, traced through every stage, ending at a citation.
//
//  WHY THIS IS NOT THE OTHER TWO REPORTS. DataHealthCheck answers "is the
//  archive healthy?" with aggregate counts. KnowledgeInventory answers "did we
//  extract the right things from each file?" by pairing source against output.
//  Neither answers the question a broken pipeline actually poses: WHERE did this
//  document stop?
//
//  That question is unanswerable from aggregates. An archive can report 4,000
//  chunks, 12,000 entities and 900 facts while a particular document contributed
//  nothing past stage three — and every one of those totals still looks healthy.
//  The failure is invisible precisely because the numbers are large. A per-stage
//  walk of a SINGLE document is the only shape that can localise it.
//
//  THE THREAD RUNS PAST THE LEDGER ON PURPOSE. The last two stages are a live
//  retrieval probe and a citation resolve. Everything before them proves rows
//  exist; only those two prove the document is REACHABLE and QUOTABLE. A
//  document can be fully ingested, fully derived, and still never surface in an
//  answer — dropped by a retrieval gate, or holding a block id that no longer
//  resolves. Stopping the trace at "facts exist" would certify a document that
//  the user can never actually get an answer out of, which is the whole product.
//
//  EVERY STAGE MUST SAY ONE OF THREE THINGS, never two. `.present` with a
//  count, `.absentExpected` with the reason it is legitimately empty, or
//  `.absentUnexpected` — a defect. There is deliberately no bare "0": a zero
//  that cannot say which of those it is has been the recurring defect in this
//  codebase, and a trace built out of bare zeroes would reproduce it per-stage.
//  A probe that could not RUN reports `.couldNotCheck`, which is not a pass.
//
//  Read-only. Runs against the live database.
//

import Foundation
import os

public enum GoldenThread {

    /// The four outcomes a stage may report — see PipelineStageOutcome for why
    /// there are four and not two. Aliased rather than redeclared so this trace
    /// and the topic-layer diagnosis cannot drift apart on what "empty" means.
    public typealias StageOutcome = PipelineStageOutcome

    public struct Stage: Sendable {
        public let name: String
        public let outcome: StageOutcome
    }

    public struct Result: Sendable {
        public let reportURL: URL
        public let documentPath: String
        public let stages: [Stage]
        /// The first stage that is a defect — where the thread BROKE. nil when
        /// the thread runs end to end.
        public let brokeAt: String?
        public let defects: Int
        public let unknowns: Int

        public var summary: String {
            let chain = stages.map { "\($0.outcome.symbol)\($0.name)" }.joined(separator: " → ")
            if let brokeAt {
                return "Thread BROKE at \(brokeAt)\n\(chain)\n\(defects) defect(s), \(unknowns) unchecked"
            }
            if unknowns > 0 {
                return "Thread complete, but \(unknowns) stage(s) could not be checked\n\(chain)"
            }
            return "Thread COMPLETE — file → citation\n\(chain)"
        }
    }

    // MARK: - Run

    /// Trace one document. `match` is a case-insensitive substring of the source
    /// path; the FIRST match in a stable order is traced, so re-running names the
    /// same document. Passing nil traces the most recently created document,
    /// which is the one an owner has just watched arrive.
    @MainActor
    public static func trace(_ state: AppState, matching match: String? = nil) async throws -> Result {
        guard let database = state.database,
              let chunks = state.chunks,
              let evidence = state.evidenceStore
        else {
            throw NSError(domain: "GoldenThread", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "AppState is not booted — nothing to trace."])
        }

        // ── Pick the document ────────────────────────────────────────────────
        guard let koRow = try await selectDocument(database: database, matching: match) else {
            throw NSError(domain: "GoldenThread", code: 2, userInfo: [
                NSLocalizedDescriptionKey: match.map {
                    "No ingested document matches “\($0)”. Note this means no KNOWLEDGE OBJECT matches — the file may have been seen and failed to parse, which the Ingestion Report's failure section would show."
                } ?? "No documents are ingested yet."])
        }

        var stages: [Stage] = []
        func add(_ name: String, _ outcome: StageOutcome) {
            stages.append(Stage(name: name, outcome: outcome))
        }

        // ── 1. FILE ──────────────────────────────────────────────────────────
        if let rows = try? await database.query("""
           SELECT COUNT(*) FROM files f
           JOIN knowledge_objects k ON k.file_id = f.id WHERE k.id = ?;
           """, [.uuid(koRow.id)]) {
            let n = Int(rows.first?.int(0) ?? 0)
            add("file", n > 0
                ? .present(count: n, detail: "the source file row this document came from")
                : .absentUnexpected(reason: "this document has no file row — it cannot be re-read, re-ingested, or shown in Sources"))
        } else {
            add("file", .couldNotCheck(why: "the files/knowledge_objects join failed"))
        }

        // ── 2. SOURCE VERSION + 3. EVIDENCE BLOCKS ───────────────────────────
        var blockIDs: [UUID] = []
        var blockText = ""
        // do/catch rather than `try?`: `try?` on a function returning `UUID?`
        // FLATTENS to `UUID?`, which would merge "the lookup threw" into "there
        // is no version". Those are a broken check and a broken document
        // respectively, and the whole point of this trace is not to conflate
        // them.
        do {
            let maybeVersion = try await evidence.currentVersionID(forObject: koRow.id)
            if let versionID = maybeVersion {
                add("version", .present(count: 1, detail: "content version `\(versionID.uuidString.prefix(8))`"))
                if let blocks = try? await evidence.blocks(forVersion: versionID) {
                    blockIDs = blocks.map { $0.id }
                    blockText = blocks
                        .map { $0.normalizedText.isEmpty ? $0.rawText : $0.normalizedText }
                        .joined(separator: "\n")
                    let kinds = Set(blocks.map { $0.kind.rawValue }).sorted().prefix(6).joined(separator: ", ")
                    add("blocks", blocks.isEmpty
                        ? .absentUnexpected(reason: "the parser produced no located blocks, so nothing in this document can be cited to a place")
                        : .present(count: blocks.count, detail: "kinds: \(kinds)"))
                } else {
                    add("blocks", .couldNotCheck(why: "the block query failed"))
                }
            } else {
                add("version", .absentUnexpected(reason: "no current source version — the document is not bound to any content, so blocks and citations cannot resolve"))
                add("blocks", .absentUnexpected(reason: "unreachable without a source version"))
            }
        } catch {
            add("version", .couldNotCheck(why: "the version lookup threw: \(error)"))
            add("blocks", .couldNotCheck(why: "unreachable without a source version"))
        }

        // ── 4. DERIVATION COMPLETE (P1.3) ────────────────────────────────────
        if let rows = try? await database.query(
            "SELECT derivation_complete FROM knowledge_objects WHERE id = ?;", [.uuid(koRow.id)]) {
            let raw = rows.first?.int(0)
            switch raw {
            case .some(1):
                add("derived", .present(count: 1, detail: "every derivation stage returned"))
            case .none:
                add("derived", .absentExpected(reason: "this document was derived before the completeness marker existed, so its completeness is genuinely unknown — not a defect, and not a pass"))
            default:
                add("derived", .absentUnexpected(reason: "derivation did not finish — part of this document's ledger is missing and a re-ingest would resume it"))
            }
        } else {
            add("derived", .couldNotCheck(why: "the derivation_complete read failed"))
        }

        // ── 5. CHUNKS ────────────────────────────────────────────────────────
        var chunkIDs: [UUID] = []
        if let list = try? await chunks.findByObjectID(koRow.id) {
            chunkIDs = list.map { $0.id }
            add("chunks", list.isEmpty
                ? .absentUnexpected(reason: "no chunks — this document is invisible to keyword and vector search alike")
                : .present(count: list.count, detail: "searchable passages"))
        } else {
            add("chunks", .couldNotCheck(why: "the chunk query failed"))
        }

        // ── 6. EMBEDDINGS ────────────────────────────────────────────────────
        if chunkIDs.isEmpty {
            add("vectors", .absentUnexpected(reason: "unreachable — there are no chunks to embed"))
        } else if let rows = try? await database.query("""
            SELECT COUNT(DISTINCT e.chunk_id) FROM chunk_embeddings e
            JOIN chunks c ON c.id = e.chunk_id WHERE c.object_id = ?;
            """, [.uuid(koRow.id)]) {
            let n = Int(rows.first?.int(0) ?? 0)
            if n >= chunkIDs.count {
                add("vectors", .present(count: n, detail: "every chunk is embedded"))
            } else if n > 0 {
                add("vectors", .present(count: n, detail: "PARTIAL — \(chunkIDs.count - n) of \(chunkIDs.count) chunk(s) not yet embedded; the drain runs in the background"))
            } else {
                add("vectors", .absentExpected(reason: "the embedding drain has not reached this document yet. Keyword search still finds it; only similarity search is blind to it. Re-run this trace after the drain finishes"))
            }
        } else {
            add("vectors", .couldNotCheck(why: "the embedding count query failed"))
        }

        // ── 7. KEYWORD INDEX — probed, not assumed ───────────────────────────
        //
        // The FTS row count is not the check. What matters is whether a phrase
        // FROM THIS DOCUMENT finds it, which is what a user does. That
        // distinction caught a real defect once already: the index was
        // populated and the query path silently returned nothing for
        // punctuated queries.
        let probeTerm = Self.probeTerm(in: blockText)
        if let probeTerm {
            if let hits = try? await chunks.searchFTS(probeTerm, limit: 50) {
                let mine = hits.filter { $0.objectID == koRow.id }
                add("keyword", mine.isEmpty
                    ? .absentUnexpected(reason: "searching this document's own distinctive phrase “\(probeTerm)” did NOT return it — it is indexed but not findable")
                    : .present(count: mine.count, detail: "found by its own phrase “\(probeTerm)”"))
            } else {
                add("keyword", .couldNotCheck(why: "the FTS query threw for “\(probeTerm)”"))
            }
        } else {
            add("keyword", .couldNotCheck(why: "no distinctive phrase could be taken from this document's text to probe with"))
        }

        // ── 8. ENTITIES · 9. EVENTS · 10. FACTS ──────────────────────────────
        if let rows = try? await database.query(
            "SELECT COUNT(*) FROM entity_mentions WHERE source_object_id = ?;", [.uuid(koRow.id)]) {
            let n = Int(rows.first?.int(0) ?? 0)
            add("entities", n > 0
                ? .present(count: n, detail: "named things mentioned here")
                : .absentExpected(reason: "no names were recognised. Common and often correct — a spreadsheet of figures or a scanned form may genuinely name nobody"))
        } else {
            add("entities", .couldNotCheck(why: "the mention count query failed"))
        }

        if let rows = try? await database.query(
            "SELECT COUNT(*) FROM events WHERE source_object_id = ?;", [.uuid(koRow.id)]) {
            let n = Int(rows.first?.int(0) ?? 0)
            add("events", n > 0
                ? .present(count: n, detail: "dated events on the timeline")
                : .absentExpected(reason: "no dated events. Expected for an undated document; a defect only if the document does carry dates"))
        } else {
            add("events", .couldNotCheck(why: "the event count query failed"))
        }

        var factCount = 0
        if blockIDs.isEmpty {
            add("facts", .absentUnexpected(reason: "unreachable — facts hang off evidence blocks and this document has none"))
        } else if let facts = state.genericFacts {
            if let list = try? await facts.facts(forBlockIDs: blockIDs) {
                factCount = list.count
                let derivations = Set(list.compactMap { $0.derivation?.rawValue }).sorted()
                let note = derivations.isEmpty ? "read verbatim" : "including \(derivations.joined(separator: ", "))"
                add("facts", list.isEmpty
                    ? .absentExpected(reason: "no structured facts. This is the universality frontier, not necessarily a fault: if the document is not in English, or is of a kind no built-in reader covers, the Ingestion Report's language and induction sections say so")
                    : .present(count: list.count, detail: note))
            } else {
                add("facts", .couldNotCheck(why: "the fact query failed"))
            }
        } else {
            add("facts", .couldNotCheck(why: "the fact repository is not booted"))
        }

        // ── 11. RETRIEVAL — the first stage that proves REACHABILITY ─────────
        if let retriever = state.retriever, let probeTerm {
            let intent = UserIntent(kind: .semanticSearch, scope: .global, rawQuestion: probeTerm)
            do {
                let result = try await retriever.retrieve(for: intent, layers: RetrievalLayer.allCases)
                let mine = result.chunks.filter { $0.chunk.objectID == koRow.id }
                if let best = mine.max(by: { $0.score < $1.score }) {
                    add("retrieval", .present(count: mine.count,
                        detail: "surfaced via the \(best.viaLayer) layer at score \(String(format: "%.3f", best.score))"))
                } else {
                    add("retrieval", .absentUnexpected(reason: "asking this document's own distinctive phrase returned \(result.chunks.count) passage(s), NONE of them from this document. It is in the ledger but a retrieval gate is dropping it, so no answer can ever cite it"))
                }
            } catch {
                add("retrieval", .couldNotCheck(why: "retrieval threw: \(error)"))
            }
        } else if probeTerm == nil {
            add("retrieval", .couldNotCheck(why: "no probe phrase available"))
        } else {
            add("retrieval", .couldNotCheck(why: "the retriever is not booted"))
        }

        // ── 12. CITATION — the end of the thread ─────────────────────────────
        if blockIDs.isEmpty {
            add("citation", .absentUnexpected(reason: "unreachable — a citation needs a located block"))
        } else if let resolved = try? await evidence.resolveEvidenceBlocks(Array(blockIDs.prefix(8))) {
            add("citation", resolved.isEmpty
                ? .absentUnexpected(reason: "this document's block ids do NOT resolve to citable references. An answer quoting it could not show the user where the words came from")
                : .present(count: resolved.count, detail: "block(s) resolve to a citable place in the source"))
        } else {
            add("citation", .couldNotCheck(why: "citation resolution threw"))
        }

        // ── Report ───────────────────────────────────────────────────────────
        let brokeAt = stages.first(where: { $0.outcome.isDefect })?.name
        let defects = stages.filter { $0.outcome.isDefect }.count
        let unknowns = stages.filter { $0.outcome.isUnknown }.count

        var md = "# Golden Thread — one document, end to end\n\n"
        md += "Generated: \(Date().formatted(date: .abbreviated, time: .standard))\n"
        md += "Build `\(BuildIdentity.gitSHA)` · schema v\(SchemaMigrations.latestVersion)\n\n"
        md += "Document: `\(koRow.path)`\n\n"
        md += "This traces ONE document through every stage to a citation. Aggregate\n"
        md += "counts cannot localise a break: an archive can report thousands of\n"
        md += "chunks and facts while this document contributed nothing past stage\n"
        md += "three, and every total still looks healthy.\n\n"

        if let brokeAt {
            md += "## ✗ The thread breaks at **\(brokeAt)**\n\n"
            md += "Stages after the break may be empty as a consequence rather than a\n"
            md += "cause. Fix the first break, then re-run.\n\n"
        } else if unknowns > 0 {
            md += "## The thread is unbroken, but \(unknowns) stage(s) could not be checked\n\n"
            md += "An unchecked stage is NOT a pass. Treat each as unknown.\n\n"
        } else {
            md += "## ✓ The thread is unbroken — file to citation\n\n"
            md += "This document is ingested, derived, findable, retrievable and\n"
            md += "quotable. It does NOT establish that the extracted values are\n"
            md += "correct — nothing here compares a value against the document.\n\n"
        }

        md += "| | stage | what was found |\n|---|---|---|\n"
        for s in stages {
            md += "| \(s.outcome.symbol) | **\(s.name)** | \(s.outcome.line) |\n"
        }
        md += "\nLegend: ✓ present · · legitimately empty (reason given) · "
        md += "✗ defect · ? could not be checked (not a pass).\n\n"

        if factCount == 0 {
            md += "**On zero facts:** the last three stages can all pass while this\n"
            md += "document yields no structured facts. It will then answer\n"
            md += "\"where was this mentioned\" but not \"what is its reference number\".\n"
            md += "Whether that is a gap or correct depends on the document.\n\n"
        }

        let documentsDir = try FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let reportDir = documentsDir.appendingPathComponent("EvalBaselines", isDirectory: true)
        try? FileManager.default.createDirectory(at: reportDir, withIntermediateDirectories: true)
        let url = reportDir.appendingPathComponent("golden-thread.md", isDirectory: false)
        try md.data(using: .utf8)?.write(to: url, options: .atomic)

        KalsmritikoshLog.app.info("GoldenThread: \(stages.count, privacy: .public) stage(s), \(defects, privacy: .public) defect(s), \(unknowns, privacy: .public) unchecked")
        return Result(reportURL: url, documentPath: koRow.path, stages: stages,
                      brokeAt: brokeAt, defects: defects, unknowns: unknowns)
    }

    // MARK: - Document selection

    /// The document to trace, resolved to its id and its file path.
    ///
    /// Split out of `trace` so a test can execute THIS SQL — not a copy of it.
    /// That distinction is the whole reason this function exists: the first
    /// version selected `knowledge_objects.source_file`, a column that does not
    /// exist (the path lives in `files.url`, reached through `file_id`), so
    /// EVERY trace threw. The compiler cannot see it, because SQL is a string,
    /// and no unit test could see it either while the query was buried in a
    /// function that needs a booted AppState. A test asserting against a
    /// duplicated query string would have passed just as happily.
    ///
    /// Returns nil when no document matches — distinct from throwing, which
    /// means the query itself could not run.
    static func selectDocument(
        database: Database, matching match: String?
    ) async throws -> (id: UUID, path: String)? {
        let rows: [SQLRow]
        if let match, !match.trimmingCharacters(in: .whitespaces).isEmpty {
            rows = try await database.query("""
            SELECT k.id, f.url FROM knowledge_objects k
            JOIN files f ON f.id = k.file_id
            WHERE LOWER(f.url) LIKE LOWER(?)
            ORDER BY k.created_at ASC LIMIT 1;
            """, [.text("%\(match)%")])
        } else {
            rows = try await database.query("""
            SELECT k.id, f.url FROM knowledge_objects k
            JOIN files f ON f.id = k.file_id
            ORDER BY k.created_at DESC LIMIT 1;
            """, [])
        }
        guard let r = rows.first, let idStr = r.string(0),
              let id = UUID(uuidString: idStr) else { return nil }
        return (id: id, path: r.string(1) ?? "(unknown path)")
    }

    // MARK: - Probe phrase

    /// A phrase from the document distinctive enough to find it by.
    ///
    /// Picks the longest run of 3 consecutive words that are all alphanumeric
    /// and not stopwords. Three words rather than one because a single common
    /// word matches half the archive and would prove nothing, and rather than a
    /// whole sentence because a long phrase is fragile to any normalization
    /// difference between storage and query. Returns nil when the text offers
    /// nothing usable — reported as "could not check", never as a failure of the
    /// index.
    nonisolated static func probeTerm(in text: String) -> String? {
        let stop: Set<String> = [
            "the", "and", "for", "with", "this", "that", "from", "have", "has",
            "was", "were", "are", "not", "but", "you", "your", "our", "their",
            "will", "would", "shall", "any", "all", "may", "can", "such", "been",
        ]
        let words = text
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 4 && !stop.contains($0.lowercased()) }
        guard words.count >= 3 else {
            // One long word is still better than nothing — an identifier or a
            // proper name is often the most distinctive thing a document has.
            return words.max(by: { $0.count < $1.count })
        }
        // Prefer a window from the START of the document: titles and headers
        // carry the document's most identifying words, and a window from the
        // middle is more likely to be boilerplate shared with other documents.
        var best: [String] = Array(words.prefix(3))
        var bestScore = best.reduce(0) { $0 + $1.count }
        for i in 0..<max(0, min(words.count - 3, 40)) {
            let window = Array(words[i..<(i + 3)])
            let score = window.reduce(0) { $0 + $1.count }
            if score > bestScore { best = window; bestScore = score }
        }
        return best.joined(separator: " ")
    }
}
