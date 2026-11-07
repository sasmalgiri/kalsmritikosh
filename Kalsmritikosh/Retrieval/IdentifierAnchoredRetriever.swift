//
//  IdentifierAnchoredRetriever.swift
//  Kalsmritikosh
//
//  When a question names a specific reference that IS in the archive — a case number, a docket,
//  a complaint or inspection number — the evidence for the answer comes from the documents that
//  carry that reference.
//
//  FOUND BY THE CASE BENCH, 2026-10-18. Asked "Where did the NTSB SEA08LA057 accident happen?"
//  over an archive of 500 accident investigations, retrieval ranked the question's SHAPE
//  ("where", "accident", "happen") and answered from other investigations' narratives, with
//  citations — on 500-case ledgers only about a quarter of date and cause answers came from the
//  case that was asked about. Ranking cannot fix this: every investigation reads like every
//  other one. What singles out the right documents is the reference the user typed.
//
//  How. The question's reference-shaped tokens (the AbsentSubjectGate's rule — the gate has
//  already refused any that are absent) are looked up in the archive's text; the source versions
//  that contain them become a retrieval scope, enforced by the existing SourceScopedRetriever —
//  scope inside every lane's candidate query, fail-closed on corrective re-retrievals, the same
//  machinery as case-scoped Ask. A persona-neutral, format-neutral decorator: it reads only the
//  question and the ledger's text.
//
//  When it stays out of the way: no reference in the question; a reference matched by more than
//  `maximumAnchoredVersions` documents (not specific enough to single anything out — "the 2023
//  annual report" style); or a lookup that fails (logged, never read as "nothing matched").
//

import Foundation
import os

public actor IdentifierAnchoredRetriever: Retriever {
    private let base: any Retriever
    private let database: Database
    private let evidence: EvidenceStore
    private let scopedRecall: SourceScopedRetriever.ScopedRecall?
    /// Re-attaches facts to the final scoped result (see HybridRetriever.attachingFacts).
    private let attachFacts: (@Sendable (RetrievalResult) async -> RetrievalResult)?

    /// Above this many matching documents a reference no longer singles out one matter.
    public static let maximumAnchoredVersions = 200

    public init(base: any Retriever, database: Database, evidence: EvidenceStore,
                scopedRecall: SourceScopedRetriever.ScopedRecall?,
                attachFacts: (@Sendable (RetrievalResult) async -> RetrievalResult)? = nil) {
        self.base = base
        self.database = database
        self.evidence = evidence
        self.scopedRecall = scopedRecall
        self.attachFacts = attachFacts
    }

    public func retrieve(for intent: UserIntent, layers: [RetrievalLayer]) async throws -> RetrievalResult {
        guard let scope = await anchorScope(for: intent.rawQuestion) else {
            return try await base.retrieve(for: intent, layers: layers)
        }
        let scoped = try await SourceScopedRetriever(base: base, evidence: evidence, scope: scope, scopedRecall: scopedRecall)
            .retrieve(for: intent, layers: layers)
        let whole = await withWholeSmallScope(scoped, scope: scope)
        return await attachFacts?(whole) ?? whole
    }

    /// A small anchored scope (one named matter) contributes ALL its documents' passages, at the
    /// lowest score, so every document's facts can ride the answer. Case bench 2026-10-18: the
    /// NTSB report page stating "Date & time: January 17, 2008" was in scope but never surfaced,
    /// so its date fact never reached "When did the accident happen?".
    static let wholeScopeLimit = 12

    func withWholeSmallScope(_ result: RetrievalResult, scope: RetrievalSourceScope) async -> RetrievalResult {
        let versions = scope.authorizedSourceVersionIDs
        guard let chunksRepo = scopedRecall?.chunks, !versions.isEmpty, versions.count <= Self.wholeScopeLimit else { return result }
        let have = Set(result.chunks.map(\.chunk.id))
        guard let ids = try? await chunksRepo.chunkIDs(sourceVersionIDs: versions, limit: 120) else { return result }
        let missing = ids.filter { !have.contains($0) }
        guard !missing.isEmpty, let fetched = try? await chunksRepo.findByIDs(missing, sourceVersionIDs: versions) else { return result }
        return RetrievalResult(
            chunks: result.chunks + fetched.map { RetrievedChunk(chunk: $0, score: 0, viaLayer: .metadata) },
            events: result.events, entities: result.entities, relationships: result.relationships,
            summaries: result.summaries, layersUsed: result.layersUsed, shortCircuitedAt: result.shortCircuitedAt,
            walkSteps: result.walkSteps, genericFacts: result.genericFacts, claimEvaluations: result.claimEvaluations,
            authorityObjectIDs: result.authorityObjectIDs)
    }

    public func retrieve(for intent: UserIntent, layers: [RetrievalLayer],
                         access: SensitiveAccessContext) async throws -> AuthorizedRetrievalResult {
        guard let scope = await anchorScope(for: intent.rawQuestion) else {
            return try await base.retrieve(for: intent, layers: layers, access: access)
        }
        let scoped = try await SourceScopedRetriever(base: base, evidence: evidence, scope: scope, scopedRecall: scopedRecall)
            .retrieve(for: intent, layers: layers, access: access)
        let whole = await withWholeSmallScope(scoped.result, scope: scope)
        return AuthorizedRetrievalResult(
            result: await attachFacts?(whole) ?? whole, accessContext: scoped.accessContext,
            withheldChunkCount: scoped.withheldChunkCount, withheldEventCount: scoped.withheldEventCount,
            withheldEntityCount: scoped.withheldEntityCount, withheldSummaryCount: scoped.withheldSummaryCount,
            withheldRelationshipCount: scoped.withheldRelationshipCount)
    }

    /// The scope the question's references single out, or nil to retrieve unanchored.
    func anchorScope(for question: String) async -> RetrievalSourceScope? {
        // References, and named cases written as their caption ("Great Oregon v. Babbitt" is
        // looked up as "oregon v. babbitt", "oregon v babbitt" and "oregon vs. babbitt").
        var tokens = AbsentSubjectGate.candidateTokens(in: question)
        var captions: [String] = []
        for c in AbsentSubjectGate.captionCores(in: question) {
            // "Hertz Corp. v. City …" — an abbreviated party keeps its period before "v.".
            for v in ["v.", "v", "vs."] {
                captions += ["\(c.left) \(v) \(c.right)", "\(c.left). \(v) \(c.right)", "\(c.left), \(v) \(c.right)"]
            }
        }
        // "In re Kehl" / "Matter of Smith" name a one-party case (case bench 2026-10-20: these
        // went unanchored, so the answer listed every opinion author in the archive).
        captions += Self.oneSidedCaptions(in: question)
        // A matter named by its quoted title — "What happened in the case "Patriot Coal to Pay
        // $6.5 Million …"?" (case bench 2026-10-21: unanchored, so the answer was a history of
        // three other cases in the archive).
        captions += Self.quotedTitles(in: question)
        // A caption is CITED by every later decision that relies on the case, so the documents
        // that OPEN with it — the decision itself — are preferred over those that merely cite
        // it (case bench 2026-10-18: a cited caption pulled another decision's "affirmed" into
        // the answer). Citing documents are used only when no document opens with it.
        if !captions.isEmpty {
            var opening = Set<UUID>()
            for caption in captions {
                guard let found = await Self.sourceVersions(containing: caption, database: database, openingOnly: true) else { break }
                opening.formUnion(found)
            }
            if !opening.isEmpty, opening.count <= Self.maximumAnchoredVersions, tokens.isEmpty {
                KalsmritikoshLog.brain.info("IdentifierAnchoredRetriever: caption anchored to \(opening.count, privacy: .public) opening document(s)")
                return .authorizing(opening)
            }
            tokens += captions
        }
        guard !tokens.isEmpty else { return nil }
        var versions = Set<UUID>()
        for token in tokens {
            guard let found = await Self.sourceVersions(containing: token, database: database) else { return nil }
            versions.formUnion(found)
            if versions.count > Self.maximumAnchoredVersions { return nil }
        }
        guard !versions.isEmpty else { return nil }
        KalsmritikoshLog.brain.info("IdentifierAnchoredRetriever: question anchored to \(versions.count, privacy: .public) source version(s)")
        return .authorizing(versions)
    }

    /// "In re Kehl", "In the Matter of Smith", "Ex parte Jones" → the caption's opening words,
    /// with the first party name ("in re kehl"). Matched only against a document's first line.
    nonisolated static func oneSidedCaptions(in question: String) -> [String] {
        let pattern = #"\b(In re|In the Matter of|Matter of|Ex parte|Estate of)\s+([A-Z][A-Za-z'&\-]*[A-Za-z])"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = question as NSString
        return re.matches(in: question, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            let name = ns.substring(with: m.range(at: 2))
            return name.count >= 2 ? "\(ns.substring(with: m.range(at: 1))) \(name)".lowercased() : nil
        }
    }

    /// Quoted phrases of at least four words — a document named by its title. Lower-cased,
    /// straight and curly quotes alike.
    nonisolated static func quotedTitles(in question: String) -> [String] {
        let pattern = #"["“”]([^"“”]{12,220})["“”]"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = question as NSString
        let quoted: [String] = re.matches(in: question, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            let t = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            return t.split(separator: " ").count >= 4 ? t.lowercased() : nil
        }
        if !quoted.isEmpty { return quoted }
        // Unquoted, a headline still reads as one: "Summarize the case Alabama Woman Pleads Guilty
        // to Stealing Over $700,000 From Her Employer" — the words after "the case" / "the release
        // (about)", most of them capitalised (wide case bench 2026-10-25).
        guard let r = question.range(of: #"(?i)\bthe (?:case|release|press release)(?: about| titled| named)?\s+(.{12,220}?)[.?!]?\s*$"#,
                                     options: .regularExpression) else { return [] }
        let tail = String(question[r]).replacingOccurrences(of: #"(?i)^the (?:case|release|press release)(?: about| titled| named)?\s+"#,
                                                            with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " .?!"))
        let words = tail.split(separator: " ")
        guard words.count >= 4 else { return [] }
        let capitalised = words.filter { $0.first.map { $0.isUppercase || $0.isNumber || $0 == "$" } ?? false }.count
        return Double(capitalised) / Double(words.count) >= 0.6 ? [tail.lowercased()] : []
    }

    /// Current source versions whose text contains `token` (case-insensitive), at most
    /// maximumAnchoredVersions + 1; nil when the lookup fails.
    static func sourceVersions(containing token: String, database: Database, openingOnly: Bool = false) async -> Set<UUID>? {
        let needle = "%\(token.lowercased())%"
        // openingOnly: the FIRST LINE of the document's first chunk — its title / caption line.
        let sql = """
        SELECT DISTINCT COALESCE(c.source_version_id, eb.source_version_id) AS v FROM chunks c
        LEFT JOIN evidence_blocks eb ON eb.id = c.evidence_block_id
        WHERE LOWER(\(openingOnly ? "substr(c.text, 1, CASE WHEN instr(c.text, char(10)) > 0 THEN instr(c.text, char(10)) ELSE 300 END)" : "REPLACE(c.text, char(10), ' ')")) LIKE ? \(openingOnly ? "AND c.ordinal = 0" : "")
          AND COALESCE(c.source_version_id, eb.source_version_id) IS NOT NULL
        LIMIT \(maximumAnchoredVersions + 1);
        """
        do {
            let rows = try await database.query(sql, [.text(needle)])
            return Set(rows.compactMap { $0.uuid(0) })
        } catch {
            KalsmritikoshLog.brain.error("IdentifierAnchoredRetriever: lookup failed; answering unanchored: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
