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

    /// Above this many matching documents a reference no longer singles out one matter.
    public static let maximumAnchoredVersions = 200

    public init(base: any Retriever, database: Database, evidence: EvidenceStore,
                scopedRecall: SourceScopedRetriever.ScopedRecall?) {
        self.base = base
        self.database = database
        self.evidence = evidence
        self.scopedRecall = scopedRecall
    }

    public func retrieve(for intent: UserIntent, layers: [RetrievalLayer]) async throws -> RetrievalResult {
        guard let scope = await anchorScope(for: intent.rawQuestion) else {
            return try await base.retrieve(for: intent, layers: layers)
        }
        return try await SourceScopedRetriever(base: base, evidence: evidence, scope: scope, scopedRecall: scopedRecall)
            .retrieve(for: intent, layers: layers)
    }

    public func retrieve(for intent: UserIntent, layers: [RetrievalLayer],
                         access: SensitiveAccessContext) async throws -> AuthorizedRetrievalResult {
        guard let scope = await anchorScope(for: intent.rawQuestion) else {
            return try await base.retrieve(for: intent, layers: layers, access: access)
        }
        return try await SourceScopedRetriever(base: base, evidence: evidence, scope: scope, scopedRecall: scopedRecall)
            .retrieve(for: intent, layers: layers, access: access)
    }

    /// The scope the question's references single out, or nil to retrieve unanchored.
    func anchorScope(for question: String) async -> RetrievalSourceScope? {
        let tokens = AbsentSubjectGate.candidateTokens(in: question)
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

    /// Current source versions whose text contains `token` (case-insensitive), at most
    /// maximumAnchoredVersions + 1; nil when the lookup fails.
    static func sourceVersions(containing token: String, database: Database) async -> Set<UUID>? {
        let needle = "%\(token.lowercased())%"
        let sql = """
        SELECT DISTINCT COALESCE(c.source_version_id, eb.source_version_id) AS v FROM chunks c
        LEFT JOIN evidence_blocks eb ON eb.id = c.evidence_block_id
        WHERE LOWER(c.text) LIKE ? AND COALESCE(c.source_version_id, eb.source_version_id) IS NOT NULL
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
